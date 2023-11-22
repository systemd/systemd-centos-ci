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

## SETUP ##
set -ex
# Download & prepare the Fedora SELinux test suite
fedpkg co -a tests/selinux
pushd selinux
cat >plans/systemd.fmf <<EOF
summary: systemd-related SELinux tests

discover:
    how: fmf
    filter:
        - "component: systemd | recommend: systemd"
        - "component: selinux-policy"
provision:
    how: local
execute:
    how: tmt
EOF

tmt plans show -v /plans/systemd
tmt run plan -n systemd discover -v

popd
set +ex

## TESTS ##
exectask "selinux-status" "sestatus -v -b"

# systemd SELinux sanity test
export QEMU_SMP="$(nproc)"
export QEMU_TIMEOUT=600
export TEST_NESTED_KVM=1
export TESTDIR="/var/tmp/TEST-06-SELINUX"
rm -fr "$TESTDIR"
if ! exectask "TEST-06-SELINUX" "make -C test/TEST-06-SELINUX clean setup run"; then
    [[ -f "$TESTDIR/system.journal" ]] && rsync -aq "$TESTDIR/system.journal" "$LOGDIR/TEST-06-SELINUX/"
fi

# systemd-related tests from the SELinux test suite
exectask "fedora-selinux-testsuite" "tmt -vvv --root selinux run --id fedora-selinux-testsuite plan --name systemd"
# Note: the --include "*/" rule is important, otherwise the following --exclude '*' rule excludes
#       all subdirectories before they can be matched by the first --include '*.txt' rule. This also
#       causes all empty directories to by copied over as well, but that's mitigated by
#       the -m/--prune-empty-dirs option
rsync -amq --include '*.txt' --include '*/' --exclude '*' /var/tmp/tmt/fedora-selinux-testsuite/{log.txt,plans/systemd/execute} "$LOGDIR/fedora-selinux-testsuite/"

exectask "avc-check" "! ausearch -m avc,user_avc -i --start boot"

# Summary
show_task_summary

exectask "journalctl-testsuite" "journalctl -b -o short-monotonic --no-hostname --no-pager"

finish_and_exit
