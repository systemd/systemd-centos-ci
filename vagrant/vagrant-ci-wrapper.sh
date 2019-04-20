#!/usr/bin/bash
# Auxilliary script for the CentOS CI infrastructure.
#
# This script basically checks out the requested branch of the systemd/systemd
# repository, install & configures Vagrant, and runs the configured testsuite
# in the Vagrant container on given distributions.

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "vagrant-logs" || exit 1

REPO_URL="${REPO_URL:-https://github.com/systemd/systemd.git}"
SCRIPT_ROOT="$(dirname "$0")"
DISTROS=(arch)

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e -u
set -o pipefail

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
git clone "$REPO_URL" systemd
export SYSTEMD_ROOT="$PWD/systemd"

pushd systemd
git_checkout_pr "${1:-""}"
popd

# Disable SELinux on the test hosts and avoid false positives.
setenforce 0

"$SCRIPT_ROOT/vagrant-setup.sh"

# Disable firewalld to avoid issues with NFS
systemctl stop firewalld
systemctl restart libvirtd

set +e

EC=0

# Run the vagrant-build script for each supported distro from the DISTROS array
for distro in ${DISTROS[@]}; do
    "$SCRIPT_ROOT/vagrant-build.sh" "$distro" 2>&1 | tee "$LOGDIR/console-$distro.log"
    if [[ $? -ne 0 ]]; then
        EC=$((EC + 1))
    fi
done

# Copy over all vagrant-related artifacts, so the Jenkins artifact plugin
# can gather them for further investigation
cp -r $SYSTEMD_ROOT/vagrant-* "$LOGDIR"

exit $EC
