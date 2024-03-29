#!/bin/bash
# shellcheck disable=SC2155
# Vagrant provider for a standard systemd setup

set -eux
set -o pipefail

whoami
uname -a

# The custom CentOS CI box should be updated and provide necessary
# build & test dependencies

# Let's make the $BUILD_DIR for meson reside outside of the NFS volume mounted
# under /build to avoid certain race conditions, like:
# /usr/bin/ld: error: /build/build/src/udev/libudev.so.1: file too short
# The same path must be exported in the respective tests scripts (vagrant-test.sh,
# etc.) so the unit & integration tests can find the compiled binaries
# Note: avoid using /tmp or /var/tmp, as certain tests use binaries from the
#       buildir in combination with PrivateTmp=true
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Use systemd repo path specified by SYSTEMD_ROOT
pushd /build

# FIXME: monkey-patch systemd's mkinitcpio hook to install libkmod as well,
#        as it's a dlopen() dep since [0]. Drop this once a new systemd release
#        is out and the hook in Arch is tweaked.
# [0] https://github.com/systemd/systemd/pull/31131
sed -i 's/qrencode; do/qrencode kmod; do/' /usr/lib/initcpio/install/systemd

# Dump list of installed packages
pacman -Q > vagrant-arch-installed-pkgs.txt
# Dump additional OS info
{
    echo "### CPUINFO ###"
    cat /proc/cpuinfo
    echo "### MEMINFO ###"
    cat /proc/meminfo
    echo "### VERSION ###"
    cat /proc/version
} > vagrant-arch-osinfo.txt

rm -fr "$BUILD_DIR"
# Build phase
# shellcheck disable=SC2046
meson setup "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
      -Dlog-trace=true \
      -Dfexecve=true \
      -Dslow-tests=true \
      -Dfuzz-tests=true \
      -Dtests=unsafe \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dlocalegen-path=/usr/bin/locale-gen \
      $(grep -q default-network meson_options.txt && echo -Ddefault-network=true) \
      -Dman=true \
      -Dhtml=true
ninja -C "$BUILD_DIR"
ninja -C "$BUILD_DIR" install

# Make sure the revision we just compiled is actually bootable
(
    # We need a custom initrd (with the systemd module) for integration tests
    # See vagrant-test.sh for reasoning
    export INITRD="$(mktemp /var/tmp/initrd-testsuite-XXX.img)"
    mkinitcpio -c /dev/null -A base,systemd,modconf,block,filesystems,keyboard,fsck -g "$INITRD"
    # Enable as much debug logging as we can to make debugging easier
    # (especially for boot issues)
    export KERNEL_APPEND="debug systemd.log_level=debug rd.systemd.log_target=console"
    export QEMU_TIMEOUT=600
    # Skip the nspawn version of the test
    export TEST_NO_NSPAWN=1
    # Enforce nested KVM
    export TEST_NESTED_KVM=1

    if ! make -C test/TEST-01-BASIC clean setup run clean-again; then
        rsync -amq /var/tmp/systemd-test*/system.journal vagrant-sanity-boot-check.journal >/dev/null || :
        exit 1
    fi

    rm -fv "$INITRD"
) 2>&1 | grep --text --line-buffered '^' | tee vagrant-arch-sanity-boot-check.log

popd
