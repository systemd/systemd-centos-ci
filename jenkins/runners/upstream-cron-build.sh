#!/bin/bash
# shellcheck disable=SC2181,SC2317

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
    ./agent-control.py --pool metal-ec2-c5n-centos-8s-x86_64 \
                       --vagrant arch-sanitizers-gcc \
                       --no-index \
                       ${ARGS:+"${ARGS[@]}"}

    #./agent-control.py --pool metal-ec2-c5n-centos-8s-x86_64 \
    #                   --vagrant arch-sanitizers-clang \
    #                   --no-index \
    #                   ${ARGS:+"${ARGS[@]}"}
}

run_ppc64le_sanitizers() {
    # Run the integration test suite on C8S ppc64le with sanitizers
    ./agent-control.py --pool virt-one-medium-centos-8s-ppc64le \
                       --bootstrap-script="bootstrap-alt.sh" \
                       --testsuite-script="testsuite-alt.sh" \
                       --no-index \
                       ${ARGS:+"${ARGS[@]}"}
}

run_c8s_full() {
    # Run the full test suite on C8S (i.e. with QEMU tests as well)
    ./agent-control.py --pool virt-ec2-t2-centos-8s-x86_64 \
                       --timeout 180 \
                       --kdump-collect \
                       ${ARGS:+"${ARGS[@]}"}
}

for job in run_remaining_sanitizer_job run_ppc64le_sanitizers run_c8s_full; do
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
