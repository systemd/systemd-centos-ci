#!/bin/bash
# Single purpose script to copy a file from one place to another using rsync,
# since the CentOS CI artifact server supports only rsync.
# Disclaimer: this doesn't work in all cases - it was written to "simply" rename
#             a file using the rsync protocol, so please bear that in mind.
set -eu
set -o pipefail

# CentOS CI specific thing - a part of the duffy key is necessary to
# authenticate against the CentOS CI rsync server
# See: https://wiki.centos.org/QaWiki/CI/GettingStarted#Exporting_artifacts_.28if_needed.29_to_a_storage_box
PASSWORD_FILE="$(mktemp "$PWD/.rsync-passwd.XXX")"
SRC="${1:?Missing argument: source}"
DEST="${2:?Missing argument: destination}"
[[ "$SRC" == */* ]] && SRC_DIR="${SRC%/*}" || SRC_DIR="."
[[ "$DEST" == */* ]] && DEST_DIR="${DEST%/*}" || DEST_DIR="."
TEMP_DIR="$(mktemp -d "$PWD/.sync-dirXXX")"

trap "cd && rm -fr '$TEMP_DIR' '$PASSWORD_FILE'" EXIT

echo "${CICO_API_KEY:0:13}" > "$PASSWORD_FILE"

pushd "$TEMP_DIR"
mkdir -p "$SRC_DIR" "$DEST_DIR"
# Crucial line, otherwise we won't be able to access the web directory listing
chmod -R o+rx .

rsync --password-file="$PASSWORD_FILE" -av "systemd@artifacts.ci.centos.org::systemd/$SRC" "$SRC_DIR"
mv -v "$SRC" "$DEST"
rm -fr "$SRC"
rsync --password-file="$PASSWORD_FILE" -av . "systemd@artifacts.ci.centos.org::systemd/"

popd
