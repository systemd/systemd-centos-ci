#!/usr/bin/bash

. "$(dirname "$0")/../common/logging.sh" "testsuite-logs" || exit 1

# EXIT signal handler
function at_exit {
    set +e
    exectask "Dump system journal" "journalctl-testsuite.log" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -e

# Install test dependencies
exectask "Install test dependencies" "yum-depinstall.log" \
    "yum -y install net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm python-enum34"

set +e

### TEST PHASE ###
cd systemd-rhel

# Run the internal unit tests (make check)
exectask "make check" "make-check.log" "make check"
if [[ -f "test-suite.log" ]]; then
    cat test-suite.log
    exectask "make check (full log)" "make-check-full.log" "cat test-suite.log"
fi

## Integration test suite ##

[ ! -f /usr/bin/qemu-kvm ] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

for t in test/TEST-??-*; do
    if [[ " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi

    rm -fr /var/tmp/systemd-test*

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    export INITRD="/boot/initramfs-$(uname -r).img"
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="user_namespace.enable=1"
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    export NSPAWN_TIMEOUT=600

    exectask "$t" "${t##*/}.log" "make -C $t clean setup run"
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

exit $FAILED
