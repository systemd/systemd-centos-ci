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

# Add a local ~/bin dir to path for custom binaries (currently used only
# for the tree binary for generating the artifact landing page)
export PATH="/home/systemd/bin:$PATH"
ARGS=

set -e
set -o pipefail

if [ "$ghprbPullId" ]; then
    ARGS="$ARGS --pr $ghprbPullId "
fi

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --version 8 --rhel 8 $ARGS
