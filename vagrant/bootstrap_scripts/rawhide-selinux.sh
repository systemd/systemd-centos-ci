#!/bin/bash
# Vagrant provider for a standard systemd setup

set -eu
set -o pipefail

whoami
uname -a

# Do a system upgrade
dnf upgrade --refresh -y

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

# FIXME (LoadCredential= assert)
# The patch for systemd/systemd#19178 is not yet in Rawhide, so let's temporarily
# revert the revert of the original mainline workaround to make the job pass again.
git config user.email "systemd@ci.centos.org"
git config user.name "systemd CentOS CI"
git revert --no-ed d4d7127d94c13cd1b88232fb0c138c619e1bae16

rm -fr "$BUILD_DIR"
# Build phase
meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
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

# Switch SELinux to permissive mode after reboot, so we catch all possible
# AVCs, not just the first one
sed -ri 's/^SELINUX=\w+$/SELINUX=permissive/' /etc/selinux/config
sed -ri 's/^SELINUXTYPE=\w+$/SELINUXTYPE=mls/' /etc/selinux/config
cat /etc/selinux/config
echo "-F" >/.autorelabel
