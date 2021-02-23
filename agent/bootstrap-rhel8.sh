#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-rhel8" || exit 1

REPO_URL="${REPO_URL:-https://github.com/systemd-rhel/rhel-8.git}"
CGROUP_HIERARCHY="legacy"
REMOTE_REF=""

# EXIT signal handler
at_exit() {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

trap at_exit EXIT

# Parse optional script arguments
while getopts "r:h:" opt; do
    case "$opt" in
        h)
            CGROUP_HIERARCHY="$OPTARG"
            if [[ "$CGROUP_HIERARCHY" != legacy && "$CGROUP_HIERARCHY" != unified ]]; then
                echo "Invalid cgroup hierarchy specified: $CGROUP_HIERARCHY"
                exit 1
            fi
            ;;
        r)
            REMOTE_REF="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-h CGROUP_HIERARCHY] [-r REMOTE_REF]"
            exit 1
    esac
done

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -e -u
set -o pipefail

ADDITIONAL_DEPS=(
    libasan
    libubsan
    make
    net-tools
    perl-IPC-SysV
    perl-Time-HiRes
    qemu-kvm
    strace
)

# Install and enable EPEL
dnf -y install epel-release "${ADDITIONAL_DEPS[@]}"
dnf config-manager --enable epel
# Upgrade the machine to get the most recent environment
dnf -y upgrade
# Install systemd's build dependencies
dnf -y --enablerepo "powertools" builddep systemd

# Fetch the systemd repo
test -e systemd && rm -rf systemd
git clone "$REPO_URL" systemd
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

git_checkout_pr "$REMOTE_REF"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Compile systemd
#   - slow-tests=true: enable slow tests
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
    # Make sure we copy over the meson logs even if the compilation fails
    trap "[[ -d $PWD/build/meson-logs ]] && cp -r $PWD/build/meson-logs '$LOGDIR'" EXIT
    CONFIGURE_OPTS=(
            # RHEL8 options
            -Dsysvinit-path=/etc/rc.d/init.d
            -Drc-local=/etc/rc.d/rc.local
            -Ddns-servers=''
            -Ddev-kvm-mode=0666
            -Dkmod=true
            -Dxkbcommon=true
            -Dblkid=true
            -Dseccomp=true
            -Dima=true
            -Dselinux=true
            -Dapparmor=false
            -Dpolkit=true
            -Dxz=true
            -Dzlib=true
            -Dbzip2=true
            -Dlz4=true
            -Dpam=true
            -Dacl=true
            -Dsmack=true
            -Dgcrypt=true
            -Daudit=true
            -Delfutils=true
            -Dlibcryptsetup=true
            -Delfutils=true
            -Dqrencode=false
            -Dgnutls=true
            -Dmicrohttpd=true
            -Dlibidn2=true
            -Dlibiptc=true
            -Dlibcurl=true
            -Defi=true
            -Dtpm=true
            -Dhwdb=true
            -Dsysusers=true
            -Ddefault-kill-user-processes=false
            -Dtests=unsafe
            -Dinstall-tests=true
            -Dtty-gid=5
            -Dusers-gid=100
            -Dnobody-user=nobody
            -Dnobody-group=nobody
            -Dsplit-usr=false
            -Dsplit-bin=true
            -Db_lto=false
            -Dnetworkd=false
            -Dtimesyncd=false
            -Ddefault-hierarchy=legacy
            # Custom options
            -Dslow-tests=true
            -Dtests=unsafe
            -Dinstall-tests=true
            -Dc_args='-g -O0 -ftrapv'
            --werror
            -Dman=true
            -Dhtml=true
    )
    meson build "${CONFIGURE_OPTS[@]}"
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build.log"

# Install the compiled systemd
ninja-build -C build install

# Create necessary systemd users/groups
getent group systemd-resolve &>/dev/null || groupadd -r -g 193 systemd-resolve 2>&1
getent passwd systemd-resolve &>/dev/null || useradd -r -u 193 -l -g systemd-resolve -d / -s /sbin/nologin -c "systemd Resolver" systemd-resolve &>/dev/null

# Configure the selected cgroup hierarchy for both the host machine and each
# integration test VM
if [[ "$CGROUP_HIERARCHY" == unified ]]; then
    CGROUP_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=1 systemd.legacy_systemd_cgroup_controller=0"
else
    CGROUP_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=1"
fi

# Let's check if the new systemd at least boots before rebooting the system
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
    export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console $CGROUP_KERNEL_ARGS"
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    make -C test/TEST-01-BASIC clean setup run clean

    rm -fv "$INITRD"
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# The new systemd binary boots, so let's issue a daemon-reexec to use it.
# This is necessary, since at least once we got into a situation where
# the old systemd binary was incompatible with the unit files on disk and
# prevented the system from reboot
SYSTEMD_LOG_LEVEL=debug systemctl daemon-reexec

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

# Switch between cgroups v1 (legacy) or cgroups v2 (unified) if requested
echo "Configuring $CGROUP_HIERARCHY cgroup hierarchy using '$CGROUP_KERNEL_ARGS'"

# Set user_namespace.enable=1 (needed for systemd-nspawn -U to work correctly)
grubby --args="user_namespace.enable=1 $CGROUP_KERNEL_ARGS" --update-kernel="$(grubby --default-kernel)"
# grub on RHEL 8 uses BLS
grep -r "user_namespace.enable=1" /boot/loader/entries/
grep -r "systemd.unified_cgroup_hierarchy" /boot/loader/entries/
echo "user.max_user_namespaces=10000" >> /etc/sysctl.conf

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
