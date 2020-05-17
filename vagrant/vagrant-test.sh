#!/usr/bin/bash
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

DISTRO="${1:-unspecified}"
SCRIPT_DIR="$(dirname $0)"
# This variable is automagically consumed by the "framework" for integration tests
# See respective bootstrap script under vagrant/bootstrap_scripts/ for reasoning
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Following scripts are copied from the systemd-centos-ci/common directory
# by vagrant-build.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
. "$SCRIPT_DIR/utils.sh" || exit 1

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

# Disable certain flaky tests
# test-journal-flush: unstable on nested KVM
echo 'int main(void) { return 77; }' > src/journal/test-journal-flush.c

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=3"

## Integration test suite ##
# Prepare a custom-tailored initrd image (with the systemd module included).
# This is necessary, as the default mkinitcpio config includes only the udev module,
# which breaks certain things, like setting global env variables for systemd from
# the kernel command line.
# The exported INITRD variable is picked up by all following integration tests
export INITRD="$(mktemp /var/tmp/initrd-testsuite-XXX.img)"
if ! mkinitcpio -c /dev/null -A base,systemd,autodetect,modconf,block,filesystems,keyboard,fsck -g "$INITRD"; then
    echo >&2 "Failed to generate initrd, can't continue"
    exit 1
fi

# The current revision of the integration test suite uses a set of base images
# to reduce the overhead of building the same image over and over again.
# However, this isn't compatible with parallelization & concurrent access.
# To mitigate this, we need to run all tests with TEST_PARALLELIZE=1 (set below)
# and to initialize the set of base images beforehand.
if ! initialize_integration_tests "$PWD"; then
    echo >&2 "Failed to initialize integration tests, can't continue..."
    exit 1
fi

# Parallelized tasks
SKIP_LIST=(
    "test/TEST-10-ISSUE-2467"       # Serialized below
    "test/TEST-16-EXTEND-TIMEOUT"   # flaky test
    "test/TEST-25-IMPORT"           # Serialized below
)

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    # Tell the test framework to copy the base image for each test, so we
    # can run them in parallel
    export TEST_PARALLELIZE=1
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=900
    export NSPAWN_TIMEOUT=900
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP
    # Enforce nested KVM
    export TEST_NESTED_KVM=1
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    # TODO: check if disabling nested KVM for this particular test case
    #       helps with the unexpected test hangs
    if [[ "$t" == "test/TEST-13-NSPAWN-SMOKE" ]]; then
        unset TEST_NESTED_KVM
        export QEMU_TIMEOUT=1200
    fi

    rm -fr "$TESTDIR"
    mkdir -p "$TESTDIR"

    exectask_p "${t##*/}" "make -C $t setup run && touch $TESTDIR/pass"
done

# Wait for remaining running tasks
exectask_p_finish

# Serialized tasks (i.e. tasks which have issues when run on a system under
# heavy load)
SERIALIZED_TASKS=(
    # "test/TEST-10-ISSUE-2467" # Temporarily disabled...
    "test/TEST-25-IMPORT"
)

for t in "${SERIALIZED_TASKS[@]}"; do
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
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    rm -fr "$TESTDIR"
    mkdir -p "$TESTDIR"

    exectask "${t##*/}" "make -C $t setup run && touch $TESTDIR/pass"
done

COREDUMPCTL_SKIP=(
    # This test intentionally kills several processes using SIGABRT, thus generating
    # cores which we're not interested in
    "test/TEST-48-UDEV-EVENT-TIMEOUT"
)

# Save journals created by integration tests
for t in test/TEST-??-*; do
    testdir="/var/tmp/systemd-test-${t##*/}"
    if [[ -f "$testdir/system.journal" ]]; then
        if ! in_set "$t" "${COREDUMPCTL_SKIP[@]}"; then
            # Attempt to collect coredumps from test-specific journals as well
            exectask "${t##*/}_coredumpctl_collect" "coredumpctl_collect '$testdir/'"
        fi
        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$testdir/pass" ]]; then
            rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
        fi
    fi

    # Clean the no longer necessary test artifacts
    make -C "$t" clean-again > /dev/null
done

## Other integration tests ##
TEST_LIST=(
    "test/test-exec-deserialization.py"
    "test/test-network/systemd-networkd-tests.py"
)

# Prepare environment for the systemd-networkd testsuite
systemctl disable --now dhcpcd dnsmasq
systemctl reload dbus.service
# FIXME
# As the DHCP lease time in libvirt is quite short, and it's not configurable,
# yet, let's start a DHCP daemon _only_ for the "master" network device to
# keep it up during the systemd-networkd testsuite
systemctl enable --now dhcpcd@eth0.service
systemctl status dhcpcd@eth0.service

for t in "${TEST_LIST[@]}"; do
    exectask "${t##*/}" "timeout -k 60s 60m ./$t"
done

# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

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
