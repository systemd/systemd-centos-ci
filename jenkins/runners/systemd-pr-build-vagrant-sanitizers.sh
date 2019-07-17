#!/bin/sh

set -e

function at_exit() {
    # Correctly collect artifacts from all sanitizer jobs and generate a nice
    # directory structure
    mkdir _artifacts_all
    mv artifacts_* _artifacts_all
    mv _artifacts_all artifacts_all

    utils/generate-index.sh artifacts_all index.html
}

trap at_exit EXIT

export PATH="/home/systemd/bin:$PATH"
ARGS=

if [ "$ghprbPullId" ]; then
    ARGS="$ARGS --pr $ghprbPullId "
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --no-index --vagrant arch-sanitizers-gcc $ARGS
./agent-control.py --no-index --vagrant arch-sanitizers-clang $ARGS
