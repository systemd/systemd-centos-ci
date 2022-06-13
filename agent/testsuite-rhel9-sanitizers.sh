#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# The common/utils.sh include needs to come first, as it includes definition
# of print_cgroup_hierarchy()
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-$(print_cgroup_hierarchy)-rhel9-sanitizers" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

set -eu
set -o pipefail

trap at_exit EXIT

pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

### SETUP PHASE ###
## Sanitizer-specific options
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_invalid_pointer_pairs=2:handle_ioctl=1:print_cmdline=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1
BUILD_DIR="build"
CGROUP_HIERARCHY="$(print_cgroup_hierarchy)"

echo "Current cgroup hierarchy: $CGROUP_HIERARCHY"
# Reflect the current cgroup hierarchy in each test VM
if [[ "$CGROUP_HIERARCHY" == unified ]]; then
    CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=1" "systemd.legacy_systemd_cgroup_controller=0")
else
    CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=0" "systemd.legacy_systemd_cgroup_controller=1")
fi

# Dump current ASan config
ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}help=1" "$BUILD_DIR/systemctl" is-system-running &>"$LOGDIR/asan_config.txt"

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ ! -f /usr/bin/qemu-kvm ]]; then
    ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
fi
qemu-kvm --version

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

set +e
### TEST PHASE ###
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

# FIXME: test-barrier
# This test is flaky on systems under load, which happens intermittently due
# to how meson runs the tests (in parallel).
#
# See:
#   https://github.com/systemd/systemd/commit/fd23f9c9a70e1214507641d327da40d1688b74d7
#   https://github.com/systemd/systemd/commit/a1e3f0f38b43e68ff9ea33ab1935aed4edf6ed7f
echo 'int main(void) { return 77; }' > src/test/test-barrier.c

# Run the internal unit tests (make check)
# Note: All .dusty.* servers have Intel Xeon CPUs with 4 cores and HT enabled
#       which causes issues when the machine is under heavy load (in this case
#       when meson parallelizes the jobs on all 8 CPUs) - namely spurious
#       timeouts and hangups/deadlocks (like in test-barries).
[[ "$(hostnamectl --static)" =~ .dusty.ci.centos.org$ ]] && MESON_NUM_PROCESSES=4
exectask "ninja-test" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=3 ${MESON_NUM_PROCESSES:+--num-processes "$MESON_NUM_PROCESSES"}"
exectask "check-meson-logs-for-sanitizer-errors" "cat $BUILD_DIR/meson-logs/testlog*.txt | check_for_sanitizer_errors"
# Copy over meson test artifacts
[[ -d "$BUILD_DIR/meson-logs" ]] && rsync -aq "$BUILD_DIR/meson-logs" "$LOGDIR"

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
if ! dracut -o multipath --rebuild "$INITRD"; then
    echo >&2 "Failed to generate initrd, can't continue"
    exit 1
fi

## Run TEST-01-BASIC under sanitizers
# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=1200
export NSPAWN_TIMEOUT=1200
# Set QEMU_SMP to speed things up
export QEMU_SMP=$(nproc)
# Arch Linux requires booting with initrd, as all commonly used filesystems
# are compiled in as modules
export SKIP_INITRD=no
export KERNEL_APPEND="user_namespace.enable=1 ${CGROUP_KERNEL_ARGS[*]}"

# As running integration tests with broken systemd can be quite time consuming
# (usually we need to wait for the test to timeout, see $QEMU_TIMEOUT and
# $NSPAWN_TIMEOUT above), let's try to sanity check systemd first by running
# the basic integration test under systemd-nspawn
#
# If the sanity check passes we can be at least somewhat sure the systemd
# 'core' is stable and we can run the rest of the selected integration tests.
# 1) Run it under systemd-nspawn
export TESTDIR="/var/tmp/TEST-01-BASIC_sanitizers-nspawn"
rm -fr "$TESTDIR"
exectask "TEST-01-BASIC_sanitizers-nspawn" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_QEMU=1 && touch $TESTDIR/pass"
NSPAWN_EC=$?
# Each integration test dumps the system journal when something breaks
[[ ! -f "$TESTDIR/pass" ]] && rsync -aq "$TESTDIR/system.journal" "$LOGDIR/${TESTDIR##*/}/"

