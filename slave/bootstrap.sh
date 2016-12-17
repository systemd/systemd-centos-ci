#!/usr/bin/sh

set -e

pr=$1

curl 'http://copr.fedorainfracloud.org/coprs/lnykryn/systemd-centosci-environment/repo/epel-7/lnykryn-systemd-centosci-environment-epel-7.repo' -o /etc/yum.repos.d/lnykryn-systemd-centosci-environment-epel-7.repo
yum -q -y update
yum -q -y install systemd-ci-environment python-lxml

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

./autogen.sh
./configure CFLAGS='-g -O0 -ftrapv' --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib64 --with-dbuspolicydir=/etc/dbus-1/system.d

make -j16
make install




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

