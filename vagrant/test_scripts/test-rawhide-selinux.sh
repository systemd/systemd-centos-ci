#!/usr/bin/bash
# shellcheck disable=SC2155

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname "$0")"
# This variable is automagically consumed by the "framework" for integration tests
# See respective bootstrap script under vagrant/bootstrap_scripts/ for reasoning
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Following scripts are copied from the systemd-centos-ci/common directory
# by vagrant-build.sh
# shellcheck source=common/task-control.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/utils.sh" || exit 1

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

# Run certain systemd integration tests w/ SELinux enabled to check for any
# interoperability issues
EXECUTED_LIST=()
INTEGRATION_TESTS=(
    test/TEST-01-BASIC
    test/TEST-06-SELINUX
)

for t in "${INTEGRATION_TESTS[@]}"; do
    ## Configure test environment
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    export NSPAWN_TIMEOUT=600
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$(nproc)
    # Enforce nested KVM
    export TEST_NESTED_KVM=1
    # Use a "unique" name for each nspawn container to prevent scope clash.
    # Also, explicitly set SELinux context for both processes and API FS to
    # test the respective code paths (like systemd/systemd#19977)
    export NSPAWN_ARGUMENTS="--machine=${t##*/} --selinux-apifs-context=system_u:object_r:container_file_t:s0:c0,c1 --selinux-context=system_u:system_r:container_t:s0:c0,c1"
    # Tell the test setup to configure SELinux
    export SETUP_SELINUX=yes
    export KERNEL_APPEND="selinux=1"

    # Skipped test don't create the $TESTDIR automatically, so do it explicitly
    # otherwise the `touch` command would fail
    mkdir -p "$TESTDIR"
    rm -f "$TESTDIR/pass"

    exectask "${t##*/}" "make -C $t setup run && touch $TESTDIR/pass"
    EXECUTED_LIST+=("$t")
done

for t in "${EXECUTED_LIST[@]}"; do
    testdir="/var/tmp/systemd-test-${t##*/}"
    if [[ -f "$testdir/system.journal" ]]; then
        # Filter out test-specific coredumps which are usually intentional
        # Note: $COREDUMPCTL_EXCLUDE_MAP resides in common/utils.sh
        if [[ -v "COREDUMPCTL_EXCLUDE_MAP[$t]" ]]; then
            export COREDUMPCTL_EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_MAP[$t]}"
        fi
        # Attempt to collect coredumps from test-specific journals as well
        exectask "${t##*/}_coredumpctl_collect" "coredumpctl_collect '$testdir/'"
        # Make sure to not propagate the custom coredumpctl filter override
        [[ -v COREDUMPCTL_EXCLUDE_RX ]] && unset -v COREDUMPCTL_EXCLUDE_RX

        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$testdir/pass" ]]; then
            rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
        fi
    fi

    # Clean the no longer necessary test artifacts
    [[ -d "$t" ]] && make -C "$t" clean-again > /dev/null
done

exectask "selinux-status" "sestatus -v -b"

exectask "avc-check" "! ausearch -m avc -i --start boot"

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"

if [[ ${#FAILED_LIST[@]} -ne 0 ]]; then
    echo
    echo "FAILED TASKS:"
    echo "-------------"
    for task in "${FAILED_LIST[@]}"; do
        echo "$task"
    done
fi

[[ -d "$BUILD_DIR/meson-logs" ]] && cp -r "$BUILD_DIR/meson-logs" "$LOGDIR"
exectask "journalctl-testsuite" "journalctl -b --no-pager"

exit $FAILED
