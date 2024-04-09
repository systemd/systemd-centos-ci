#!/bin/bash
set -eux
set -o pipefail

dnf clean all
# Try to get the new GPG repo keys. In some situations this might fail, usually
# when we try to update the fedora-gpg-keys by two versions (e.g. 35 -> 37). In
# that case use a relatively ugly hack to force-get the latest GPG keys from
# the Rawhide repository.
if ! dnf -y update fedora-repos fedora-gpg-keys; then
  dnf -y --nogpgcheck --disablerepo '*' \
      --repofrompath the-true-rawhide,https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/ \
      update fedora-repos fedora-gpg-keys
fi

# Upgrade the system
dnf upgrade -y

# Install build & test dependencies
dnf install -y attr busybox cryptsetup dnf5-plugins dosfstools fedpkg git nc qemu-kvm rpm-build rpmdevtools rust socat \
               strace time tmt tpm2-tss-devel 'python3dist(jinja2)'
dnf builddep -y dracut systemd

# Unlock root account and set its password to 'vagrant' to allow root login
# via ssh
echo "vagrant" | passwd --stdin
passwd -S root
# Fedora's default for PermitRootLogin= is 'prohibit-password' which breaks
# Vagrant 'insert_key' feature
echo "PermitRootLogin yes" >>/etc/ssh/sshd_config

# Configure NTP (chronyd)
dnf install -y chrony
systemctl enable --now chronyd
systemctl status chronyd

# Disable 'quiet' mode on the kernel command line and forward everything
# to ttyS0 instead of just tty0, so we can collect it using QEMU's
# -serial file:xxx feature
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ { s/quiet//; s/"$/ console=ttyS0"/ }' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
