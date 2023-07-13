#!/bin/bash
# shellcheck disable=SC2181,SC2317,SC2043

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../rhel-cron-build.sh
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

run_rhel9_full() {
    # C9S job with unified cgroup hierarchy
    ./agent-control.py --no-index --pool virt-ec2-t2-centos-9s-x86_64 \
                       --bootstrap-script="bootstrap-rhel9.sh" \
                       --bootstrap-args="-h unified" \
                       --testsuite-script="testsuite-rhel9.sh" \
                       ${ARGS:+"${ARGS[@]}"}

    # C9S job with legacy cgroup hierarchy
    ./agent-control.py --no-index --pool virt-ec2-t2-centos-9s-x86_64 \
                       --bootstrap-script="bootstrap-rhel9.sh" \
                       --bootstrap-args="-h legacy" \
                       --testsuite-script="testsuite-rhel9.sh" \
                   ${ARGS:+"${ARGS[@]}"}
}

for job in run_rhel9_full; do
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
