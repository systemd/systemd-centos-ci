#!/usr/bin/bash

. "$(dirname "$0")/../common/task-control.sh" "testsuite-logs-upstream" || exit 1
. "$(dirname "$0")/../common/utils.sh" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -e -u

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# FIXME: test-journal-flush
# A particularly ugly workaround for the flaky test-journal-flush. As the issue
# presented so far only in the QEMU TEST-02, let's skip it just there, instead
# of disabling it completely (even in the `meson test`).
#
# See: systemd/systemd#17963
sed -i '/TEST_LIST=/aTEST_LIST=("${TEST_LIST[@]/\\/usr\\/lib\\/systemd\\/tests\\/test-journal-flush}")' test/units/testsuite-02.sh

# FIXME: test-seccomp
# This test became flaky once again, so disable it temporarily until the reason
# is found out.
#
# See: systemd/systemd#17078
echo 'int main(void) { return 77; }' > src/test/test-seccomp.c

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -aq "build/meson-logs" "$LOGDIR"

# If we're not testing the main branch (the first diff) check if the tested
# branch doesn't contain only man-related changes. If so, skip the integration
# tests
if ! git diff --quiet main HEAD && ! git diff $(git merge-base main HEAD) --name-only | grep -qvE "^man/"; then
    echo "Detected man-only PR, skipping integration tests"
    exit $FAILED
fi

## Integration test suite ##
SKIP_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
)

[[ ! -f /usr/bin/qemu-kvm ]] && ln -s /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

## Generate a custom-tailored initrd for the integration tests
# The host initrd contains multipath modules & services which are unused
# in the integration tests and sometimes cause unexpected failures. Let's build
# a custom initrd used solely by the integration tests
#
# Set a path to the custom initrd into the INITRD variable which is read by
# the integration test suite "framework"
export INITRD="/var/tmp/ci-initramfs-$(uname -r).img"
# Copy over the original initrd, as we want to keep the custom installed
# files we installed during the bootstrap phase (i.e. we want to keep the
# command line arguments the original initrd was built with)
cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
# Rebuild the original initrd without the multipath module
dracut -o multipath --rebuild "$INITRD"

# Initialize the 'base' image (default.img) on which the other images are based
exectask "setup-the-base-image" "make -C test/TEST-01-BASIC clean setup TESTDIR=/var/tmp/systemd-test-TEST-01-BASIC"

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    # Tell the test framework to copy the base image for each test, so we
    # can run them in parallel
    export TEST_PARALLELIZE=1
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    # See $INITRD above
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Explicitly enable user namespaces
    export KERNEL_APPEND="user_namespace.enable=1"
    # Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    export NSPAWN_TIMEOUT=600
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    # Skipped test don't create the $TESTDIR automatically, so do it explicitly
    # otherwise the `touch` command would fail
    mkdir -p "$TESTDIR"
    rm -f "$TESTDIR/pass"

    exectask_p "${t##*/}" "make -C $t setup run && touch $TESTDIR/pass"
done

# Wait for remaining running tasks
exectask_p_finish

COREDUMPCTL_SKIP=(
    # This test intentionally kills several processes using SIGABRT, thus generating
    # cores which we're not interested in
    "test/TEST-49-UDEV-EVENT-TIMEOUT"
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

exit $FAILED
