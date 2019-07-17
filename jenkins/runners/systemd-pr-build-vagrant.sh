#!/bin/sh

# Add a local ~/bin dir to path for custom binaries (currently used only
# for the tree binary for generating the artifact landing page)
export PATH="/home/systemd/bin:$PATH"
ARGS=

if [ "$ghprbPullId" ]; then
        ARGS="$ARGS --pr $ghprbPullId "
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --vagrant arch $ARGS
