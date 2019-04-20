#!/usr/bin/bash

# As the repository for RHEL 7 and RHEL 8 systemd is the same, we need to
# somehow distinguish between them and execute the right scripts.
# This script basically checks the root of the git repository for 'meson.build'
# file. If it exists, we'll use the upstream scripts (boostrap.sh, testsuite.sh),
# otherwise we assume RHEL 7 with their script counterparts (bootstrap-rhel7.sh,
# testsuite-rhel7.sh).

SCRIPT_ROOT="$(dirname $0)"
. "$SCRIPT_ROOT/../common/utils.sh" || exit 1

set -e -u

if [[ $# -lt 1 ]]; then
    echo >&2 "Usage: $0 phase [branch]"
    exit 1
fi

REPO_URL="https://github.com/lnykryn/systemd-rhel.git"
TEMP_GIT="$(mktemp -d)"
PHASE="${1^^}"
BRANCH="$2"

git clone "$REPO_URL" "$TEMP_GIT"
pushd "$TEMP_GIT"

git_checkout_pr "$BRANCH"

# Quick dirty decision check
SCRIPT_SUFFIX="rhel7"
[[ -f meson.build ]] && SCRIPT_SUFFIX="rhel8"

echo "RHEL script suffix: $SCRIPT_SUFFIX"

popd
rm -fr "$TEMP_GIT"

case $PHASE in
    BOOTSTRAP)
        exec "$SCRIPT_ROOT/bootstrap-$SCRIPT_SUFFIX.sh" "$BRANCH"
        ;;
    TESTSUITE)
        exec "$SCRIPT_ROOT/testsuite-$SCRIPT_SUFFIX.sh" "$BRANCH"
        ;;
    *)
        echo >&2 "Unknown phase '$PHASE'"
esac

# We should get here only when something fails
exit 1
