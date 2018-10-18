#!/usr/bin/sh

set -e

yum -q -y install net-tools strace nc busybox

cd systemd

#make check

for t in test/TEST-*; do
    test -d $t && \
        PKG_CONFIG_PATH=../../src/core make -C $t clean setup run INITRD=/initrd.img
done

