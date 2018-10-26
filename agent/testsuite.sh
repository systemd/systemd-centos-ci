#!/usr/bin/sh

. "$(dirname $0)/common.sh" "testsuite-logs" || exit 1

### SETUP PHASE ###
# Exit on error in the setup phase
set -e

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
