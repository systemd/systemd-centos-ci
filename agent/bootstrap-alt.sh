#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-upstream-$(uname -m)" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"
REPO_URL="${REPO_URL:-https://github.com/systemd/systemd.git}"
REMOTE_REF=""

# EXIT signal handler
at_exit() {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/system.journal "$LOGDIR/sanity-boot-check.journal" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

trap at_exit EXIT

# Parse optional script arguments
while getopts "r:" opt; do
    case "$opt" in
        r)
            REMOTE_REF="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-r REMOTE_REF]"
            exit 1
    esac
done

# All commands from this script are fundamental, ensure they all pass
# before continuing (or die trying)
set -eu
set -o pipefail

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
    gnutls-utils
    integritysetup
    iproute-tc
    iscsi-initiator-utils
    jq
    "kernel-modules-$(uname -r)"
    "kernel-modules-extra-$(uname -r)"
    "kernel-tools-$(uname -r)"
    keyutils
    kmod-wireguard # Kmods SIG
    knot
    knot-dnssecutils
    libasan
    libfdisk-devel
    libpwquality-devel
    libubsan
    libzstd-devel
    llvm
    make
    mdadm
    mtools
    net-tools
    nmap-ncat
    nvme-cli
    opensc
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
    softhsm # EPEL
    squashfs-tools
    strace
    stress # EPEL
    systemd-networkd # EPEL
    systemd-timesyncd # EPEL
    swtpm
    time
    tpm2-tools
    tpm2-tss-devel
    veritysetup
    wget
    vim-common
    zstd
)

dnf -y install epel-release epel-next-release dnf-plugins-core gdb
dnf -y config-manager --enable epel --enable epel-next --enable powertools
# Install the Kmods SIG repository for certain kernel modules
# See: https://sigs.centos.org/kmods/repositories/
cmd_retry dnf -y install centos-release-kmods
# Local mirror of https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/
cmd_retry dnf -y config-manager --add-repo "https://jenkins-systemd.apps.ocp.cloud.ci.centos.org/job/reposync/lastSuccessfulBuild/artifact/repos/mrc0mmand-systemd-centos-ci-centos8-stream8/mrc0mmand-systemd-centos-ci-centos8-stream8.repo"
dnf -y update
# Install systemd's build dependencies
# Note: --skip-unavailable is necessary as the systemd SRPM has a gnu-efi
#       dependency, but the package is not available on ppc64le, causing
#       the builddep command to fail. The dependency is conditional, but
#       the condition is not resolved during the build dep installation
dnf -y --skip-unavailable builddep systemd
dnf -y install "${ADDITIONAL_DEPS[@]}"
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
git clone "$REPO_URL" systemd
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

git_checkout_pr "$REMOTE_REF"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Disable firewalld (needed for systemd-networkd tests)
systemctl -q is-enabled firewalld && systemctl disable --now firewalld

# Set tuned to throughput-performance if available
if command -v tuned-adm 2>/dev/null; then
    tuned-adm profile throughput-performance
    tuned-adm active
    tuned-adm verify
fi

# Unlike gcc's ASan, clang's ASan DSO is in a non-standard path, thus any binary
# compiled with -shared-libasan using clang will fail to start. Let's add the
# necessary path to the ldconfig cache to avoid that.
ARCH="$(uname -m)"
[[ $ARCH == ppc64le ]] && ARCH=powerpc64le
if ! ASAN_RT_PATH="$(${CC:-clang} --print-file-name "libclang_rt.asan-$ARCH.so")" || ! [[ -f "$ASAN_RT_PATH" ]]; then
    echo >&2 "Couldn't detect path to the clang's ASan RT library"
    exit 1
fi

if ! ldconfig -p | grep -- "$ASAN_RT_PATH" >/dev/null; then
    LDCONFIG_PATH="$(mktemp /etc/ld.so.conf.d/99-clang-libasan-XXX.conf)"
    echo "Adding ${ASAN_RT_PATH%/*} to ldconfig cache (using $LDCONFIG_PATH)"
    echo "${ASAN_RT_PATH%/*}" >"$LDCONFIG_PATH"
    ldconfig

    if ! ldconfig -p | grep -- "$ASAN_RT_PATH" >/dev/null; then
        echo >&2 "Failed to add $ASAN_RT_PATH to ldconfig cache"
        exit 1
    fi
fi

# Compile systemd with the Address Sanitizer (ASan) and Undefined Behavior
# Sanitizer (UBSan) using llvm/clang
# FIXME (--as-needed)
# Since version 10, both gcc and clang started to ignore certain linker errors
# when compiling with -fsanitize=address. This eventually leads up to -lcrypt
# not being correctly propagated, but the fact is masked by the aforementioned
# issue. However, when the binary attempts to load a symbol from the libcrypt
# binary, it crashes since it's not linked correctly against it.
# Negating the -Wl,--as-needed used by default by -Wl,--no-as-needed seems to
# help in this case.
#
# See:
#   https://bugzilla.redhat.com/show_bug.cgi?id=1827338#c3
#   https://github.com/systemd/systemd-centos-ci/issues/247
(
    export CC=clang
    export CXX=clang++
    # Make sure we copy over the meson logs even if the compilation fails
    # shellcheck disable=SC2064
    trap "[[ -d $BUILD_DIR/meson-logs ]] && cp -r $BUILD_DIR/meson-logs '$LOGDIR'" EXIT
    meson "$BUILD_DIR" \
        -Dc_args='-Og -fno-omit-frame-pointer -ftrapv -shared-libasan' \
        -Dc_link_args="-shared-libasan" \
        -Dcpp_args='-Og -fno-omit-frame-pointer -ftrapv -shared-libasan' \
        -Dcpp_link_args="-shared-libasan" \
        -Db_asneeded=false `# See the FIXME (--as-needed) above` \
        -Ddebug=true \
        --werror \
        -Dfuzz-tests=true \
        -Dslow-tests=true \
        -Dtests=unsafe \
        -Dinstall-tests=true \
        -Ddbuspolicydir=/etc/dbus-1/system.d \
        -Dman=false \
        -Db_sanitize=address,undefined \
        -Db_lundef=false # See https://github.com/mesonbuild/meson/issues/764
    ninja -C "$BUILD_DIR"
) 2>&1 | tee "$LOGDIR/build-$(uname -m).log"

# Reboot the machine here to switch to the latest kernel if available
echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
