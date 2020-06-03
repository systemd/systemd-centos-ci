#!/usr/bin/bash

set -u

# Internal logging helpers which make use of the internal call stack to get
# the function name of the caller
_log() { echo "[${FUNCNAME[1]}] $1"; }
_err() { echo >&2 "[${FUNCNAME[1]}] $1"; }

if [[ -n "$1" ]]; then
    LOGDIR="$(mktemp -d "$PWD/$1.XXX")"
else
    LOGDIR="$(mktemp -d "$PWD/testsuite-logs.XXX")"
fi
PASSED=0
FAILED=0
FAILED_LIST=()
# Variables for parallel tasks
declare -A TASK_QUEUE=()
# Try to determine the optimal values for parallel execution using the nproc
# utility. If that fails, fall back to using default values for necessary
# variables.
if NPROC=$(nproc); then
    OPTIMAL_QEMU_SMP=2
    MAX_QUEUE_SIZE=$((NPROC / OPTIMAL_QEMU_SMP))
    if [[ $MAX_QUEUE_SIZE -lt 1 ]]; then
        # We have enough CPUs for only one concurrent task
        OPTIMAL_QEMU_SMP=1
        MAX_QUEUE_SIZE=1
    fi
else
    # Using nproc failed, let's fall back to defaults, which can be overriden
    # from the outside.
    MAX_QUEUE_SIZE=${MAX_QUEUE_SIZE:-1}
    OPTIMAL_QEMU_SMP=${OPTIMAL_QEMU_SMP:-1}
fi

echo "[TASK-CONTROL] OPTIMAL_QEMU_SMP = $OPTIMAL_QEMU_SMP"
echo "[TASK-CONTROL] MAX_QUEUE_SIZE = $MAX_QUEUE_SIZE"

