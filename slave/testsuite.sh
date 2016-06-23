#!/usr/bin/sh

set -e

yum -qy install net-tools strace

cd systemd

#adduser test
#chmod a+x ..
#chown -R test:test .
#su test -c "make check"

for t in 01-BASIC 03-JOBS 04-JOURNAL 05-RLIMITS 07-ISSUE-1981; do
	d=test/TEST-$t/
	test -d $d && \
		PKG_CONFIG_PATH=../../src/core make -C test/TEST-$t/ clean setup run INITRD=/initrd.img
done

