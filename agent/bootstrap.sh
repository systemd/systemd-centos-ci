#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-upstream" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

REPO_URL="https://github.com/systemd/systemd.git"
REMOTE_REF=""

# EXIT signal handler
at_exit() {
    # Let's collect some build-related logs
    set +e
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

set -eu
set -o pipefail

trap at_exit EXIT

# Parse optional script arguments
while getopts "r:s" opt; do
    case "$opt" in
        r)
            REMOTE_REF="$OPTARG"
            ;;
        s)
            # Work on the systemd-stable repo instead
            REPO_URL="https://github.com/systemd/systemd-stable.git"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-r REMOTE_REF] [-s]"
            exit 1
    esac
done

ADDITIONAL_DEPS=(
    attr
    bpftool
    clang
    device-mapper-event
    device-mapper-multipath
    dhcp-server
    dnsmasq
    dosfstools
    e2fsprogs
    elfutils
    elfutils-devel
    gcc-c++
    integritysetup
    iproute-tc
    iscsi-initiator-utils
    kernel-modules-extra
    kmod-wireguard # Kmods SIG
    libasan
    libfdisk-devel
    libpwquality-devel
    libzstd-devel
    llvm
    make
    net-tools
    nmap-ncat
    openssl-devel
    pcre2-devel
    python3-jinja2
    python3-pexpect
    qemu-kvm
    qrencode-devel
    quota
    rust
    screen
    scsi-target-utils
    selinux-policy-devel
    socat
    squashfs-tools
    strace
    swtpm
    tpm2-tools
    tpm2-tss-devel
    veritysetup
    wget
)

cmd_retry dnf -y install epel-release dnf-plugins-core gdb
cmd_retry dnf -y config-manager --enable epel --enable powertools
# Install the Kmods SIG repository for certain kernel modules
# See: https://sigs.centos.org/kmods/repositories/
cmd_retry dnf -y install centos-release-kmods
# Local mirror of https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/
cmd_retry dnf -y config-manager --add-repo "https://jenkins-systemd.apps.ocp.ci.centos.org/job/centos8-reposync/lastSuccessfulBuild/artifact/repos/mrc0mmand-systemd-centos-ci-centos8-stream8/mrc0mmand-systemd-centos-ci-centos8-stream8.repo"
cmd_retry dnf -y update
cmd_retry dnf -y builddep systemd
cmd_retry dnf -y install "${ADDITIONAL_DEPS[@]}"
# As busybox is not shipped in RHEL 8/CentOS 8 anymore, we need to get it
# using a different way. Needed by TEST-13-NSPAWN-SMOKE
cmd_retry wget -O /usr/bin/busybox https://www.busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64 && chmod +x /usr/bin/busybox
# Remove setroubleshoot-server if it's installed, since we don't use it anyway
# and it's causing some weird performance issues
if rpm -q setroubleshoot-server; then
    dnf -y remove setroubleshoot-server
fi
# Use the Nmap's version of nc, since TEST-13-NSPAWN-SMOKE doesn't seem to work
# with the OpenBSD version present on CentOS 8
if alternatives --display nmap; then
    alternatives --set nmap /usr/bin/ncat
    alternatives --display nmap
fi

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
echo "Cloning repo: $REPO_URL"
git clone "$REPO_URL" systemd
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

git_checkout_pr "$REMOTE_REF"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Set SELinux to permissive on the test hosts to avoid false positives, but
# to still allow running tests which require SELinux.
if setenforce 0; then
    echo SELINUX=permissive >/etc/selinux/config
fi

# Disable firewalld (needed for systemd-networkd tests)
systemctl disable firewalld

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

# Compile & install libbpf-next
(
    git clone --depth=1 https://github.com/libbpf/libbpf libbpf
    pushd libbpf/src
    LD_FLAGS="-Wl,--no-as-needed" NO_PKG_CONFIG=1 make
    make install
    ldconfig
    popd
    rm -fr libbpf
)

# Compile systemd
#   - slow-tests=true: enables slow tests
#   - fuzz-tests=true: enables fuzzy tests using libasan installed above
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
    # Make sure we copy over the meson logs even if the compilation fails
    # shellcheck disable=SC2064
    trap "[[ -d $PWD/build/meson-logs ]] && cp -r $PWD/build/meson-logs '$LOGDIR'" EXIT
    meson build -Dc_args='-fno-omit-frame-pointer -ftrapv -Og' \
                -Dcpp_args='-Og' \
                -Ddebug=true \
                --werror \
                -Dlog-trace=true \
                -Dslow-tests=true \
                -Dfuzz-tests=true \
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
    export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console systemd.default_standard_output=journal+console"
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    if ! make -C test/TEST-01-BASIC clean setup run clean-again; then
        rsync -amq /var/tmp/systemd-test*/system.journal "$LOGDIR/sanity-boot-check.journal" >/dev/null || :
        exit 1
    fi

    rm -fv "$INITRD"
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# The new systemd binary boots, so let's issue a daemon-reexec to use it.
# This is necessary, since at least once we got into a situation where
# the old systemd binary was incompatible with the unit files on disk and
# prevented the system from reboot
SYSTEMD_LOG_LEVEL=debug systemctl daemon-reexec
SYSTEMD_LOG_LEVEL=debug systemctl --user daemon-reexec

# The systemd testsuite uses the ext4 filesystem for QEMU virtual machines.
# However, the ext4 module is not included in initramfs by default, because
# CentOS uses xfs as the default filesystem
dracut -f --regenerate-all --filesystems ext4

# Check if the new dracut image contains the systemd module to avoid issues
# like systemd/systemd#11330
if ! lsinitrd -m "/boot/initramfs-$(uname -r).img" | grep "^systemd$"; then
    echo >&2 "Missing systemd module in the initramfs image, can't continue..."
    lsinitrd "/boot/initramfs-$(uname -r).img"
    exit 1
fi

GRUBBY_ARGS=(
    # Needed for systemd-nspawn -U
    "user_namespace.enable=1"
    # As the RTC on CentOS CI machines is notoriously incorrect, let's override
    # it early in the boot process to properly execute units using
    # ConditionNeedsUpdate=
    # See: https://github.com/systemd/systemd/issues/15724#issuecomment-628194867
    # Update: if the original time difference is too big, the mtime of
    # /etc/.updated is already too far in the future, so it doesn't matter if
    # we correct the time during the next boot, since it's still going to be
    # in the past. Let's just explicitly override all ConditionNeedsUpdate=
    # directives to true to fix this once and for all
    "systemd.condition-needs-update=1"
    # Also, store & reuse the current (and corrected) time & date, as it doesn't
    # persist across reboots without this kludge and can (actually it does)
    # interfere with running tests
    "systemd.clock_usec=$(($(date +%s%N) / 1000 + 1))"
    # Reboot the machine on kernel panic
    "panic=3"
)
grubby --args="${GRUBBY_ARGS[*]}" --update-kernel="$(grubby --default-kernel)"
# Check if the $GRUBBY_ARGS were applied correctly
for arg in "${GRUBBY_ARGS[@]}"; do
    if ! grep -q -r "$arg" /boot/loader/entries/; then
        echo >&2 "Kernel parameter '$arg' was not found in /boot/loader/entries/*.conf"
        exit 1
    fi
done

# coredumpctl_collect takes an optional argument, which upsets shellcheck
# shellcheck disable=SC2119
coredumpctl_collect

# Configure kdump
kdumpctl status || kdumpctl restart
kdumpctl showmem
kdumpctl rebuild

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
