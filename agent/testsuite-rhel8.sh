#!/usr/bin/bash

# The common/utils.sh include needs to come first, as it includes definition
# of print_cgroup_hierarchy()
. "$(dirname "$0")/../common/utils.sh" || exit 1
. "$(dirname "$0")/../common/task-control.sh" "testsuite-logs-$(print_cgroup_hierarchy)-rhel8" || exit 1

# EXIT signal handler
function at_exit {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -e -u

CGROUP_HIERARCHY="$(print_cgroup_hierarchy)"

echo "Current cgroup hierarchy: $CGROUP_HIERARCHY"
# Reflect the current cgroup hierarchy in each test VM
if [[ "$CGROUP_HIERARCHY" == unified ]]; then
    CGROUP_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=1 systemd.legacy_systemd_cgroup_controller=0"
else
    CGROUP_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=1"
fi

# To get meaningful results from coredumps collected from integration tests
# we need to store them in journal. This patchset is currently only in upcoming
# RHEL 8.3, see https://github.com/systemd-rhel/rhel-8/pull/85.
if grep -q "Storage=journal" systemd/test/test-functions; then
    COLLECT_COREDUMPS=1
else
    COLLECT_COREDUMPS=0
fi

# Enable systemd-coredump
if [[ $COLLECT_COREDUMPS -ne 0 ]] && ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

# Install test dependencies
exectask "dnf-depinstall" \
    "dnf -y install dnsmasq e2fsprogs gdb nc net-tools qemu-kvm quota socat strace wget"

# As busybox is not shipped in RHEL 8/CentOS 8 anymore, we need to get it
# using a different way. Needed by TEST-13-NSPAWN-SMOKE
exectask "install-busybox" \
    "wget -O /bin/busybox https://www.busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64 && chmod +x /bin/busybox"

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -aq "build/meson-logs" "$LOGDIR"

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

if [[ "$CGROUP_HIERARCHY" == "legacy" ]]; then
    # This test explicitly requires unified cgroup hierarchy
    SKIP_LIST=("test/TEST-19-DELEGATE")
fi

[[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

# Workaround for RHEL 8 (TEST-13-NSPAWN-SMOKE)
# Even though RHEL 8 supports cgroups v2, we can't run systemd-nspawn with
# unified cgroup hierarchy on it, as it still uses the legacy hierarchy.
# As the auto-detection checks only for cgroups v2 support and not which
# hierarchy is currently used on the host system, let's override the
# auto-detection completely and skip tests using the unified hierarchy.
sed -i 's/is_v2_supported=yes/is_v2_supported=no/g' test/TEST-13-NSPAWN-SMOKE/test.sh

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    export INITRD="/boot/initramfs-$(uname -r).img"
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="user_namespace.enable=1 $CGROUP_KERNEL_ARGS"
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    export NSPAWN_TIMEOUT=600
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    rm -fr "$TESTDIR"
    mkdir -p "$TESTDIR"

    exectask_p "${t##*/}" "make -C $t clean setup run && touch $TESTDIR/pass"
done

# Wait for remaining running tasks
exectask_p_finish

# Save journals created by integration tests
for t in test/TEST-??-*; do
    testdir="/var/tmp/systemd-test-${t##*/}"
    if [[ -d "$testdir/journal" ]]; then
        if [[ $COLLECT_COREDUMPS -ne 0 ]]; then
            # Attempt to collect coredumps from test-specific journals as well
            exectask "${t##*/}_coredumpctl_collect" "coredumpctl_collect '$testdir/journal'"
        fi
        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$testdir/pass" ]]; then
            rsync -aq "$testdir/journal" "$LOGDIR/${t##*/}"
        fi
    fi
done

## Other integration tests ##
TEST_LIST=(
    "test/test-exec-deserialization.py"
#    "test/test-network/systemd-networkd-tests.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask "${t##*/}" "./$t"
done

if [[ $COLLECT_COREDUMPS -ne 0 ]]; then
    # Collect coredumps using the coredumpctl utility, if any
    exectask "coredumpctl_collect" "coredumpctl_collect"
fi

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
