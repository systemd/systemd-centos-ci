#!/bin/bash
# Script which updates Vagrant boxes used by systemd CentOS CI
# with build dependencies and other configuration, so we don't have to that in
# every CI job. These updated images are then stored on the CentOS CI artifact
# server and can be reused by other CI jobs.
# This script is intended to run in CentOS CI Jenkins periodically, to keep
# the images up-to-date.
#
# In time of writing this, the setup phase, which consists of updating the
# base system in the container and installing build/test dependencies, took
# around 10 minutes, which is pretty substantial time slice for a CI run, which
# takes ~45 minutes.

set -eu
set -o pipefail

EC=0
# CentOS CI specific thing - a part of the duffy key is necessary to
# authenticate against the CentOS CI rsync server
DUFFY_KEY_FILE="/duffy.key"
VAGRANT_ROOT="$(dirname "$(readlink -f "$0")")"
VAGRANT_FILE="$VAGRANT_ROOT/boxes/${1:?Missing argument: Vagrantfile}"

if [[ ! -f "$VAGRANT_FILE" ]]; then
    echo >&2 "Couldn't find Vagrantfile '$VAGRANT_FILE'"
    exit 1
fi

# Disable SELinux on the test hosts and avoid false positives.
sestatus | grep -E "SELinux status:\s*disabled" || setenforce 0

# Install vagrant if not already installed
"$VAGRANT_ROOT"/vagrant-setup.sh

# Stop firewalld
systemctl stop firewalld
systemctl restart libvirtd

TEMP_DIR="$(mktemp -d vagrant-cache-XXXXX)"
pushd "$TEMP_DIR" || { echo >&2 "Can't pushd to $TEMP_DIR"; exit 1; }

# The URL for Fedora Rawhide Vagrant box changes over time, so let's attempt
# to get the latest one
if [[ "${VAGRANT_FILE##*/}" == "Vagrantfile_rawhide_selinux" ]]; then
    echo "Fetching Vagrant name URL for Fedora Rawhide"

    if ! BOX_NAME="$(curl -s https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Cloud/x86_64/images/ | grep -Po -m1 '(?<=")Fedora.*?vagrant-libvirt.box(?=")')"; then
        echo >&2 "Failed to fetch the box name for Fedora Rawhide (got: $BOX_NAME)"
        exit 1
    fi

    echo "Using '$BOX_NAME' as the Fedora Rawhide box name"

    sed -i "/config.vm.box_url/s/BOX-NAME-PLACEHOLDER/$BOX_NAME/" "$VAGRANT_FILE"

    echo "Installing btrfs-aware packages"
    dnf -y install centos-release-hyperscale-experimental
    dnf -y install btrfs-progs kernel libguestfs-tools-c
    # Add the btrfs-progs package to the guestfs image
    echo "btrfs-progs" >>/usr/lib64/guestfs/supermin.d/packages
fi

# Start a VM described in the Vagrantfile with all provision steps
export VAGRANT_DRIVER="${VAGRANT_DRIVER:-kvm}"
export VAGRANT_MEMORY="${VAGRANT_MEMORY:-8192}"
export VAGRANT_CPUS="${VAGRANT_CPUS:-$(nproc)}"

cp "$VAGRANT_FILE" Vagrantfile
vagrant up --no-tty --provider=libvirt
# Register a cleanup handler
# shellcheck disable=SC2064
trap "cd $PWD && vagrant destroy -f && cd / && rm -fr $TEMP_DIR" EXIT

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
vagrant halt

# Create a box from the VM, so it can be reused later. The box name is suffixed
# with '-new' to avoid using it immediately in "production".
# Output file example:
#   boxes/Vagrantfile_archlinux_systemd => archlinux_systemd-new
BOX_NAME="${VAGRANT_FILE##*/Vagrantfile_}-new"
# Workaround for `virt-sysprep` - work with the image via qemu directly
# instead of using libvirt
export LIBGUESTFS_BACKEND=direct
# You guessed it, another workaround - let's include the original
# Vagrantfile as well, as it usually contains important settings
# which make the box actually bootable. For this, we need to detect the location
# of the box, from the original box name (i.e. generic/arch, see the
# beautiful awk below), and then transform it to a path to the Vagrantfile,
# which contains the box name, but all slashes are replaced by
# "-VAGRANTSLASH-" (and that's what the bash substitution is for)
ORIGINAL_BOX_NAME="$(awk 'match($0, /^[^#]*config.vm.box\s*=\s*"([^"]+)"/, m) { print m[1]; exit 0; }' "$VAGRANT_FILE")"
vagrant package --no-tty --output "$BOX_NAME" --vagrantfile ~/.vagrant.d/boxes/"${ORIGINAL_BOX_NAME//\//-VAGRANTSLASH-}"/*/libvirt/Vagrantfile

# Check if we can build a usable VM from the just packaged box
(
    TEST_DIR="$(mktemp -d testbox.XXX)"
    INNER_EC=0

    vagrant box remove -f testbox || :
    vagrant box add --name testbox "$BOX_NAME"
    pushd "$TEST_DIR"
    vagrant init testbox
    # Test root login via SSH, since that's what we use in tests
    sed -i '/^Vagrant.configure/a\  config.ssh.username = "root"' Vagrantfile
    sed -i '/^Vagrant.configure/a\  config.ssh.password = "vagrant"' Vagrantfile
    sed -i '/^Vagrant.configure/a\  config.ssh.insert_key = "true"' Vagrantfile
    vagrant up --no-tty --provider=libvirt
    # shellcheck disable=SC2016
    vagrant ssh -c 'bash -exc "uname -a; id; [[ $UID == 0 ]]"' || INNER_EC=1

    # Cleanup
    vagrant destroy -f
    vagrant box remove -f testbox
    popd && rm -fr "$TEST_DIR"

    exit $INNER_EC
)

# Upload the box to the CentOS CI artifact storage
# CentOS CI rsync password is the first 13 characters of the duffy key
PASSWORD_FILE="$(mktemp .rsync-passwd.XXX)"
cut -b-13 "$DUFFY_KEY_FILE" > "$PASSWORD_FILE"

# Little workaround to create a proper directory hierarchy on the server
mkdir vagrant_boxes
mv "$BOX_NAME" vagrant_boxes

rsync --password-file="$PASSWORD_FILE" -av "vagrant_boxes" systemd@artifacts.ci.centos.org::systemd/
echo "Box URL: http://artifacts.ci.centos.org/systemd/vagrant_boxes/$BOX_NAME"

exit $EC
