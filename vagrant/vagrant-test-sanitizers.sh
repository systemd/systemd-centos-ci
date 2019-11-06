#!/usr/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname $0)"
# task-control.sh is copied from the systemd-centos-ci/common directory by vagrant-builder.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
. "$SCRIPT_DIR/utils.sh" || exit 1

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

# Sanitizer-specific options
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

_clang_asan_rt_name="$(ldd build/systemd | awk '/libclang_rt.asan/ {print $1; exit}')"

if [[ -n "$_clang_asan_rt_name" ]]; then
    # We are compiled with clang & -shared-libasan, let's tweak the runtime library
    # paths, so binaries can correctly find the clang's runtime ASan DSO
    _clang_asan_rt_path="$(find /usr/lib* /usr/local/lib* -type f -name "$_clang_asan_rt_name" 2>/dev/null | sed 1q)"
    # Add the non-standard clang DSO path to the ldconfig cache
    mkdir -p /etc/ld.so.conf.d/
    echo "${_clang_asan_rt_path%/*}" > /etc/ld.so.conf.d/99-clang-libasan.conf
    ldconfig
fi

# Run the internal unit tests (make check)
exectask "ninja-test_sanitizers" "meson test -C build --print-errorlogs --timeout-multiplier=3"

## Run TEST-01-BASIC under test sanitizers
# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=600
export NSPAWN_TIMEOUT=600
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

# 1) Run it under systemd-nspawn
export TESTDIR="/var/tmp/TEST-01-BASIC_sanitizers-nspawn"
rm -fr "$TESTDIR"
exectask "TEST-01-BASIC_sanitizers-nspawn" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_QEMU=1"
NSPAWN_EC=$?
# Each integration test dumps the system journal when something breaks
rsync -amq "$TESTDIR/journal" "$LOGDIR/${TESTDIR##*/}" &>/dev/null || :

if [[ $NSPAWN_EC -eq 0 ]]; then
    # 2) Run it under QEMU, but only if the systemd-nspawn run was successful
    export TESTDIR="/var/tmp/TEST-01-BASIC_sanitizers-qemu"
    rm -fr "$TESTDIR"
    exectask "TEST-01-BASIC_sanitizers-qemu" "make -C test/TEST-01-BASIC clean setup run TEST_NO_NSPAWN=1 && touch $TESTDIR/pass"

    if [[ -d $TESTDIR/journal ]]; then
        # Attempt to collect coredumps from test-specific journals as well
        exectask "TEST-01-BASIC_coredumpctl_collect" "coredumpctl_collect '$TESTDIR/journal'"
        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$TESTDIR/pass" ]]; then
            rsync -amq "$TESTDIR/journal" "$LOGDIR/${TESTDIR##*/}" &>/dev/null
        fi
    fi
fi

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
            "timeout -k 60s 45m test/test-network/systemd-networkd-tests.py --build-dir=$PWD/build --debug --asan-options=$ASAN_OPTIONS --ubsan-options=$UBSAN_OPTIONS"

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

[[ -d /build/build/meson-logs ]] && cp -r /build/build/meson-logs "$LOGDIR"
exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
