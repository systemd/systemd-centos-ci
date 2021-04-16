#!/usr/bin/bash
# shellcheck disable=SC2155
# This file contains useful functions shared among scripts from this repository

set -o pipefail
set -u

__COREDUMPCTL_TS=""

# Internal logging helpers which make use of the internal call stack to get
# the function name of the caller
_log() { echo "[${FUNCNAME[1]}] $1"; }
_err() { echo >&2 "[${FUNCNAME[1]}] $1"; }

# Checks if the first argument is in a set consisting of the rest of the arguments
#
# Works around the limitation of not being able to pass arrays as arguments in bash
# (well, there *are* ways, but not convenient ones). It, of course, doesn't work
# for _extra_ large arrays (but that's not a case we need, at least for now).
# Example usage:
#   my_array=("one", "two", "three")
#   if ! in_set "five" "${my_array[@]}"; then...
#
# Arguments:
#   $1    - element to check
#   $2-$n - "set" of elements
#
# Returns:
#   0 on success, 1 otherwise
in_set() {
    if [[ $# -lt 2 ]]; then
        _err "Not enough arguments"
        return 1
    fi

    local NEEDLE="$1"
    shift

    for _elem in "$@"; do
        if [[ "$_elem" == "$NEEDLE" ]]; then
            return 0
        fi
    done

    return 1
}

# Checkout to the requested branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
git_checkout_pr() {
    local MASTER_BRANCH

    _log "Arguments: $*"
    (
        set -e -u
        case $1 in
            pr:*)
                git branch | grep -E '\bmaster\b' && MASTER_BRANCH="master" || MASTER_BRANCH="main"
                # Draft and already merged pull requests don't have the 'merge'
                # ref anymore, so fall back to the *standard* 'head' ref in
                # such cases and rebase it against the master branch
                if ! git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"; then
                    git fetch -fu origin "refs/pull/${1#pr:}/head:pr"
                    git rebase "$MASTER_BRANCH" pr
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

    _log "Checked out version: $(git describe)"
    git log -1
}

# Check input from stdin for sanitizer errors/warnings
# Takes no arguments, reads input directly from stdin to allow piping, like:
#   journalctl -b | check_for_sanitizer_errors
#
# shellcheck disable=SC1004
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
    # Internal errors (==119906==LeakSanitizer has encountered a fatal error.)
    /==[0-9]+==.+?\w+Sanitizer has encountered a fatal error/,/==[0-9]+==HINT: \w+Sanitizer/ {
        print $0;
        next;
    }

    # "Standard" errors
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
        _err "Failed to start systemd-coredump.socket"
        return 1
    fi

    # Let's make sure coredumpctl doesn't crash on invocation
    # Note: coredumpctl returns 1 when no coredumps are found, so accept this EC
    # as a success as well
    coredumpctl > /dev/null
    EC=$?

    if ! [[ $EC -eq 0 || $EC -eq 1 ]]; then
        _err "coredumpctl is not in operative state"
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
    local ARGS=(-q --no-legend --no-pager)
    # Allow overriding the coredumpctl binary for cases when we read coredumps
    # from a custom directory, which may contain journals with different features
    # than are supported by the local journalctl/coredumpctl versions
    local COREDUMPCTL_BIN="${COREDUMPCTL_BIN:-coredumpctl}"
    local JOURNALDIR="${1:-}"
    local TEMPFILE="$(mktemp)"

    # Register a cleanup handler
    # shellcheck disable=SC2064
    trap "rm -f '$TEMPFILE'" EXIT

    if ! "$COREDUMPCTL_BIN" --version >/dev/null; then
        _err "'$COREDUMPCTL_BIN' is not a valid binary"
        return 1
    fi

    _log "Attempting to collect info about possible coredumps"

    # If coredumpctl_set_ts() was called beforehand, use the saved timestamp
    if [[ -n "$__COREDUMPCTL_TS" ]]; then
        _log "Looking for coredumps since $__COREDUMPCTL_TS"
        ARGS+=(--since "$__COREDUMPCTL_TS")
    fi

    # To get meaningful results from non-standard journal locations (especially
    # when it comes to full stack traces), systemd-coredump should be configured
    # with 'Storage=journal'
    if [[ -n "$JOURNALDIR" ]]; then
        _log "Using a custom journal directory: $JOURNALDIR"
        ARGS+=(-D "$JOURNALDIR")
    fi

    # Collect executable paths of all coredumps and filter out the expected ones.
    # The filter can be overridden using the $COREDUMPCTL_EXCLUDE_RX env variable.
    # EXCLUDE_RX:
    #   test-execute - certain subtests die with SIGSEGV intentionally
    #   dhcpcd - [temporary] keeps crashing intermittently with SIGABRT, needs
    #            further investigation
    #   python3.x - one of the test-execute subtests triggers SIGSYS in python3.x
    #               (since systemd/systemd#16675)
    #   bash - intentional SIGABRT caused by TEST-57
    local EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_RX:-/(test-execute|dhcpcd|bin/python3.[0-9]+|platform-python3.[0-9]+|bash)$}"
    _log "Excluding coredumps matching '$EXCLUDE_RX'"
    if ! "$COREDUMPCTL_BIN" "${ARGS[@]}" -F COREDUMP_EXE | grep -Ev "$EXCLUDE_RX" > "$TEMPFILE"; then
        _log "No relevant coredumps found"
        return 0
    fi

    # For each unique executable path call 'coredumpctl info' to get the stack
    # trace and other useful info
    while read -r path; do
        local EXE
        local GDB_CMD="bt full\nquit"

        _log "Gathering coredumps for '$path'"
        "$COREDUMPCTL_BIN" "${ARGS[@]}" info "$path"
        # Make sure we use the built binaries for getting gdb trace
        # This is relevant mainly for the sanitizers run, where we don't install
        # the just built revision, so `coredumpctl debug` pulls in a local binary
        # instead of the built one, which produces useless results.
        # Note: this works _ONLY_ when $BUILD_DIR is set (the same variable
        # as used by the systemd integration tests) so we know from where to
        # pull binaries in
        if [[ -v BUILD_DIR && -d $BUILD_DIR && -x $BUILD_DIR/${path##*/} ]]; then
            # $BUILD_DIR is set and we found the binary in it, let's override
            # the gdb command
            EXE="$BUILD_DIR/${path##*/}"
            GDB_CMD="file $EXE\nthread apply all bt\nbt full\nquit"
            _log "\$BUILD_DIR is set and '${path##*/}' was found in it"
            _log "Overriding the executable to '$EXE' and gdb command to '$GDB_CMD'"
        fi

        # Attempt to get a full stack trace for the first occurrence of the
        # given executable path
        if gdb -v > /dev/null; then
            echo -e "\n"
            _log "Trying to run gdb with '$GDB_CMD' for '$path'"
            echo -e "$GDB_CMD" | "$COREDUMPCTL_BIN" "${ARGS[@]}" debug "$path"
            echo -e "\n"
        fi
    done < <(sort -u "$TEMPFILE")

    return 1
}

# Print the currently used cgroups hierarchy in a "human-friendly" form:
# unified, hybrid, legacy, or unknown.
print_cgroup_hierarchy() {
    if [[ "$(stat -c '%T' -f /sys/fs/cgroup)" == cgroup2fs ]]; then
        echo "unified"
    elif [[ "$(stat -c '%T' -f /sys/fs/cgroup)" == tmpfs ]]; then
        if [[ -d /sys/fs/cgroup/unified && "$(stat -c '%T' -f /sys/fs/cgroup/unified)" == cgroup2fs ]]; then
            echo "hybrid"
        else
            echo "legacy"
        fi
    else
        echo "unknown"
    fi
}

is_nested_kvm_enabled() {
    local KVM_MODULE_NAME KVM_MODULE_NESTED

    if KVM_MODULE_NAME="$(lsmod | grep -m1 -Eo '(kvm_amd|kvm_intel)')"; then
        _log "Detected KVM module: $KVM_MODULE_NAME"

        KVM_MODULE_NESTED="$(< "/sys/module/$KVM_MODULE_NAME/parameters/nested")" || :
        _log "/sys/module/$KVM_MODULE_NAME/parameters/nested: $KVM_MODULE_NESTED"

        if [[ "$KVM_MODULE_NESTED" =~ (1|Y) ]]; then
            _log "Nested KVM is enabled"
            return 0
        else
            _log "Nested KVM is disabled"
            return 1
        fi
    else
        _log "No KVM module detected"
    fi

    return 1
}
