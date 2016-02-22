#!/usr/bin/sh

set -e

pr=$1

curl 'http://copr.fedorainfracloud.org/coprs/lnykryn/systemd-centosci-environment/repo/epel-7/lnykryn-systemd-centosci-environment-epel-7.repo' -o /etc/yum.repos.d/lnykryn-systemd-centosci-environment-epel-7.repo
yum -y install systemd-ci-environment
git clone https://github.com/systemd/systemd.git

exit 0

./autogen.sh
./configure CFLAGS='-g -O0 -ftrapv' --sysconfdir=/etc --localstatedir=/var --libdir=/usr/lib64

make -j10

# readahead is dead in systemd upstream
rm -f /usr/lib/systemd/system/systemd-readahead-done.service

