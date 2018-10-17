#!/usr/bin/sh

set -e

COPR_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci/repo/epel-7/mrc0mmand-systemd-centos-ci-epel-7.repo"

curl "$COPR_REPO" -o "/etc/yum.repos.d/${COPR_REPO##*/}"
yum -q -y install epel-release yum-utils
yum-config-manager -q --enable epel
yum -q -y update
yum -q -y install systemd-ci-environment python-lxml python36 ninja-build
python3.6 -m ensurepip
pip3.6 install meson

# python36 package doesn't create the python3 symlink
rm -f /usr/bin/python3
ln -s `which python3.6` /usr/bin/python3

test -e systemd && rm -rf systemd
git clone https://github.com/systemd/systemd.git

cd systemd

echo "$0 called with argument '$1'"

case $1 in
	pr:*)
		git fetch -fu origin refs/pull/${1#pr:}/head:pr
		git checkout pr
		;;

	"")
		;;

	*)
		git checkout $1
		;;
esac

echo -n "Checked out version "
git describe

replace() {
	git grep -l $1 | grep \.c$ | xargs -r -n 1 sed -i -e s/$1/$2/g
}

#replace IN6_ADDR_GEN_MODE_STABLE_PRIVACY 2
#replace IFLA_BRPORT_PROXYARP 10

CFLAGS='-g -O0 -ftrapv' meson build -Ddbuspolicydir=/etc/dbus-1/system.d
ninja-build -C build
ninja-build -C build install




cat >/usr/lib/systemd/system-shutdown/debug.sh <<_EOF_
#!/bin/sh
mount -o remount,rw /
dmesg > /shutdown-log.txt
mount -o remount,ro /
_EOF_

chmod a+x /usr/lib/systemd/system-shutdown/debug.sh




# It's impossible to keep the local SELinux policy database up-to-date with arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
echo SELINUX=disabled >/etc/selinux/config

# readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service

# --------------- rebuild initrd -------------

cd ~
test -e dracut && rm -rf dracut
git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
cd dracut
git checkout 044
./configure --disable-documentation
make -j 16
make install
dracut -f --regenerate-all

