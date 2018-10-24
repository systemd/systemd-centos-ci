#!/bin/bash

LOGDIR="$(mktemp -d $PWD/testsuite-logs.XXX)"
PASSED=0
FAILED=0
FAILED_LIST=()

# Workaround for older ninja-build versions
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

    echo "Waiting for PID $1 to finish"
    while kill -0 $1 2>/dev/null; do
        echo -n "."
        sleep 10
    done

    echo

    return $(wait $1)
}

# Convert passed exit code to a "human readable" message
#   - EC == 0: PASS, FAIL otherwise
#   - dump the passed log file in case of FAIL
# Arguments
#   $1 - exit code to process
#   $2 - path to log file "belonging" to the exit code
printresult() {
    if [ $# -lt 2 ]; then
        echo >&2 "printresult: missing arguments"
        return 1
    fi

    if [ $1 -eq 0 ]; then
        PASSED=$((PASSED + 1))
        echo "[RESULT] PASS (log file: $2)"
    else
        cat "$2"
        FAILED=$((FAILED + 1))
        echo "[RESULT] FAIL (log file: $2)"
    fi
}

# Execute given task "silently":
#   - redirect stdout/stderr to a given log file
#   - show a simple progress "bar"
#   - dump the log on error
# Arguments
#   $1 - task name
#   $2 - task logfile name
#   $3 - task command
exectask() {
    if [ $# -lt 3 ]; then
        echo >&2 "exectask: missing arguments"
        return 1
    fi

    echo -e "\n[TASK] $1"
    local LOGFILE="$LOGDIR/$2"
    $3 &> "$LOGFILE" &
    local PID=$!
    waitforpid $PID
    local EC=$?
    printresult $EC "$LOGFILE"

    if [ $EC -ne 0 ]; then
        FAILED_LIST+=("$1")
    fi

    return $EC
}
