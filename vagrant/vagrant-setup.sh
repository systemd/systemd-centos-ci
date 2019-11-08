#!/usr/bin/bash
# Simple script which installs Vagrant to a machine from CentOS CI
# infrastructure if not already installed. The script also installs
# vagrant-libvirt module to support "proper" virtualization (kvm/qemu) instead
# of default containers.

VAGRANT_PKG_URL="https://releases.hashicorp.com/vagrant/2.2.4/vagrant_2.2.4_x86_64.rpm"

set -o pipefail
set -e -u

# Use dnf if present, otherwise fall back to yum
command -v dnf > /dev/null && PKG_MAN=dnf || PKG_MAN=yum

# Set up nested KVM
# Let's make all errors "soft", at least for now, as we're still perfectly
# fine with running tests without nested KVM
if KVM_MODULE_NAME="$(lsmod | grep -m1 -Eo '(kvm_intel|kvm_amd)')"; then
    echo "[vagrant-setup] Detected KVM module: $KVM_MODULE_NAME"
    # Attempt to reload the detected KVM module with nested=1 parameter
    if modprobe -v -r $KVM_MODULE_NAME && modprobe -v $KVM_MODULE_NAME nested=1; then
        # The reload was successful, check if the module's 'nested' parameter
        # confirms that nested KVM is indeed enabled
        KVM_MODULE_NESTED="$(< /sys/module/$KVM_MODULE_NAME/parameters/nested)" || :
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

if ! vagrant version 2>/dev/null; then
    # Install Vagrant
    $PKG_MAN -y install "$VAGRANT_PKG_URL"
fi

if ! vagrant plugin list | grep vagrant-libvirt; then
    # Install vagrant-libvirt dependencies
    $PKG_MAN -y install libvirt libvirt-devel ruby-devel gcc qemu-kvm libguestfs-tools-c
    # Start libvirt daemon
    systemctl start libvirtd
    systemctl status libvirtd
    # Sanity-check if Vagrant is correctly installed
    vagrant version
    # Install vagrant-libvirt plugin
    # See: https://github.com/vagrant-libvirt/vagrant-libvirt
    vagrant plugin install vagrant-libvirt
fi

vagrant --version
vagrant plugin list
