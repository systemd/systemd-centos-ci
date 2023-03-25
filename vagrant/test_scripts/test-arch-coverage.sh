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
# Consumed by coredumpctl_init()/coredumpctl_collect()
export COREDUMPCTL_BIN="$BUILD_DIR/coredumpctl"

# Following scripts are copied from the systemd-centos-ci/common directory
# by vagrant-build.sh
# shellcheck source=common/task-control.sh
. "$SCRIPT_DIR/task-control.sh" "vagrant-$DISTRO-testsuite" || exit 1
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/utils.sh" || exit 1

COVERAGE_DIR="$(mktemp -d)"
if ! meson_get_bool "$BUILD_DIR" "b_coverage"; then
    echo >&2 "systemd is not built with -Db_coverage=true, can't collect coverage"
    exit 1
fi

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

# Disable swap, since it seems to cause CPU soft lock-ups in some cases
swapoff -av

pushd /build || { echo >&2 "Can't pushd to /build"; exit 1; }

# Tweak $BUILD_DIR's permissions, so anybody can read & write the gcov metadata
setfacl --recursive --modify="d:u::rwX,d:g::rwX,d:o:rwX" --modify="u::rwX,g::rwX,o:rwX" "$BUILD_DIR"

exectask "ninja-test" "GCOV_ERROR_FILE=$LOGDIR/ninja-test-gcov-errors.log meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=5"
exectask "ninja-test-collect-coverage" "lcov_collect $COVERAGE_DIR/unit-tests.coverage-info $BUILD_DIR && lcov_clear_metadata $BUILD_DIR"
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
    "test/TEST-10-ISSUE-2467"     # flaky test
    "test/TEST-16-EXTEND-TIMEOUT" # flaky test
    "test/TEST-25-IMPORT"         # flaky when paralellized (systemd/systemd#13973)
    "test/TEST-46-HOMED"          # flaky test (systemd/systemd#21589)
)
SKIP_LIST=(
    "test/TEST-61-UNITTESTS-QEMU" # redundant test, runs the same tests as TEST-02, but only QEMU (systemd/systemd#19969)
    "${FLAKE_LIST[@]}"
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

    # Suffix the $TESTDIR of each retry with an index to tell them apart
    export MANGLE_TESTDIR=1
    exectask_retry "${t##*/}" "/bin/time -v -- make -C $t setup run && touch \$TESTDIR/pass"

    # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
    # array accordingly to correctly find the respective journals
    for ((i = 1; i <= TASK_RETRY_DEFAULT; i++)); do
        [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
    done
done

# Save journals created by integration tests
for t in "${EXECUTED_LIST[@]}"; do
    testname="${t##*/}"
    testdir="/var/tmp/systemd-test-$testname"

    if [[ -f "$testdir/system.journal" ]]; then
        # Filter out test-specific coredumps which are usually intentional
        # Note: $COREDUMPCTL_EXCLUDE_MAP resides in common/utils.sh
        if [[ -v "COREDUMPCTL_EXCLUDE_MAP[$t]" ]]; then
            export COREDUMPCTL_EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_MAP[$t]}"
        fi
        # Attempt to collect coredumps from test-specific journals as well
        exectask "${testname}_coredumpctl_collect" "coredumpctl_collect '$testdir/'"
        # Make sure to not propagate the custom coredumpctl filter override
        [[ -v COREDUMPCTL_EXCLUDE_RX ]] && unset -v COREDUMPCTL_EXCLUDE_RX

        # Keep the journal files only if the associated test case failed
        if [[ ! -f "$testdir/pass" ]]; then
            rsync -aq "$testdir/system.journal" "$LOGDIR/$testname/"
        fi
    fi

    if [[ -f "$testdir/coverage-info" ]]; then
        cp "$testdir/coverage-info" "$COVERAGE_DIR/${testname}.coverage-info"
    fi

    # Clean the no longer necessary test artifacts
    [[ -d "$t" ]] && make -C "$t" clean-again > /dev/null
done

## Other integration tests ##
# Prepare environment for the systemd-networkd testsuite
systemctl disable --now dhcpcd dnsmasq
systemctl reload dbus.service
# FIXME
# As the DHCP lease time in libvirt is quite short, and it's not configurable,
# yet, let's start a DHCP daemon _only_ for the "master" network device to
# keep it up during the systemd-networkd testsuite
systemctl enable --now dhcpcd@eth0.service
systemctl status dhcpcd@eth0.service

# Collect coverage metadata from the $BUILD_DIR (since we use the just-built nspawn
# and other tools)
exectask "lcov_build_dir_collect" "lcov_collect $COVERAGE_DIR/build_dir.coverage-info $BUILD_DIR && lcov_clear_metadata $BUILD_DIR"

exectask "systemd-networkd" \
         "/bin/time -v -- timeout -k 60s 60m test/test-network/systemd-networkd-tests.py --build-dir=$BUILD_DIR --debug --with-coverage"
exectask "lcov_networkd_collect_coverage" "lcov_collect $COVERAGE_DIR/systemd-networkd.coverage-info $BUILD_DIR && lcov_clear_metadata $BUILD_DIR"

# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Merge all "coverage-info" files from the integration tests into one file
exectask "lcov_merge_coverage" "lcov_merge all-integration-tests.coverage-info $COVERAGE_DIR"
# Drop *.gperf files from the lcov files
# See: https://github.com/eddyxu/cpp-coveralls/issues/126#issuecomment-946716583
#      for reasoning
exectask "lcov_drop_gperf" "lcov -r all-integration-tests.coverage-info '*.gperf' -o everything.coverage-info"
# Coveralls repo token is set via the .coveralls.yml configuration file generated
# in vagrant/vagrant-ci-wrapper.sh
exectask "coveralls_upload" "coveralls --no-gcov --lcov-file everything.coverage-info"
# Copy the final coverage report to artifacts for local analysis if needed
cp -fv "everything.coverage-info" "$LOGDIR/"

# If the test logs contain lines like:
#
# ...systemd-resolved[735885]: profiling:/systemd-meson-build/src/shared/libsystemd-shared-250.a.p/base-filesystem.c.gcda:Cannot open
#
# it means we're possibly missing some coverage since gcov can't write the stats,
# usually due to the sandbox being too restrictive (e.g. ProtectSystem=yes,
# ProtectHome=yes) or the $BUILD_DIR being inaccessible to non-root users - see
# `setfacl` stuff above.
_check_for_missing_coverage() {
    local ec=0

    while read -r file; do
        echo "*** Processing file $file ***"
        ! grep -E "profiling:.+?gcda:[Cc]annot open" "$file" || ec=1
    done < <(find "$LOGDIR" -maxdepth 1 -name "*.log" ! -name "check_for_missing_coverage*.log")

    return $ec
}
exectask "check_for_missing_coverage" "_check_for_missing_coverage"

# Summary
show_task_summary

exectask "journalctl-testsuite" "journalctl -b --no-pager"

finish_and_exit