if [[ $NSPAWN_EC -eq 0 ]]; then
    # 2) The sanity check passed, let's run the other half of the TEST-01-BASIC
    #    (under QEMU) and possibly other selected tests
    export TESTDIR="/var/tmp/systemd-test-TEST-01-BASIC_sanitizers-qemu"
    rm -fr "$TESTDIR"
    exectask "TEST-01-BASIC_sanitizers-qemu" "make -C test/TEST-01-BASIC clean setup run TEST_NO_NSPAWN=1 && touch $TESTDIR/pass"

    # Run certain other integration tests under sanitizers to cover bigger
    # systemd subcomponents (but only if TEST-01-BASIC passed, so we can
    # be somewhat sure the 'base' systemd components work).
    EXECUTED_LIST=()
    INTEGRATION_TESTS=(
        test/TEST-04-JOURNAL        # systemd-journald
        test/TEST-13-NSPAWN-SMOKE   # systemd-nspawn
        test/TEST-15-DROPIN         # dropin logic
        test/TEST-17-UDEV           # systemd-udevd
        test/TEST-22-TMPFILES       # systemd-tmpfiles
        test/TEST-23-TYPE-EXEC
        # We don't ship portabled in RHEL
        #test/TEST-29-PORTABLE       # systemd-portabled
        test/TEST-34-DYNAMICUSERMIGRATE
        # We don't ship homed in RHEL
        #test/TEST-46-HOMED          # systemd-homed
        test/TEST-50-DISSECT        # systemd-dissect
        test/TEST-54-CREDS          # credentials & stuff
        test/TEST-55-OOMD           # systemd-oomd
        test/TEST-58-REPART         # systemd-repart
        test/TEST-65-ANALYZE        # systemd-analyze
    )

    for t in "${INTEGRATION_TESTS[@]}"; do
        # Set the test dir to something predictable so we can refer to it later
        export TESTDIR="/var/tmp/systemd-test-${t##*/}"

        # Suffix the $TESTDIR of each retry with an index to tell them apart
        export MANGLE_TESTDIR=1
        exectask_retry "${t##*/}" "make -C $t setup run && touch \$TESTDIR/pass"

        # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
        # array accordingly to correctly find the respective journals
        for ((i = 1; i <= EXECTASK_RETRY_DEFAULT; i++)); do
            [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
        done
    done

    # Save journals created by integration tests
    for t in "TEST-01-BASIC_sanitizers-qemu" "${EXECUTED_LIST[@]}"; do
        testdir="/var/tmp/systemd-test-${t##*/}"
        if [[ -f "$testdir/system.journal" ]]; then
            # Filter out test-specific coredumps which are usually intentional
            # Note: $COREDUMPCTL_EXCLUDE_MAP resides in common/utils.sh
            # Note2: since all tests in this run are using the `exectask_retry`
            #        runner, they're always suffixed with '_X'
            if [[ -v "COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]" ]]; then
                export COREDUMPCTL_EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]}"
            fi
            # Attempt to collect coredumps from test-specific journals as well
            exectask "${t##*/}_coredumpctl_collect" "COREDUMPCTL_BIN='$BUILD_DIR/coredumpctl' coredumpctl_collect '$testdir/'"
            # Make sure to not propagate the custom coredumpctl filter override
            [[ -v COREDUMPCTL_EXCLUDE_RX ]] && unset -v COREDUMPCTL_EXCLUDE_RX

            # Check for sanitizer errors in test journals
            exectask "${t##*/}_sanitizer_errors" "$BUILD_DIR/journalctl -o short-monotonic --no-hostname --file $testdir/system.journal | check_for_sanitizer_errors"
            # Keep the journal files only if the associated test case failed
            if [[ ! -f "$testdir/pass" ]]; then
                rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
            fi
        fi
    done
fi

# Check the test logs for sanitizer errors as well, since some tests may
# output the "interesting" information only to the console.
_check_test_logs_for_sanitizer_errors() {
    local ec=0

    while read -r file; do
        echo "*** Processing file $file ***"
        check_for_sanitizer_errors < "$file" || ec=1
    done < <(find "$LOGDIR" -maxdepth 1 -name "TEST-*.log" ! -name "*_sanitizer_*" ! -name "*_coredumpctl_*")

    return $ec
}
exectask "test_logs_sanitizer_errors" "_check_test_logs_for_sanitizer_errors"
exectask "check-journal-for-sanitizer-errors" "journalctl -o short-monotonic --no-hostname -b | check_for_sanitizer_errors"
# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Summary
show_task_summary

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
