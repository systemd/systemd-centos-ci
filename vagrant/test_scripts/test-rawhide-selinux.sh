#!/usr/bin/bash

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname $0)"
# This variable is automagically consumed by the "framework" for integration tests
# See respective bootstrap script under vagrant/bootstrap_scripts/ for reasoning
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Following scripts are copied from the systemd-centos-ci/common directory
# by vagrant-build.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
. "$SCRIPT_DIR/utils.sh" || exit 1

exectask "selinux-status" "sestatus -v -b"

exectask "avc-check" "! ausearch -m avc -i --start boot"

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
