#!/bin/bash
# Vagrant provider for a standard systemd setup

set -eu
set -o pipefail

whoami
uname -a

# Do a system upgrade
dnf upgrade -y

# Let's make the $BUILD_DIR for meson reside outside of the NFS volume mounted
# under /build to avoid certain race conditions, like:
# /usr/bin/ld: error: /build/build/src/udev/libudev.so.1: file too short
# The same path must be exported in the respective tests scripts (vagrant-test.sh,
# etc.) so the unit & integration tests can find the compiled binaries
# Note: avoid using /tmp or /var/tmp, as certain tests use binaries from the
#       buildir in combination with PrivateTmp=true
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Use systemd repo path specified by SYSTEMD_ROOT
pushd /build

# Dump list of installed packages
rpm -qa > vagrant-rawhide-installed-pkgs.txt
# Dump additional OS info
{
    echo "### CPUINFO ###"
    cat /proc/cpuinfo
    echo "### MEMINFO ###"
    cat /proc/meminfo
    echo "### VERSION ###"
    cat /proc/version
} > vagrant-rawhide-osinfo.txt

# Switch SELinux to permissive mode after reboot, so we catch all possible
# AVCs, not just the first one
setenforce 0
sed -ri 's/^SELINUX=\w+$/SELINUX=permissive/' /etc/selinux/config
cat /etc/selinux/config

rm -fr "$BUILD_DIR"
# Build phase
meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
      -Dsysvinit-path=/etc/rc.d/init.d \
      -Drc-local=/etc/rc.d/rc.local \
      -Dtests=true \
      -Dinstall-tests=true
ninja -C "$BUILD_DIR" install

popd

# Install the latest SELinux policy
fedpkg clone -a selinux-policy
pushd selinux-policy
dnf -y builddep selinux-policy.spec
./make-rhat-patches.sh
fedpkg local
dnf install -y noarch/selinux-policy-*
popd

# Force relabel on next boot
fixfiles -v -F onboot

dracut -f --regenerate-all

systemd-analyze set-log-level debug
systemd-analyze set-log-target console
