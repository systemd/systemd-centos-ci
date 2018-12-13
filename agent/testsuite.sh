#!/usr/bin/bash

. "$(dirname "$0")/common.sh" "testsuite-logs" || exit 1

# EXIT signal handler
function at_exit {
    set +e
    exectask "Dump system journal" "journalctl.log" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -e

if [ ! -f /usr/bin/ninja ]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

# Install test dependencies
exectask "Install test dependencies" "yum-depinstall.log" \
    "yum -y install net-tools strace nc busybox e2fsprogs quota dnsmasq"

set +e

### TEST PHASE ###
cd systemd

# Run the internal unit tests (make check)
# Temporarily disable test-exec-privatenetwork
sed -i 's/test_exec_privatenetwork,//' src/test/test-execute.c
exectask "ninja test (make check)" "ninja-test.log" "ninja -C build test"

# Run the internal integration testsuite
INITRD_PATH="/boot/initramfs-$(uname -r).img"
KERNEL_PATH="/boot/vmlinuz-$(uname -r)"
SKIP_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT"
)

for t in test/TEST-??-*; do
    if [[ " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi
    exectask "$t" "${t##*/}.log" "make -C $t clean setup run clean-again INITRD=$INITRD_PATH KERNEL_BIN=$KERNEL_PATH"
done

# Other integration tests
TEST_LIST=(
    "test/test-exec-deserialization.py"
#    "test/test-network/systemd-networkd-tests.py"
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
