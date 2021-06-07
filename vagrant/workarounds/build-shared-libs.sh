#!/bin/bash
# A single-purpose script to build the necessary shared libraries to make
# vagrant-libvirt work on CentOS 8 (see the comments below for explanation).
#
# Usage: podman run -it --rm -v $PWD:/build --env OUT_DIR=/build centos:8 /build/build-shared-libs.sh

set -eu
set -o pipefail

OUT_DIR="${OUT_DIR:-$PWD}"
VAGRANT_PKG_URL="https://releases.hashicorp.com/vagrant/2.2.16/vagrant_2.2.16_x86_64.rpm"

[[ ! -d "$OUT_DIR" ]] && mkdir -p "$OUT_DIR"

if ! vagrant version 2>/dev/null; then
    dnf -y install "$VAGRANT_PKG_URL"
fi

# Install necessary dependencies
dnf -y install 'dnf-command(download)' 'dnf-command(builddep)' perl diffutils libarchive

# Workaround for current Vagrant's DSO hell
# ---
# The krb5-libs RPM is compiled with --with-crypto-impl=openssl, which
# includes symbols, that are not available in the Vagrant's embedded OpenSSL
# library, causing errors like:
#   /opt/vagrant/embedded/lib64/libk5crypto.so.3: undefined symbol: EVP_KDF_ctrl, version OPENSSL_1_1_1b

# Workaround this by compiling a local version of the krb5-libs using the
# builtin crypto implementation and copying the built libraries into
# the embedded lib dir.
#
# See:
#   https://github.com/hashicorp/vagrant/issues/11020
#   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/1031
#   https://github.com/vagrant-libvirt/vagrant-libvirt/issues/943
(
    BUILD_DIR="$(mktemp -d)"
    pushd "$BUILD_DIR"
    dnf -y install gcc byacc tar make
    dnf download --source krb5
    rpm2cpio krb5-*.src.rpm | cpio -imdV
    tar xf krb5-*.tar.gz
    cd krb5-*/src
    ./configure --with-crypto-impl=builtin
    make -j
    cp -a lib/crypto/libk5crypto.* "$OUT_DIR/"
    # We need to build libssh (below) with the just compiled libkrb5crypto.so
    cp -a lib/crypto/libk5crypto.* /opt/vagrant/embedded/lib64/
    popd
    rm -fr "$BUILD_DIR"
)
# Same as above, but for libssh
(
    BUILD_DIR="$(mktemp -d)"
    pushd "$BUILD_DIR"
    # In some cases the currently installed libssh version doesn't have its SRPM
    # in the repositories. Keep a fallback SRPM version for such cases.
    if ! dnf download --source libssh; then
        dnf download --source "libssh-0.9.4-2.el8"
    fi
    dnf -y --enablerepo powertools builddep libssh*.src.rpm
    rpm2cpio libssh-*.src.rpm | cpio -imdV
    tar xf libssh-*.tar.xz
    cd "$(find . -maxdepth 1 -name "libssh-*" -type d)"
    mkdir build
    cd build
    cmake .. -DOPENSSL_ROOT_DIR=/opt/vagrant/embedded/ -DCMAKE_PREFIX_PATH=/opt/vagrant/embedded/
    make -j
    cp -a lib/libssh* "$OUT_DIR/"
    popd
    rm -fr "$BUILD_DIR"
)

pushd "$OUT_DIR"
tar -pczvf vagrant-shared-libs.tar.gz --exclude "*.sh" --exclude "*.gz" --remove-files -- *
popd
