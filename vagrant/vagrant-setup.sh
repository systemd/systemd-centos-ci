#!/usr/bin/bash
# Simple script which installs Vagrant to a machine from CentOS CI
# infrastructure if not already installed. The script also installs
# vagrant-libvirt module to support "proper" virtualization (kvm/qemu) instead
# of default containers.

VAGRANT_PKG_URL="https://releases.hashicorp.com/vagrant/2.2.9/vagrant_2.2.9_x86_64.rpm"

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

# Configure NTP (chronyd)
if ! rpm -q chrony; then
    $PKG_MAN -y install chrony
fi

systemctl enable --now chronyd
systemctl status chronyd

# Configure Vagrant
if ! vagrant version 2>/dev/null; then
    # Install Vagrant
    $PKG_MAN -y install "$VAGRANT_PKG_URL"
fi

# Workaround for current Vagrant's DSO hell
# ---
# The krb5-libs RPM is compiled with --with-crypto-impl=openssl, which
# includes symbols, that are not available in the Vagrant's embedded OpenSSL
# library, causing errors like:
#   /opt/vagrant/embedded/lib64/libk5crypto.so.3: undefined symbol: EVP_KDF_ctrl, version OPENSSL_1_1_1b

# Workaround this by compiling a local version of the krb5-libs using the
# builtin crypto implementation and copying the built libraries into
# the embedded lib dir.
#
# See:
#   https://github.com/hashicorp/vagrant/issues/11020
#   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/1031
#   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/943
(
    BUILD_DIR="$(mktemp -d)"
    pushd "$BUILD_DIR"
    $PKG_MAN -y install gcc byacc tar make
    $PKG_MAN download --source krb5
    rpm2cpio krb5-*.src.rpm | cpio -imdV
    tar xf krb5-*.tar.gz
    cd krb5-*/src
    ./configure --with-crypto-impl=builtin
    make -j $(($(nproc) * 2))
    cp -a lib/crypto/libk5crypto.* /opt/vagrant/embedded/lib64/
    popd
    rm -fr "$BUILD_DIR"
)

if ! vagrant plugin list | grep vagrant-libvirt; then
    # Install vagrant-libvirt dependencies
    $PKG_MAN -y install gcc libguestfs-tools-c libvirt libvirt-devel make qemu-kvm ruby-devel
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
rpm -q nfs-utils || $PKG_MAN -y install nfs-utils
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
