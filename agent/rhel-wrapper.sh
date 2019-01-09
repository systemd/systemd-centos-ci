#!/usr/bin/bash

# As the repository for RHEL 7 and RHEL 8 systemd is the same, we need to
# somehow distinguish between them and execute the right scripts.
# This script basically checks the root of the git repository for 'meson.build'
# file. If it exists, we'll use the upstream scripts (boostrap.sh, testsuite.sh),
# otherwise we assume RHEL 7 with their script counterparts (bootstrap-rhel7.sh,
# testsuite-rhel7.sh).

set -e

if [ $# -lt 1 ]; then
    echo >&2 "Usage: $0 phase [branch]"
    exit 1
fi

REPO_URL="https://github.com/lnykryn/systemd-rhel.git"
SCRIPT_ROOT="$(dirname $0)"
TEMP_GIT="$(mktemp -d)"
PHASE="${1^^}"
BRANCH="$2"

git clone "$REPO_URL" "$TEMP_GIT"
pushd "$TEMP_GIT"

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
case $BRANCH in
    pr:*)
        git fetch -fu origin "refs/pull/${BRANCH#pr:}/merge:pr"
        git checkout pr
        ;;

    "")
        ;;

    *)
        git checkout "$BRANCH"
        ;;
esac

# Quick dirty decision check
IS_RHEL_7=true
[ -f meson.build ] && IS_RHEL_7=false

popd
rm -fr "$TEMP_GIT"

case $PHASE in
    BOOTSTRAP)
        if $IS_RHEL_7; then
            exec "$SCRIPT_ROOT/bootstrap-rhel7.sh" "$BRANCH"
        else
            REPO_URL="$REPO_URL" exec "$SCRIPT_ROOT/bootstrap.sh" "$BRANCH"
        fi
        ;;
    TESTSUITE)
        if $IS_RHEL_7; then
            exec "$SCRIPT_ROOT/testsuite-rhel7.sh" "$BRANCH"
        else
            REPO_URL="$REPO_URL" exec "$SCRIPT_ROOT/testsuite.sh" "$BRANCH"
        fi
        ;;
    *)
        echo >&2 "Unknown phase '$PHASE'"
esac

# We should get here only when something fails
exit 1
