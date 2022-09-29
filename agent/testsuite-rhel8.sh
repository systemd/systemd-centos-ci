#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# The common/utils.sh include needs to come first, as it includes definition
# of print_cgroup_hierarchy()
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-$(print_cgroup_hierarchy)-rhel8" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

set -eu
set -o pipefail

trap at_exit EXIT

### TEST PHASE ###
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

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# FIXME: test-journal-flush
# A particularly ugly workaround for the flaky test-journal-flush. As the issue
# presented so far only in the QEMU TEST-24, let's skip it just there, instead
# of disabling it completely (even in the `meson test`).
#
# See: systemd/systemd#17963
# shellcheck disable=SC2016
sed -i '/TEST_LIST=/aTEST_LIST=("${TEST_LIST[@]/\\/usr\\/lib\\/systemd\\/tests\\/test-journal-flush}")' test/TEST-24-UNIT-TESTS/testsuite.sh

# FIXME: test-barrier
# This test is flaky on systems under load, which happens intermittently due
# to how meson runs the tests (in parallel).
#
# See:
#   https://github.com/systemd/systemd/commit/fd23f9c9a70e1214507641d327da40d1688b74d7
#   https://github.com/systemd/systemd/commit/a1e3f0f38b43e68ff9ea33ab1935aed4edf6ed7f
echo 'int main(void) { return 77; }' > src/test/test-barrier.c

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -amq --include '*.txt' --include '*/' --exclude '*' "build/meson-logs" "$LOGDIR"

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

if [[ "$CGROUP_HIERARCHY" == "legacy" ]]; then
    # This test explicitly requires unified cgroup hierarchy
    SKIP_LIST+=("test/TEST-19-DELEGATE")
fi

[[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

## Generate a custom-tailored initrd for the integration tests
# The host initrd contains multipath modules & services which are unused
# in the integration tests and sometimes cause unexpected failures. Let's build
# a custom initrd used solely by the integration tests
#
# Set a path to the custom initrd into the INITRD variable which is read by
# the integration test suite "framework"
export INITRD="/var/tmp/ci-initramfs-$(uname -r).img"
# Copy over the original initrd, as we want to keep the custom installed
# files we installed during the bootstrap phase (i.e. we want to keep the
# command line arguments the original initrd was built with)
cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
# Rebuild the original initrd without the multipath module
dracut -o multipath --rebuild "$INITRD"

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    # See $INITRD above
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    export KERNEL_APPEND="$CGROUP_KERNEL_ARGS"
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
show_task_summary

finish_and_exit
