#!/usr/bin/bash

if [[ $# -ne 1 ]]; then
    echo >&2 "Usage: $0 enable|disable"
    exit 1
fi

set -e

KVM_SRC_BIN="/usr/libexec/qemu-kvm"
KVM_DEST_BIN="/usr/bin/qemu-kvm"

case $1 in
    enable)
        echo "Installing/updating qemu-kvm"
        yum -q -y install qemu-kvm
        ln -v -s --force "$KVM_SRC_BIN" /usr/bin/qemu-kvm
        qemu-kvm --version
        ;;
    disable)
        rm -fv "$KVM_DEST_BIN"
        ;;
    *)
        echo >&2 "Invalid command"
        exit 1
        ;;
esac
