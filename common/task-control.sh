#!/usr/bin/bash

if [ -n "$1" ]; then
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

# Active wait for PID to finish
#   - print '.' every 10 seconds
#   - return the exit code of the waited for process
# Arguments
#   - PID (must be a child of current shell)
waitforpid() {
    if [ $# -lt 1 ]; then
        echo >&2 "waitforpid: missing arguments"
        return 1
    fi

    local EC
    SECONDS=0

    echo "Waiting for PID $1 to finish"
    while kill -0 $1 2>/dev/null; do
        echo -n "."
        sleep 10
    done

    wait $1
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
printresult() {
    if [ $# -lt 3 ]; then
        echo >&2 "printresult: missing arguments"
        return 1
    fi

    local TASK_EC="$1"
    local TASK_LOGFILE="$2"
    local TASK_NAME="$3"
    # Let's rename the target log file according to the test result (PASS/FAIL)
    local LOGFILE_BASE="${TASK_LOGFILE%.*}" # Log file path without the extension
    local LOGFILE_EXT="${TASK_LOGFILE##*.}" # Log file extension without the leading dot
    local NEW_LOGFILE

    # Determine the log's new name
    if [ $TASK_EC -eq 0 ]; then
        NEW_LOGFILE="${LOGFILE_BASE}_PASS.${LOGFILE_EXT}"
    else
        NEW_LOGFILE="${LOGFILE_BASE}_FAIL.${LOGFILE_EXT}"
    fi

    # Attempt to rename the log file. If we don't succeed, continue with the old one
    if mv "$TASK_LOGFILE" "$NEW_LOGFILE"; then
        TASK_LOGFILE="$NEW_LOGFILE"
    else
        echo >&2 "printresult: log rename failed"
    fi

    if [[ $TASK_EC -eq 0 ]]; then
        PASSED=$((PASSED + 1))
        echo "[RESULT] $TASK_NAME - PASS (log file: $TASK_LOGFILE)"
    else
        cat "$TASK_LOGFILE"
        FAILED=$((FAILED + 1))
        FAILED_LIST+=("$TASK_NAME")
        echo "[RESULT] $TASK_NAME - FAIL (log file: $TASK_LOGFILE)"
    fi
}

# Execute given task "silently":
#   - redirect stdout/stderr to a given log file
#   - show a simple progress "bar"
#   - dump the log on error
# Arguments
#   $1 - task name
#   $2 - task command
exectask() {
    if [ $# -lt 2 ]; then
        echo >&2 "exectask: missing arguments"
        return 1
    fi

    local LOGFILE="$LOGDIR/$1.log"
    touch "$LOGFILE"

    echo -e "\n[TASK] $1"
    echo "[TASK START] $(date)" >> "$LOGFILE"

    if [ "$CI_DEBUG" ]; then
        $2
    else
        $2 &> "$LOGFILE" &
        local PID=$!
        waitforpid $PID
    fi
    local EC=$?
    echo "[TASK END] $(date)" >> "$LOGFILE"

    printresult $EC "$LOGFILE" "$1"

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
    if [ $# -lt 2 ]; then
        echo >&2 "exectask: missing arguments"
        return 1
    fi

    local TASK_NAME="$1"
    local TASK_COMMAND="$2"
    local LOGFILE="$LOGDIR/$TASK_NAME.log"
    touch "$LOGFILE"

    echo -e "\n[PARALLEL TASK] $TASK_NAME ($TASK_COMMAND)"
    echo "[TASK START] $(date)" >> "$LOGFILE"

    while [[ ${#TASK_QUEUE[@]} -ge $MAX_QUEUE_SIZE ]]; do
        for key in "${!TASK_QUEUE[@]}"; do
            if ! kill -0 ${TASK_QUEUE[$key]} &>/dev/null; then
                # Task has finished, report its result and drop it from the queue
                wait ${TASK_QUEUE[$key]}
                ec=$?
                logfile="$LOGDIR/$key.log"
                echo "[TASK END] $(date)" >> "$logfile"
                printresult $ec "$logfile" "$key"
                unset TASK_QUEUE["$key"]
                # Break from inner for loop and outer while loop to skip
                # the sleep below when we find a free slot in the queue
                break 2
            fi
        done

        # Precisely* calculated constant to keep the spinlock from burning the CPU(s)
        sleep 0.01
    done

    $TASK_COMMAND &> "$LOGFILE" &
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
        unset TASK_QUEUE["$key"]
    done
}
