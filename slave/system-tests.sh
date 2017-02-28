#!/usr/bin/sh

set -e

# Prepare environment
git clone https://github.com/beakerlib/beakerlib.git
make -C beakerlib
make -C beakerlib install

# Run testsuite
for t in tests/*; do
    pushd $t
    ./runtest.sh
    popd
done

