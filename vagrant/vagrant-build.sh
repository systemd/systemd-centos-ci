#!/usr/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI.
#
# The script takes a distro string as the only argument and then tries to fetch,
# build, and configure a Vagrant VM according to the respective Vagrantfile,
# if such Vagrantfile exists. On success, vagrant-test.sh script is executed
# inside the VM and the test artifacts are stored in a respective vagrant-$DISTRO_STRING
# folder in the $SYSTEMD_ROOT directory for further investigation.

# The passed distro string is split into two parts, for example:
# DISTRO_STRING=arch-sanitizers-clang is split into 'arch', which identifies
# a respective Vagrantfile and 'sanitizers-clang' which denotes the test type.
# Also, the distro string as a whole identifies the bootstrap script, which
# will be executed as part of the Vagrantfile.

if ! vagrant version; then
    echo >&2 "Missing vagrant package, consider running 'vagrant-setup.sh'"
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo >&2 "Usage: $0 <distro-test-type>"
    exit 1
fi

set -e -u
set -o pipefail

VAGRANT_ROOT="$(dirname "$(readlink -f "$0")")"
VAGRANT_FILES="$VAGRANT_ROOT/vagrantfiles"
VAGRANT_BOOTSTRAP_SCRIPTS="$VAGRANT_ROOT/bootstrap_scripts"
VAGRANT_TEST_SCRIPTS="$VAGRANT_ROOT/test_scripts"
USING_SANITIZERS=false
DISTRO_STRING="${1,,}"
# Takes the first part of the hyphen-delimited distro string as a distro name
# e.g.: if DISTRO_STRING=arch-sanitizers-clang then DISTRO=arch
DISTRO="${DISTRO_STRING%%-*}"

# To test generated images before they get into "production" vagran-make-cache.sh
# suffixes them with "-new", so they're not picked automatically by the pipeline
# and we can test them separately first without affecting the CI.
if [[ $DISTRO_STRING =~ -new$ ]]; then
    # Tell the respective Vagrantfile to use a test box name/url instead of the
    # regular ("production") one
    export VAGRANT_TEST_IMAGE=1
    # Drop the '-new' suffix from the distro string to use the "standard"
    # bootstrap scripts
    DISTRO_STRING="${DISTRO_STRING%-new}"
fi

# If the distro string is in "<distro>-sanitizers-*" format, we're testing
# systemd using various sanitizers (ASan, UBSan, etc.) and due to performance
# issue we want to skip certain steps (like reboot and integration tests).
if [[ $DISTRO_STRING =~ -sanitizers- ]]; then
    USING_SANITIZERS=true
fi

# Decide which Vagrant file to use
VAGRANT_FILE="$VAGRANT_FILES/Vagrantfile_$DISTRO"
# Use a custom external script, so we can use one Vagrantfile with multiple
# different scripts instead of having multiple Vagrantfiles with inlined
# scripts
BOOTSTRAP_SCRIPT="${VAGRANT_BOOTSTRAP_SCRIPT:-$VAGRANT_BOOTSTRAP_SCRIPTS/$DISTRO_STRING.sh}"
# Pick the respective test script for given distro string
TEST_SCRIPT="${VAGRANT_TEST_SCRIPT:-$VAGRANT_TEST_SCRIPTS/test-$DISTRO_STRING.sh}"

if [[ ! -f $VAGRANT_FILE ]]; then
    echo >&2 "No Vagrantfile found for distro '$DISTRO'"
    exit 1
fi

if [[ ! -f $BOOTSTRAP_SCRIPT ]]; then
    echo >&2 "Bootstrap script '$BOOTSTRAP_SCRIPT' not found"
    exit 1
fi

if [[ ! -f $TEST_SCRIPT ]]; then
    echo >&2 "Test script '$TEST_SCRIPT' not found"
    exit 1
fi

# Configure environment (following env variables are used in the respective
# Vagrantfile)
export SYSTEMD_ROOT="${SYSTEMD_ROOT:-$HOME/systemd}"
export VAGRANT_DRIVER="${VAGRANT_DRIVER:-kvm}"
export VAGRANT_MEMORY="${VAGRANT_MEMORY:-8192}"
if [[ "$(hostnamectl --static)" =~ .dusty.ci.centos.org$ ]]; then
    # All dusty machines have Intel Xeon CPUs with 4 cores and HT enabled,
    # which causes issues when the HT cores are counted as "real" ones, namely
    # CPU over-saturation and strange hangups. As all dusty server have the
    # same HW, let's manually override the # of CPUs for the VM to 4.
    export VAGRANT_CPUS=4
else
    export VAGRANT_CPUS="${VAGRANT_CPUS:-8}"
fi
export VAGRANT_BOOTSTRAP_SCRIPT="$BOOTSTRAP_SCRIPT"

# Absolute systemd git root path on the host machine
TEST_DIR="$(mktemp -d "$SYSTEMD_ROOT/vagrant-$DISTRO_STRING-config.XXX")"
# Relative path (i.e just the vagrant-$DISTRO_STRING.XXX dir) used for navigation
# in the guest VM
RELATIVE_TEST_DIR="${TEST_DIR##*/}"

# Copy the target Vagrant file to the test dir
cp "$VAGRANT_FILE" "$TEST_DIR/Vagrantfile"
cp "$VAGRANT_ROOT/../common/task-control.sh" "$TEST_DIR/task-control.sh"
cp "$VAGRANT_ROOT/../common/utils.sh" "$TEST_DIR/utils.sh"
pushd "$TEST_DIR" || { echo >&2 "Can't pushd to $TEST_DIR"; exit 1; }
# Copy the test script to the test dir
# Note: -L is necessary, since some test script may be symlinks, to avoid
#       code duplication
cp -L "$TEST_SCRIPT" "$TEST_DIR/"

# Provision the machine
vagrant up --no-tty --provider=libvirt

set +e

if $USING_SANITIZERS; then
    # Skip the reboot/reload when running with sanitizers, as it in most cases
    # causes boot to timeout or die completely
    # Run tests with sanitizers
    vagrant ssh -c "cd /build && sudo $RELATIVE_TEST_DIR/${TEST_SCRIPT##*/} $DISTRO_STRING"
    SSH_EC=$?
else
    # Reboot the VM to "apply" the new systemd
    timeout 5m vagrant reload
    case $? in
        0)
            ;;
        124)
            echo >&2 "Timeout during machine reboot"
            exit 124
            ;;
        *)
            echo >&2 "Failed to reboot the VM using 'vagrant reload'"
            exit 1
            ;;
    esac
    # Run tests
    vagrant ssh -c "cd /build && sudo $RELATIVE_TEST_DIR/${TEST_SCRIPT##*/} $DISTRO_STRING"
    SSH_EC=$?
fi

if [[ $SSH_EC -ne 0 ]]; then
    echo >&2 "'vagrant ssh' exited with an unexpected EC: $SSH_EC"
    exit $SSH_EC
fi

# Destroy the VM
vagrant destroy -f
popd
