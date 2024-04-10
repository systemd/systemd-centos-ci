#!/bin/bash
# Simple wrapper around kexec stuff to avoid doing unnecessary kexec when already
# running the latest installed kernel
set -eu
set -o pipefail

if [[ "${1:-}" == "-u" ]]; then
    dnf --refresh -y update kernel
fi

RUNNING_KERNEL="$(uname -r)"
LATEST_KERNEL="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -Vr | head -n1)"

echo "Running kernel: $RUNNING_KERNEL"
echo "Latest installed kernel: $LATEST_KERNEL"

if [[ "$RUNNING_KERNEL" == "$LATEST_KERNEL" ]]; then
    echo "Already running the latest kernel, skipping kexec"
    exit 0
fi

if ! command -v kexec >/dev/null; then
    dnf install -y kexec-tools
fi

echo "Loading & executing kernel $LATEST_KERNEL"
kexec --initrd="/boot/initramfs-$LATEST_KERNEL.img" --reuse-cmdline --load "/boot/vmlinuz-$LATEST_KERNEL"
kexec --exec
