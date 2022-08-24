#!/usr/bin/bash
# shellcheck disable=SC2155
# This script is part of the systemd Vagrant test suite for CentOS CI and
# it's expected to be executed in a Vagrant VM configured by vagrant-build.sh
# script.
# Majority of this script is copied from the systemd-centos-ci/agent/testsuite.sh
# script with some modifications to support other distributions. Test dependencies
# for each distribution must be installed prior executing this script.

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

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

# Disable swap, since it seems to cause CPU soft lock-ups in some cases
swapoff -av

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

## FIXME: systemd-networkd testsuite: skip test_macsec
# Since kernel 5.7.2 the macsec module is broken, causing a runtime NULL pointer
# dereference (and since 5.8.0 an additional oops). Since the issue hasn't been
# looked at/fixed for over a month now, let's disable the failing test to
# no longer block the CI image updates.
# See: systemd/systemd#16199
sed -i '/def test_macsec/i\    @unittest.skip("See systemd/systemd#16199")' test/test-network/systemd-networkd-tests.py

# Run the internal unit tests (make check)
exectask "ninja-test" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=3"
[[ -d "$BUILD_DIR/meson-logs" ]] && rsync -amq --include '*.txt' --include '*/' --exclude '*' "$BUILD_DIR/meson-logs" "$LOGDIR"

## Integration test suite ##
# Prepare a custom-tailored initrd image (with the systemd module included).
# This is necessary, as the default mkinitcpio config includes only the udev module,
# which breaks certain things, like setting global env variables for systemd from
# the kernel command line.
# The exported INITRD variable is picked up by all following integration tests
export INITRD="$(mktemp /var/tmp/initrd-testsuite-XXX.img)"
if ! mkinitcpio -c /dev/null -A base,systemd,sd-encrypt,autodetect,modconf,block,filesystems,keyboard,fsck -g "$INITRD"; then
    echo >&2 "Failed to generate initrd, can't continue"
    exit 1
fi

# Initialize the 'base' image (default.img) on which the other images are based
exectask "setup-the-base-image" "make -C test/TEST-01-BASIC clean setup TESTDIR=/var/tmp/systemd-test-TEST-01-BASIC"

# Parallelized tasks
EXECUTED_LIST=()
FLAKE_LIST=(
    "test/TEST-10-ISSUE-2467"      # flaky test
    "test/TEST-16-EXTEND-TIMEOUT"  # flaky test
    "test/TEST-25-IMPORT"          # flaky when paralellized (systemd/systemd#13973)
    "test/TEST-46-HOMED"           # flaky test (systemd/systemd#21589)
)
SKIP_LIST=(
    "test/TEST-61-UNITTESTS-QEMU"  # redundant test, runs the same tests as TEST-02, but only QEMU (systemd/systemd#19969)
    "${FLAKE_LIST[@]}"
)

## Other integration tests ##
# Enqueue the "other" tests first. The networkd testsuite has quite a long
# runtime without requiring too much resources, hence it can run in parallel
# with the "standard" integration tests, saving ~30 minutes ATTOW (this excludes
# dusty nodes, where any kind of parallelism leads to unstable tests)
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
    exectask_p "${t##*/}" "/bin/time -v -- timeout -k 60s 60m ./$t"
done

for t in test/TEST-??-*; do
    if [[ ${#SKIP_LIST[@]} -ne 0 ]] && in_set "$t" "${SKIP_LIST[@]}"; then
        echo -e "[SKIP] Skipping test $t\n"
        continue
    fi

    ## Configure test environment
    export KERNEL_APPEND="kernel.nmi_watchdog=1 kernel.softlockup_panic=1 kernel.softlockup_all_cpu_backtrace=1 panic=1 oops=panic"
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
    # Use a "unique" name for each nspawn container to prevent scope clash
    export NSPAWN_ARGUMENTS="--machine=${t##*/}"

    # Disable nested KVM for TEST-13-NSPAWN-SMOKE, which keeps randomly
    # failing due to time outs caused by CPU soft locks. Also, bump the
    # QEMU timeout, since the test is a bit slower without KVM.
    export TEST_NESTED_KVM=1
    if [[ "$t" == "test/TEST-13-NSPAWN-SMOKE" ]]; then
        unset TEST_NESTED_KVM
        export QEMU_TIMEOUT=1200
    fi

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

    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass"

    # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
    # array accordingly to correctly find the respective journals
    for ((i = 1; i <= EXECTASK_RETRY_DEFAULT; i++)); do
        [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
    done
done

# Save journals created by integration tests
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

exectask "journalctl-testsuite" "journalctl -b --no-pager"

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
