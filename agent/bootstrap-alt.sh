#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-upstream-$(uname -m)" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

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
    clang
    compiler-rt
    e2fsprogs
    gdb
    libasan
    libfdisk-devel
    libidn2-devel
    libpwquality-devel
    libubsan
    libzstd-devel
    llvm
    make
    openssl-devel
    perl-IPC-SysV
    perl-Time-HiRes
    qrencode-devel
    quota
    squashfs-tools
    strace
    veritysetup
    wget
)

dnf -y install epel-release dnf-plugins-core gdb
dnf -y config-manager --enable epel --enable powertools
# Local mirror of https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/
dnf -y config-manager --add-repo "http://artifacts.ci.centos.org/systemd/repos/mrc0mmand-systemd-centos-ci-centos8-epel8/mrc0mmand-systemd-centos-ci-centos8-epel8.repo"
dnf -y update
dnf -y builddep systemd
# Install systemd's build dependencies
# Note: --skip-unavailable is necessary as the systemd SRPM has a gnu-efi
#       dependency, but the package is not available on ppc64le, causing
#       the builddep command to fail. The dependency is conditional, but
#       the condition is not resolved during the build dep installation
dnf -y --skip-unavailable builddep systemd
dnf -y install "${ADDITIONAL_DEPS[@]}"

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
systemctl disable firewalld

# Compile systemd with the Address Sanitizer (ASan) and Undefined Behavior
# Sanitizer (UBSan) using llvm/clang
(
    export CC=clang
    export CXX=clang++
    # Make sure we copy over the meson logs even if the compilation fails
    # shellcheck disable=SC2064
    trap "[[ -d $PWD/build/meson-logs ]] && cp -r $PWD/build/meson-logs '$LOGDIR'" EXIT
    meson build -Dc_args='-fno-omit-frame-pointer -ftrapv -Og' \
                -Dcpp_args='-Og' \
                -Ddebug=true \
                --werror \
                -Dfuzz-tests=true \
                -Dtests=unsafe \
                -Ddbuspolicydir=/etc/dbus-1/system.d \
                -Dnobody-user=nfsnobody \
                -Dnobody-group=nfsnobody \
                -Dman=false \
                -Db_sanitize=address,undefined \
                -Db_lundef=false # See https://github.com/mesonbuild/meson/issues/764
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build-$(uname -m).log"

# Manually install upstream D-Bus config file for org.freedesktop.network1
# so systemd-networkd testsuite can use potentially new/updated methods
cp -fv src/network/org.freedesktop.network1.conf /usr/share/dbus-1/system.d/

# Manually install upstream systemd-networkd service unit files in case a PR
# introduces a change in them
# See: https://github.com/systemd/systemd/pull/14415#issuecomment-579307925
cp -fv build/units/systemd-networkd.service /usr/lib/systemd/system/systemd-networkd.service
cp -fv build/units/systemd-networkd-wait-online.service /usr/lib/systemd/system/systemd-networkd-wait-online.service

# Don't reboot the machine, since we don't install the sanitized build anyway,
# due to stability reasons
