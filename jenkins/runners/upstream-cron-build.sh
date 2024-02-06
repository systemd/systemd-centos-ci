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

run_arch_remaining_sanitizer_job() {
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

run_c9s_ppc64le() {
    # Run the integration test suite on C9S ppc64le
    ./agent-control.py --pool virt-one-medium-centos-9s-ppc64le \
                       --testsuite-args="-n" \
                       --no-index \
                       ${ARGS:+"${ARGS[@]}"}
}

run_c9s_aarch64() {
    # Run the integration test suite on C9S aarch64
    ./agent-control.py --pool virt-ec2-c6g-centos-9s-aarch64 \
                       --testsuite-args="-n" \
                       --no-index \
                       ${ARGS:+"${ARGS[@]}"}
}

run_c9s_full() {
    # Run the full test suite on C9S (i.e. with QEMU tests as well)
    ./agent-control.py --pool virt-ec2-t2-centos-9s-x86_64 \
                       --timeout 180 \
                       --kdump-collect \
                       ${ARGS:+"${ARGS[@]}"}
}

JOBS=(
    run_arch_remaining_sanitizer_job
    run_c9s_ppc64le
    run_c9s_aarch64
    run_c9s_full
)

for job in "${JOBS[@]}"; do
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
