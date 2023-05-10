#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-upstream" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

set -eu
set -o pipefail

trap at_exit EXIT

### TEST PHASE ###
# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

centos_ensure_qemu_symlink

set +e

# FIXME: drop once https://github.com/systemd/systemd/issues/27287 is sorted out
watch_systemd_and_dump() {
    while :; do
        if ! timeout 30 systemctl -q is-active systemd-journald.service; then
            echo -ne "set pagination off\nbt full\n" | gdb -p 1 |& tee "$LOGDIR/PID1-stack-trace"
            break
        fi

        sleep 60
    done
}

watch_systemd_and_dump &

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -amq --include '*.txt' --include '*/' --exclude '*' "build/meson-logs" "$LOGDIR"

# If we're not testing the main branch (the first diff) check if the tested
# branch doesn't contain only man-related changes. If so, skip the integration
# tests
MAIN_BRANCH="$(git rev-parse --abbrev-ref origin/HEAD)"
if ! git diff --quiet "$MAIN_BRANCH" HEAD && ! git diff "$(git merge-base "$MAIN_BRANCH" HEAD)" --name-only | grep -vE "^man/" >/dev/null; then
    echo "Detected man-only PR, skipping integration tests"
    finish_and_exit
fi

## Integration test suite ##
CHECK_LIST=()
FLAKE_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT"  # flaky test, see below
    "test/TEST-63-PATH" # flaky when the AWS region is under heavy load
)
SKIP_LIST=(
    "test/TEST-61-UNITTESTS-QEMU"  # redundant test, runs the same tests as TEST-02, but only QEMU (systemd/systemd#19969)
    "${FLAKE_LIST[@]}"
)

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
# Rebuild the original initrd with the dm-crypt modules and without the multipath module
dracut -a crypt -o "multipath rngd" --filesystems ext4 --rebuild "$INITRD"
# Don't strip systemd binaries installed into test images, so we can get nice
# stack traces when something crashes
export STRIP_BINARIES=no

# Initialize the 'base' image (default.img) on which the other images are based
exectask "setup-the-base-image" "make -C test/TEST-01-BASIC clean setup TESTDIR=/var/tmp/systemd-test-TEST-01-BASIC"

## Other integration tests ##
# Enqueue the "other" tests first. The networkd testsuite has quite a long
# runtime without requiring too much resources, hence it can run in parallel
# with the "standard" integration tests, saving ~30 minutes ATTOW (this excludes
# dusty nodes, where any kind of parallelism leads to unstable tests)
TEST_LIST=(
    "test/test-exec-deserialization.py"
    "test/test-network/systemd-networkd-tests.py"
)

for t in "${TEST_LIST[@]}"; do
    exectask_p "${t##*/}" "/bin/time -v -- timeout -k 60s 60m ./$t"
done

# Shared test env variables
export KERNEL_APPEND="enforcing=0 watchdog_thresh=60 workqueue.watchdog_thresh=120"
# Explicitly set paths to initramfs and kernel images (for QEMU tests)
# See $INITRD above
export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=1800
export NSPAWN_TIMEOUT=600
export QEMU_OPTIONS="-cpu max"

# Let's re-shuffle the test list a bit by placing the most expensive tests
# in the front, so they can run in background while we go through the rest
# of the list
readarray -t INTEGRATION_TESTS < <(
    [[ -d test/TEST-64-UDEV-STORAGE ]] && echo test/TEST-64-UDEV-STORAGE
    find test/ -maxdepth 1 -type d -name "TEST-??-*" ! -name "TEST-64-UDEV-STORAGE" | sort
)

for t in "${INTEGRATION_TESTS[@]}"; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    export TASK_RETRIES=2
    # Tell the test framework to copy the base image for each test, so we
    # can run them in parallel
    export TEST_PARALLELIZE=1
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$OPTIMAL_QEMU_SMP

    # FIXME: retry each task again if it fails (i.e. run each task twice at most)
    #        to work around intermittent QEMU soft lockups/ACPI timer errors
    #
    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry_p "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass; rm -fv \$TESTDIR/*.img; test -e \$TESTDIR/pass" "${TASK_RETRIES:?}"
    # Retried tasks are suffixed with an index, so update the $CHECK_LIST
    # array with all possible task names correctly find the respective journals
    # shellcheck disable=SC2207
    CHECK_LIST+=($(seq -f "${t}_%g" 1 "$TASK_RETRIES"))
done

# Wait for remaining running tasks
exectask_p_finish

for t in "${FLAKE_LIST[@]}"; do
    # For older stable branches
    if [[ ! -d "$t" ]]; then
        echo "Test '$t' is not available, skipping..."
        continue
    fi

    ## Configure test environment
    # Set the test dir to something predictable so we can refer to it later
    export TESTDIR="/var/tmp/systemd-test-${t##*/}"
    # Set QEMU_SMP appropriately (regarding the parallelism)
    # OPTIMAL_QEMU_SMP is part of the common/task-control.sh file
    export QEMU_SMP=$(nproc)

    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass; rm -fv \$TESTDIR/*.img; test -e \$TESTDIR/pass"

    # Retried tasks are suffixed with an index, so update the $CHECK_LIST
    # array accordingly to correctly find the respective journals
    for ((i = 1; i <= TASK_RETRY_DEFAULT; i++)); do
        [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && CHECK_LIST+=("${t}_${i}")
    done
done

for t in "${CHECK_LIST[@]}"; do
    testdir="/var/tmp/systemd-test-${t##*/}"
    if [[ -f "$testdir/system.journal" ]]; then
        # Filter out test-specific coredumps which are usually intentional
        # Note: $COREDUMPCTL_EXCLUDE_MAP resides in common/utils.sh
        # Note2: strip the "_X" suffix added by exectask_retry*()
        if [[ -v "COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]" ]]; then
            export COREDUMPCTL_EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]}"
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

# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Summary
show_task_summary

finish_and_exit
