#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-rhel9" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

REPO_URL="${REPO_URL:-https://github.com/redhat-plumbers/systemd-rhel9}"
CGROUP_HIERARCHY="unified"
REMOTE_REF=""
SANITIZE=0

# EXIT signal handler
at_exit() {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/system.journal "$LOGDIR/sanity-boot-check.journal" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

set -eu
set -o pipefail

trap at_exit EXIT

# Parse optional script arguments
while getopts "r:h:z" opt; do
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
        z)
            # Use -z instead of -s for sanitized runs to avoid confusion with
            # the -s option in the upstream jobs which refers to the stable repo
            SANITIZE=1
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-h CGROUP_HIERARCHY] [-r REMOTE_REF] [-z]"
            exit 1
    esac
done

ADDITIONAL_DEPS=(
    attr
    bpftool
    clang
    device-mapper-event
    dhcp-client
    dnsmasq
    dosfstools
    e2fsprogs
    elfutils
    elfutils-devel
    gcc-c++
    integritysetup
    iproute-tc
    kernel-modules-extra
    libasan
    libfdisk-devel
    libpwquality-devel
    libubsan
    libzstd-devel
    llvm
    make
    net-tools
    nmap-ncat
    openssl-devel
    pcre2-devel
    python3-jinja2
    qemu-kvm
    quota
    rust
    selinux-policy-devel
    socat
    squashfs-tools
    strace
    tpm2-tss-devel
    veritysetup
    wget
)

cmd_retry dnf -y install dnf-plugins-core gdb
cmd_retry dnf -y config-manager --enable crb
cmd_retry dnf -y update
cmd_retry dnf -y builddep systemd
cmd_retry dnf -y install "${ADDITIONAL_DEPS[@]}"
# As busybox is not shipped since RHEL 8/CentOS 8 anymore, we need to get it
# using a different way. Needed by TEST-13-NSPAWN-SMOKE
cmd_retry wget -O /usr/bin/busybox https://www.busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64 && chmod +x /usr/bin/busybox

# Fetch the upstream systemd repo
test -e systemd && rm -rf systemd
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

# Compile systemd
#   - slow-tests=true: enables slow tests
#   - fuzz-tests=true: enables fuzzy tests using libasan installed above
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
    # Make sure we copy over the meson logs even if the compilation fails
    # shellcheck disable=SC2064
    trap "[[ -d $PWD/build/meson-logs ]] && cp -r $PWD/build/meson-logs '$LOGDIR'" EXIT
    # shellcheck disable=SC2191
    CONFIGURE_OPTS=(
            -Dmode=developer
            -Dsysvinit-path=/etc/rc.d/init.d
            -Drc-local=/etc/rc.d/rc.local
            -Dntp-servers='0.rhel.pool.ntp.org 1.rhel.pool.ntp.org 2.rhel.pool.ntp.org 3.rhel.pool.ntp.org'
            -Ddns-servers=
            -Duser-path=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin
            -Dservice-watchdog=3min
            -Ddev-kvm-mode=0666
            -Dkmod=true
            -Dxkbcommon=true
            -Dblkid=true
            -Dfdisk=true
            -Dseccomp=true
            -Dima=true
            -Dselinux=true
            -Dapparmor=false
            -Dpolkit=true
            -Dxz=true
            -Dzlib=true
            -Dbzip2=true
            -Dlz4=true
            -Dzstd=true
            -Dpam=true
            -Dacl=true
            -Dsmack=true
            -Dopenssl=true
            -Dp11kit=true
            -Dgcrypt=true
            -Daudit=true
            -Delfutils=true
            -Dlibcryptsetup=true
            -Delfutils=true
            -Dpwquality=false
            -Dqrencode=false
            -Dgnutls=true
            -Dmicrohttpd=true
            -Dlibidn2=true
            -Dlibiptc=false
            -Dlibcurl=true
            -Dlibfido2=false
            -Dgnu-efi=false
            -Dtpm=true
            -Dhwdb=true
            -Dsysusers=true
            -Dstandalone-binaries=true
            -Ddefault-kill-user-processes=false
            -Dinstall-tests=false
            -Dtty-gid=5
            -Dusers-gid=100
            -Dnobody-user=nobody
            -Dnobody-group=nobody
            -Dcompat-mutable-uid-boundaries=true
            -Dsplit-usr=false
            -Dsplit-bin=true
            -Db_lto=true
            -Db_ndebug=false
            #-Dversion-tag=v%{version}-%{release}
            -Dfallback-hostname=localhost
            -Ddefault-dnssec=no
            # https://bugzilla.redhat.com/show_bug.cgi?id=1867830
            -Ddefault-mdns=no
            -Ddefault-llmnr=resolve
            -Doomd=true
            -Dtimesyncd=false
            -Dhomed=false
            -Duserdb=false
            -Dportabled=false
            -Dnetworkd=false
            -Dsupport-url=https://access.redhat.com/support
            # Custom options
            -Dslow-tests=true
            -Dtests=unsafe
            -Dfuzz-tests=true
            -Dinstall-tests=true
            --werror
    )
    if [[ $SANITIZE -ne 0 ]]; then
        CONFIGURE_OPTS+=(
            "-Db_sanitize=address,undefined"
            -Dc_args='-g -Og -ftrapv -fno-omit-frame-pointer'
        )
    else
        CONFIGURE_OPTS+=(
            -Dc_args='-g -O0 -ftrapv'
            -Dman=true
            -Dhtml=true
        )
    fi
    meson build "${CONFIGURE_OPTS[@]}"
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build.log"

