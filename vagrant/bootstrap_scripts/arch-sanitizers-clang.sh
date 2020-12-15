#!/bin/bash

set -eu

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
pacman -Q > vagrant-arch-sanitizers-clang-installed-pkgs.txt
# Dump additional OS info
{
    echo "### CPUINFO ###"
    cat /proc/cpuinfo
    echo "### MEMINFO ###"
    cat /proc/meminfo
    echo "### VERSION ###"
    cat /proc/version
} > vagrant-arch-sanitizers-clang-osinfo.txt

rm -fr "$BUILD_DIR"
# Build phase
# Compile systemd with the Address Sanitizer (ASan) and Undefined Behavior
# Sanitizer (UBSan) using llvm/clang
export CC=clang
export CXX=clang++
export CFLAGS="-shared-libasan"
export CXXFLAGS="-shared-libasan"
# FIXME
# Since version 10, both gcc and clang started to ignore certain linker errors
# when compiling with -fsanitize=address. This eventually leads up to -lcrypt
# not being correctly propagated, but the fact is masked by the aforementioned
# issue. However, when the binary attempts to load a symbol from the libcrypt
# binary, it crashes since it's not linked correctly against it.
# Negating the -Wl,--as-needed used by default by -Wl,--no-as-needed seems to
# help in this case.
#
# See:
#   https://bugzilla.redhat.com/show_bug.cgi?id=1827338#c3
#   https://github.com/systemd/systemd-centos-ci/issues/247
export LDFLAGS="-Wl,--no-as-needed"

meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-Og -fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
      -Dtests=unsafe \
      -Dfuzz-tests=true \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dman=false \
      -Db_sanitize=address,undefined \
      -Db_lundef=false # See https://github.com/mesonbuild/meson/issues/764
ninja -C "$BUILD_DIR"

# Manually install upstream D-Bus config file for org.freedesktop.network1
# so systemd-networkd testsuite can use potentially new/updated methods
cp -fv src/network/org.freedesktop.network1.conf /usr/share/dbus-1/system.d/

# Manually install upstream systemd-networkd service unit files in case a PR
# introduces a change in them
# See: https://github.com/systemd/systemd/pull/14415#issuecomment-579307925
cp -fv "$BUILD_DIR/units/systemd-networkd.service" /usr/lib/systemd/system/systemd-networkd.service
cp -fv "$BUILD_DIR/units/systemd-networkd-wait-online.service" /usr/lib/systemd/system/systemd-networkd-wait-online.service

# Support udevadm/systemd-udevd merge efforts from
# https://github.com/systemd/systemd/pull/15918
# The udevadm -> systemd-udevd symlink is created in the install phase which
# we don't execute in sanitizer runs, so let's create it manually where
# we need it
if [[ -x "$BUILD_DIR/udevadm" && ! -x "$BUILD_DIR/systemd-udevd" ]]; then
    ln -frsv "$BUILD_DIR/udevadm" "$BUILD_DIR/systemd-udevd"
fi

popd
