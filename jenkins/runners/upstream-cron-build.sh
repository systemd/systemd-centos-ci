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
# curl -q -o runner.sh https://../upstream-cron-build.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
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

ARGS=()

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --version 8 --no-index --vagrant arch-sanitizers-gcc ${ARGS:+"${ARGS[@]}"}
#./agent-control.py --version 8 --no-index --vagrant arch-sanitizers-clang ${ARGS:+"${ARGS[@]}"}
