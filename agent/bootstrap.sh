#!/usr/bin/bash

. "$(dirname "$0")/common.sh" "bootstrap-logs" || exit 1

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    [ -d systemd/build/meson-logs ] && cp -r systemd/build/meson-logs "$LOGDIR"
    [ -d /var/tmp/systemd-test*/journal ] && rsync -aq /var/tmp/systemd-test*/journal "$LOGDIR"
    exectask "Dump system journal" "journalctl-bootstrap.log" "journalctl -b --no-pager"
}

trap at_exit EXIT

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e
set -o pipefail

COPR_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci/repo/epel-7/mrc0mmand-systemd-centos-ci-epel-7.repo"
COPR_REPO_PATH="/etc/yum.repos.d/${COPR_REPO##*/}"

# Enable necessary repositories and install required packages
#   - enable custom Copr repo with newer versions of certain packages (necessary
#     to sucessfully compile upstream systemd on CentOS)
#   - enable EPEL repo for additional dependencies
#   - update current system
#   - install python 3.6 (required by meson) and install meson + other build deps
curl "$COPR_REPO" -o "$COPR_REPO_PATH"
# Add a copr repo mirror
# Note: if a URL starts on a new line, it MUST begin with leading spaces,
#       otherwise it will be ignored
sed -i '/baseurl=/a\    https://rpm.sumsal.cz/mrc0mmand-systemd-centos-ci/' "$COPR_REPO_PATH"
sed -i '/gpgkey=/d' "$COPR_REPO_PATH"
sed -i 's/skip_if_unavailable=True/skip_if_unavailable=False/' "$COPR_REPO_PATH"
# As the gpgkey directive doesn't support mirrors, let's install the GPG key manually
if ! rpm --import https://copr-be.cloud.fedoraproject.org/results/mrc0mmand/systemd-centos-ci/pubkey.gpg; then
    rpm --import https://rpm.sumsal.cz/mrc0mmand-systemd-centos-ci/pubkey.gpg
fi
yum -q -y install epel-release yum-utils
yum-config-manager -q --enable epel
yum -q -y update
yum -q -y install systemd-ci-environment python-lxml python36 ninja-build libasan net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm
python3.6 -m ensurepip
python3.6 -m pip install meson

# python36 package doesn't create the python3 symlink
rm -f /usr/bin/python3
ln -s "$(which python3.6)" /usr/bin/python3

# Build and install dracut from upstream
(
    test -e dracut && rm -rf dracut
    git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
    pushd dracut
    git checkout 046
    ./configure --disable-documentation
    make
    make install
    popd
) 2>&1 | tee "$LOGDIR/dracut-build.log"

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

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
setenforce 0
echo SELINUX=disabled >/etc/selinux/config

# Compile systemd
#   - slow-tests=true: enable slow tests => enables fuzzy tests using libasan
#     installed above
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
    CFLAGS='-g -O0 -ftrapv' meson build \
          -Dslow-tests=true \
          -Dtests=unsafe \
          -Dinstall-tests=true \
          -Ddbuspolicydir=/etc/dbus-1/system.d \
          -Dnobody-user=nfsnobody \
          -Dnobody-group=nfsnobody
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build.log"

# Install the compiled systemd
ninja-build -C build install

# Let's check if the new systemd at least boots before rebooting the system
# As the CentOS' systemd-nspawn version is too old, we have to use QEMU
(
    INITRD_PATH="/boot/initramfs-$(uname -r).img"
    KERNEL_PATH="/boot/vmlinuz-$(uname -r)"
    # Ensure the initrd contains the same systemd version as the one we're
    # trying to test
    dracut -f --filesystems ext4
    [ ! -f /usr/bin/qemu-kvm ] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
    make -C test/TEST-01-BASIC clean setup run clean-again QEMU_TIMEOUT=600 TEST_NO_NSPAWN=1 INITRD=$INITRD_PATH KERNEL_BIN=$KERNEL_PATH KERNEL_APPEND=debug
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# Readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service
popd

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
