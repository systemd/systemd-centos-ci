#!/bin/bash
# Single purpose script to copy a file from one place to another using rsync,
# since the CentOS CI artifact server supports only rsync/sftp.
# Disclaimer: this doesn't work in all cases - it was written to "simply" rename
#             a file using the rsync protocol, so please bear that in mind.
set -eu
set -o pipefail

SRC="${1:?Missing argument: source}"
DEST="${2:?Missing argument: destination}"
[[ "$SRC" == */* ]] && SRC_DIR="${SRC%/*}" || SRC_DIR="."
[[ "$DEST" == */* ]] && DEST_DIR="${DEST%/*}" || DEST_DIR="."
TEMP_DIR="$(mktemp -d "$PWD/.sync-dirXXX")"

# shellcheck disable=SC2064
trap "cd && rm -fr '$TEMP_DIR'" EXIT

pushd "$TEMP_DIR"
mkdir -p "$SRC_DIR" "$DEST_DIR"
# Crucial line, otherwise we won't be able to access the web directory listing
chmod -R o+rx .

rsync -av "systemd@artifacts.ci.centos.org:/srv/artifacts/systemd/$SRC" "$SRC_DIR"
mv -v "$SRC" "$DEST"
rm -fr "$SRC"
rsync -av . "systemd@artifacts.ci.centos.org:/srv/artifacts/systemd/"

popd
