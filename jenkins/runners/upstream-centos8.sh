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

analyze_fail() {
    set +e

    case "$?" in
        124)
            # The current way the EC2 T2 machines work is that they compete for
            # CPU time in given region. If the region is oversaturated, the CPU
            # time is not guaranteed and we might spend quite some time waiting
            # for the hypervisor to allocate some for us. This is unfortunate,
            # especially for the QEMU tests, which run without acceleration
            # (since AWS VMs don't support nested virt) and the emulation is
            # heavily dependent on CPU. The affected jobs will usually have
            # runtime over 4 hours, wasting resources, so let's kill them earlier.
            # See: https://lists.centos.org/pipermail/ci-users/2022-October/004618.html
            echo "|------------------------------------------------------------|"
            echo "|                         WARNING                            |"
            echo "| The job exceeded the set timeout. This means that there's  |"
            echo "| either something seriously wrong with the PR or the AWS    |"
            echo "| region this job was run in is oversaturated, causing       |"
            echo "| the hypervisor to steal our CPU time. Below you'll find    |"
            echo "| a grep over the test suite logs for timeouts - if there    |"
            echo "| are timeouts in both attempts of some more resource-heavy  |"
            echo "| tests (TEST-02, TEST-04, TEST-06, TEST-64, ...) it's       |"
            echo "| probably the latter case and you can ignore the failed     |"
            echo "| tests.                                                     |"
            echo "|----------------------------------------------------------- |"
            echo
            grep -Er "^TEST-.*?: \(timeout\)" artifacts_*
            ;;
        0)
            return 0
            ;;
        *)
            # "Workaround" for RHBZ#1956276
            # Since the kernel panic still occurs scarcely, but still often enough to cause
            # annoying noise, let's make use of the Jenkin's Naginator plugin to reschedule
            # the job when it encounters a specific line in the job output.
            #
            # Jenkins part: Post-build Actions -> Retry build after failure
            if grep -s "VFS: Busy inodes after unmount of" artifacts_*/kdumps/*/vmcore-dmesg.txt; then
                echo "[NAGINATOR REQUEST] RHBZ#1956276 encountered, reschedule the job"
            fi
    esac
}

trap analyze_fail EXIT

if [[ -v ghprbPullId && -n "$ghprbPullId" ]]; then
    ARGS+=(--pr "$ghprbPullId")

    # We're not testing the main branch, so let's see if the PR scope
    # is something we should indeed test
    #
    # Let's make the regex here less strict, so we can, for example, test man page
    # generation and other low-impact changes
    SCOPE_RX='(^(catalog|factory|hwdb|man|meson.*|network|[^\.].*\.d|rules|src|test|tools|units))'
    git fetch -fu origin "refs/pull/${ghprbPullId:?}/head"
    if ! git diff --name-only "origin/${ghprbTargetBranch:?}" FETCH_HEAD | grep -E "$SCOPE_RX"; then
        echo "Changes in this PR don't seem relevant, skipping..."
        exit 0
    fi
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

timeout -k 2m 150m ./agent-control.py --pool virt-ec2-t2-centos-8s-x86_64 --kdump-collect ${ARGS:+"${ARGS[@]}"}
