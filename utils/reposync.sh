#!/bin/bash

DOWNLOAD_LOCATION="${1:-.}"

if [[ ! -v CICO_API_KEY ]]; then
    echo >&2 "Missing \$CICO_API_KEY env variable, can't continue"
    exit 1
fi

at_exit() {
    # Clean up before exiting (either successfully or on an error)
    [[ -n "${WORK_DIR:-}" ]] && rm -fr "$WORK_DIR"
    [[ -n "${PASSWORD_FILE:-}" ]] && rm -f "$PASSWORD_FILE"
}

set -eu
set -o pipefail

trap at_exit EXIT

# CentOS CI rsync password is the first 13 characters of the duffy key
PASSWORD_FILE="$(mktemp)"
echo "${CICO_API_KEY:0:13}" >"$PASSWORD_FILE"

WORK_DIR="$(mktemp -d)"
pushd "$WORK_DIR"

# Make sure we have all packages we need
# As we now run this task in a rootless container, let's do a "little" (and ugly)
# hack to install necessary packages, instead of having to deal with custom
# containers, etc.
# All this will go away once the worker image is updated to CentOS 8.
INSTALLROOT="$PWD/installroot"
mkdir "$INSTALLROOT"

for package in dnf dnf-plugins-core patch rsync wget; do
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
    export PYTHONPATH="$INSTALLROOT/usr/lib/python2.7/site-packages/:$INSTALLROOT/usr/lib64/python2.7/site-packages/"

    # Taken from https://github.com/rpm-software-management/dnf-plugins-core/commit/a2ce53d3ac534f9677206ff66358e819d9de4d6e.patch
    patch "$INSTALLROOT/usr/lib/python2.7/site-packages/dnf-plugins/reposync.py" <<EOF
diff --git a/plugins/reposync.py b/plugins/reposync.py
index 8306651c..548a05b4 100644
--- a/plugins/reposync.py
+++ b/plugins/reposync.py
@@ -71,6 +71,8 @@ def set_argparser(parser):
                             help=_('download only newest packages per-repo'))
         parser.add_argument('-p', '--download-path', default='./',
                             help=_('where to store downloaded repositories'))
+        parser.add_argument('--norepopath', default=False, action='store_true',
+                            help=_("Don't add the reponame to the download path."))
         parser.add_argument('--metadata-path',
                             help=_('where to store downloaded repository metadata. '
                                    'Defaults to the value of --download-path.'))
@@ -102,6 +104,10 @@ def configure(self):
         if self.opts.source:
             repos.enable_source_repos()

+        if len(list(repos.iter_enabled())) > 1 and self.opts.norepopath:
+            raise dnf.cli.CliError(
+                _("Can't use --norepopath with multiple repositories"))
+
         for repo in repos.iter_enabled():
             repo._repo.expire()
             repo.deltarpm = False
@@ -148,7 +154,8 @@ def run(self):
                 self.delete_old_local_packages(repo, pkglist)

     def repo_target(self, repo):
-        return _pkgdir(self.opts.destdir or self.opts.download_path, repo.id)
+        return _pkgdir(self.opts.destdir or self.opts.download_path,
+                       repo.id if not self.opts.norepopath else '')

     def metadata_target(self, repo):
         if self.opts.metadata_path:
EOF
fi

sync_repo() {
    local REPO_LINK="${1:?}"
    local REPO_ID="${2:?}"
    local LOCAL_REPO_ID="${3:?}"
    local ARCHES GPG_KEY_URL GPG_KEY_NAME
    # This is so ugly, yet I'm still amazed that it works
    local DNF_OPTS=(
        "--setopt=pluginconfpath=$INSTALLROOT/etc/dnf/plugins/"
        "--setopt=pluginpath=$INSTALLROOT/usr/lib/python2.7/site-packages/dnf-plugins/"
    )

    IFS=" " read -ra ARCHES <<<"${4:?}"

    rm -f repo-config.repo
    wget -O repo-config.repo "$REPO_LINK"

    # Check if the original repository configuration contains a URL to a GPG key
    # If so, parse it and download it
    GPG_KEY_URL="$(awk -F= '/^gpgkey=/ { print $2 }' repo-config.repo)"
    if [[ -n "$GPG_KEY_URL" ]]; then
        GPG_KEY_NAME="${GPG_KEY_URL##*/}"
        wget -O "$GPG_KEY_NAME" "$GPG_KEY_URL"
    fi

    for arch in "${ARCHES[@]}"; do
        # Make a local copy of the original repository packages
        dnf "${DNF_OPTS[@]}" reposync --norepopath --newest-only --download-metadata --arch "$arch" --forcearch "$arch" --config="repo-config.repo" --repoid="$REPO_ID" --download-path="$DOWNLOAD_LOCATION/$LOCAL_REPO_ID/$arch"
    done

    # Create a repo file
    cat >"$DOWNLOAD_LOCATION/$LOCAL_REPO_ID/$LOCAL_REPO_ID.repo" << EOF
[$LOCAL_REPO_ID]
name=Mirror of $REPO_ID Copr repo (\$basearch)
baseurl=http://artifacts.ci.centos.org/systemd/repos/$LOCAL_REPO_ID/\$basearch/
skip_if_unavailable=False
enabled=1
# Disable modular filtering for this repository, so we can override certain
# module packages with our own
module_hotfixes=1
EOF
    # Copy over the downloaded GPG key, if any
    if [[ -f "$GPG_KEY_NAME" ]]; then
        mv "$GPG_KEY_NAME" "$DOWNLOAD_LOCATION/$LOCAL_REPO_ID/$GPG_KEY_NAME"
        echo "gpgkey=http://artifacts.ci.centos.org/systemd/repos/$LOCAL_REPO_ID/$GPG_KEY_NAME" >>"$DOWNLOAD_LOCATION/$LOCAL_REPO_ID/$LOCAL_REPO_ID.repo"
    fi

    # Sync the repo to the CentOS CI artifacts server
    rsync --password-file="$PASSWORD_FILE" -av "$DOWNLOAD_LOCATION/$LOCAL_REPO_ID" systemd@artifacts.ci.centos.org::systemd/repos/
    echo "Mirror url: http://artifacts.ci.centos.org/systemd/repos/$LOCAL_REPO_ID"
}

# TODO: add ppc64le once the copr builders are up
# EPEL-8
ORIGINAL_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/repo/epel-8/mrc0mmand-systemd-centos-ci-centos8-epel-8.repo"
ORIGINAL_REPO_ID="copr:copr.fedorainfracloud.org:mrc0mmand:systemd-centos-ci-centos8"
LOCAL_REPO_ID="mrc0mmand-systemd-centos-ci-centos8-epel8"
sync_repo "$ORIGINAL_REPO" "$ORIGINAL_REPO_ID" "$LOCAL_REPO_ID" "x86_64 aarch64"

# centos-8-stream
ORIGINAL_REPO="https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/repo/centos-stream-8/mrc0mmand-systemd-centos-ci-centos8-centos-stream-8.repo"
ORIGINAL_REPO_ID="copr:copr.fedorainfracloud.org:mrc0mmand:systemd-centos-ci-centos8"
LOCAL_REPO_ID="mrc0mmand-systemd-centos-ci-centos8-stream8"
sync_repo "$ORIGINAL_REPO" "$ORIGINAL_REPO_ID" "$LOCAL_REPO_ID" "x86_64 aarch64"
