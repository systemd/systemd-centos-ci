#!/bin/bash

ORIGINAL_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci/repo/epel-7/mrc0mmand-systemd-centos-ci-epel-7.repo"
ORIGINAL_REPO_ID="mrc0mmand-systemd-centos-ci"
DOWNLOAD_LOCATION="${1:-.}"
# CentOS CI specific thing - a part of the duffy key is necessary to
# authenticate against the CentOS CI rsync server
DUFFY_KEY_FILE="$HOME/duffy.key"

function at_exit() {
    # Clean up before exiting (either successfully or on an error)
    if [[ -n $WORK_DIR ]]; then
        rm -fr "$WORK_DIR"
    fi
}

set -e -u
set -o pipefail

trap at_exit EXIT

WORK_DIR="$(mktemp -d)"
pushd "$WORK_DIR"

wget -O repo-config.repo "$ORIGINAL_REPO"

# Check if the original repository configuration contains a URL to a GPG key
# If so, parse it and download it
GPG_KEY_URL="$(awk -F= '/^gpgkey=/ { print $2 }' repo-config.repo)"
if [[ -n $GPG_KEY_URL ]]; then
    GPG_KEY_URL_NAME="${GPG_KEY_URL##*/}"
    wget -O "$GPG_KEY_URL_NAME" "$GPG_KEY_URL"
fi

# Make a local copy of the original repository packages
reposync -q --plugins --config="repo-config.repo" --repoid="$ORIGINAL_REPO_ID" --download_path="$DOWNLOAD_LOCATION"
# Create necessary repo metadata, so the local repository can act as a mirror
createrepo_c --update -q "$DOWNLOAD_LOCATION/$ORIGINAL_REPO_ID"
# Copy over the downloaded GPG key, if any
if [[ -n $GPG_KEY_URL ]]; then
    mv "$GPG_KEY_URL_NAME" "$DOWNLOAD_LOCATION/$ORIGINAL_REPO_ID/$GPG_KEY_URL_NAME"
fi

# CentOS CI rsync password is the first 13 characters of the duffy key
PASSWORD_FILE="$(mktemp .rsync-passwd.XXX)"
cut -b-13 "$DUFFY_KEY_FILE" > "$PASSWORD_FILE"

# Sync the repo to the CentOS CI artifacts server
rsync --password-file="$PASSWORD_FILE" -av "$DOWNLOAD_LOCATION/$ORIGINAL_REPO_ID" systemd@artifacts.ci.centos.org::systemd/
echo "Mirror url: http://artifacts.ci.centos.org/systemd/$ORIGINAL_REPO_ID"
