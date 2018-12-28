#!/usr/bin/bash

# This script generates a simple index HTML page to make possible
# investigation easier.
# Note: this is a single-purpose script which heavily depends on the directory
#       structure created by the systemd CentOS CI Jenkins job, as well as
#       its environment (i.e. env variables)

set -e
set -o pipefail

if [ $# -ne 2 ]; then
    echo >&2 "Usage: $0 artifacts_dir index_file"
    exit 1
fi

ARTIFACTS_DIR="$1"
INDEX_FILE="$2"

if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo >&2 "'$ARTIFACTS_DIR' is not a directory"
    exit 1
fi

PR="${ghprbPullId:-N/A}"
PR_URL="${ghprbPullLink:-#}"

# Generate a nice HTML directory listing using the tree utility
tree -T "systemd CentOS CI (PR#<a href='$PR_URL'>$PR</a>)" -H "$ARTIFACTS_DIR" "$ARTIFACTS_DIR" -o "$INDEX_FILE"

# Use a relatively ugly sed to append a red cross after each "_FAIL" log file
sed -i -r 's/(_FAIL.log)(<\/a>)/\1 \&#x274C;\2/g' "$INDEX_FILE"
