#!/usr/bin/sh

set -e

pr=$1

curl 'http://copr.fedorainfracloud.org/coprs/lnykryn/systemd-centosci-environment/repo/epel-7/lnykryn-systemd-centosci-environment-epel-7.repo' -o /etc/yum.repos.d/lnykryn-systemd-centosci-environment-epel-7.repo
yum -qy update
yum -qy install systemd-ci-environment python-lxml

test -f systemd && rm -rf systemd
git clone https://github.com/systemd/systemd.git

cd systemd

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

./autogen.sh
./configure CFLAGS='-g -O0 -ftrapv' --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib64

make -j16
make install

# It's impossible to keep the local SELinux policy database up-to-date with arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
echo SELINUX=disabled >/etc/selinux/config

# readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service

# --------------- rebuild initrd -------------

cd ~
git clone git://git.kernel.org/pub/scm/boot/dracut/dracut.git
cd dracut
git checkout 044
./configure --disable-documentation
make -j 16
make install
dracut -f

