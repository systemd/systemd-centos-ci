#!/usr/bin/bash

. "$(dirname "$0")/../common/task-control.sh" "testsuite-logs-upstream" || exit 1

# EXIT signal handler
function at_exit {
    set +e
    exectask "journald-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -e -u

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

# Install test dependencies
exectask "yum-depinstall" \
    "yum -y install net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm socat"

set +e

### TEST PHASE ###
cd systemd

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"

## Other integration tests ##
TEST_LIST=(
    "test/test-network/systemd-networkd-tests.py"
)

set -e
for t in "${TEST_LIST[@]}"; do
    for ((i = 0; i < 100; i++)); do
        exectask "${t##*/}_$i" "timeout 30m ./$t"
    done
done

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"

if [[ ${#FAILED_LIST[@]} -ne 0 ]]; then
    echo
    echo "FAILED TASKS:"
    echo "-------------"
    for task in "${FAILED_LIST[@]}"; do
        echo "$task"
    done
fi

exit $FAILED
