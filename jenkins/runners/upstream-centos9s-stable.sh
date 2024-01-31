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
# curl -q -o runner.sh https://../upstream-centos9-stable.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

ARGS=()

if [[ -v ghprbPullId && -n "$ghprbPullId" ]]; then
    ARGS+=(--pr "$ghprbPullId")

    # We're not testing the main branch, so let's see if the PR scope
    # is something we should indeed test
    #
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|(?!mkosi)[^\.].*\.d|rules|src|test|tools|units))'
    git fetch -fu origin "refs/pull/${ghprbPullId:?}/merge"
    if ! git diff --name-only "origin/${ghprbTargetBranch:?}" FETCH_HEAD | grep -P "$SCOPE_RX"; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --pool virt-ec2-t2-centos-9s-x86_64 \
                   --bootstrap-args="-s https://github.com/systemd/systemd-stable.git" \
                   --testsuite-args="-n" \
                   --kdump-collect \
                   ${ARGS:+"${ARGS[@]}"}
