#!/usr/bin/sh

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

### SETUP PHASE ###
# Exit on error in the setup phase
set -e

LOGDIR="$(mktemp -d $PWD/testsuite-logs.XXX)"
PASSED=0
FAILED=0
FAILED_LIST=()

# Workaround for older ninja-build versions
if [ ! -f /usr/bin/ninja ]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

# Install test dependencies
exectask "Install test dependencies" "yum-depinstall.log" \
    "yum -y install net-tools strace nc busybox e2fsprogs quota net-tools strace"

set +e

### TEST PHASE ###
cd systemd

# Run the internal unit tests (make check)
exectask "ninja test (make check)" "ninja-test.log" "ninja -C build test"

# Run the internal integration testsuite
for t in test/TEST-??-*; do
    exectask "$t" "${t##*/}.log" "make -C $t clean setup run clean-again"
done

# Other integration tests
TEST_LIST=(
    "test/test-exec-deserialization.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask "$t" "${t##*/}.log" "./$t"
done

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"
echo
echo "FAILED TASKS:"
echo "-------------"
for task in "${FAILED_LIST[@]}"; do
    echo  "$task"
done

exit $FAILED
