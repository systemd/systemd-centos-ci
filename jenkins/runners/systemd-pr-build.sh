#!/bin/sh

# Add a local ~/bin dir to path for custom binaries (currently used only
# for the tree binary for generating the artifact landing page)
export PATH="/home/systemd/bin:$PATH"
ARGS=

set -e
set -o pipefail

if [ "$ghprbPullId" ]; then
    ARGS="$ARGS --pr $ghprbPullId "

    # We're not testing the master branch, so let's see if the PR scope
    # is something we should indeed test
    git clone https://github.com/systemd/systemd systemd-tmp && cd systemd-tmp
    git fetch -fu origin "refs/pull/$ghprbPullId/head:pr"
    git checkout pr
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|[^\.].*\.d$|rules|src|test|tools|units))'
    if ! git diff $(git merge-base master pr) --name-only | grep -E "$SCOPE_RX" ; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py $ARGS
