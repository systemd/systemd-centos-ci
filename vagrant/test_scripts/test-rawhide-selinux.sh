#!/usr/bin/bash
# shellcheck disable=SC2155

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname "$0")"
# This variable is automagically consumed by the "framework" for integration tests
# See respective bootstrap script under vagrant/bootstrap_scripts/ for reasoning
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Following scripts are copied from the systemd-centos-ci/common directory
# by vagrant-build.sh
# shellcheck source=common/task-control.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/utils.sh" || exit 1

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

# systemd SELinux sanity test
export QEMU_SMP="$(nproc)"
export QEMU_TIMEOUT=600
export TEST_NESTED_KVM=1
export TESTDIR="/var/tmp/TEST-06-SELINUX"
rm -fr "$TESTDIR"
if ! exectask "TEST-06-SELINUX" "make -C test/TEST-06-SELINUX clean setup run"; then
    [[ -f "$TESTDIR/system.journal" ]] && rsync -aq "$TESTDIR/system.journal" "$LOGDIR/TEST-06-SELINUX/"
fi

exectask "selinux-status" "sestatus -v -b"

exectask "avc-check" "! ausearch -m avc -i --start boot | audit2why"

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

exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