# Following stuff is relevant only to unsanitized builds, since we don't install
# the resulting build nor reboot the machine when built with sanitizers
if [[ $SANITIZE -ne 0 ]]; then
    echo "\$SANITIZE is set, skipping the build installation"

    # Support udevadm/systemd-udevd merge efforts from
    # https://github.com/systemd/systemd/pull/15918
    # The udevadm -> systemd-udevd symlink is created in the install phase which
    # we don't execute in sanitizer runs, so let's create it manually where
    # we need it
    if [[ -x "build/udevadm" && ! -x "build/systemd-udevd" ]]; then
        ln -frsv "build/udevadm" "build/systemd-udevd"
    fi

    exit 0
else
    # Install the compiled systemd
    ninja-build -C build install

    # Configure the selected cgroup hierarchy for both the host machine and each
    # integration test VM
    if [[ "$CGROUP_HIERARCHY" == unified ]]; then
        CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=1" "systemd.legacy_systemd_cgroup_controller=0")
    else
        CGROUP_KERNEL_ARGS=("systemd.unified_cgroup_hierarchy=0" "systemd.legacy_systemd_cgroup_controller=1")
    fi

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
        export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console ${CGROUP_KERNEL_ARGS[*]}"
        # Set timeout for QEMU tests to kill them in case they get stuck
        export QEMU_TIMEOUT=600
        # Disable nspawn version of the test
        export TEST_NO_NSPAWN=1

        make -C test/TEST-01-BASIC clean setup run clean-again

        rm -fv "$INITRD"
    ) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

    # The new systemd binary boots, so let's issue a daemon-reexec to use it.
    # This is necessary, since at least once we got into a situation where
    # the old systemd binary was incompatible with the unit files on disk and
    # prevented the system from reboot
    SYSTEMD_LOG_LEVEL=debug systemctl daemon-reexec
    SYSTEMD_LOG_LEVEL=debug systemctl --user daemon-reexec

    dracut -f --regenerate-all --filesystems ext4

    # Check if the new dracut image contains the systemd module to avoid issues
    # like systemd/systemd#11330
    if ! lsinitrd -m "/boot/initramfs-$(uname -r).img" | grep "^systemd$"; then
        echo >&2 "Missing systemd module in the initramfs image, can't continue..."
        lsinitrd "/boot/initramfs-$(uname -r).img"
        exit 1
    fi

    # Switch between cgroups v1 (legacy) or cgroups v2 (unified) if requested
    echo "Configuring $CGROUP_HIERARCHY cgroup hierarchy using '${CGROUP_KERNEL_ARGS[*]}'"

    GRUBBY_ARGS=(
        "${CGROUP_KERNEL_ARGS[@]}"
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
fi
