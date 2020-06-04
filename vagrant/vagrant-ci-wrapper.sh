#!/usr/bin/bash
# Auxiliary script for the CentOS CI infrastructure.
#
# This script basically checks out the requested branch of the systemd/systemd
# repository, installs & configures Vagrant, and runs the configured test suite
# in the Vagrant container on given distributions.

# TODO: argument parsing, so we can properly distinguish between branch/commit
#       and distro tag

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "vagrant-logs" || exit 1

at_exit() {
    set +e
    journalctl -b --no-pager > "$LOGDIR/journalctl-vagrant-host.log"
    # Copy over all vagrant-related artifacts, so the Jenkins artifact plugin
    # can gather them for further investigation
    if [[ -v SYSTEMD_ROOT ]]; then
        cp -r "$SYSTEMD_ROOT"/vagrant-* "$LOGDIR"
    fi
    # Collect QEMU serial console logs (see the configuration in a respective
    # Vagrantfile)
    cp /tmp/vagrant-*-console.log "$LOGDIR"
}

REPO_URL="${REPO_URL:-https://github.com/systemd/systemd.git}"
SCRIPT_ROOT="$(dirname "$0")"
# Supported distros:
#
# Arch Linux with sanitizers (Address Sanitizer, Undefined Behavior Sanitizer
# Runs only a selected part of the test suite, see vagrant-test-sanitizers.sh
# for more information
# distro-tag: arch-sanitizers-gcc or arch-sanitizers-clang
#
# "Standalone" Arch Linux
# Runs unit tests, fuzzers, and integration tests
# distro-tag: arch
DISTRO="${1:?missing argument: distro tag}"

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e -u
set -o pipefail

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
git clone "$REPO_URL" systemd
export SYSTEMD_ROOT="$PWD/systemd"

trap at_exit EXIT

pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }
git_checkout_pr "${2:-""}"
popd

# Disable SELinux on the test hosts and avoid false positives.
sestatus | grep -E "SELinux status:\s*disabled" || setenforce 0

"$SCRIPT_ROOT/vagrant-setup.sh"

# Disable firewalld to avoid issues with NFS
systemctl stop firewalld
systemctl restart libvirtd

# DEBUG ONLY
dnf install -y sysstat
sar -d -q -p -P ALL -u ALL -w 30 &
SAR_PID=$!

if ! "$SCRIPT_ROOT/vagrant-build.sh" "$DISTRO" 2>&1 | tee "$LOGDIR/console-$DISTRO.log"; then
    EC=1
else
    EC=0
fi

kill $SAR_PID

exit $EC
