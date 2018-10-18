#!/usr/bin/sh

# Temporarily skipped test
# - TEST-24 doesn't work in nspawn, investigate

SKIP_LIST=(
    "test/TEST-24-UNIT-TESTS"
)

set -e

yum -q -y install net-tools strace nc busybox

cd systemd

#make check

for t in test/TEST-*; do
    if [[ " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        continue
    fi
    test -d $t && \
        PKG_CONFIG_PATH=../../src/core make -C $t clean setup run INITRD=/initrd.img
done

