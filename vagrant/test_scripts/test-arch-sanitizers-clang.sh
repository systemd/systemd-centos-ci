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
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

## To be able to run integration tests under sanitizers we have to use the dynamic
## versions of sanitizer libraries, especially when it comes to ASAn. With gcc
## it's quite easy as ASan is compiled dynamically by default there and all necessary
## libraries are in standard locations.
## With clang things get a little bit complicated as we need to explicitly tell clang
## to use the dynamic ASan library and then instruct the rest of the system
## to where it can find it, as it is in a non-standard library location.
_clang_asan_rt_name="$(ldd "$BUILD_DIR/systemd" | awk '/libclang_rt.asan/ {print $1; exit}')"

if [[ -n "$_clang_asan_rt_name" ]]; then
    # We are compiled with clang & -shared-libasan, let's tweak the runtime library
    # paths, so binaries can correctly find the clang's runtime ASan DSO
    _clang_asan_rt_path="$(find /usr/lib* /usr/local/lib* -type f -name "$_clang_asan_rt_name" 2>/dev/null | sed 1q)"
    # Add the non-standard clang DSO path to the ldconfig cache
    mkdir -p /etc/ld.so.conf.d/
    echo "${_clang_asan_rt_path%/*}" > /etc/ld.so.conf.d/99-clang-libasan.conf
    ldconfig
fi

## Disable certain flaky tests
# test-journal-flush: unstable on nested KVM
echo 'int main(void) { return 77; }' > src/journal/test-journal-flush.c

## FIXME: systemd-networkd testsuite: skip test_macsec
# Since kernel 5.7.2 the macsec module is broken, causing a runtime NULL pointer
# dereference (and since 5.8.0 an additional oops). Since the issue hasn't been
# looked at/fixed for over a month now, let's disable the failing test to
# no longer block the CI image updates.
# See: systemd/systemd#16199
sed -i '/def test_macsec/i\    @unittest.skip("See systemd/systemd#16199")' test/test-network/systemd-networkd-tests.py

## Temporary wrapper for `meson test` which disables LSan for `test-execute`
# LSan keeps randomly crashing during `test-execute` so let's (temporarily)
# disable it until we find out the culprit.
# See:
#   https://github.com/systemd/systemd-centos-ci/pull/217#issuecomment-580717687
#   https://github.com/systemd/systemd/issues/14598
ASAN_WRAPPER="$(mktemp "$BUILD_DIR/asan-wrapper-XXX.sh")"
cat > "$ASAN_WRAPPER" << EOF
#!/bin/bash

export ASAN_OPTIONS=$ASAN_OPTIONS
export UBSAN_OPTIONS=$UBSAN_OPTIONS

if [[ \$(basename "\$1") == 'test-execute' ]]; then
    ASAN_OPTIONS="\$ASAN_OPTIONS:detect_leaks=0"
fi

exec "\$@"
EOF

chmod +x "$ASAN_WRAPPER"

# Run the internal unit tests (make check)
exectask "ninja-test_sanitizers" "meson test -C $BUILD_DIR --wrapper=$ASAN_WRAPPER --print-errorlogs --timeout-multiplier=3"
exectask "check-meson-logs-for-sanitizer-errors" "cat $BUILD_DIR/meson-logs/testlog.txt | check_for_sanitizer_errors"

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

## As running integration tests with broken systemd can be quite time consuming
## (usually we need to wait for the test to timeout, see $QEMU_TIMEOUT and
## $NSPAWN_TIMEOUT above), let's try to sanity check systemd first by running
## the basic integration test under systemd-nspawn (note that we don't install
## built systemd during sanitizers run, so we use the stable systemd-nspawn
## version provided by package manager).
##
## If the sanity check passes we can be at least somewhat sure the systemd
## 'core' is stable and we can run the rest of the selected integration tests.
# 1) Run it under systemd-nspawn
export TESTDIR="/var/tmp/TEST-01-BASIC_sanitizers-nspawn"
rm -fr "$TESTDIR"
exectask "TEST-01-BASIC_sanitizers-nspawn" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_QEMU=1"
NSPAWN_EC=$?
# Each integration test dumps the system journal when something breaks
rsync -amq "$TESTDIR/system.journal" "$LOGDIR/${TESTDIR##*/}/" &>/dev/null || :

if [[ $NSPAWN_EC -eq 0 ]]; then
    # 2) The sanity check passed, let's run the other half of the TEST-01-BASIC
    #    (under QEMU) and possibly other selected tests
    export TESTDIR="/var/tmp/systemd-test-TEST-01-BASIC_sanitizers-qemu"
    rm -fr "$TESTDIR"
    exectask "TEST-01-BASIC_sanitizers-qemu" "make -C test/TEST-01-BASIC clean setup run TEST_NO_NSPAWN=1 && touch $TESTDIR/pass"

    ## Run certain other integration tests under sanitizers to cover bigger
    ## systemd subcomponents (but only if TEST-01-BASIC passed, so we can
    ## be somewhat sure the 'base' systemd components work).
    INTEGRATION_TESTS=(
        test/TEST-04-JOURNAL        # systemd-journald
        test/TEST-13-NSPAWN-SMOKE   # systemd-nspawn
        test/TEST-46-HOMED          # systemd-homed & friends
    )

    for t in "${INTEGRATION_TESTS[@]}"; do
        # Set the test dir to something predictable so we can refer to it later
        export TESTDIR="/var/tmp/systemd-test-${t##*/}"

        # TEST-13-NSPAWN-SMOKE causes intermittent CPU soft lockups during
        # the QEMU run, causing timeouts & unexpected fails. Let's run only
        # the systemd-nspawn part of this test to make the CI more stable.
        unset TEST_NO_QEMU
        if [[ "$t" == "test/TEST-13-NSPAWN-SMOKE" ]]; then
            export TEST_NO_QEMU=1
        fi

        rm -fr "$TESTDIR"
        mkdir -p "$TESTDIR"

        exectask "${t##*/}" "make -C $t clean setup run && touch $TESTDIR/pass"
    done

    # Save journals created by integration tests
    for t in "TEST-01-BASIC_sanitizers-qemu" "${INTEGRATION_TESTS[@]}"; do
        testdir="/var/tmp/systemd-test-${t##*/}"
        if [[ -f "$testdir/system.journal" ]]; then
            # Attempt to collect coredumps from test-specific journals as well
            exectask "${t##*/}_coredumpctl_collect" "COREDUMPCTL_BIN='$BUILD_DIR/coredumpctl' coredumpctl_collect '$testdir/'"
            # Check for sanitizer errors in test journals
            exectask "${t##*/}_sanitizer_errors" "$BUILD_DIR/journalctl --file $testdir/system.journal | check_for_sanitizer_errors"
            # Keep the journal files only if the associated test case failed
            if [[ ! -f "$testdir/pass" ]]; then
                rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
            fi
        fi
    done
fi

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
exectask "check-journal-for-sanitizer-errors" "journalctl -b | check_for_sanitizer_errors"
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
