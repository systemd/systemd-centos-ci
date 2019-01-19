#!/usr/bin/bash
# This file contains useful functions shared among scripts from this repository

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
git_checkout_pr() {
    echo "[git_checkout_pr] Arguments: $*"
    (set -e
        case $1 in
            pr:*)
                git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"
                git checkout pr
                ;;
            "")
                ;;
            *)
                git checkout "$1"
                ;;
        esac
    ) || return 1

    echo -n "[git_checkout_pr] Checked out version: "
    git describe
}
