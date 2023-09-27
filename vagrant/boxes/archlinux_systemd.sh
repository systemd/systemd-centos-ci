#!/bin/bash
set -eux
set -o pipefail

whoami

# We should have a working TPM 2.0 device
stat /dev/tpm0
[[ "$(</sys/class/tpm/tpm0/tpm_version_major)" == 2 ]]

# Clear Pacman's caches
pacman --noconfirm -Scc
rm -fv /var/lib/pacman/sync/*.db
# Initialize pacman's keyring
pacman-key --init
pacman-key --populate archlinux
pacman --needed --noconfirm -Sy archlinux-keyring
# Upgrade the system
pacman --noconfirm -Syu
# Install build dependencies
# Package groups: base, base-devel
pacman --needed --noconfirm -Sy base base-devel bpf btrfs-progs acl audit bash-completion clang compiler-rt docbook-xsl \
    ethtool gdm git gnu-efi-libs gperf intltool iptables kexec-tools kmod libbpf libcap libelf libfido2 libgcrypt libidn2 \
    libmicrohttpd libpwquality libseccomp libutil-linux libxkbcommon libxslt linux-api-headers llvm llvm-libs lvm2 lz4 \
    meson multipath-tools ninja p11-kit pam pcre2 pesign python-jinja python-lxml python-pillow qrencode quota-tools rust \
    sbsigntools tpm2-pkcs11 xz
# Install test dependencies
# Note: openbsd-netcat in favor of gnu-netcat is used intentionally, as
#       the GNU one doesn't support -U option required by test/TEST-12-ISSUE-3171
pacman --needed --noconfirm -S coreutils bind busybox cpio dhclient dhcp dhcpcd diffutils dnsmasq dosfstools e2fsprogs erofs-utils \
    evemu expect fsverity-utils gdb inetutils jq knot keyutils lcov libdwarf libelf mdadm mtools net-tools nfs-utils nftables ntp \
    openbsd-netcat open-iscsi perl-capture-tiny perl-datetime perl-json-xs python-pefile python-pexpect python-psutil python-pyelftools \
    python-pyparsing python-pytest rsync screen socat squashfs-tools strace stress time tpm2-tools swtpm vim wireguard-tools

# Unlock root account and set its password to 'vagrant' to allow root login
# via ssh
echo -e 'vagrant\nvagrant' | passwd
passwd -S root
echo "PermitRootLogin yes" >>/etc/ssh/sshd_config

# Create /etc/localtime
systemd-firstboot --timezone=UTC

# Change the default locale from C.UTF-8
localectl set-locale en_US.UTF-8

# Enable GDM by default (to catch certain systemd-logind related issues)
systemctl enable gdm.service
systemctl set-default graphical.target
systemctl get-default

cd /tmp

# Compile & install tgt (iSCSI target utils)
pacman --needed --noconfirm -S docbook-xsl libxslt perl-config-general
git clone --depth=1 https://github.com/fujita/tgt
pushd tgt
make sbindir=/usr/bin ISCSI=1
make sbindir=/usr/bin install
install -Dm644 scripts/tgtd.service /usr/lib/systemd/system/tgtd.service
# Workaround for a race condition when starting tgtd
# See:
#   * https://bugzilla.redhat.com/show_bug.cgi?id=848942
#   * https://src.fedoraproject.org/rpms/scsi-target-utils/c/3a25fe7a57200b61ecebcec0d867671597080196?branch=rawhide
#   * https://src.fedoraproject.org/rpms/scsi-target-utils/c/5de1dd10b8804e555c1c010c1af52a4415155971?branch=rawhide
sed -i '/^ExecStart=\/usr\/sbin\/tgtd/aExecStartPost=\/bin\/sleep 5' /usr/lib/systemd/system/tgtd.service
popd
rm -fr tgt
tgtadm --version

# Compile & install netlabel_tools
pacman --needed --noconfirm -S autoconf automake gcc libtool make pkg-config
git clone --depth=1 https://github.com/netlabel/netlabel_tools
pushd netlabel_tools
./autogen.sh
./configure --prefix=/usr
make -j
make install
popd
rm -fr netlabel_tools
netlabelctl --help

# Compile & install radvd
# FIXME: drop once [0] is released & lands in Arch Linux
# [0] https://github.com/radvd-project/radvd/pull/141
pacman --needed --noconfirm -S autoconf automake byacc flex gcc libbsd libtool make pkg-config
git clone --depth=1 https://github.com/radvd-project/radvd
pushd radvd
./autogen.sh
./configure --prefix=/usr --sysconfdir=/etc --mandir=/usr/share/man
make -j
make install
popd
rm -fr radvd
# radvd returns 1 for both --version and --help, so we need to be a bit more creative here
(radvd --version || :) |& grep "^Version"

# Compile & install dfuzzer
pacman --needed --noconfirm -S docbook-xsl gcc glib2 libxslt meson pkg-config
git clone --depth=1 https://github.com/dbus-fuzzer/dfuzzer
pushd dfuzzer
meson build
ninja -C build install
popd
rm -fr dfuzzer
dfuzzer --version

# Configure a FIDO2 QEMU device using CanoKey
#
# This has 2 steps:
#   1) Build & install canokey-qemu
#   2) Rebuild QEMU with --enable-canokey
#
# After this we should have a CanoKey device available through
#   qemu-system-x86_64 -usb -device canokey,file=...
#
# References:
#   - https://www.qemu.org/docs/master/system/devices/canokey.html
#   - https://github.com/canokeys/canokey-qemu
#
# 1) Build & install canokey-qemu
pacman --needed --noconfirm -S cmake gcc make patch pkgconf
git clone --depth=1 --recursive https://github.com/canokeys/canokey-qemu
mkdir canokey-qemu/build
pushd canokey-qemu/build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr
make -j
make install
popd
rm -fr canokey-qemu
pkg-config --libs --cflags canokey-qemu

# 2) Rebuild QEMU with --enable-canokey
#
# 2a) Since makepkg won't run under root, we need to create a separate user
#     and give it access to paswordless sudo
useradd --create-home builder
mkdir -p /etc/sudoers.d
echo "builder ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/builder

# 2b) Patch QEMU's PKGBUILD, rebuild it, and install the rebuilt packages
pacman --needed --noconfirm -S bison fakeroot flex
git clone --depth=1 https://gitlab.archlinux.org/archlinux/packaging/packages/qemu.git
chown -R builder qemu
pushd qemu
sed -i 's/^pkgrel=.*$/pkgrel=999/' PKGBUILD
sed -i '/local configure_options=(/a\    --enable-canokey' PKGBUILD
# The GPG key ID can be found at https://www.qemu.org/download/
runuser -u builder -- gpg --receive-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584
runuser -u builder -- makepkg --noconfirm --needed --clean --syncdeps --rmdeps
# This part is a bit convoluted, since we can't use makepkg --install or install
# all the just built packages explicitly, as some of the packages conflict with
# each other. So, in order to leave dependency resolving on pacman, let's create
# a local repo from the just built packages and instruct pacman to use it
repo-add "$PWD/qemu.db.tar.gz" ./*.zst
cp /etc/pacman.conf pacman.conf
echo -ne "[qemu]\nSigLevel=Optional\nServer=file://$PWD\n" >>pacman.conf
# Note: we _need_ to prefix the qemu-base meta package with our local repo name,
#       otherwise pacman will install the first qemu-base package it encounters,
#       which would be the regular one from the extras repository
pacman --noconfirm -Sy qemu/qemu-base --config pacman.conf
popd
rm -fr qemu
qemu-system-x86_64 -usb -device canokey,help

# 2c) Cleanup
rm /etc/sudoers.d/builder
userdel -fr builder

# Replace systemd-networkd with dhcpcd as the network manager for the default
# interface, so we can run the systemd-networkd test suite without having
# to worry about the network staying up
#
# Tell systemd-networkd to ignore eth0 netdev, so we can keep it up
# during the systemd-networkd testsuite
cat >/etc/systemd/network/eth0.network <<EOF
[Match]
Name=eth0

[Link]
Unmanaged=yes
EOF
# Remove the image-supplied eth* network file
rm -fv /etc/systemd/network/80-dhcp.network
# Enable dhcpcd for the eth0 interface
systemctl enable dhcpcd@eth0.service

# Replace GRUB with systemd-boot
#
# Note: this doesn't update the mkinitcpio preset file (/etc/mkinitcpio.d/linux.preset)
#       so any future updates of kernel/initrd will still get installed under /boot.
#       However, we don't really care about this as this is a single-purpose CI image.
MACHINE_ID="$(</etc/machine-id)"
KERNEL_VER="$(pacman -Q linux | sed -r 's/^linux\s+([0-9\.]+)\.(.+)$/\1-\2/')"

bootctl install
cat >/efi/loader/entries/arch.conf <<EOF
title ArchLinux
linux /$MACHINE_ID/$KERNEL_VER/linux
initrd /$MACHINE_ID/$KERNEL_VER/initrd
options root=UUID=$(findmnt -n -o UUID /) rw console=ttyS0 net.ifnames=0
EOF
# Follow the recommended layout from the Boot Loader Specification
mkdir -p "/efi/$MACHINE_ID/$KERNEL_VER"
mv -v /boot/vmlinuz-linux "/efi/$MACHINE_ID/$KERNEL_VER/linux"
mv -v /boot/initramfs-linux.img "/efi/$MACHINE_ID/$KERNEL_VER/initrd"
bootctl status
pacman -Rcnsu --noconfirm grub
# shellcheck disable=SC2114
rm -rf /boot
