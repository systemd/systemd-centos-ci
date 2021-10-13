#!/usr/bin/bash
# shellcheck disable=SC2155
# This file contains useful functions shared among scripts from this repository

set -o pipefail
set -u

__COREDUMPCTL_TS=""
# Keep a map of test-specific excludes to avoid code duplication
declare -Arx COREDUMPCTL_EXCLUDE_MAP=(
    ["test/TEST-17-UDEV"]="/(sleep|udevadm)$"
    ["test/TEST-59-RELOADING-RESTART"]="/(sleep|bash|systemd-notify)$"
)

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

    local needle="$1"
    shift

    for _elem in "$@"; do
        if [[ "$_elem" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

# Convert a string boolean value to a corresponding bash exit code
#
# Arguments:
#   $1 - boolean string
#
# Returns:
#   0 if the string value evaluates to 'true' (i.e. 1, yes, true, etc.),
#   1 otherwise (including an empty string)
get_bool() {
    # Make the value lowercase to make the regex matching simpler
    local _bool="${1,,}"

    # Consider empty value as "false"
    if [[ -z "$_bool" || "$_bool" =~ ^(0|no|false)$ ]]; then
        return 1
    elif [[ "$_bool" =~ ^(1|yes|true)$ ]]; then
        return 0
    else
        _err "Value '$_bool' is not a valid boolean value"
        exit 1
    fi
}

# Get the value of a boolean flag from the given meson project
#
# Arguments:
#   $1 - initialized meson build directory
#   $2 - flag name
#
# Returns:
#   0 if the flag value evaluates to 'true', 0 otherwise
meson_get_bool() {
    local build_dir="${1:?}"
    local flag_name="${2:?}"
    local value

    # jq alternative: | jq '.[] | select(.name=="b_coverage") | .value'
    # Use python, since jq might not be installed and we require python3 anyway
    value="$(meson introspect --buildoptions "$build_dir" | python3 -c "import json, sys; j = json.load(sys.stdin); [print(x['value']) for x in j if x['name'] == '$flag_name']")"
    if [[ -z "$value" ]]; then
        _err "'$flag_name' flag not found in the introspect output for '$build_dir'"
        exit 1
    fi

    get_bool "$value"
}

# Retry specified commands if it fails. The default # of retries is 3, this
# value can be overriden via the $RETRIES env variable
#
# Arguments:
#   $1 - $* - command to run
#
# Returns:
#   0 on success, last EC of the failing command otherwise
cmd_retry() {
    if [[ $# -eq 0 ]]; then
        _err "Missing arguments"
        return 1
    fi

    local retries="${RETRIES:-3}"
    local ec i

    for ((i = 1; i <= retries; i++)); do
        eval "$@" && return 0 || ec=$?
        _log "Command '$*' failed (EC: $ec) [try $i/$retries]"
        [[ $i -eq $retries ]] || sleep 5
    done

    return $ec
}

# Checkout to the requested branch:
#   1) if pr:XXX where XXX is a pull request ID is passed to the script,
#      the corresponding branch for this PR is be checked out
#   2) if any other string except pr:* is passed, it's used as a branch
#      name to check out
#   3) if the script is called without arguments, the default (possibly master)
#      branch is used
git_checkout_pr() {
    local master_branch

    _log "Arguments: $*"
    (
        set -e -u
        case $1 in
            pr:*)
                git branch | grep -E '\bmaster\b' && master_branch="master" || master_branch="main"
                # Draft and already merged pull requests don't have the 'merge'
                # ref anymore, so fall back to the *standard* 'head' ref in
                # such cases and rebase it against the master branch
                if ! git fetch -fu origin "refs/pull/${1#pr:}/merge:pr"; then
                    git fetch -fu origin "refs/pull/${1#pr:}/head:pr"
                    git rebase "$master_branch" pr
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
    local ec

    if ! systemctl start systemd-coredump.socket; then
        _err "Failed to start systemd-coredump.socket"
        return 1
    fi

    # Let's make sure coredumpctl doesn't crash on invocation
    # Note: coredumpctl returns 1 when no coredumps are found, so accept this EC
    # as a success as well
    coredumpctl > /dev/null
    ec=$?

    if ! [[ $ec -eq 0 || $ec -eq 1 ]]; then
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
    local args=(-q --no-legend --no-pager)
    # Allow overriding the coredumpctl binary for cases when we read coredumps
    # from a custom directory, which may contain journals with different features
    # than are supported by the local journalctl/coredumpctl versions
    local coredumpctl_bin="${COREDUMPCTL_BIN:-coredumpctl}"
    local journaldir="${1:-}"
    local tempfile="$(mktemp)"

    # Register a cleanup handler
    # shellcheck disable=SC2064
    trap "rm -f '$tempfile'" RETURN

    if ! "$coredumpctl_bin" --version >/dev/null; then
        _err "'$coredumpctl_bin' is not a valid binary"
        return 1
    fi

    _log "Attempting to collect info about possible coredumps"

    # If coredumpctl_set_ts() was called beforehand, use the saved timestamp
    if [[ -n "$__COREDUMPCTL_TS" ]]; then
        _log "Looking for coredumps since $__COREDUMPCTL_TS"
        args+=(--since "$__COREDUMPCTL_TS")
    fi

    # To get meaningful results from non-standard journal locations (especially
    # when it comes to full stack traces), systemd-coredump should be configured
    # with 'Storage=journal'
    if [[ -n "$journaldir" ]]; then
        _log "Using a custom journal directory: $journaldir"
        args+=(-D "$journaldir")
    fi

    # Collect executable paths of all coredumps and filter out the expected ones.
    # The filter can be overridden using the $COREDUMPCTL_EXCLUDE_RX env variable.
    # EXCLUDE_RX:
    #   test-execute - certain subtests die with SIGSEGV intentionally
    #   dhcpcd - [temporary] keeps crashing intermittently with SIGABRT, needs
    #            further investigation
    #   python3.x - one of the test-execute subtests triggers SIGSYS in python3.x
    #               (since systemd/systemd#16675)
    #   sleep/bash - intentional SIGABRT caused by TEST-57
    #   systemd-notify - intermittent (and intentional) SIGABRT caused by TEST-59
    local exclude_rx="${COREDUMPCTL_EXCLUDE_RX:-/(test-execute|dhcpcd|bin/python3.[0-9]+|platform-python3.[0-9]+|bash|sleep|systemd-notify)$}"
    _log "Excluding coredumps matching '$exclude_rx'"
    if ! "$coredumpctl_bin" "${args[@]}" -F COREDUMP_EXE | grep -Ev "$exclude_rx" > "$tempfile"; then
        _log "No relevant coredumps found"
        return 0
    fi

    # For each unique executable path call 'coredumpctl info' to get the stack
    # trace and other useful info
    while read -r path; do
        local exe
        local gdb_cmd="bt full\nquit"

        _log "Collecting coredumps for '$path'"
        "$coredumpctl_bin" "${args[@]}" info "$path"
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
            exe="$BUILD_DIR/${path##*/}"
            gdb_cmd="file $exe\nthread apply all bt\nbt full\nquit"
            _log "\$BUILD_DIR is set and '${path##*/}' was found in it"
            _log "Overriding the executable to '$exe' and gdb command to '$gdb_cmd'"
        fi

        # Attempt to get a full stack trace for the first occurrence of the
        # given executable path
        if gdb -v > /dev/null; then
            echo -e "\n"
            _log "Trying to run gdb with '$gdb_cmd' for '$path'"
            echo -e "$gdb_cmd" | "$coredumpctl_bin" "${args[@]}" debug "$path"
            echo -e "\n"
        fi
    done < <(sort -u "$tempfile")

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
    local kvm_module_name kvm_module_nested

    if kvm_module_name="$(lsmod | grep -m1 -Eo '(kvm_amd|kvm_intel)')"; then
        _log "Detected KVM module: $kvm_module_name"

        kvm_module_nested="$(< "/sys/module/$kvm_module_name/parameters/nested")" || :
        _log "/sys/module/$kvm_module_name/parameters/nested: $kvm_module_nested"

        if [[ "$kvm_module_nested" =~ (1|Y) ]]; then
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

# Collect coverage metadata from given directory and generate a coverage report
#
# Arguments:
#   $1 - output file (coverage report)
#   $2 - directory which will be searched for coverage metadata (recursively)
lcov_collect() {
    local output_file="${1:?}"
    local build_dir="${2:?}"

    if ! lcov --directory "$build_dir" --capture --output-file "$output_file"; then
        _err "Failed to capture coverage data from '$build_dir'"
        return 1
    fi

    if ! lcov --remove "$output_file" -o "$output_file" '/usr/include/*' '/usr/lib/*'; then
        _err "Failed to remove unrelated data from the capture file"
        return 1
    fi
}

# Collect all lcov reports from given directory (recursively) and merge them
# into a single file
#
# Arguments:
#   $1 - output file
#   $2 - $* - directories to search the lcov reports in
#
# Returns:
#   0 on success, 1 otherwise (i.e. no reports found, invalid data, etc.)
lcov_merge() {
    local lcov_args=()
    local file
    local output_file="${1:?}"
    shift

    if [[ $# -eq 0 ]]; then
        _err "Usage: ${FUNCNAME[0]} <output file> <input dir> [<input dir> ...]"
        return 1
    fi

    # Recursively find all *.coverage-info files in the given directory and
    # add them to the command line for `lcov`
    while read -r file; do
        lcov_args+=(--add-tracefile "${file}")
    done < <(find "$@" -name "*.coverage-info")

    if [[ ${#lcov_args[@]} -gt 0 ]]; then
        _log "Merging $((${#lcov_args[@]}/2)) lcov reports into $output_file"
        if ! lcov "${lcov_args[@]}" --output-file "$output_file"; then
            _err "Failed to merge the coverage reports"
            return 1
        fi
    else
        _err "No coverage files (*.coverage-info) found in given directories"
        return 1
    fi
}

# Remove coverage metadata (*.gcda and *.gcno files) from given directory (recursively)
#
# Arguments:
#   $1 - directory which will be search for metadata (recursively)
#
# Returns:
#   0 on success, >0 otherwise
lcov_clear_metadata() {
    local dir="${1?}"

    if [[ ! -d "$dir" ]]; then
        _err "Invalid directory '$dir'"
        return 1
    fi

    find "$dir" \( -name "*.gcda" -o -name "*.gcno" \) -exec rm -f '{}' \;
}
