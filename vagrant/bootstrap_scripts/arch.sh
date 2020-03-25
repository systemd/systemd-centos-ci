#!/bin/bash
# Vagrant provider for a standard systemd setup

set -e
set -o pipefail

whoami
uname -a

# The custom CentOS CI box should be updated and provide necessary
# build & test dependencies

# Use systemd repo path specified by SYSTEMD_ROOT
pushd /build

# Dump list of installed packages
pacman -Q > vagrant-arch-installed-pkgs.txt
# Dump additional OS info
cat <(echo "# CPUINFO") /proc/cpuinfo >> vagrant-arch-osinfo.txt
cat <(echo "# MEMINFO") /proc/meminfo >> vagrant-arch-osinfo.txt
cat <(echo "# VERSION") /proc/version >> vagrant-arch-osinfo.txt

rm -fr build
# Build phase
meson build \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      --buildtype=debug \
      --optimization=g \
      -Dslow-tests=true \
      -Dtests=unsafe \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dman=true \
      -Dhtml=true
ninja -C build
ninja -C build install

# Make sure the revision we just compiled is actually bootable
(
  # We need a custom initrd (with the systemd module) for integration tests
  # See vagrant-test.sh for reasoning
  export INITRD="$(mktemp /var/tmp/initrd-testsuite-XXX.img)"
  mkinitcpio -c /dev/null -A base,systemd,autodetect,modconf,block,filesystems,keyboard,fsck -g "$INITRD"
  # Enable as much debug logging as we can to make debugging easier
  # (especially for boot issues)
  export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console"
  export QEMU_TIMEOUT=600
  # Skip the nspawn version of the test
  export TEST_NO_NSPAWN=1
  # Enforce nested KVM
  export TEST_NESTED_KVM=1

  make -C test/TEST-01-BASIC clean setup run clean-again

  rm -f "$INITRD"
) 2>&1 | grep --line-buffered '^' | tee vagrant-arch-sanity-boot-check.log

popd
