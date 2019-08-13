#!/usr/bin/bash
# This file contains useful functions shared among scripts from this repository

__COREDUMPCTL_TS=""

# Checkout to the requsted branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
git_checkout_pr() {
    echo "[$FUNCNAME] Arguments: $*"
    (
        set -e -u
        case $1 in
            pr:*)
                # Draft and already merged pull requests don't have the 'merge'
                # ref anymore, so fall back to the *standard* 'head' ref in
                # such cases and rebase it against the master branch
                if ! git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"; then
                    git fetch -fu origin "refs/pull/${1#pr:}/head:pr"
                    git rebase master pr
                fi

                git checkout pr
                ;;
            "")
                ;;
            *)
                git checkout "$1"
                ;;
        esac
    ) || return 1

    # Initialize git submodules, if any
    git submodule update --init --recursive

    echo -n "[$FUNCNAME] Checked out version: "
    git describe
    git log -1
}

# Check input from stdin for sanitizer errors/warnings
# Takes no arguments, reads input directly from stdin to allow piping, like:
#   journalctl -b | check_for_sanitizer_errors
check_for_sanitizer_errors() {
    awk '
    BEGIN {
        # Counters
        asan_cnt = 0;
        ubsan_cnt = 0;
        msan_cnt = 0;
        total_cnt = 0;
    }

    # Extractors
    /([0-9]+: runtime error|==[0-9]+==.+?\w+Sanitizer)/,/SUMMARY:\s+(\w+)Sanitizer/ {
        print $0;
    }

    # Counters
    match($0, /SUMMARY:\s+(\w+)Sanitizer/, m) {
        total_cnt++;

        switch (m[1]) {
        case "Address":
            asan_cnt++;
            break;
        case "UndefinedBehavior":
            ubsan_cnt++;
            break;
        case "Memory":
            msan_cnt++;
            break;
        }

        # Print a newline after every SUMMARY line (i.e. end of the sanitizer error
        # block), to improve readability
        print "\n";
    }

    END {
        if (total_cnt != 0) {
            printf " ____________________________________________\n" \
                   "/ Found %3d sanitizer errors (%3d ASan, %3d  \\\n" \
                   "| UBSan, %3d MSan). Looks like you need to   |\n" \
                   "\\ look at the log                            /\n" \
                   " --------------------------------------------\n" \
                   " \\\n" \
                   "  \\\n" \
                   "     __\n" \
                   "    /  \\\n" \
                   "    |  |\n" \
                   "    @  @\n" \
                   "    |  |\n" \
                   "    || |/\n" \
                   "    || ||\n" \
                   "    |\\_/|\n" \
                   "    \\___/\n", \
                    total_cnt, asan_cnt, ubsan_cnt, msan_cnt;
            exit 1
        }
    }
    '
}

# Enable coredump collection using systemd-coredump
#
# Basically just enable systemd-coredump.socket and check if coredumpctl doesn't
# crash when invoked
#
# Returns:
#   0 when both systemd-coredump & coredumpctl work as expected, 1 otherwise
coredumpctl_init() {
    local EC

    if ! systemctl start systemd-coredump.socket; then
        echo >&2 "[$FUNCNAME] Failed to start systemd-coredump.socket"
        return 1
    fi

    # Let's make sure coredumpctl doesn't crash on invocation
    # Note: coredumpctl returns 1 when no coredumps are found, so accept this EC
    # as a success as well
    coredumpctl > /dev/null
    EC=$?

    if ! [[ $EC -eq 0 || $EC -eq 1 ]]; then
        echo >&2 "[$FUNCNAME] coredumpctl is not in operative state"
        return 1
    fi
}

# Set the timestamp for future coredump collection using coredumpctl_collect()
#
# Arguments:
#
#   $1: timestamp to set. If empty, the current date & time is used instead
coredumpctl_set_ts() {
    __COREDUMPCTL_TS="${1:-$(date +"%Y-%m-%d %H:%M:%S")}"
}

# Attempt to dump info about relevant coredumps using the coredumpctl utility.
#
# To limit the collection scope (e.g. consider coredumps only since a certain
# date), use the coredumpctl_set_ts() function
#
# Arguments:
#   $1: (optional) path to a directory with journal files
#
# Returns:
#   0 when no coredumps were found, 1 otherwise
coredumpctl_collect() {
    local ARGS=(--no-legend --no-pager)
    local JOURNALDIR="${1:-}"
    local TEMPFILE="$(mktemp)"

    # Register a cleanup handler
    trap "rm -f '$TEMPFILE'" EXIT

    echo "[$FUNCNAME] Attempting to collect info about possible coredumps"

    # If coredumpctl_set_ts() was called beforehand, use the saved timestamp
    if [[ -n "$__COREDUMPCTL_TS" ]]; then
        echo "[$FUNCNAME] Looking for coredumps since $__COREDUMPCTL_TS"
        ARGS+=(--since "$__COREDUMPCTL_TS")
    fi

    # To get meaningful results from non-standard journal locations (especially
    # when it comes to full stack traces), systemd-coredump should be configured
    # with 'Storage=journal'
    if [[ -n "$JOURNALDIR" ]]; then
        echo "[$FUNCNAME] Using a custom journal directory: $JOURNALDIR"
        ARGS+=(-D "$JOURNALDIR")
    fi

    # Collect executable paths of all coredumps and filter out the expected ones
    # FILTER_RX:
    #   test-execute - certain subtests die with SIGSEGV intentionally
    FILTER_RX="/test-execute$"
    if ! coredumpctl "${ARGS[@]}" -F COREDUMP_EXE | grep -Ev "$FILTER_RX" > "$TEMPFILE"; then
        echo "[$FUNCNAME] No relevant coredumps found"
        return 0
    fi

    # For each unique executable path call 'coredumpctl info' to get the stack
    # trace and other useful info
    while read -r path; do
        echo "[$FUNCNAME] Gathering coredumps for '$path'"
        coredumpctl "${ARGS[@]}" info "$path"
        # Attempt to get a full stack trace for the first occurrence of the
        # given executable path
        if gdb -v > /dev/null; then
            echo -e "\n[$FUNCNAME] Trying to run gdb with 'bt full' for '$path'"
            echo -e "bt full\nquit" | coredumpctl "${ARGS[@]}" debug "$path"
            echo -e "\n"
        fi
    done <<< "$(sort -u $TEMPFILE)"

    return 1
}
