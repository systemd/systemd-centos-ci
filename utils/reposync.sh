#!/bin/bash

DOWNLOAD_LOCATION="${1:-.}"
# JOB_URL is exported by Jenkins
# See: https://jenkins-systemd.apps.ocp.ci.centos.org/env-vars.html/
ARTIFACT_BASE_DIR="${JOB_URL:?}/lastSuccessfulBuild/artifact/$DOWNLOAD_LOCATION"

at_exit() {
    rm -f repo-config.repo
}

set -eu
set -o pipefail

trap at_exit EXIT

sync_repo() {
    local repo_link="${1:?}"
    local repo_id="${2:?}"
    local local_repo_id="${3:?}"
    local arches gpg_key_url gpg_key_name

    IFS=" " read -ra arches <<<"${4:?}"

    rm -f repo-config.repo
    curl -s -o repo-config.repo "$repo_link"

    # Check if the original repository configuration contains a URL to a GPG key
    # If so, parse it and download it
    gpg_key_url="$(awk -F= '/^gpgkey=/ { print $2 }' repo-config.repo)"
    if [[ -n "$gpg_key_url" ]]; then
        gpg_key_name="${gpg_key_url##*/}"
        curl -s -o "$gpg_key_name" "$gpg_key_url"
    fi

    for arch in "${arches[@]}"; do
        # Make a local copy of the original repository packages
        dnf reposync --norepopath --newest-only --download-metadata \
                     --arch "${arch},noarch" --forcearch "$arch" \
                     --config="repo-config.repo" --repoid="$repo_id" \
                     --download-path="$DOWNLOAD_LOCATION/$local_repo_id/$arch"
    done

    # Create a repo file
    cat >"$DOWNLOAD_LOCATION/$local_repo_id/$local_repo_id.repo" << EOF
[$local_repo_id]
name=Mirror of $repo_id Copr repo (\$basearch)
baseurl=$ARTIFACT_BASE_DIR/$local_repo_id/\$basearch/
skip_if_unavailable=False
enabled=1
# Disable modular filtering for this repository, so we can override certain
# module packages with our own
module_hotfixes=1
EOF
    # Copy over the downloaded GPG key, if any
    if [[ -f "$gpg_key_name" ]]; then
        mv "$gpg_key_name" "$DOWNLOAD_LOCATION/$local_repo_id/$gpg_key_name"
        echo "gpgkey=$ARTIFACT_BASE_DIR/$local_repo_id/$gpg_key_name" >>"$DOWNLOAD_LOCATION/$local_repo_id/$local_repo_id.repo"
    fi
}

# centos-8-stream
ORIGINAL_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/repo/centos-stream-8/mrc0mmand-systemd-centos-ci-centos8-centos-stream-8.repo"
ORIGINAL_REPO_ID="copr:copr.fedorainfracloud.org:mrc0mmand:systemd-centos-ci-centos8"
LOCAL_REPO_ID="mrc0mmand-systemd-centos-ci-centos8-stream8"
sync_repo "$ORIGINAL_REPO" "$ORIGINAL_REPO_ID" "$LOCAL_REPO_ID" "x86_64 aarch64 ppc64le"
