#!/bin/bash
# Relatively simple script which updates Vagrant boxes used by systemd CentOS CI
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
VAGRANT_ROOT="$(dirname $(readlink -f $0))"
# Relative paths to cache-able Vagrantfiles
VAGRANTFILES=(
    $VAGRANT_ROOT/boxes/Vagrantfile_archlinux_systemd
)

# Install vagrant if not already installed
$VAGRANT_ROOT/vagrant-setup.sh

# Stop firewalld
systemctl stop firewalld
systemctl restart libvirtd

for vagrantfile in "${VAGRANTFILES[@]}"; do
    TEMP_DIR="$(mktemp -d vagrant-cache-XXXXX)"
    pushd "$TEMP_DIR"

    # Start a VM described in the Vagrantfile with all provision steps
    export VAGRANT_DRIVER="${VAGRANT_DRIVER:-kvm}"
    export VAGRANT_MEMORY="${VAGRANT_MEMORY:-8192}"
    export VAGRANT_CPUS="${VAGRANT_CPUS:-8}"
    export VAGRANT_DISK_BUS

    cp "$vagrantfile" Vagrantfile
    vagrant up --provider=libvirt

    # Run the following commands in a subshell, so we can do a proper cleanup
    # even in case of an error
    set +e
    (
        vagrant halt
        # Create a box from the VM, so it can be reused later
        # Output file example:
        #   boxes/Vagrantfile_archlinux_systemd => archlinux_systemd
        BOX_NAME="${vagrantfile##*/Vagrantfile_}"
        # Workaround for `virt-sysprep` - work with the image via qemu directly
        # instead of using libvirt
        export LIBGUESTFS_BACKEND=direct
        # Another, pretty ugly, workaround for `vagrant package`, where the
        # embedded `virt-sysprep` strips away vagrant's ssh keys and makes
        # any new images based on such box unusable for our purposes.
        # The temporary fix is taken from
        #   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/759#issuecomment-293585359
        # a better fix is already merged in the master of vagrant-libvirt, but
        # not yet released:
        #   https://github.com/vagrant-libvirt/vagrant-libvirt/pull/955
        # Note: this is only half of the workaround, the second half is in the
        # 'box' Vagrantfile, where the original Vagrant SSH key is not replaced
        # by a more secure one (option config.ssh.insert_key=false).
        # That's also necessary, as described here:
        #   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/759#issuecomment-432200391
        # I'm slowly starting to question my choices
        sed -i'' 's/virt-sysprep --no-logfile.*$/virt-sysprep --no-logfile --operations defaults,-ssh-userdir,-ssh-hostkeys -a #{@tmp_img}`/' $(find ~/.vagrant.d/ -name package_domain.rb)
        # You guessed it, another workaround - let's include the original
        # Vagrantfile as well, as it usually contains important settings
        # which make the box actually bootable. For this, we need to detect the location
        # of the box, from the original box name (i.e. generic/arch, see the
        # beautiful awk below), and then transform it to a path to the Vagrantfile,
        # which contains the box name, but all slashes are replaced by
        # "-VAGRANTSLASH-" (and that's what the bash substitution is for)
        ORIGINAL_BOX_NAME="$(awk 'match($0, /^[^#]*config.vm.box\s*=\s*"([^"]+)"/, m) { print m[1]; exit 0; }' "$vagrantfile")"
        vagrant package --output "$BOX_NAME" --vagrantfile ~/.vagrant.d/boxes/${ORIGINAL_BOX_NAME//\//-VAGRANTSLASH-}/*/libvirt/Vagrantfile

        # Upload the box to the CentOS CI artifact storage
        # CentOS CI rsync password is the first 13 characters of the duffy key
        PASSWORD_FILE="$(mktemp .rsync-passwd.XXX)"
        cut -b-13 "$DUFFY_KEY_FILE" > "$PASSWORD_FILE"

        # Little workaround to create a proper directory hierarchy on the server
        mkdir vagrant_boxes
        mv "$BOX_NAME" vagrant_boxes

        rsync --password-file="$PASSWORD_FILE" -av "vagrant_boxes" systemd@artifacts.ci.centos.org::systemd/
        echo "Box URL: http://artifacts.ci.centos.org/systemd/vagrant_boxes/$BOX_NAME"
    )

    if [[ $? -ne 0 ]]; then
        EC=1
    fi

    # Cleanup
    vagrant destroy -f
    rm -fr "$TEMP_DIR"
    popd
    set -e
done

exit $EC
