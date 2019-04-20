#!/usr/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI.
#
# The script takes a distro name as the only argument and then tries to fetch,
# build, and configure a Vagrant VM according to the respective Vagrantfile,
# if such Vagrantfile exists. On success, vagrant-test.sh script is executed
# inside the VM and the test artifacts are stored in a respective vagrant-$DISTRO
# folder in the $SYSTEMD_ROOT directory for further investigation.

if ! vagrant version; then
    echo >&2 "Missing vagrant package, consider running 'vagrant-setup.sh'"
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo >&2 "Usage: $0 <distro>"
    exit 1
fi

VAGRANT_ROOT="$(dirname $(readlink -f $0))"
VAGRANT_FILES="$VAGRANT_ROOT/Vagrantfiles"
echo "$VAGRANT_ROOT"
DISTRO="${1,,}"

set -e -u
set -o pipefail

# Decide which Vagrant file to use
VAGRANT_FILE="$VAGRANT_FILES/Vagrantfile_$DISTRO"

if [[ ! -f $VAGRANT_FILE ]]; then
    echo >&2 "No Vagrantfile found for distro '$DISTRO'"
    exit 1
fi

# Configure environment (following env variables are used in the respective
# Vagrantfile)
export SYSTEMD_ROOT="${SYSTEMD_ROOT:-$HOME/systemd}"
export VAGRANT_DRIVER="${VAGRANT_DRIVER:-kvm}"
export VAGRANT_MEMORY="${VAGRANT_MEMORY:-8192}"
export VAGRANT_CPUS="${VAGRANT_CPUS:-8}"
export VAGRANT_DISK_BUS

# Absolute systemd git root path on the host machine
TEST_DIR="$(mktemp -d "$SYSTEMD_ROOT/vagrant-$DISTRO-config.XXX")"
# Relative path (i.e just the vagrant-$DISTRO.XXX dir) used for navigation
# in the guest VM
RELATIVE_TEST_DIR="${TEST_DIR##*/}"

# Copy the target Vagrant file to the test dir
cp "$VAGRANT_FILE" "$TEST_DIR/Vagrantfile"
# Possible FIXME: copy the common.sh "library" from the systemd-centos-ci/agent
# directory
cp "$VAGRANT_ROOT/../common/task-control.sh" "$TEST_DIR/task-control.sh"
pushd "$TEST_DIR"
# Copy the test script to the test dir
cp "$VAGRANT_ROOT/vagrant-test.sh" "$TEST_DIR/vagrant-test.sh"

# Provision the machine
vagrant up --provider=libvirt
# Reboot the VM to "apply" the new systemd
vagrant reload
# Run tests
vagrant ssh -c "cd /build && sudo $RELATIVE_TEST_DIR/vagrant-test.sh $DISTRO"

# Destroy the VM
vagrant destroy -f
popd
