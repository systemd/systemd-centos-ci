#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-upstream" || exit 1

REPO_URL="${REPO_URL:-https://github.com/systemd/systemd.git}"

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

trap at_exit EXIT

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e -u
set -o pipefail

ADDITIONAL_DEPS=(libasan libubsan make net-tools qemu-kvm quota strace)

# Install and enable EPEL
dnf -q -y install epel-release dnf-utils "${ADDITIONAL_DEPS[@]}"
dnf config-manager -q --enable epel
# Upgrade the machine to get the most recent environment
dnf -y upgrade
# Install systemd's build dependencies
dnf -q -y --enablerepo "PowerTools" builddep systemd

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
git clone "$REPO_URL" systemd
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

git_checkout_pr "${1:-""}"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Disable firewalld (needed for systemd-networkd tests)
systemctl disable firewalld

# Compile systemd
#   - slow-tests=true: enable slow tests => enables fuzzy tests using libasan
#     installed above
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
    # Make sure we copy over the meson logs even if the compilation fails
    trap "[[ -d $PWD/build/meson-logs ]] && cp -r $PWD/build/meson-logs '$LOGDIR'" EXIT
    meson build -Dc_args='-fno-omit-frame-pointer -ftrapv' \
                --buildtype=debug \
                --optimization=1 \
                --werror \
                -Dslow-tests=true \
                -Dtests=unsafe \
                -Dinstall-tests=true \
                -Ddbuspolicydir=/etc/dbus-1/system.d \
                -Dnobody-user=nfsnobody \
                -Dnobody-group=nfsnobody \
                -Dman=true \
                -Dhtml=true
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build.log"

# Install the compiled systemd
ninja-build -C build install

# Let's check if the new systemd at least boots before rebooting the system
# As the CentOS' systemd-nspawn version is too old, we have to use QEMU
(
    # Ensure the initrd contains the same systemd version as the one we're
    # trying to test
    dracut -f --filesystems ext4

    [[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    export INITRD="/boot/initramfs-$(uname -r).img"
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Enable kernel debug output for easier debugging when something goes south
    export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console"
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    make -C test/TEST-01-BASIC clean setup run clean-again
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# The systemd testsuite uses the ext4 filesystem for QEMU virtual machines.
# However, the ext4 module is not included in initramfs by default, because
# CentOS uses xfs as the default filesystem
dracut -f --regenerate-all --filesystems ext4

# Check if the new dracut image contains the systemd module to avoid issues
# like systemd/systemd#11330
if ! lsinitrd -m /boot/initramfs-$(uname -r).img | grep "^systemd$"; then
    echo >&2 "Missing systemd module in the initramfs image, can't continue..."
    lsinitrd /boot/initramfs-$(uname -r).img
    exit 1
fi

# Set user_namespace.enable=1 (needed for systemd-nspawn -U to work correctly)
grubby --args="user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"
# grub on RHEL 8 uses BLS
grep -r "user_namespace.enable=1" /boot/loader/entries/
echo "user.max_user_namespaces=10000" >> /etc/sysctl.conf

# Following steps are needed to 'unconfuse' systemd after being replaced by
# an upstream version
# 1) user-0.slice get stuck for a while, which breaks ssh connections
# 2) systemd-reboot.service has an incompatible format, so daemon-reexec
#    is needed to fix this
SYSTEMD_LOG_LEVEL=debug systemctl restart user-0.slice
systemctl status user-0.slice
SYSTEMD_LOG_LEVEL=debug systemctl daemon-reexec

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
