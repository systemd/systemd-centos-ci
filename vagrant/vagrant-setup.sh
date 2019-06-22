#!/usr/bin/bash
# Simple script which installs Vagrant to a machine from CentOS CI
# infrastructure if not already installed. The script also installs
# vagrant-libvirt module to support "proper" virtualization (kvm/qemu) instead
# of default containers.

VAGRANT_PKG_URL="https://releases.hashicorp.com/vagrant/2.2.4/vagrant_2.2.4_x86_64.rpm"

set -e -u
set -o pipefail

if ! vagrant version 2>/dev/null; then
    # Install Vagrant
    yum -y install "$VAGRANT_PKG_URL"
fi

if ! vagrant plugin list | grep vagrant-libvirt; then
    # Install vagrant-libvirt dependencies
    yum -y install qemu libvirt libvirt-devel ruby-devel gcc qemu-kvm libguestfs-tools-c
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
