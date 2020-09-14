#!/bin/sh

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../systemd-rhel8-pr-build.sh
# chmod +x runner.sh
# ./runner.sh
ARGS=
TARGET_BRANCH="${ghprbTargetBranch:-master}"

set -e
set -o pipefail

at_exit() {
    # Correctly collect artifacts from all cron jobs and generate a nice
    # directory structure
    if find . -name "artifacts_*" | grep -q "."; then
        mkdir _artifacts_all
        mv artifacts_* _artifacts_all
        mv _artifacts_all artifacts_all

        utils/generate-index.sh artifacts_all index.html
    fi
}

trap at_exit EXIT

if [ "$ghprbPullId" ]; then
    ARGS="$ARGS --pr $ghprbPullId "
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

# RHEL 8 job with legacy cgroup hierarchy
./agent-control.py --no-index --version 8 --rhel 8 --rhel-bootstrap-args="-h legacy" $ARGS

# RHEL 8 supports unified cgroups since RHEL 8.2, so ignore RHEL 8.0 and
# RHEL 8.1 branches
if [ "$TARGET_BRANCH" != "rhel-8.0.0" ] && [ "$TARGET_BRANCH" != "rhel-8.1.0" ]; then
    # RHEL 8 job with unified cgroup hierarchy
    ./agent-control.py --no-index --version 8 --rhel 8 --rhel-bootstrap-args="-h unified" $ARGS
fi
