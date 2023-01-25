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
# curl -q -o runner.sh https://../upstream-centos8-stable.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

ARGS=()

retry_on_kdump() {
    # "Workaround" for RHBZ#1956276
    # Since the kernel panic still occurs scarcely, but still often enough to cause
    # annoying noise, let's make use of the Jenkin's Naginator plugin to reschedule
    # the job when it encounters a specific line in the job output.
    #
    # Jenkins part: Post-build Actions -> Retry build after failure
    #
    # shellcheck disable=SC2181
    if [[ $? -ne 0 ]]; then
        set +e
        if grep -s "VFS: Busy inodes after unmount of" artifacts_*/kdumps/*/vmcore-dmesg.txt; then
            echo "[NAGINATOR REQUEST] RHBZ#1956276 encountered, reschedule the job"
        fi
    fi
}

trap retry_on_kdump EXIT

if [[ -v ghprbPullId && -n "$ghprbPullId" ]]; then
    ARGS+=(--pr "$ghprbPullId")

    # We're not testing the main branch, so let's see if the PR scope
    # is something we should indeed test
    #
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|[^\.].*\.d|rules|src|test|tools|units))'
    git fetch -fu origin "refs/pull/${ghprbPullId:?}/merge"
    if ! git diff --name-only "origin/${ghprbTargetBranch:?}" FETCH_HEAD | grep -E "$SCOPE_RX"; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --pool virt-ec2-t2-centos-8s-x86_64 \
                   --bootstrap-args='-s https://github.com/systemd/systemd-stable.git' \
                   --kdump-collect \
                   ${ARGS:+"${ARGS[@]}"}
