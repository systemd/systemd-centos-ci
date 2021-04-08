#!/bin/bash

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../upstream-centos8.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

ARGS=()

if [[ -v ghprbPullId && -n "$ghprbPullId" ]]; then
    ARGS+=(--pr "$ghprbPullId")

    # We're not testing the main branch, so let's see if the PR scope
    # is something we should indeed test
    git clone https://github.com/systemd/systemd systemd-tmp && cd systemd-tmp
    git fetch -fu origin "refs/pull/$ghprbPullId/head:pr"
    git checkout pr
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|[^\.].*\.d|rules|src|test|tools|units))'
    if ! git diff "$(git merge-base main pr)" --name-only | grep -E "$SCOPE_RX" ; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
    cd .. && rm -fr systemd-tmp
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py ${ARGS:+"${ARGS[@]}"}
