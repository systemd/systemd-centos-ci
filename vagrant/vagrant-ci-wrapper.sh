#!/usr/bin/bash
# Auxiliary script for the CentOS CI infrastructure.
#
# This script basically checks out the requested branch of the systemd/systemd
# repository, installs & configures Vagrant, and runs the configured test suite
# in the Vagrant container on given distributions.

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "vagrant-logs" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

at_exit() {
    set +e
    journalctl -b -o short-monotonic --no-hostname --no-pager >"$LOGDIR/journalctl-vagrant-host.log"
    # Copy over all vagrant-related artifacts, so the Jenkins artifact plugin
    # can gather them for further investigation
    if [[ -v SYSTEMD_ROOT ]]; then
        cp -r "$SYSTEMD_ROOT"/vagrant-* "$LOGDIR"
    fi
    # Collect QEMU serial console logs (see the configuration in a respective
    # Vagrantfile)
    cp /tmp/vagrant-*-console.log "$LOGDIR"
}

REPO_URL="https://github.com/systemd/systemd.git"
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
DISTRO=""
REMOTE_REF=""

set -eu
set -o pipefail

while getopts "d:r:s:" opt; do
    case "$opt" in
        d)
            DISTRO="$OPTARG"
            ;;
        r)
            REMOTE_REF="$OPTARG"
            ;;
        s)
            REPO_URL="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 -d DISTRO_TAG [-r REMOTE_REF] [-s SOURCE_REPO_URL]"
            exit 1
    esac
done

if [[ -z "$DISTRO" ]]; then
    echo >&2 "Missing argument: distro tag"
fi

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
echo "Cloning repo: $REPO_URL"
git clone "$REPO_URL" systemd
export SYSTEMD_ROOT="$PWD/systemd"

trap at_exit EXIT

pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }
git_checkout_pr "$REMOTE_REF"
git revert --no-commit 7eb7e3ec4f5dbc13ee729557e1544527f3101187

# Create a Coveralls configuration file if the Coveralls token is present
# (the file is provided by the agent-control.py script)
if [[ -f /.coveralls.token ]]; then
    (
        set +x
        cat >.coveralls.yml <<EOF
repo_token: $(</.coveralls.token)
repo_name: systemd/systemd
service_name: CentOS CI
EOF
    )
fi
popd

# Disable SELinux on the test hosts and avoid false positives.
sestatus | grep -E "SELinux status:\s*disabled" || setenforce 0

"$SCRIPT_ROOT/vagrant-setup.sh"

# Disable firewalld to avoid issues with NFS
systemctl -q is-enabled firewalld && systemctl disable --now firewalld
systemctl restart libvirtd

"$SCRIPT_ROOT/vagrant-build.sh" "$DISTRO" 2>&1 | tee "$LOGDIR/console-$DISTRO.log"
