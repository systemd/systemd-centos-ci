#!/bin/bash

ORIGINAL_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci/repo/epel-7/mrc0mmand-systemd-centos-ci-epel-7.repo"
ORIGINAL_REPO_ID="copr:copr.fedorainfracloud.org:mrc0mmand:systemd-centos-ci"
LOCAL_REPO_ID="mrc0mmand-systemd-centos-ci"
DOWNLOAD_LOCATION="${1:-.}"

if [[ ! -v CICO_API_KEY ]]; then
    echo >&2 "Missing \$CICO_API_KEY env variable, can't continue"
    exit 1
fi

at_exit() {
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

# Make sure we have all packages we need
# As we now run this task in a rootless container, let's do a little (and ugly)
# hack to install necessary packages, instead of having to deal with custom
# containers, etc.
INSTALLROOT="$PWD/installroot"
mkdir "$INSTALLROOT"

for package in createrepo_c rsync wget yum-utils; do
    if ! rpm -q "$package"; then
        yumdownloader --destdir "$INSTALLROOT" --resolve "$package"
    fi
done

if ls "$INSTALLROOT"/*.rpm >/dev/null; then
    # cpio needs to be invoked separately for each RPM, thus the weird
    # construction
    cd "$INSTALLROOT" && find . -name "*.rpm" -printf "rpm2cpio %p | cpio -id\n" | sh

    export PATH="$PATH:$INSTALLROOT/usr/bin"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$INSTALLROOT/usr/lib64"
fi

wget -O repo-config.repo "$ORIGINAL_REPO"

# Check if the original repository configuration contains a URL to a GPG key
# If so, parse it and download it
GPG_KEY_URL="$(awk -F= '/^gpgkey=/ { print $2 }' repo-config.repo)"
if [[ -n $GPG_KEY_URL ]]; then
    GPG_KEY_URL_NAME="${GPG_KEY_URL##*/}"
    wget -O "$GPG_KEY_URL_NAME" "$GPG_KEY_URL"
fi

# Make a local copy of the original repository packages
reposync -q --norepopath --plugins --config="repo-config.repo" --repoid="$ORIGINAL_REPO_ID" --download_path="$DOWNLOAD_LOCATION/$LOCAL_REPO_ID"
# Create necessary repo metadata, so the local repository can act as a mirror
createrepo_c --update -q "$DOWNLOAD_LOCATION/$LOCAL_REPO_ID"
# Copy over the downloaded GPG key, if any
if [[ -n $GPG_KEY_URL ]]; then
    mv "$GPG_KEY_URL_NAME" "$DOWNLOAD_LOCATION/$LOCAL_REPO_ID/$GPG_KEY_URL_NAME"
fi

# CentOS CI rsync password is the first 13 characters of the duffy key
PASSWORD_FILE="$(mktemp .rsync-passwd.XXX)"
echo "${CICO_API_KEY:0:13}" > "$PASSWORD_FILE"

# Sync the repo to the CentOS CI artifacts server
rsync --password-file="$PASSWORD_FILE" -av "$DOWNLOAD_LOCATION/$LOCAL_REPO_ID" systemd@artifacts.ci.centos.org::systemd/
echo "Mirror url: http://artifacts.ci.centos.org/systemd/$LOCAL_REPO_ID"
