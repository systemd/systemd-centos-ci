#!/usr/bin/bash

. "$(dirname "$0")/common.sh" "bootstrap-logs" || exit 1

# EXIT signal handler
function at_exit {
    # Let's collect some build-related logs
    set +e
    [ -d /var/tmp/systemd-test*/journal ] && rsync -aq /var/tmp/systemd-test*/journal "$LOGDIR"
    exectask "Dump system journal" "journalctl-bootstrap.log" "journalctl -b --no-pager"
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

echo "$0 called with argument '$1'"

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
case $1 in
    pr:*)
        git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"
        git checkout pr
        ;;

    "")
        ;;

    *)
        git checkout "$1"
        ;;
esac

echo -n "Checked out version "
git describe

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
setenforce 0
echo SELINUX=disabled >/etc/selinux/config

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
    make -j 8
    make install
) 2>&1 | tee "$LOGDIR/build.log"

# Let's check if the new systemd at least boots before rebooting the system
(
    ## Configure test environment
    # Set timeout for systemd-nspawn tests to kill them in case they get stuck
    export NSPAWN_TIMEOUT=600
    # Disable QEMU version of the test
    export TEST_NO_QEMU=1

    make -C test/TEST-01-BASIC clean setup run
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
