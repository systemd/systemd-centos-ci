#!/usr/bin/sh

# Prepare environment
git clone https://git.fedorahosted.org/git/beakerlib.git
make -C beakerlib
make -C beakerlib install

# Run testsuite
for t in tests/*; do
    pushd $t
    test -e .disabled || ./runtest.sh
    popd
done