# Active wait for PID to finish
#   - print '.' every 10 seconds
#   - return the exit code of the waited for process
# Arguments
#   - PID (must be a child of current shell)
waitforpid() {
    if [[ $# -lt 1 ]]; then
        _err "Missing argument: PID"
        return 1
    fi

    local EC
    SECONDS=0

    echo "Waiting for PID $1 to finish"
    while kill -0 "$1" 2>/dev/null; do
        if ((SECONDS % 10 == 0)); then
            echo -n "."
        fi
        sleep 1
    done

    wait "$1"
    EC=$?

    echo
    echo "PID $1 finished with EC $EC in ${SECONDS}s"

    return $EC
}

# Convert passed exit code to a "human readable" message
#   - EC == 0: PASS, FAIL otherwise
#   - rename the log file accordingly (PASS/FAIL suffix)
#   - update internal counters
#   - dump the passed log file in case of FAIL
# Arguments
#   $1 - exit code to process
#   $2 - path to log file "belonging" to the exit code
#   $3 - task name
#   $4 - ignore EC (i.e. don't update statistics with this task's results)
#        takes int (0: don't ignore, !0: ignore; default: 0) [optional]
printresult() {
    if [[ $# -lt 3 ]]; then
        _err "Missing arguments"
        return 1
    fi

    local TASK_EC="$1"
    local TASK_LOGFILE="$2"
    local TASK_NAME="$3"
    local IGNORE_EC="${4:-0}"
    # Let's rename the target log file according to the test result (PASS/FAIL)
    local LOGFILE_BASE="${TASK_LOGFILE%.*}" # Log file path without the extension
    local LOGFILE_EXT="${TASK_LOGFILE##*.}" # Log file extension without the leading dot
    local NEW_LOGFILE

    # Determine the log's new name
    if [[ $TASK_EC -eq 0 ]]; then
        NEW_LOGFILE="${LOGFILE_BASE}_PASS.${LOGFILE_EXT}"
    else
        NEW_LOGFILE="${LOGFILE_BASE}_FAIL.${LOGFILE_EXT}"
    fi

    # Attempt to rename the log file. If we don't succeed, continue with the old one
    if mv "$TASK_LOGFILE" "$NEW_LOGFILE"; then
        TASK_LOGFILE="$NEW_LOGFILE"
    else
        _err "Log rename failed"
    fi

    # Don't update internal counters if we want to ignore task's EC
    if [[ $IGNORE_EC -eq 0 ]]; then
        if [[ $TASK_EC -eq 0 ]]; then
            PASSED=$((PASSED + 1))
            echo "[RESULT] $TASK_NAME - PASS (log file: $TASK_LOGFILE)"
        else
            cat "$TASK_LOGFILE"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$TASK_NAME")
            echo "[RESULT] $TASK_NAME - FAIL (EC: $TASK_EC) (log file: $TASK_LOGFILE)"
        fi
    else
        echo "[IGNORED RESULT] $TASK_NAME - EC: $TASK_EC (log file: $TASK_LOGFILE)"
    fi
}

# Execute given task "silently":
#   - redirect stdout/stderr to a given log file
#   - show a simple progress "bar"
#   - dump the log on error
# Arguments
#   $1 - task name
#   $2 - task command
#   $3 - ignore EC (i.e. don't update statistics with this task's results)
#        takes int (0: don't ignore, !0: ignore; default: 0) [optional]
exectask() {
    if [[ $# -lt 2 ]]; then
        _err "Missing arguments"
        return 1
    fi

    local LOGFILE="$LOGDIR/$1.log"
    local IGNORE_EC="${3:-0}"
    touch "$LOGFILE"

    echo "[TASK] $1"
    echo "[TASK START] $(date)" >> "$LOGFILE"

    # shellcheck disable=SC2086
    eval $2 &>> "$LOGFILE" &
    local PID=$!
    waitforpid $PID
    local EC=$?
    echo "[TASK END] $(date)" >> "$LOGFILE"

    printresult $EC "$LOGFILE" "$1" "$IGNORE_EC"
    echo

    return $EC
}

# Execute given task in parallel fashion:
#   - redirect stdout/stderr to a given log file
#   - return after inserting the task into the queue (or wait until there's
#     a free spot)
#   - dump the log on error
# Arguments
#   $1 - task name
#   $2 - task command
exectask_p() {
    if [[ $# -lt 2 ]]; then
        _err "Missing arguments"
        return 1
    fi

    local TASK_NAME="$1"
    local TASK_COMMAND="$2"
    local LOGFILE="$LOGDIR/$TASK_NAME.log"
    touch "$LOGFILE"

    echo "[PARALLEL TASK] $TASK_NAME ($TASK_COMMAND)"
    echo "[TASK START] $(date)" >> "$LOGFILE"

    while [[ ${#TASK_QUEUE[@]} -ge $MAX_QUEUE_SIZE ]]; do
        for key in "${!TASK_QUEUE[@]}"; do
            if ! kill -0 "${TASK_QUEUE[$key]}" &>/dev/null; then
                # Task has finished, report its result and drop it from the queue
                wait "${TASK_QUEUE[$key]}"
                ec=$?
                logfile="$LOGDIR/$key.log"
                echo "[TASK END] $(date)" >> "$logfile"
                printresult $ec "$logfile" "$key"
                echo
                unset "TASK_QUEUE[$key]"
                # Break from inner for loop and outer while loop to skip
                # the sleep below when we find a free slot in the queue
                break 2
            fi
        done

        # Precisely* calculated constant to keep the spinlock from burning the CPU(s)
        sleep 0.01
    done

    # shellcheck disable=SC2086
    eval $TASK_COMMAND &>> "$LOGFILE" &
    TASK_QUEUE[$TASK_NAME]=$!

    return 0
}

# Wait for the remaining tasks in the parallel tasks queue
exectask_p_finish() {
    echo "[INFO] Waiting for remaining running parallel tasks"

    for key in "${!TASK_QUEUE[@]}"; do
        wait ${TASK_QUEUE[$key]}
        ec=$?
        logfile="$LOGDIR/$key.log"
        printresult $ec "$logfile" "$key"
        unset "TASK_QUEUE[$key]"
    done
}

# Initialize all specific images used by integration tests in one go so
# the tests could be run in parallel if needed.
#
# Arguments:
#   $1 - path to the local copy of system git repository
initialize_integration_tests() {
    # Breakdown:
    #  - grep all IMAGE_NAME= variable definitions from each test's setup script
    #    (TEST-*/test.sh) - this yields following output for each such file:
    #       test/TEST-14-MACHINE-ID/test.sh:IMAGE_NAME="badid"
    #  - sort the result by the second column separated by colon and show only
    #    lines with unique IMAGE_NAME= definitions (to initialize each image only
    #    once)
    #  - split the line into file and image name using comma as the delimiter
    #  - run the clean and setup phases for the respective test ($file minus
    #    the /test.sh part)
    #
    # Also, to make things more fast (and more complicated at the same time)
    # attempt to run the setup tasks in parallel. Since the current, ehm,
    # implementation of the parallel queue doesn't support nesting, this
    # function should not be executed when other tasks use it. That is not
    # an issue (as of right now), since the initialization runs before
    # integration tests which are currently the only users of the parallelization.
    if [[ $# -ne 1 ]]; then
        _err "Function takes exactly one argument: path to systemd git repository"
        return 1
    fi

    local EC=0
    local OLD_FAILED=$FAILED

    pushd "$1" || { _err "pushd failed"; return 1; }

    while read -r line; do
        file="${line%%:*}"
        image="${line#*:}"
        testdir="${file%/*}"
        testname="${testdir##*/}"

        if [[ ! -d "$testdir" ]]; then
            _err "Parsed path '$testdir' from '$file' is not a directory"
            EC=1
            break
        fi

        # Set the $TESTDIR to something predictable, as it's going to be reused
        # for test results as well, since we don't clean up the state directory
        # after setup. The same $TESTDIR format is then used in each test suite
        # script.
        export TESTDIR="/var/tmp/systemd-test-$testname"
        # Avoid creating symlinks to the base images
        export TEST_PARALLELIZE=1

        _log "Running setup for '$image' from '$file'"
        exectask_p "setup-$testname" "make -C '$testdir' clean setup"
    done < <(grep IMAGE_NAME= test/TEST-*/test.sh | sort -k 2 -t : -u)

    # Wait for remaining parallel tasks to complete
    exectask_p_finish

    # Compare the previously saved number of failed tasks in the parallel queue
    # with the current state to check if any of the setup tasks failed. As we
    # should be the only users of the parallel queue right now (see the comment
    # at the beginning of this function) it should reflect the correct state.
    if [[ $OLD_FAILED -ne $FAILED ]]; then
        _err "Some setup tasks failed:"
        for task in "${FAILED_LIST[@]}"; do
            echo "$task"
        done

        EC=1
    fi

    popd || { _err "popd failed"; return 1; }

    return $EC
}
