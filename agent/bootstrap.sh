#!/usr/bin/bash

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e
/bin/false
COPR_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci/repo/epel-7/mrc0mmand-systemd-centos-ci-epel-7.repo"

# Enable necessary repositories and install required packages
#   - enable custom Copr repo with newer versions of certain packages (necessary
#     to sucessfully compile upstream systemd on CentOS)
#   - enable EPEL repo for additional dependencies
#   - update current system
#   - install python 3.6 (required by meson) and install meson + other build deps
curl "$COPR_REPO" -o "/etc/yum.repos.d/${COPR_REPO##*/}"
yum -q -y install epel-release yum-utils
yum-config-manager -q --enable epel
yum -q -y update
yum -q -y install systemd-ci-environment python-lxml python36 ninja-build libasan
python3.6 -m ensurepip
python3.6 -m pip install meson

# python36 package doesn't create the python3 symlink
rm -f /usr/bin/python3
ln -s "$(which python3.6)" /usr/bin/python3

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
git clone https://github.com/systemd/systemd.git
pushd systemd

echo "$0 called with argument '$1'"

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
case $1 in
    pr:*)
        git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"
        git checkout pr
        ;;

    "")
        ;;

    *)
        git checkout "$1"
        ;;
esac

echo -n "Checked out version "
git describe

# Compile systemd
#   - slow-tests=true: enable slow tests => enables fuzzy tests using libasan
#     installed above
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
CFLAGS='-g -O0 -ftrapv' meson build -Dslow-tests=true -Dinstall-tests=true -Ddbuspolicydir=/etc/dbus-1/system.d
ninja-build -C build
ninja-build -C build install

cat >/usr/lib/systemd/system-shutdown/debug.sh <<_EOF_
#!/bin/sh
mount -o remount,rw /
dmesg > /shutdown-log.txt
mount -o remount,ro /
_EOF_

chmod a+x /usr/lib/systemd/system-shutdown/debug.sh

# It's impossible to keep the local SELinux policy database up-to-date with
#arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
echo SELINUX=disabled >/etc/selinux/config

# Readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service
popd

# Build and install dracut from upstream && rebuild initrd
test -e dracut && rm -rf dracut
git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
cd dracut
git checkout 044
./configure --disable-documentation
make -j 16
make install
# The systemd testsuite uses the ext4 filesystem for QEMU virtual machines.
# However, the ext4 module is not included in initramfs by default, because
# CentOS uses xfs as the default filesystem
dracut -f --regenerate-all --filesystems ext4

# Set user_namespace.enable=1 (needed for systemd-nspawn -U to work correctly)
grubby --args="user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"
grep "user_namespace.enable=1" /boot/grub2/grub.cfg
echo "user.max_user_namespaces=10000" >> /etc/sysctl.conf

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
