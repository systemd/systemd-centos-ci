#!/bin/bash
# shellcheck disable=SC2155
# Vagrant provider for a standard systemd setup

set -eu
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
meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=0 \
      -Db_coverage=true \
      -Dlog-trace=true \
      -Dfexecve=true \
      -Dslow-tests=true \
      -Dfuzz-tests=true \
      -Dtests=unsafe \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dlocalegen-path=/usr/bin/locale-gen
ninja -C "$BUILD_DIR"

# Install cpp-coveralls to generate the Coveralls-compatible report
# See: https://github.com/eddyxu/cpp-coveralls
python3 -m ensurepip
# Temporarily install cpp-coveralls from a custom fork until
# https://github.com/eddyxu/cpp-coveralls/pull/165 is merged/resolved
python3 -m pip install git+https://github.com/mrc0mmand/cpp-coveralls@centos-ci
#python3 -m pip install cpp-coveralls

# Manually install upstream D-Bus config file for org.freedesktop.network1
# so systemd-networkd testsuite can use potentially new/updated methods
cp -fv src/network/org.freedesktop.network1.conf /usr/share/dbus-1/system.d/

# Manually install upstream systemd-networkd service unit files in case a PR
# introduces a change in them
# See: https://github.com/systemd/systemd/pull/14415#issuecomment-579307925
cp -fv "$BUILD_DIR/units/systemd-networkd.service" /usr/lib/systemd/system/systemd-networkd.service
cp -fv "$BUILD_DIR/units/systemd-networkd-wait-online.service" /usr/lib/systemd/system/systemd-networkd-wait-online.service

# In order to be able to collect all coverage reports, we need to run
# the systemd-networkd test suite from the build dir, which means we need to
# create certain symlinks manually (since usually they're created by meson
# during the 'install' step).

# Support udevadm/systemd-udevd merge efforts from
# https://github.com/systemd/systemd/pull/15918
# The udevadm -> systemd-udevd symlink is created in the install phase which
# we don't execute in sanitizer runs, so let's create it manually where
# we need it
if [[ -x "$BUILD_DIR/udevadm" && ! -x "$BUILD_DIR/systemd-udevd" ]]; then
    ln -frsv "$BUILD_DIR/udevadm" "$BUILD_DIR/systemd-udevd"
fi

popd
