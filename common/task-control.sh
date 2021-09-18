#!/usr/bin/bash

set -u
set -o pipefail

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
# Default number of retries for exectask_retry()
declare -ri EXECTASK_RETRY_DEFAULT=3
# Try to determine the optimal values for parallel execution using the nproc
# utility. If that fails, fall back to using default values for necessary
# variables.
if NPROC=$(nproc); then
    OPTIMAL_QEMU_SMP=4
    MAX_QUEUE_SIZE=$((NPROC / OPTIMAL_QEMU_SMP))
    if [[ $MAX_QUEUE_SIZE -lt 1 ]]; then
        # We have enough CPUs for only one concurrent task
        OPTIMAL_QEMU_SMP=1
        MAX_QUEUE_SIZE=1
    fi
else
    # Using nproc failed, let's fall back to defaults, which can be overridden
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
    local PID="${1:?Missing PID}"
    local EC
    SECONDS=0

    echo "Waiting for PID $PID to finish"
    while kill -0 "$PID" 2>/dev/null; do
        if ((SECONDS % 10 == 0)); then
            echo -n "."
        fi
        sleep 1
    done

    wait "$PID"
    EC=$?

    echo
    echo "PID $PID finished with EC $EC in ${SECONDS}s"

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
    local TASK_EC="${1:?Missing task exit code}"
    local TASK_LOGFILE="${2:?Missing task log file}"
    local TASK_NAME="${3:?Missing task name}"
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
    local TASK_NAME="${1:?Missing task name}"
    local TASK_COMAMND="${2:?Missing task command}"
    local IGNORE_EC="${3:-0}"
    local LOGFILE="$LOGDIR/$TASK_NAME.log"
    touch "$LOGFILE"

    echo "[TASK] $TASK_NAME ($TASK_COMAMND)"
    echo "[TASK START] $(date)" >>"$LOGFILE"

    # shellcheck disable=SC2086
    eval $TASK_COMAMND &>>"$LOGFILE" &
    local PID=$!
    waitforpid $PID
    local EC=$?
    echo "[TASK END] $(date)" >>"$LOGFILE"

    printresult $EC "$LOGFILE" "$TASK_NAME" "$IGNORE_EC"
    echo

    return $EC
}

# Execute given task "silently" and retry it n-times in case the task fails:
#   - redirect stdout/stderr to a given log file
#   - show a simple progress "bar"
#   - dump the log on error
#   - retry the task up to n times in case it fails
# Esentially the same function as exectask(), but for flaky tests.
#
# Arguments
#   $1 - task name
#   $2 - task command
#   $3 - # of retries (default: 3) [optional]
exectask_retry() {
    local TASK_NAME="${1:?Missing task name}"
    local TASK_COMMAND="${2:?Missing task command}"
    local RETRIES="${3:-$EXECTASK_RETRY_DEFAULT}"
    local EC=0
    local ORIG_TESTDIR

    for ((i = 1; i <= RETRIES; i++)); do
        local logfile="$LOGDIR/${TASK_NAME}_${i}.log"
        local pid

        touch "$logfile"

        echo "[TASK] $TASK_NAME ($TASK_COMMAND) [try $i/$RETRIES]"
        echo "[TASK START] $(date)" >>"$logfile"

        # Suffix the $TESTDIR for each retry by its index if requested
        if [[ -v MANGLE_TESTDIR && "$MANGLE_TESTDIR" -ne 0 ]]; then
            ORIG_TESTDIR="${ORIG_TESTDIR:-$TESTDIR}"
            export TESTDIR="${ORIG_TESTDIR}_${i}"
            mkdir -p "$TESTDIR"
            rm -f "$TESTDIR/pass"
        fi

        # shellcheck disable=SC2086
        eval $TASK_COMMAND &>>"$logfile" &
        pid=$!
        waitforpid $pid
        EC=$?
        echo "[TASK END] $(date)" >>"$logfile"

        if [[ $EC -eq 0 ]]; then
            # Task passed => report the result & bail out early
            printresult $EC "$logfile" "$TASK_NAME" 0
            echo
            break
        else
            # Task failed => check if we still have retries left. If so, report
            # the result as "ignored" and continue to the next retry. Otherwise,
            # report the result as failed.
            printresult $EC "$logfile" "$TASK_NAME" $((i < RETRIES))
            echo
        fi
    done

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
    local TASK_NAME="${1:?Missing task name}"
    local TASK_COMMAND="${2:?Missing task command}"
    local LOGFILE="$LOGDIR/$TASK_NAME.log"
    touch "$LOGFILE"

    echo "[PARALLEL TASK] $TASK_NAME ($TASK_COMMAND)"
    echo "[TASK START] $(date)" >>"$LOGFILE"

    while [[ ${#TASK_QUEUE[@]} -ge $MAX_QUEUE_SIZE ]]; do
        for key in "${!TASK_QUEUE[@]}"; do
            if ! kill -0 "${TASK_QUEUE[$key]}" &>/dev/null; then
                # Task has finished, report its result and drop it from the queue
                wait "${TASK_QUEUE[$key]}"
                ec=$?
                logfile="$LOGDIR/$key.log"
                echo "[TASK END] $(date)" >>"$logfile"
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
    eval $TASK_COMMAND &>>"$LOGFILE" &
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
        echo "[TASK END] $(date)" >>"$logfile"
        printresult $ec "$logfile" "$key"
        unset "TASK_QUEUE[$key]"
    done
}
