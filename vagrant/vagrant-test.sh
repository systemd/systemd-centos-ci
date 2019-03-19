#!/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname $0)"
# common.sh is copied from the systemd-centos-ci/agent directory by vagrant-builder.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1

cd /build

# Run the internal unit tests (make check)
## Temporarily disable test-exec-privatenetwork
#sed -i 's/test_exec_privatenetwork,//' src/test/test-execute.c
#exectask "ninja-test" "meson test -C build --timeout-multiplier=3"

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-02-CRYPTSETUP" # flaky test (https://github.com/systemd/systemd/issues/10093)
    "test/TEST-10-ISSUE-2467" # https://github.com/systemd/systemd/pull/7494#discussion_r155635695
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

for t in test/TEST-03-JOBS; do
    if [[ " ${SKIP_LIST[@]} " =~ " $t " ]]; then
        echo -e "\n[SKIP] Skipping test $t"
        continue
    fi

    ## Configure test environment
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    # As we're not using KVM, bump the QEMU timeout quite a bit
    export QEMU_TIMEOUT=2000
    export NSPAWN_TIMEOUT=600
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"
    export STRIP_BINARIES="no"

    rm -fr "$TESTDIR"
    mkdir -p "$TESTDIR"

    sed -i'' '/bash/aexport M_CHECK_ACTION=3' "$t/test-jobs.sh"
    sed -i'' '/bash/aexport SYSTEMD_LOG_LEVEL=debug' "$t/test-jobs.sh"
    sed -i'' '/bash/aexport MALLOC_CHECK_=3' "$t/test-jobs.sh"
    sed -i'' '/bash/aset +e' "$t/test-jobs.sh"
    sed -i'' 's#ExecStart=/test-jobs.sh#ExecStart=valgrind --leak-check=full /test-jobs.sh#' "$t/test.sh"
    sed -i'' '/setup_basic_environment/ainstall_valgrind' "$t/test.sh"
    sed -i'' '/setup_basic_environment/ainst_dir /usr/share/terminfo' "$t/test.sh"
    sed -i'' '/setup_basic_environment/ainst /etc/termcap' "$t/test.sh"

    cat "$t/test-jobs.sh"

    exectask "${t##*/}" "make -C $t clean setup run clean-again"
done

# Debug only: save E V E R Y T H I N G, even the root image
for t in test/TEST-??-*; do
    if [[ -d /var/tmp/systemd-test-${t##*/}/journal ]]; then
        rsync -aq "/var/tmp/systemd-test-${t##*/}/journal" "$LOGDIR/${t##*/}"
    fi
done

exit $FAILED

## Other integration tests ##
TEST_LIST=(
    "test/test-exec-deserialization.py"
#    "test/test-network/systemd-networkd-tests.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask "${t##*/}" "./$t"
done

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"
echo
echo "FAILED TASKS:"
echo "-------------"
for task in "${FAILED_LIST[@]}"; do
    echo  "$task"
done

[ -d /build/build/meson-logs ] && cp -r /build/build/meson-logs "$LOGDIR"
exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
