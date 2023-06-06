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
while getopts "r:s:" opt; do
    case "$opt" in
        r)
            REMOTE_REF="$OPTARG"
            ;;
        s)
            REPO_URL="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-r REMOTE_REF] [-s SOURCE_REPO_URL]"
            exit 1
    esac
done

ADDITIONAL_DEPS=(
    attr
    bind-utils
    bpftool
    busybox
    clang
    cryptsetup
    device-mapper-event
    device-mapper-multipath
    dfuzzer
    dhcp-client
    dhcp-server
    dnsmasq
    dosfstools
    e2fsprogs
    elfutils
    elfutils-devel
    evemu
    expect
    fsverity-utils # EPEL
    gcc-c++
    glibc-langpack-en
    integritysetup
    iproute-tc
    iscsi-initiator-utils
    jq
    kernel-modules-extra
    keyutils
    kmod-wireguard # Kmods SIG
    knot
    knot-dnssecutils
    libasan
    libfdisk-devel
    libpwquality-devel
    libzstd-devel
    llvm
    lvm2
    make
    mdadm
    mtools
    net-tools
    netlabel_tools
    nftables
    nmap-ncat
    openssl-devel
    pcre2-devel
    python3-jinja2
    python3-pefile # EPEL
    python3-pexpect
    python3-psutil
    python3-pyelftools # EPEL
    python3-pyparsing
    python3-pytest
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
    time
    tpm2-tools
    tpm2-tss-devel
    veritysetup
    vim-common
    wget
    zstd
)

cmd_retry dnf -y install epel-release epel-next-release dnf-plugins-core gdb
cmd_retry dnf -y config-manager --enable epel --enable epel-next --enable powertools
# Install the Kmods SIG repository for certain kernel modules
# See: https://sigs.centos.org/kmods/repositories/
cmd_retry dnf -y install centos-release-kmods
# Local mirror of https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/
cmd_retry dnf -y config-manager --add-repo "https://jenkins-systemd.apps.ocp.cloud.ci.centos.org/job/reposync/lastSuccessfulBuild/artifact/repos/mrc0mmand-systemd-centos-ci-centos8-stream8/mrc0mmand-systemd-centos-ci-centos8-stream8.repo"
cmd_retry dnf -y update
cmd_retry dnf -y builddep systemd
cmd_retry dnf -y install "${ADDITIONAL_DEPS[@]}"
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
systemctl -q is-enabled firewalld && systemctl disable --now firewalld

# Set tuned to throughput-performance if available
if command -v tuned-adm 2>/dev/null; then
    tuned-adm profile throughput-performance
    tuned-adm active
    tuned-adm verify
fi

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
                -Dman=true \
                -Dhtml=true
    ninja -C build
) 2>&1 | tee "$LOGDIR/build.log"

# shellcheck disable=SC2119
coredumpctl_set_ts

# Install the compiled systemd
ninja -C build install

# FIXME: drop once https://github.com/systemd/systemd/pull/27890 lands
DRACUT_OPTS=()
[[ -x /usr/lib/systemd/systemd-executor ]] && DRACUT_OPTS+=(--install /usr/lib/systemd/systemd-executor)

# Let's check if the new systemd at least boots before rebooting the system
# As the CentOS' systemd-nspawn version is too old, we have to use QEMU
(
    # Ensure the initrd contains the same systemd version as the one we're
    # trying to test
    # Also, rebuild the original initrd without the multipath module, see
    # comments in `testsuite.sh` for the explanation
    export INITRD="/var/tmp/ci-sanity-initramfs-$(uname -r).img"
    cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
    dracut "${DRACUT_OPTS[@]}" -o "multipath rngd" --filesystems ext4 --rebuild "$INITRD"

    centos_ensure_qemu_symlink

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
    export QEMU_OPTIONS="-cpu max"

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

dracut "${DRACUT_OPTS[@]}" -f --regenerate-all

# Check if the new dracut image contains the systemd module to avoid issues
# like systemd/systemd#11330
if ! lsinitrd -m "/boot/initramfs-$(uname -r).img" | grep "^systemd$"; then
    echo >&2 "Missing systemd module in the initramfs image, can't continue..."
    lsinitrd "/boot/initramfs-$(uname -r).img"
    exit 1
fi

GRUBBY_ARGS=(
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
# Make sure the latest kernel is the one we're going to boot into
grubby --set-default "/boot/vmlinuz-$(rpm -q kernel --qf "%{EVR}.%{ARCH}\n" | sort -Vr | head -n1)"
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

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
