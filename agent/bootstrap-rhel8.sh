#!/usr/bin/bash

LIB_ROOT="$(dirname "$0")/../common"
. "$LIB_ROOT/utils.sh" || exit 1
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-rhel8" || exit 1

REPO_URL="${REPO_URL:-https://github.com/systemd-rhel/rhel-8.git}"

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    [[ -d systemd/build/meson-logs ]] && cp -r systemd/build/meson-logs "$LOGDIR"
    [[ -d /var/tmp/systemd-test*/journal ]] && rsync -aq /var/tmp/systemd-test*/journal "$LOGDIR"
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
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
yum -q -y install epel-release yum-utils
yum-config-manager -q --enable epel
yum -q -y update
yum -q -y install systemd-ci-environment libidn2-devel python-lxml python36 ninja-build libasan net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm
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
    make -j $(nproc)
    make install
    popd
) 2>&1 | tee "$LOGDIR/dracut-build.log"

# Fetch the systemd repo
test -e systemd && rm -rf systemd
git clone "$REPO_URL" systemd
pushd systemd

git_checkout_pr "${1:-""}"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Compile systemd
#   - slow-tests=true: enable slow tests => enables fuzzy tests using libasan
#     installed above
#   - tests=unsafe: enable unsafe tests, which might change the environment
#   - install-tests=true: necessary for test/TEST-24-UNIT-TESTS
(
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
    )
    meson build "${CONFIGURE_OPTS[@]}"
    ninja-build -C build
) 2>&1 | tee "$LOGDIR/build.log"

# Install the compiled systemd
ninja-build -C build install

# Create necessary systemd users/groups
getent group systemd-resolve &>/dev/null || groupadd -r -g 193 systemd-resolve 2>&1
getent passwd systemd-resolve &>/dev/null || useradd -r -u 193 -l -g systemd-resolve -d / -s /sbin/nologin -c "systemd Resolver" systemd-resolve &>/dev/null

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
    export KERNEL_APPEND=debug
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    make -C test/TEST-01-BASIC clean setup run clean
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

# Readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service
popd

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
grep "user_namespace.enable=1" /boot/grub2/grub.cfg
echo "user.max_user_namespaces=10000" >> /etc/sysctl.conf

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
