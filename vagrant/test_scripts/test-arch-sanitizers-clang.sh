#!/usr/bin/bash
# shellcheck disable=SC2155
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname "$0")"
# This variable is automagically consumed by the "framework" for integration tests
# See respective bootstrap script under vagrant/bootstrap_scripts/ for reasoning
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Following scripts are copied from the systemd-centos-ci/common directory by vagrant-builder.sh
# shellcheck source=common/task-control.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/utils.sh" || exit 1

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

## Sanitizer-specific options
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_invalid_pointer_pairs=2:handle_ioctl=1:print_cmdline=1
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

# Run the internal unit tests (make check)
exectask "ninja-test_sanitizers" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=3"
exectask "check-meson-logs-for-sanitizer-errors" "cat $BUILD_DIR/meson-logs/testlog*.txt | check_for_sanitizer_errors"

## Run TEST-01-BASIC under sanitizers
# Prepare a custom-tailored initrd image (with the systemd module included).
# This is necessary, as the default mkinitcpio config includes only the udev module,
# which breaks certain things, like setting global env variables for systemd from
# the kernel command line.
# The exported INITRD variable is picked up by all following integration tests
export INITRD="$(mktemp /var/tmp/initrd-testsuite-XXX.img)"
if ! mkinitcpio -c /dev/null -A base,systemd,autodetect,modconf,block,filesystems,keyboard,fsck -g "$INITRD"; then
    echo >&2 "Failed to generate initrd, can't continue"
    exit 1
fi
# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=1200
export NSPAWN_TIMEOUT=1200
# Set QEMU_SMP to speed things up
export QEMU_SMP=$(nproc)
# Arch Linux requires booting with initrd, as all commonly used filesystems
# are compiled in as modules
export SKIP_INITRD=no
# Enforce nested KVM
export TEST_NESTED_KVM=yes

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

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
        test/TEST-29-PORTABLE       # systemd-portabled
        test/TEST-46-HOMED          # systemd-homed
        test/TEST-50-DISSECT        # systemd-dissect
        test/TEST-55-OOMD           # systemd-oomd
        test/TEST-58-REPART         # systemd-repart
    )

    for t in "${INTEGRATION_TESTS[@]}"; do
        # Set the test dir to something predictable so we can refer to it later
        export TESTDIR="/var/tmp/systemd-test-${t##*/}"

        # Disable nested KVM for TEST-13-NSPAWN-SMOKE, which keeps randomly
        # failing due to time outs caused by CPU soft locks. Also, bump the
        # QEMU timeout, since the test is much slower without KVM.
        export TEST_NESTED_KVM=yes
        if [[ "$t" == "test/TEST-13-NSPAWN-SMOKE" ]]; then
            unset TEST_NESTED_KVM
            export QEMU_TIMEOUT=1200
        fi

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

## systemd-networkd testsuite
# Prepare environment for the systemd-networkd testsuite
systemctl disable --now dhcpcd dnsmasq
systemctl reload dbus.service
# FIXME
# As the DHCP lease time in libvirt is quite short, and it's not configurable,
# yet, let's start a DHCP daemon _only_ for the "master" network device to
# keep it up during the systemd-networkd testsuite
systemctl enable --now dhcpcd@eth0.service
systemctl status dhcpcd@eth0.service

exectask "systemd-networkd_sanitizers" \
            "timeout -k 60s 60m test/test-network/systemd-networkd-tests.py --build-dir=$BUILD_DIR --debug --asan-options=$ASAN_OPTIONS --ubsan-options=$UBSAN_OPTIONS"

exectask "check-networkd-log-for-sanitizer-errors" "cat $LOGDIR/systemd-networkd_sanitizers*.log | check_for_sanitizer_errors"
exectask "check-journal-for-sanitizer-errors" "journalctl -o short-monotonic --no-hostname -b | check_for_sanitizer_errors"
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

[[ -d "$BUILD_DIR/meson-logs" ]] && cp -r "$BUILD_DIR/meson-logs" "$LOGDIR"
exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
