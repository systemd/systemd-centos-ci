#!/usr/bin/bash

. "$(dirname "$0")/../common/task-control.sh" "testsuite-logs-upstream" || exit 1

# EXIT signal handler
function at_exit {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
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


# If a pre-testsuite script exists in the root of the systemd repo, source it
test -e .centosci-pre-testsuite && source .centosci-pre-testsuite

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

[[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 && " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    export INITRD="${INITRD:-/boot/initramfs-$(uname -r).img}"
    export KERNEL_BIN="${INITRD:-/boot/vmlinuz-$(uname -r)}"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="${KERNEL_APPEND:-user_namespace.enable=1}"
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=${QEMU_TIMEOUT:-600}
    export NSPAWN_TIMEOUT=${NSPAWN_TIMEOUT:-600}
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    rm -fr "$TESTDIR"
    mkdir -p "$TESTDIR"

    exectask_p "${t##*/}" "make -C $t clean setup run clean-again"
done

# Wait for remaining running tasks
exectask_p_finish

# Save journals created by integration tests
for t in test/TEST-??-*; do
    if [[ -d /var/tmp/systemd-test-${t##*/}/journal ]]; then
        rsync -aq "/var/tmp/systemd-test-${t##*/}/journal" "$LOGDIR/${t##*/}"
    fi
done

## Other integration tests ##
TEST_LIST=(
    "test/test-exec-deserialization.py"
    "test/test-network/systemd-networkd-tests.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask "${t##*/}" "timeout 30m ./$t"
done

# If a post-testsuite script exists in the root of the systemd repo, source it
test -e .centosci-post-testsuite && source .centosci-post-testsuite

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
