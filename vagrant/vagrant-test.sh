#!/usr/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname $0)"
# common.sh is copied from the systemd-centos-ci/agent directory by vagrant-builder.sh
. "$SCRIPT_DIR/logging.sh" "vagrant-$DISTRO-testsuite" || exit 1

cd /build

# Run the internal unit tests (make check)
# Temporarily disable test-exec-privatenetwork
sed -i 's/test_exec_privatenetwork,//' src/test/test-execute.c
exectask "ninja test (make check)" "ninja-test.log" "ninja -C build test"

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-02-CRYPTSETUP" # flaky test (https://github.com/systemd/systemd/issues/10093)
    "test/TEST-10-ISSUE-2467" # https://github.com/systemd/systemd/pull/7494#discussion_r155635695
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

for t in test/TEST-??-*; do
    if [[ " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi

    rm -fr /var/tmp/systemd-test*

    ## Configure test environment
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export NSPAWN_TIMEOUT=600
    # Disable QEMU tests as we don't want to use nested virtualization (yet)
    export TEST_NO_QEMU=yes

    exectask "$t" "${t##*/}.log" "make -C $t clean setup run clean-again"
    # Each integration test dumps the system journal when something breaks
    [ -d /var/tmp/systemd-test*/journal ] && rsync -aq /var/tmp/systemd-test*/journal "$LOGDIR/${t##*/}"
done

## Other integration tests ##
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

[ -d /build/build/meson-logs ] && cp -r /build/build/meson-logs "$LOGDIR"
exectask "Dump system journal" "journalctl-testsuite.log" "journalctl -b --no-pager"

exit $FAILED
