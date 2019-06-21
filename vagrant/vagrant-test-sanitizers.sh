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

pushd /build || (echo >&2 "Can't pushd to /build"; exit 1)

# Sanitizer-specific options
if ldd build/systemd | grep -q libasan; then
# Temporarily disable the detect_stack_use_after_return runtime option due
# to performance issues with GCC9
    export ASAN_OPTIONS=strict_string_checks=1:check_initialization_order=1:strict_init_order=1:detect_stack_use_after_return=0
else
    export ASAN_OPTIONS=strict_string_checks=1:check_initialization_order=1:strict_init_order=1:detect_stack_use_after_return=1
fi
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

if _clang_asan_rt_name="$(ldd build/systemd | awk '/libclang_rt.asan/ {print $1; exit}')"; then
    # We are compiled with clang & -shared-libasan, let's tweak the runtime library
    # paths, so binaries can correctly find the clang's runtime ASan DSO
    _clang_asan_rt_path="$(find /usr/lib* /usr/local/lib* -type f -name "$_clang_asan_rt_name" 2>/dev/null | sed 1q)"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}${_clang_asan_rt_path%/*}"
fi

declare -p ASAN_OPTIONS UBSAN_OPTIONS LD_LIBRARY_PATH

# Run the internal unit tests (make check)
exectask "ninja-test_sanitizers" "meson test -C build --print-errorlogs --timeout-multiplier=3"

## Run TEST-01-BASIC under test sanitizers
# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
# As we're not using KVM, bump the QEMU timeout quite a bit
export QEMU_TIMEOUT=600
export NSPAWN_TIMEOUT=600
# Set QEMU_SMP to speed things up
export QEMU_SMP=$(nproc)
# Arch Linux requires booting with initrd, as all commonly used filesystems
# are compiled in as modules
export SKIP_INITRD=no

# Skip the basic integration tests on gcc as well (see above), as we can't
# override the ASAN_OPTIONS from the outside (see create_asan_wrapper under
# systemd/test/test-functions)
if ! ldd build/systemd | grep -q libasan; then
    # 1) Run it under systemd-nspawn
    rm -fr /var/tmp/systemd-test*
    exectask "TEST-01-BASIC_sanitizers-nspawn" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_QEMU=1"
    NSPAWN_EC=$?
    # Each integration test dumps the system journal when something breaks
    rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR/TEST-01-BASIC_sanitizers-nspawn/" &>/dev/null || :

    if [[ $NSPAWN_EC -eq 0 ]]; then
        # 2) Run it under QEMU, but only if the systemd-nspawn run was successful
        rm -fr /var/tmp/systemd-test*
        exectask "TEST-01-BASIC_sanitizers-qemu" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_NSPAWN=1"
        #make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_NSPAWN=1 KERNEL_APPEND=debug
        # Each integration test dumps the system journal when something breaks
        rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR/TEST-01-BASIC_sanitizers-qemu/" &>/dev/null || :
    fi
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

[[ -d /build/build/meson-logs ]] && cp -r /build/build/meson-logs "$LOGDIR"
exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
