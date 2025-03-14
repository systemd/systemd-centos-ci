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
    evemu expect fsverity-utils gdb gnutls inetutils jq knot keyutils lcov libdwarf libelf mdadm mtools net-tools nfs-utils \
    nftables nmap ntp nvme-cli open-iscsi openbsd-netcat opensc perl-capture-tiny perl-datetime perl-json-xs python-pefile python-pexpect \
    python-psutil python-pyelftools python-pyparsing python-pytest rsync screen socat squashfs-tools strace stress stress-ng time \
    tpm2-tools softhsm swtpm vim wireguard-tools qemu-base
# Install SELinux-aware packages
# See:
#   - https://github.com/archlinuxhardened/selinux
#   - https://wiki.archlinux.org/title/SELinux
cat >>/etc/pacman.conf <<EOF
[selinux]
Server = https://github.com/archlinuxhardened/selinux/releases/download/ArchLinux-SELinux
SigLevel = Never
EOF
# Note: can't use --noconfirm here, as the default resolution for a package conflict is to bail out, so pacman just
#       exits without replacing any packages. Also, ignore SIGPIPE from `yes`.
set +o pipefail
yes y | pacman --needed -Sy checkpolicy coreutils-selinux findutils-selinux libselinux libsemanage libsepol pam-selinux \
    pambase-selinux policycoreutils psmisc-selinux selinux-refpolicy-arch semodule-utils util-linux-selinux
set -o pipefail

# FIXME: downgrade screen to < 5.0.0, as it's a bit broken
# See: https://savannah.gnu.org/bugs/?66171
pacman --noconfirm -U https://archive.archlinux.org/packages/s/screen/screen-4.9.1-2-x86_64.pkg.tar.zst

# FIXME: downgrade tzdata to 2024a, since 2024b breaks test-time-util
# See: https://github.com/systemd/systemd/issues/34471
pacman --noconfirm -U https://archive.archlinux.org/packages/t/tzdata/tzdata-2024a-2-x86_64.pkg.tar.zst

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

# Since makepkg won't run under root, we need to create a separate use and give it
# access to paswordless sudo
useradd --create-home builder
mkdir -p /etc/sudoers.d
echo "builder ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/builder

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

# Remove the makepkg user
rm /etc/sudoers.d/builder
userdel -fr builder

# Replace systemd-networkd with dhcpcd as the network manager for the default
# interface, so we can run the systemd-networkd test suite without having
# to worry about the network staying up
#
# Tell systemd-networkd to ignore eth0 netdev, so we can keep it up
# during the systemd-networkd testsuite
cat >/etc/systemd/network/10-eth0.network <<EOF
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
# Since the linux{,-lts} package version format differs from the version reported by
# `uname -a`, let's just parse the version part from the full path to the actual kernel
# image in the respective kernel package. The additional sed shenanigans just ensure
# we return non-zero if we, for whatever reason, fail to parse the version, just to make
# debugging easier.
KERNEL_VER="$(pacman -Ql linux | grep vmlinuz | sed -nr 's/^.+\/([^/]+)\/vmlinuz$/\1/p;tx;q1;:x')"
BOOT="$(bootctl --print-boot-path)"

bootctl install
cat >"$BOOT/loader/entries/arch.conf" <<EOF
title ArchLinux
linux /$MACHINE_ID/$KERNEL_VER/linux
initrd /$MACHINE_ID/$KERNEL_VER/initrd
options root=UUID=$(findmnt -n -o UUID /) rw console=ttyS0 net.ifnames=0
EOF
# Follow the recommended layout from the Boot Loader Specification
mkdir -p "$BOOT/$MACHINE_ID/$KERNEL_VER"
mv -v /boot/vmlinuz-linux "$BOOT/$MACHINE_ID/$KERNEL_VER/linux"
mv -v /boot/initramfs-linux.img "$BOOT/$MACHINE_ID/$KERNEL_VER/initrd"
bootctl status
pacman -Rcnsu --noconfirm grub
