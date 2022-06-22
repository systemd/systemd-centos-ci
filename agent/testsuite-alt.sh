#!/usr/bin/bash
# shellcheck disable=SC2155

export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-upstream-$(uname -m)" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -eu

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

[[ ! -f /usr/bin/ninja ]] && ln -s /usr/bin/ninja-build /usr/bin/ninja
[[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

## Sanitizer-specific options
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_invalid_pointer_pairs=2:print_cmdline=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

# Dump current ASan config
ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}help=1" "$BUILD_DIR/systemctl" is-system-running &>"$LOGDIR/asan_config.txt"

## Disable certain flaky tests
# FIXME: test-execute
# This test occasionally timeouts when running under sanitizers. Until the root
# cause is figured out, let's temporarily skip this test to not disturb CI runs.
echo 'int main(void) { return 77; }' > src/test/test-execute.c

## FIXME: systemd-networkd testsuite: skip test_macsec
# Since kernel 5.7.2 the macsec module is broken, causing a runtime NULL pointer
# dereference (and since 5.8.0 an additional oops). Since the issue hasn't been
# looked at/fixed for over a month now, let's disable the failing test to
# no longer block the CI image updates.
# See: systemd/systemd#16199
sed -i '/def test_macsec/i\    @unittest.skip("See systemd/systemd#16199")' test/test-network/systemd-networkd-tests.py
exectask "ninja-test_sanitizers_$(uname -m)" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=3"
exectask "check-meson-logs-for-sanitizer-errors" "cat $BUILD_DIR/meson-logs/testlog*.txt | check_for_sanitizer_errors"
[[ -d "$BUILD_DIR/meson-logs" ]] && rsync -amq --include '*.txt' --include '*/' --exclude '*' "$BUILD_DIR/meson-logs" "$LOGDIR"

# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=1200
export NSPAWN_TIMEOUT=1200
# Set QEMU_SMP to speed things up
export QEMU_SMP=$(nproc)
export SKIP_INITRD=no
export QEMU_BIN=/usr/bin/qemu-kvm
# Since QEMU without accel is extremely slow on the alt-arch machines, let's use
# it only when we don't have a choice (i.e. with QEMU-only test)
export TEST_PREFER_NSPAWN=yes

## Generate a custom-tailored initrd for the integration tests
# The host initrd contains multipath modules & services which are unused
# in the integration tests and sometimes cause unexpected failures. Let's build
# a custom initrd used solely by the integration tests
#
# Set a path to the custom initrd into the INITRD variable which is read by
# the integration test suite "framework"
export INITRD="/var/tmp/ci-initramfs-$(uname -r).img"
cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
# Rebuild the original initrd with the dm-crypt modules and without the multipath module
# Note: we need to built the initrd with --no-hostonly, otherwise the resulting
#       initrd lacks certain drivers for the qemu's virt hdd
dracut --no-hostonly --filesystems ext4 -a crypt -o multipath --rebuild "$INITRD"

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

    # Run the systemd-networkd testsuite "in the background" while we run other
    # integration tests, since it doesn't require much resources and should not
    # interfere with them (and vice versa), saving a non-insignificant amount
    # of time
    exectask_p "systemd-networkd_sanitizers" \
               "/bin/time -v -- timeout -k 60s 60m test/test-network/systemd-networkd-tests.py --build-dir=$BUILD_DIR --debug --asan-options=$ASAN_OPTIONS --ubsan-options=$UBSAN_OPTIONS"

    # Run certain other integration tests under sanitizers to cover bigger
    # systemd subcomponents (but only if TEST-01-BASIC passed, so we can
    # be somewhat sure the 'base' systemd components work).
    EXECUTED_LIST=()
    INTEGRATION_TESTS=(
        test/TEST-04-JOURNAL        # systemd-journald
        # FIXME: This test gets stuck on C8S when calling `sysctl, possibly
        #        related to https://bugzilla.redhat.com/show_bug.cgi?id=2098125
        #test/TEST-13-NSPAWN-SMOKE   # systemd-nspawn
        test/TEST-15-DROPIN         # dropin logic
        test/TEST-17-UDEV           # systemd-udevd
        test/TEST-22-TMPFILES       # systemd-tmpfiles
        test/TEST-23-TYPE-EXEC
        test/TEST-29-PORTABLE       # systemd-portabled
        test/TEST-34-DYNAMICUSERMIGRATE
        test/TEST-45-TIMEDATE       # systemd-timedated
        test/TEST-46-HOMED          # systemd-homed
        # FIXME: device-mapper complains about invalid ioctl and then dies
        #        because it can't allocate memory; needs further investigation
        #test/TEST-50-DISSECT        # systemd-dissect
        test/TEST-54-CREDS          # credentials & stuff
        test/TEST-55-OOMD           # systemd-oomd
        test/TEST-58-REPART         # systemd-repart
        test/TEST-65-ANALYZE        # systemd-analyze
        test/TEST-70-TPM2           # systemd-cryptenroll
        test/TEST-71-HOSTNAME       # systemd-hostnamed
        test/TEST-72-SYSUPDATE      # systemd-sysupdate
        test/TEST-73-LOCALE         # systemd-localed
    )

    for t in "${INTEGRATION_TESTS[@]}"; do
        # Some of the newer tests might not be available in stable branches,
        # so let's skip them instead of failing
        if [[ ! -d "$t" ]]; then
            echo "Test '$t' is not available, skipping..."
            continue
        fi

        # Set the test dir to something predictable so we can refer to it later
        export TESTDIR="/var/tmp/systemd-test-${t##*/}"

        # Suffix the $TESTDIR of each retry with an index to tell them apart
        export MANGLE_TESTDIR=1
        exectask_retry "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass"

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

    exectask_p_finish
    exectask "check-networkd-log-for-sanitizer-errors" "cat $LOGDIR/systemd-networkd_sanitizers*.log | check_for_sanitizer_errors"
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
exectask "check-journal-for-sanitizer-errors" "journalctl -b | check_for_sanitizer_errors"
# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Summary
show_task_summary

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
