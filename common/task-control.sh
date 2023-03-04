#!/usr/bin/bash

set -u
set -o pipefail

# Internal logging helpers which make use of the internal call stack to get
# the function name of the caller
_log() { echo "[${FUNCNAME[1]}] $1"; }
_err() { echo >&2 "[${FUNCNAME[1]}] $1"; }
_echo() { [[ "${TASK_LOG_LEVEL:-1}" -ne 0 ]] && echo "$@"; }

if [[ -n "$1" ]]; then
    LOGDIR="$(mktemp -d "$PWD/$1.XXX")"
else
    LOGDIR="$(mktemp -d "$PWD/testsuite-logs.XXX")"
fi
declare -r LOGDIR

# We need to use files to track the passed/failed tasks, as in certain cases
# we use subprocesses which can't modify variables in the parent process
declare -r PASSED_TASKS_STATE="$LOGDIR/.passed_tasks"
declare -r FAILED_TASKS_STATE="$LOGDIR/.failed_tasks"
# Initialize the state files
: >"$PASSED_TASKS_STATE"
: >"$FAILED_TASKS_STATE"
# Variables for parallel tasks
declare -A TASK_QUEUE=()
# Default number of retries for exectask_retry()
declare -ri TASK_RETRY_DEFAULT=3
# Try to determine the optimal values for parallel execution using the nproc
# utility. If that fails, fall back to using default values for necessary
# variables.
if NPROC=$(nproc); then
    # Workaround: in case of EC2 machines the hypervisor might start stealing
    #             our CPU time once the region we run in gets under heavy load.
    #             This makes the tests run longer (in the better case) or timeout
    #             unexpectedly. Let's attempt to lessen the impact in such situations
    #             by keeping some CPUs "free" in hopes that when the "stealing"
    #             begins we will have some spare resources to distribute the load to.
    if [[ "$(uname -m)" == "x86_64" && "$(systemd-detect-virt -v)" == "xen" ]]; then
        NPROC=$((NPROC - 2))
        echo "[TASK-CONTROL] Reducing the # of usable CPUs from $(nproc) to $NPROC"
    fi

    OPTIMAL_QEMU_SMP=2
    MAX_QUEUE_SIZE=$((NPROC / OPTIMAL_QEMU_SMP))
    if [[ $MAX_QUEUE_SIZE -lt 1 ]]; then
        # We have enough CPUs for only one concurrent task
        OPTIMAL_QEMU_SMP=$NPROC
        MAX_QUEUE_SIZE=1
    elif [[ $MAX_QUEUE_SIZE -gt 4 ]]; then
        # Cap the max # of parallel jobs, otherwise we start hitting I/O limits
        # causing unexpected test fails
        MAX_QUEUE_SIZE=4
        OPTIMAL_QEMU_SMP=$((NPROC / MAX_QUEUE_SIZE))
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
    local pid="${1:?Missing PID}"
    local counter=0
    local ec
    SECONDS=0

    _echo "Waiting for PID $pid to finish"
    while kill -0 "$pid" 2>/dev/null; do
        if ((counter++ % 100 == 0)); then
            _echo -n "."
        fi
        sleep .1
    done

    wait "$pid"
    ec=$?

    _echo
    _echo "PID $pid finished with EC $ec in ${SECONDS}s"

    return $ec
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
    local task_ec="${1:?Missing task exit code}"
    local task_logfile="${2:?Missing task log file}"
    local task_name="${3:?Missing task name}"
    local ignore_ec="${4:-0}"
    # Let's rename the target log file according to the test result (PASS/FAIL)
    local logfile_base="${task_logfile%.*}" # Log file path without the extension
    local logfile_ext="${task_logfile##*.}" # Log file extension without the leading dot
    local new_logfile

    # Determine the log's new name
    if [[ $task_ec -eq 0 ]]; then
        new_logfile="${logfile_base}_PASS.${logfile_ext}"
    else
        new_logfile="${logfile_base}_FAIL.${logfile_ext}"
    fi

    # Attempt to rename the log file. If we don't succeed, continue with the old one
    if mv "$task_logfile" "$new_logfile"; then
        task_logfile="$new_logfile"
    else
        _err "Log rename failed"
    fi

    # Don't update internal counters if we want to ignore task's EC
    if [[ $ignore_ec -eq 0 ]]; then
        if [[ $task_ec -eq 0 ]]; then
            echo "$task_name" >>"$PASSED_TASKS_STATE"
            echo "[RESULT] $task_name - PASS (log file: $task_logfile)"
        else
            cat "$task_logfile"
            echo "$task_name" >>"$FAILED_TASKS_STATE"
            echo "[RESULT] $task_name - FAIL (EC: $task_ec) (log file: $task_logfile)"
        fi
    else
        echo "[IGNORED RESULT] $task_name - EC: $task_ec (log file: $task_logfile)"
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
    local task_name="${1:?Missing task name}"
    local task_command="${2:?Missing task command}"
    local ignore_ec="${3:-0}"
    local logfile="$LOGDIR/$task_name.log"
    touch "$logfile"

    echo "[TASK] $task_name ($task_command)"
    echo "[TASK START] $(date)" >>"$logfile"

    # shellcheck disable=SC2086
    eval $task_command &>>"$logfile" &
    local pid=$!
    waitforpid $pid
    local ec=$?
    echo "[TASK END] $(date)" >>"$logfile"

    printresult $ec "$logfile" "$task_name" "$ignore_ec"
    echo

    return $ec
}

