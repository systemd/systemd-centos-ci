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
# curl -q -o runner.sh https://../upstream-vagrant-archlinux-sanitizers.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

at_exit() {
    # Correctly collect artifacts from all sanitizer jobs and generate a nice
    # directory structure
    if find . -name "artifacts_*" | grep -q "."; then
        mkdir _artifacts_all
        mv artifacts_* _artifacts_all
        mv _artifacts_all artifacts_all

        utils/generate-index.sh artifacts_all index.html
    fi
}

trap at_exit EXIT

ARGS=()

if [[ -v ghprbPullId && -n "$ghprbPullId" ]]; then
    ARGS+=(--pr "$ghprbPullId")

    # We're not testing the main branch, so let's see if the PR scope
    # is something we should indeed test
    git clone https://github.com/systemd/systemd systemd-tmp
    cd systemd-tmp
    git fetch -fu origin "refs/pull/$ghprbPullId/head:pr"
    git checkout pr
    SCOPE_RX='(^(catalog|factory|hwdb|meson.*|network|[^\.].*\.d|rules|src|test|units))'
    if ! git diff "$(git merge-base main pr)" --name-only | grep -E "$SCOPE_RX" ; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
    cd .. && rm -fr systemd-tmp
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

#./agent-control.py --pool metal-ec2-c5n-centos-8s-x86_64 \
#                   --vagrant arch-sanitizers-gcc \
#                   --no-index \
#                   ${ARGS:+"${ARGS[@]}"}

./agent-control.py --pool metal-ec2-c5n-centos-8s-x86_64 \
                   --vagrant arch-sanitizers-clang \
                   --no-index \
                   ${ARGS:+"${ARGS[@]}"}
