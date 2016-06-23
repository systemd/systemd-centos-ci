#!/usr/bin/sh

set -e

curl -sL https://rpm.nodesource.com/setup | bash -
yum install -y nodejs json-glib-devel polkit-devel krb5-devel libssh-devel pcp-libs-devel \
		xmlto python-libguestfs qemu mock qemu-kvm rpm-build \
		curl libvirt-client libvirt-python libvirt python-lxml \
		krb5-workstation krb5-server selinux-policy-devel openssl \
		libguestfs-tools expect rsync

npm -g install npm@latest-2
npm -g install phantomjs

git clone https://github.com/systemd/cockpit.git

cd cockpit

git checkout ci

yum-builddep -y tools/cockpit.spec

mkdir build
cd build

../autogen.sh --prefix=/usr --enable-maintainer-mode --enable-debug
make -j 10

systemctl start libvirtd

