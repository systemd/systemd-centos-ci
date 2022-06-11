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
FAILED=()
PASSED=()
EC=0

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

run_remaining_sanitizer_job() {
    # Run the "leftover" ASan/UBSan job (i.e. the one which is not run by
    # the `upstream-vagrant-archlinux-sanitizers` job for each PR)
    ./agent-control.py --version 8-stream --no-index --vagrant arch-sanitizers-gcc ${ARGS:+"${ARGS[@]}"}
    #./agent-control.py --version 8-stream --no-index --vagrant arch-sanitizers-clang ${ARGS:+"${ARGS[@]}"}
}

run_coverage() {
    # Collect test coverage & upload it to Coveralls
    ./agent-control.py --version 8-stream --no-index --vagrant arch-coverage ${ARGS:+"${ARGS[@]}"}
}

run_ppc64le_sanitizers() {
    # Run the integration test suite on C8S ppc64le with sanitizers
    ./agent-control.py --version 8-stream --arch ppc64le --flavor medium --skip-reboot \
                       --bootstrap-script="bootstrap-alt.sh" --testsuite-script="testsuite-alt.sh" \
                       ${ARGS:+"${ARGS[@]}"}
}

for job in run_remaining_sanitizer_job run_coverage run_ppc64le_sanitizers; do
    if ! "$job"; then
        FAILED+=("$job")
        EC=$((EC + 1))
    else
        PASSED+=("$job")
    fi
done

echo "PASSED TASKS:"
printf "    %s\n" "${PASSED[@]}"
echo
echo "FAILED TASKS:"
printf "    %s\n" "${FAILED[@]}"

exit $EC