# Execute given task "silently" and retry it n-times in case the task fails:
#   - redirect stdout/stderr to a given log file
#   - show a simple progress "bar"
#   - dump the log on error
#   - retry the task up to n times in case it fails
# Essentially the same function as exectask(), but for flaky tests.
#
# Arguments
#   $1 - task name
#   $2 - task command
#   $3 - # of retries (default: 3) [optional]
exectask_retry() {
    local task_name="${1:?Missing task name}"
    local task_command="${2:?Missing task command}"
    local retries="${3:-$TASK_RETRY_DEFAULT}"
    local ec=0
    local orig_testdir

    for ((i = 1; i <= retries; i++)); do
        local logfile="$LOGDIR/${task_name}_${i}.log"
        local pid

        touch "$logfile"

        echo "[TASK] $task_name ($task_command) [try $i/$retries]"
        echo "[TASK START] $(date)" >>"$logfile"

        # Make sure each retry has a unique state dir ($TESTDIR) and container
        # name (passed in $NSPAWN_ARGUMENTS), so we don't overwrite results
        # of previous retries or die because of a name clash.
        # Note: this is relevant only for the integration tests (test/TEST-??-*)
        if [[ "${MANGLE_TESTDIR:-0}" -ne 0 ]]; then
            # Suffix the $TESTDIR for each retry by its index if requested
            orig_testdir="${orig_testdir:-$TESTDIR}"
            export TESTDIR="${orig_testdir}_${i}"
            mkdir -p "$TESTDIR"
            rm -f "$TESTDIR/pass"

            # Also, set a unique name for each nspawn container to prevent scope clash
            export NSPAWN_ARGUMENTS="--machine=${task_name}--${i}"
        fi

        # shellcheck disable=SC2086
        eval $task_command &>>"$logfile" &
        pid=$!
        waitforpid $pid
        ec=$?
        echo "[TASK END] $(date)" >>"$logfile"

        if [[ $ec -eq 0 ]]; then
            # Task passed => report the result & bail out early
            printresult $ec "$logfile" "$task_name" 0
            echo
            break
        else
            # Task failed => check if we still have retries left. If so, report
            # the result as "ignored" and continue to the next retry. Otherwise,
            # report the result as failed.
            printresult $ec "$logfile" "$task_name" $((i < retries))
            echo
        fi
    done

    return $ec
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
    local task_name="${1:?Missing task name}"
    local task_command="${2:?Missing task command}"
    local key

    while [[ ${#TASK_QUEUE[@]} -ge $MAX_QUEUE_SIZE ]]; do
        for key in "${!TASK_QUEUE[@]}"; do
            if ! kill -0 "${TASK_QUEUE[$key]}" &>/dev/null; then
                # Task has finished, drop it from the queue
                wait "${TASK_QUEUE[$key]}"
                unset "TASK_QUEUE[$key]"
                # Break from inner for loop and outer while loop to skip
                # the sleep below when we find a free slot in the queue
                break 2
            fi
        done

        # Precisely* calculated constant to keep the spinlock from burning the CPU(s)
        sleep 0.01
    done

    TASK_LOG_LEVEL=0 exectask "$task_name" "$task_command" &
    TASK_QUEUE[$task_name]=$!

    return 0
}

# Execute given task in parallel fashion:
#   - redirect stdout/stderr to a given log file
#   - return after inserting the task into the queue (or wait until there's
#     a free spot)
#   - dump the log on error
# Arguments
#   $1 - task name
#   $2 - task command
#   $3 - # of retries (default: 3) [optional]
exectask_retry_p() {
    local task_name="${1:?Missing task name}"
    local task_command="${2:?Missing task command}"
    local retries="${3:-$TASK_RETRY_DEFAULT}"
    local key

    while [[ ${#TASK_QUEUE[@]} -ge $MAX_QUEUE_SIZE ]]; do
        for key in "${!TASK_QUEUE[@]}"; do
            if ! kill -0 "${TASK_QUEUE[$key]}" &>/dev/null; then
                # Task has finished, drop it from the queue
                wait "${TASK_QUEUE[$key]}"
                unset "TASK_QUEUE[$key]"
                # Break from inner for loop and outer while loop to skip
                # the sleep below when we find a free slot in the queue
                break 2
            fi
        done

        # Precisely* calculated constant to keep the spinlock from burning the CPU(s)
        sleep 0.01
    done

    TASK_LOG_LEVEL=0 exectask_retry "$task_name" "$task_command" "$retries" &
    TASK_QUEUE[$task_name]=$!

    return 0
}
# Wait for the remaining tasks in the parallel tasks queue
exectask_p_finish() {
    local key

    echo "[INFO] Waiting for remaining running parallel tasks"

    for key in "${!TASK_QUEUE[@]}"; do
        echo "[INFO] Waiting for task '$key' to finish..."
        wait "${TASK_QUEUE[$key]}"
        unset "TASK_QUEUE[$key]"
    done
}

# Show summary about executed tasks
show_task_summary() {
    local failed passed

    failed="$(wc -l <"$FAILED_TASKS_STATE")"
    passed="$(wc -l <"$PASSED_TASKS_STATE")"

    echo
    echo "TEST SUMMARY:"
    echo "-------------"
    echo "PASSED: $passed"
    echo "FAILED: $failed"
    echo "TOTAL:  $((passed + failed))"

    if [[ $failed -ne 0 ]]; then
        echo
        echo "FAILED TASKS:"
        echo "-------------"
        sort "$FAILED_TASKS_STATE"
    fi
}

finish_and_exit() {
    local failed

    failed="$(wc -l <"$FAILED_TASKS_STATE")" || exit 1
    [[ "$failed" -eq 0 ]] && exit 0 || exit 1
}
