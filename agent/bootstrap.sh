#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-upstream" || exit 1

REPO_URL="${REPO_URL:-https://github.com/systemd/systemd.git}"

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/system.journal "$LOGDIR/sanity-boot-check.journal" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

trap at_exit EXIT

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e -u
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
sed -i '/baseurl=/a\    http://artifacts.ci.centos.org/systemd/mrc0mmand-systemd-centos-ci/' "$COPR_REPO_PATH"
sed -i '/gpgkey=/d' "$COPR_REPO_PATH"
sed -i 's/skip_if_unavailable=True/skip_if_unavailable=False/' "$COPR_REPO_PATH"
# As the gpgkey directive doesn't support mirrors, let's install the GPG key manually
if ! rpm --import https://copr-be.cloud.fedoraproject.org/results/mrc0mmand/systemd-centos-ci/pubkey.gpg; then
    rpm --import http://artifacts.ci.centos.org/systemd/mrc0mmand-systemd-centos-ci/pubkey.gpg
fi
yum -y install epel-release yum-utils gdb
yum-config-manager --enable epel
yum -y update
yum -y install busybox dnsmasq e2fsprogs gcc-c++ libasan libbpf-devel libfdisk-devel nc net-tools ninja-build \
                  openssl-devel pcre2-devel python36 python-lxml qemu-kvm quota socat strace systemd-ci-environment
python3.6 -m ensurepip
python3.6 -m pip install meson

# python36 package doesn't create the python3 symlink
rm -f /usr/bin/python3
ln -s "$(which python3.6)" /usr/bin/python3

# Build and install dracut from upstream
(
    test -e dracut && rm -rf dracut
    git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
    pushd dracut || { echo >&2 "Can't pushd to dracut"; exit 1; }
    git checkout 046
    ./configure --disable-documentation
    make -j $(nproc)
    make install
    popd
) 2>&1 | tee "$LOGDIR/dracut-build.log"

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
                --optimization=g \
                --werror \
                -Dhomed=false \
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
    # Also, rebuild the original initrd without the multipath module, see
    # comments in `testsuite.sh` for the explanation
    export INITRD="/var/tmp/ci-sanity-initramfs-$(uname -r).img"
    cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
    dracut -o multipath --filesystems ext4 --rebuild "$INITRD"

    [[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm

    ## Configure test environment
    # Explicitly set paths to initramfs (see above) and kernel images
    # (for QEMU tests)
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Enable kernel debug output for easier debugging when something goes south
    export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console"
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    make -C test/TEST-01-BASIC clean setup run clean-again

    rm -fv "$INITRD"
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# Readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service
popd

# The systemd testsuite uses the ext4 filesystem for QEMU virtual machines.
# However, the ext4 module is not included in initramfs by default, because
# CentOS uses xfs as the default filesystem
# Also, install the new udev rules introduced in systemd/systemd#7594 explicitly
# until dracut's udev module is updated
INSTALL_FILES=()
REQUESTED_FILES=(
    /usr/lib/udev/rules.d/53-storage-hardware.rules
    /usr/lib/udev/rules.d/56-fallback-scsi_id.rules
    /usr/lib/udev/rules.d/59-storage-content.rules
)
# To get rid of the (although bening but ugly) dracut's error message about
# non-existent files, let's first check out if the files we're trying to install
# into the initrd indeed exist
for rfile in "${REQUESTED_FILES[@]}"; do
    if [[ -f $rfile ]]; then
        INSTALL_FILES+=(--install "$rfile")
    fi
done

# A particularly ugly workaround for older versions of bash which treat empty
# array as an unset variable, thus tripping over `set -u` used above.
# The ${param+expr} expression expands `expr` only if `param` is set.
dracut -f --regenerate-all --filesystems ext4 ${INSTALL_FILES[@]+"${INSTALL_FILES[@]}"}

# Check if the new dracut image contains the systemd module to avoid issues
# like systemd/systemd#11330
if ! lsinitrd -m /boot/initramfs-$(uname -r).img | grep "^systemd$"; then
    echo >&2 "Missing systemd module in the initramfs image, can't continue..."
    lsinitrd /boot/initramfs-$(uname -r).img
    exit 1
fi

GRUBBY_ARGS=(
    # Needed for systemd-nspawn -U
    "user_namespace.enable=1"
    # As the RTC on CentOS CI machines is notoriously incorrect, let's override
    # it early in the boot process to properly execute units using
    # ConditionNeedsUpdate=
    # See: https://github.com/systemd/systemd/issues/15724#issuecomment-628194867
    "systemd.clock_usec=$(($(date +%s%N) / 1000 + 1))"
)
grubby --args="${GRUBBY_ARGS[*]}" --update-kernel="$(grubby --default-kernel)"
# Check if the $GRUBBY_ARGS were applied correctly
for arg in "${GRUBBY_ARGS[@]}"; do
    if ! grep -q "$arg" /boot/grub2/grub.cfg; then
        echo >&2 "Kernel parameter '$arg' was not found in /boot/grub2/grub.cfg"
        exit 1
    fi
done

# Let's leave this here for a while for debugging purposes
echo "Current date:         $(date)"
echo "RTC:                  $(hwclock --show)"
echo "/usr mtime:           $(date -r /usr)"
echo "/etc/.updated mtime:  $(date -r /etc/.updated)"

echo "user.max_user_namespaces=10000" >> /etc/sysctl.conf

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
