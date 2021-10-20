#!/bin/bash
# shellcheck disable=SC2181

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
EC=0

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

set +e

(
    set -e
    # Run the "leftover" ASan/UBSan job (i.e. the one which is not run by
    # the `upstream-vagrant-archlinux-sanitizers` job for each PR)
    ./agent-control.py --version 8 --no-index --vagrant arch-sanitizers-gcc ${ARGS:+"${ARGS[@]}"}
    #./agent-control.py --version 8 --no-index --vagrant arch-sanitizers-clang ${ARGS:+"${ARGS[@]}"}
)
[[ $? -ne 0 ]] && EC=$((EC + 1))

(
    set -e
    # Collect test coverage & upload it to Coveralls
    ./agent-control.py --version 8 --no-index --vagrant arch-coverage ${ARGS:+"${ARGS[@]}"}
)
[[ $? -ne 0 ]] && EC=$((EC + 1))

exit $EC
