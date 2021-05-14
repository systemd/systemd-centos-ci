#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# The common/utils.sh include needs to come first, as it includes definition
# of print_cgroup_hierarchy()
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-$(print_cgroup_hierarchy)-rhel9" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -eu
set -o pipefail

CGROUP_HIERARCHY="$(print_cgroup_hierarchy)"

echo "Current cgroup hierarchy: $CGROUP_HIERARCHY"
# Reflect the current cgroup hierarchy in each test VM
if [[ "$CGROUP_HIERARCHY" == unified ]]; then
    CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=1" "systemd.legacy_systemd_cgroup_controller=0")
else
    CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=0" "systemd.legacy_systemd_cgroup_controller=1")
fi

# Enable systemd-coredump
if ! coredumpctl_init; then
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

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# FIXME: test-journal-flush
# A particularly ugly workaround for the flaky test-journal-flush. As the issue
# presented so far only in the QEMU TEST-02, let's skip it just there, instead
# of disabling it completely (even in the `meson test`).
#
# See: systemd/systemd#17963
# shellcheck disable=SC2016
sed -i '/mapfile -t TEST_LIST/aTEST_LIST=("${TEST_LIST[@]/\\/usr\\/lib\\/systemd\\/tests\\/test-journal-flush}")' test/units/testsuite-02.sh

# FIXME: test-loop-block
# This test is flaky due to uevent mess, and requires a kernel change.
#
# See:
#   systemd/systemd#17469
#   systemd/systemd#18166
echo 'int main(void) { return 77; }' > src/test/test-loop-block.c

# FIXME: test-seccomp
# This test became flaky once again, so disable it temporarily until the reason
# is found out.
#
# See: systemd/systemd#17078
echo 'int main(void) { return 77; }' > src/test/test-seccomp.c

# Run the internal unit tests (make check)
# Note: All .dusty.* servers have Intel Xeon CPUs with 4 cores and HT enabled
#       which causes issues when the machine is under heavy load (in this case
#       when meson parallelizes the jobs on all 8 CPUs) - namely spurious
#       timeouts and hangups/deadlocks (like in test-barries).
[[ "$(hostnamectl --static)" =~ .dusty.ci.centos.org$ ]] && MESON_NUM_PROCESSES=4
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3 ${MESON_NUM_PROCESSES:+--num-processes "$MESON_NUM_PROCESSES"}"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -aq "build/meson-logs" "$LOGDIR"

# If we're not testing the main branch (the first diff) check if the tested
# branch doesn't contain only man-related changes. If so, skip the integration
# tests
if ! git diff --quiet main HEAD && ! git diff "$(git merge-base main HEAD)" --name-only | grep -qvE "^man/"; then
    echo "Detected man-only PR, skipping integration tests"
    exit $FAILED
fi

## Integration test suite ##
EXECUTED_LIST=()
FLAKE_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test, see below
    "test/TEST-29-PORTABLE"       # flaky test, see below (systemd/systemd#17469)
    "test/TEST-50-DISSECT"        # flaky test, see below (systemd/systemd#17469)
)
SKIP_LIST=(
    "test/TEST-30-ONCLOCKCHANGE" # we don't ship timesyncd in RHEL 9
    "${FLAKE_LIST[@]}"
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

# Initialize the 'base' image (default.img) on which the other images are based
exectask "setup-the-base-image" "make -C test/TEST-01-BASIC clean setup TESTDIR=/var/tmp/systemd-test-TEST-01-BASIC"

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    # Tell the test framework to copy the base image for each test, so we
    # can run them in parallel
    export TEST_PARALLELIZE=1
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    # See $INITRD above
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="user_namespace.enable=1 ${CGROUP_KERNEL_ARGS[*]}"
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

    # Skipped test don't create the $TESTDIR automatically, so do it explicitly
    # otherwise the `touch` command would fail
    mkdir -p "$TESTDIR"
    rm -f "$TESTDIR/pass"

    exectask_p "${t##*/}" "make -C $t setup run && touch $TESTDIR/pass"
    EXECUTED_LIST+=("$t")
done

# Wait for remaining running tasks
exectask_p_finish

for t in "${FLAKE_LIST[@]}"; do
    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    # See $INITRD above
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="user_namespace.enable=1 ${CGROUP_KERNEL_ARGS[*]}"
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    export NSPAWN_TIMEOUT=600
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$(nproc)
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry "${t##*/}" "make -C $t setup run && touch \$TESTDIR/pass"

    # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
    # array accordingly to correctly find the respective journals
    for ((i = 1; i <= EXECTASK_RETRY_DEFAULT; i++)); do
        [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
    done
done

for t in "${EXECUTED_LIST[@]}"; do
    testdir="/var/tmp/systemd-test-${t##*/}"
    if [[ -f "$testdir/system.journal" ]]; then
        if [[ "$t" == "test/TEST-17-UDEV" ]]; then
            # This test intentionally kills several processes using SIGABRT, thus
            # generating cores which we're not interested in
            export COREDUMPCTL_EXCLUDE_RX="/(sleep|udevadm)$"
        fi
        # Attempt to collect coredumps from test-specific journals as well
        exectask "${t##*/}_coredumpctl_collect" "coredumpctl_collect '$testdir/'"
        # Make sure to not propagate the custom coredumpctl filter override
        [[ -v COREDUMPCTL_EXCLUDE_RX ]] && unset -v COREDUMPCTL_EXCLUDE_RX

        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$testdir/pass" ]]; then
            rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
        fi
    fi

    # Clean the no longer necessary test artifacts
    [[ -d "$t" ]] && make -C "$t" clean-again > /dev/null
done

## Other integration tests ##
TEST_LIST=(
    "test/test-exec-deserialization.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask "${t##*/}" "timeout -k 60s 60m ./$t"
done

# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

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
