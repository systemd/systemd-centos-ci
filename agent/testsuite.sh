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

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

if [[ $(cat /proc/sys/user/max_user_namespaces) -le 0 ]]; then
    echo >&2 "user.max_user_namespaces must be > 0"
    exit 1
fi

centos_ensure_qemu_symlink

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

# FIXME: test-seccomp
# This test became flaky once again, so disable it temporarily until the reason
# is found out.
#
# See: systemd/systemd#17078
echo 'int main(void) { return 77; }' > src/test/test-seccomp.c

# FIXME: test-barrier
# This test is flaky on systems under load, which happens intermittently due
# to how meson runs the tests (in parallel).
#
# See:
#   https://github.com/systemd/systemd/commit/fd23f9c9a70e1214507641d327da40d1688b74d7
#   https://github.com/systemd/systemd/commit/a1e3f0f38b43e68ff9ea33ab1935aed4edf6ed7f
echo 'int main(void) { return 77; }' > src/test/test-barrier.c

# Run the internal unit tests (make check)
# Note: All .dusty.* servers have Intel Xeon CPUs with 4 cores and HT enabled
#       which causes issues when the machine is under heavy load (in this case
#       when meson parallelizes the jobs on all 8 CPUs) - namely spurious
#       timeouts and hangups/deadlocks (like in test-barries).
[[ "$(hostnamectl --static)" =~ .dusty.ci.centos.org$ ]] && MESON_NUM_PROCESSES=4
exectask "ninja-test" "meson test -C build --print-errorlogs --timeout-multiplier=3 ${MESON_NUM_PROCESSES:+--num-processes "$MESON_NUM_PROCESSES"}"
# Copy over meson test artifacts
[[ -d "build/meson-logs" ]] && rsync -amq --include '*.txt' --include '*/' --exclude '*' "build/meson-logs" "$LOGDIR"

# If we're not testing the main branch (the first diff) check if the tested
# branch doesn't contain only man-related changes. If so, skip the integration
# tests
MAIN_BRANCH="$(git rev-parse --abbrev-ref origin/HEAD)"
if ! git diff --quiet "$MAIN_BRANCH" HEAD && ! git diff "$(git merge-base "$MAIN_BRANCH" HEAD)" --name-only | grep -vE "^man/" >/dev/null; then
    echo "Detected man-only PR, skipping integration tests"
    exit $FAILED
fi

## Integration test suite ##
EXECUTED_LIST=()
FLAKE_LIST=(
    "test/TEST-16-EXTEND-TIMEOUT"  # flaky test, see below
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
dracut -a crypt -o multipath --rebuild "$INITRD"

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
    # Explicitly enable user namespaces and default SELinux to permissive
    # for TEST-06-SELINUX (since we use CentOS 8 policy with the upstream systemd)
    export KERNEL_APPEND="user_namespace.enable=1 enforcing=0"
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

    exectask_p "${t##*/}" "/bin/time -v -- make -C $t setup run && touch $TESTDIR/pass"
    EXECUTED_LIST+=("$t")
done

# Wait for remaining running tasks
exectask_p_finish

for t in "${FLAKE_LIST[@]}"; do
    ## Configure test environment
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
    export QEMU_SMP=$(nproc)
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass"

    # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
    # array accordingly to correctly find the respective journals
    for ((i = 1; i <= EXECTASK_RETRY_DEFAULT; i++)); do
        [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
    done
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

# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Summary
show_task_summary

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
