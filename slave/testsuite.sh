#!/usr/bin/sh

set -e

yum -qy install net-tools strace

cd systemd

for t in 01-BASIC 03-JOBS 04-JOURNAL 05-RLIMITS do
	PKG_CONFIG_PATH=../../src/core make -C test/TEST-$t/ clean setup run  INITRD=/initrd.img
done

