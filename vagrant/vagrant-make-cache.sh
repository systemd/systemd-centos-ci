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

set -eux
set -o pipefail

DUFFY_SSH_KEY="/root/.ssh/duffy.key"
VAGRANT_ROOT="$(dirname "$(readlink -f "$0")")"
VAGRANT_FILE="$VAGRANT_ROOT/boxes/${1:?Missing argument: Vagrantfile}"

if [[ ! -e "$DUFFY_SSH_KEY" ]]; then
    echo >&2 "Missing Duffy SSH key, can't continue"
    exit 1
fi

if [[ ! -f "$VAGRANT_FILE" ]]; then
    echo >&2 "Couldn't find Vagrantfile '$VAGRANT_FILE'"
    exit 1
fi

# Disable SELinux on the test hosts and avoid false positives.
sestatus | grep -E "SELinux status:\s*disabled" || setenforce 0

# Install vagrant if not already installed
"$VAGRANT_ROOT"/vagrant-setup.sh

# Stop firewalld
systemctl -q is-enabled firewalld && systemctl disable --now firewalld
systemctl restart libvirtd

mkdir vagrant_cache
pushd vagrant_cache

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
fi

echo "Installing btrfs-aware packages"
dnf -y install centos-release-hyperscale-experimental
dnf -y install btrfs-progs kernel libguestfs-tools-c
# Add the btrfs-progs package to the guestfs image
echo "btrfs-progs" >>/usr/lib64/guestfs/supermin.d/packages

# Start a VM described in the Vagrantfile with all provision steps
export VAGRANT_DRIVER="${VAGRANT_DRIVER:-kvm}"
export VAGRANT_MEMORY="${VAGRANT_MEMORY:-8192}"
export VAGRANT_CPUS="${VAGRANT_CPUS:-$(nproc)}"

# Provision the VM
cp "$VAGRANT_FILE" Vagrantfile
cp "$VAGRANT_ROOT"/boxes/*.sh .
vagrant up --no-tty --provider=libvirt
# Make sure the VM is bootable after running the provision script
timeout -v 5m vagrant reload
# shellcheck disable=SC2016
vagrant ssh -c 'set -x; sudo bootctl status; cat /etc/machine-id; sudo ls -lR /efi; sudo test -e "/efi/$(</etc/machine-id)"'
vagrant halt

# Workaround for `virt-{sysprep,resize,...}` - work with the image via qemu directly
# instead of using libvirt
export LIBGUESTFS_BACKEND=direct

# A very convoluted way to expand the backing image from the original 20G (ATTOW)
# to something more usable
if [[ "${VAGRANT_FILE##*/}" == "Vagrantfile_archlinux_systemd" ]]; then
    LIBVIRT_IMAGE="/var/lib/libvirt/images/vagrant_cache_archlinux_systemd.img"

    virt-cat -a "$LIBVIRT_IMAGE" /etc/machine-id

    # Convert the qcow2 image back into a raw one so it's easier to manipulate with
    qemu-img convert -f qcow2 -O raw "$LIBVIRT_IMAGE" image.raw
    # Prepare a sparse file for the expanded image
    truncate -r image.raw new_image.raw
    truncate -s +100G new_image.raw
    # Expand the last partition in the image
    LAST_PART="$(virt-filesystems --parts -a image.raw | sort -r | head -n1)"
    virt-resize --expand "$LAST_PART" image.raw new_image.raw
    # Convert the new image back to qcow2 and copy it back to the libvirt storage
    # (and hope for the best)
    qemu-img convert -f raw -O qcow2 new_image.raw "$LIBVIRT_IMAGE"
    rm -f image.raw

    virt-cat -a "$LIBVIRT_IMAGE" /etc/machine-id

    # Check if the new image boots
    vagrant up
    vagrant ssh -c 'set -x; lsblk; df -h /; cat /etc/machine-id; sudo ls -lR /efi; sudo test -e "/efi/$(</etc/machine-id)"'
    vagrant halt

    virt-cat -a "$LIBVIRT_IMAGE" /etc/machine-id
fi

# Create a box from the VM, so it can be reused later. The box name is suffixed
# with '-new' to avoid using it immediately in "production".
# Output file example:
#   boxes/Vagrantfile_archlinux_systemd => archlinux_systemd-new
BOX_NAME="${VAGRANT_FILE##*/Vagrantfile_}-new"
# You guessed it, another workaround - let's include the original
# Vagrantfile as well, as it usually contains important settings
# which make the box actually bootable. For this, we need to detect the location
# of the box, from the original box name (i.e. generic/arch, see the
# beautiful awk below), and then transform it to a path to the Vagrantfile,
# which contains the box name, but all slashes are replaced by
# "-VAGRANTSLASH-" (and that's what the bash substitution is for)
ORIGINAL_BOX_NAME="$(awk 'match($0, /^[^#]*config.vm.box\s*=\s*"([^"]+)"/, m) { print m[1]; exit 0; }' "$VAGRANT_FILE")"
export VAGRANT_LIBVIRT_VIRT_SYSPREP_OPERATIONS="defaults,-machine-id"
vagrant package --no-tty --output "$BOX_NAME" --vagrantfile ~/.vagrant.d/boxes/"${ORIGINAL_BOX_NAME//\//-VAGRANTSLASH-}"/*/libvirt/Vagrantfile
# Remove the VM we just packaged
vagrant destroy -f

# Check if we can build a usable VM from the just packaged box
TEST_DIR="$(mktemp -d testbox.XXX)"

mkdir _foo
pushd _foo
tar xvf  "../$BOX_NAME"
virt-cat -a box.img /etc/machine-id
popd
rm -fr _foo

vagrant box remove -f testbox || :
vagrant box add --name testbox "$BOX_NAME"
pushd "$TEST_DIR"
cat >Vagrantfile <<EOF
Vagrant.configure("2") do |config|
    config.vm.define :testbox_vm
    config.vm.box = "testbox"

    # Test root login via SSH, since that's what we use in tests
    config.ssh.username = "root"
    config.ssh.password = "vagrant"
    config.ssh.insert_key = "true"
    config.vm.synced_folder '.', '/vagrant', disabled: true

    config.vm.provider :libvirt do |libvirt|
        libvirt.random :model => 'random'
        libvirt.machine_type = "q35"
        libvirt.loader = "/usr/share/OVMF/OVMF_CODE.fd"
        libvirt.nvram = "/tmp/OVMF_VARS.fd"
    end

end
EOF
cp -fvL /usr/share/OVMF/OVMF_VARS.fd /tmp
chmod o+rw /tmp/OVMF_VARS.fd
vagrant up --no-tty --provider=libvirt
# shellcheck disable=SC2016
vagrant ssh -c 'bash -exc "bootctl status; uname -a; id; [[ $UID == 0 ]]"; cat /etc/machine-id; ls -lR /efi; test -e "/efi/$(</etc/machine-id)"'

# Cleanup
vagrant halt
vagrant destroy -f
vagrant box remove -f testbox
popd && rm -fr "$TEST_DIR"

# Upload the box to the CentOS CI artifact storage

# Little workaround to create a proper directory hierarchy on the server
mkdir vagrant_boxes
mv "$BOX_NAME" vagrant_boxes

rsync -e "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $DUFFY_SSH_KEY" -av "vagrant_boxes" systemd@artifacts.ci.centos.org:/srv/artifacts/systemd/
echo "Box URL: https://artifacts.ci.centos.org/systemd/vagrant_boxes/$BOX_NAME"
