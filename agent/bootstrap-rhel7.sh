#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-rhel7" || exit 1

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    [[ -d /var/tmp/systemd-test*/journal ]] && rsync -aq /var/tmp/systemd-test*/journal "$LOGDIR"
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
}

trap at_exit EXIT

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e
set -o pipefail

# Install necessary dependencies
# - systemd-* packages are necessary for correct users/groups to be created
yum -q -y install systemd-journal-gateway systemd-resolved rpm-build yum-utils net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm
yum-builddep -y systemd

# Fetch the downstream systemd repo
test -e systemd-rhel && rm -rf systemd-rhel
git clone https://github.com/lnykryn/systemd-rhel.git
pushd systemd-rhel

git_checkout_pr "$1"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Compile systemd
(
    ./autogen.sh
    CONFIGURE_OPTS=(
        --with-sysvinit-path=/etc/rc.d/init.d
        --with-rc-local-script-path-start=/etc/rc.d/rc.local
        --disable-timesyncd
        --disable-kdbus
        --disable-terminal
        --enable-gtk-doc
        --enable-compat-libs
        --disable-sysusers
        --disable-ldconfig
        --enable-lz4
    )
    ./configure "${CONFIGURE_OPTS[@]}"
    make -j $(nproc)
    make install
) 2>&1 | tee "$LOGDIR/build.log"

# Let's check if the new systemd at least boots before rebooting the system
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
    export KERNEL_APPEND=debug
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    make -C test/TEST-01-BASIC clean setup run clean
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
