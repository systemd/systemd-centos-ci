#!/usr/bin/bash
# Simple script which installs Vagrant to a machine from CentOS CI
# infrastructure if not already installed. The script also installs
# vagrant-libvirt module to support "proper" virtualization (kvm/qemu) instead
# of default containers.

VAGRANT_PKG_URL="https://releases.hashicorp.com/vagrant/2.2.16/vagrant_2.2.16_x86_64.rpm"
WORKAROUNDS_DIR="$(dirname "$(readlink -f "$0")")/workarounds"

set -eu
set -o pipefail

# Set up nested KVM
# Let's make all errors "soft", at least for now, as we're still perfectly
# fine with running tests without nested KVM
if KVM_MODULE_NAME="$(lsmod | grep -m1 -Eo '(kvm_intel|kvm_amd)')"; then
    echo "[vagrant-setup] Detected KVM module: $KVM_MODULE_NAME"
    # Attempt to reload the detected KVM module with nested=1 parameter
    if modprobe -v -r "$KVM_MODULE_NAME" && modprobe -v "$KVM_MODULE_NAME" nested=1; then
        # The reload was successful, check if the module's 'nested' parameter
        # confirms that nested KVM is indeed enabled
        KVM_MODULE_NESTED="$(< "/sys/module/$KVM_MODULE_NAME/parameters/nested")" || :
        echo "[vagrant-setup] /sys/module/$KVM_MODULE_NAME/parameters/nested: $KVM_MODULE_NESTED"

        if [[ "$KVM_MODULE_NESTED" =~ (1|Y) ]]; then
            echo "[vagrant-setup] Nested KVM is enabled"
        else
            echo "[vagrant-setup] Failed to enable nested KVM"
        fi
    else
        echo "[vagrant-setup] Failed to reload module '$KVM_MODULE_SETUP'"
    fi
else
    echo "[vagrant-setup] No KVM module found, can't setup nested KVM"
fi

# Configure NTP (chronyd)
if ! rpm -q chrony; then
    dnf -y install chrony
fi

systemctl enable --now chronyd
systemctl status chronyd

# Configure Vagrant
if ! vagrant version 2>/dev/null; then
    # Install Vagrant
    dnf -y install "$VAGRANT_PKG_URL"
fi

# To speed up Vagrant jobs, let's use a pre-compiled bundle with the necessary
# shared libraries. See vagrant/workarounds/build-shared-libs.sh for more info.
if [[ -e "$WORKAROUNDS_DIR/vagrant-shared-libs.tar.gz" ]]; then
    echo "[vagrant-setup] Found pre-compiled shared libs, unpacking..."
    command -v tar >/dev/null || dnf -q -y install tar
    tar -xzvf "$WORKAROUNDS_DIR/vagrant-shared-libs.tar.gz" -C /opt/vagrant/embedded/lib64/
fi

if ! vagrant plugin list | grep vagrant-libvirt; then
    # Install vagrant-libvirt dependencies
    dnf -y install gcc libguestfs-tools-c libvirt libvirt-devel libgcrypt make qemu-kvm ruby-devel

    # FIXME?: install newer qemu-kvm
    dnf -y install dnf-plugins-core
    # Local mirror of https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/
    dnf -y config-manager --add-repo "http://artifacts.ci.centos.org/systemd/repos/mrc0mmand-systemd-centos-ci-centos8-epel8/mrc0mmand-systemd-centos-ci-centos8-epel8.repo"
    # Note: this is necessary, because a package from a module shadows every other
    #       package with the same name even if it's newer than the module one,
    #       *sigh*. See: https://access.redhat.com/solutions/5588101
    dnf -y module disable virt
    dnf -y update qemu-kvm
    dnf -y module enable virt

    # Start libvirt daemon
    systemctl start libvirtd
    systemctl status libvirtd
    # Sanity-check if Vagrant is correctly installed
    vagrant version
    # Install vagrant-libvirt plugin
    # See: https://github.com/vagrant-libvirt/vagrant-libvirt
    # Env variables taken from https://github.com/vagrant-libvirt/vagrant-libvirt#possible-problems-with-plugin-installation-on-linux
    export CONFIGURE_ARGS='with-ldflags="-L/opt/vagrant/embedded/lib64 -L/opt/vagrant/embedded/lib" with-libvirt-include=/usr/include/libvirt with-libvirt-lib=/usr/lib'
    export GEM_HOME=~/.vagrant.d/gems
    export GEM_PATH=$GEM_HOME:/opt/vagrant/embedded/gems
    export PATH=/opt/vagrant/embedded/bin:$PATH
    vagrant plugin install vagrant-libvirt
fi

vagrant --version
vagrant plugin list

# Configure NFS for Vagrant's shared folders
rpm -q nfs-utils || dnf -y install nfs-utils
systemctl stop nfs-server
systemctl start proc-fs-nfsd.mount
lsmod | grep -E '^nfs$' || modprobe -v nfs
lsmod | grep -E '^nfsd$' || modprobe -v nfsd
echo 10 > /proc/sys/fs/nfs/nlm_grace_period
echo 10 > /proc/fs/nfsd/nfsv4gracetime
echo 10 > /proc/fs/nfsd/nfsv4leasetime
systemctl enable  nfs-server
systemctl restart nfs-server
systemctl status nfs-server
sleep 10

# Debug for #272
echo "[DEBUG] Simulate Vagrant's nfs_installed check"
/usr/bin/systemctl list-units '*nfs*server*' --no-pager --no-legend
/bin/sh -c "systemctl --no-pager --no-legend --plain list-unit-files --all --type=service | grep nfs-server.service"
echo "[DEBUG] End"
