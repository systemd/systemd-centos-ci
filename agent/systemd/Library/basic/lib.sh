#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   lib.sh of /CoreOS/systemd/Library/basic
#   Description: Basic functions for systemd testing
#   Author: Branislav Blaskovic <bblaskov@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2015 Red Hat, Inc.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = basic
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 NAME

systemd/basic - Basic functions for systemd testing

=head1 DESCRIPTION

This is a trivial example of a BeakerLib library. It's main goal
is to provide a minimal template which can be used as a skeleton
when creating a new library. It implements function fileCreate().
Please note, that all library functions must begin with the same
prefix which is defined at the beginning of the library.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 VARIABLES

Below is the list of global variables. When writing a new library,
please make sure that all global variables start with the library
prefix to prevent collisions with other libraries.

=over

=item fileFILENAME

Default file name to be used when no provided ('foo').

=back

=cut

fileFILENAME="foo"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 systemdArch

Returns current architecture which is used in systemd. (So you can grep it easily)

=cut

systemdArch() {
    out=$(uname -m)

    case `uname -m` in
        x86_64)
            out="x86-64"
            ;;
        aarch64)
            out="arm64"
            ;;
        ppc64le)
            out="ppc64-le"
            ;;
    esac

    echo "$out"
}

true <<'=cut'
=pod

=head2 systemdVersionCompare

Compare current version of systemd with the given one

systemdVersionCompare {comparation} {version}
systemdVersionCompare > 219-30.el7

Allowed comparisions: lt(<), gt(>), eq(=), ge(>=), le(<=)

=cut

systemdVersionCompare() {
    compare=$1
    version=$2
    phaseName=$3
    currentVersion=$(rpm -q systemd --qf "%{VERSION}-%{RELEASE}")
    result=$(python -c "import rpmUtils.miscutils ; print rpmUtils.miscutils.compareVerOnly('$version', '$currentVersion');")
    out=0
    if [ $result -eq 1 ] ; then
        # current is lower
        case $compare in
            "lt") out=0 ; ;;
            "gt") out=1 ; ;;
            "eq") out=1 ; ;;
            "le") out=0 ; ;;
            "ge") out=1 ; ;;
        esac
    elif [ $result -eq 0 ] ; then
        # current is the same
        case $compare in
            "lt") out=1 ; ;;
            "gt") out=1 ; ;;
            "eq") out=0 ; ;;
            "le") out=0 ; ;;
            "ge") out=0 ; ;;
        esac
    else
        # current is higher
        case $compare in
            "lt") out=1 ; ;;
            "gt") out=0 ; ;;
            "eq") out=1 ; ;;
            "le") out=1 ; ;;
            "ge") out=0 ; ;;
        esac
    fi
    return $out
}


# Wait until system "finishes" bootup
# This is a nasty hack, as all currently supported harnesses start before
# the systemd bootup is finished. This causes all systemd-analyze calls to fail.
# This function checks every 5 seconds if the bootup is finished (timeout is
# specified as a first argument in seconds, default: 120 secs), if so, it breaks
# the waiting loop, so the next command can continue.
# This solution is not error-prone, as the bootup time depends heavily on
# the particular machine performance. Unfortunately, it is the fastest and
# simplest solution we currently have.
#
# Parameters:
# $1 - max. waiting time in seconds (default: 120 secs)
basicWaitForBootup() {
    local timeout=1
    local delay=120
    if [[ ! -z $1 ]]; then
        delay=$1
    fi

    looplim=$(($delay/5))
    total=0

    echo "[basicWaitForBootup] Waiting for system bootup, timeout: $delay secs"
    for _ in $(seq 1 $looplim); do
        if systemd-analyze &> /dev/null; then
            timeout=0
            break
        fi
        sleep 5
        total=$(($total + 5))
    done

    if [[ $timeout -eq 1 ]]; then
        echo "[basicWaitForBootup] Waiting finished, reason: timeout reached"
        systemctl list-jobs
    else
        echo "[basicWaitForBootup] Waiting finished, reason: bootup finished (${total}s)"
    fi

}

# goto statement implementation for bash
# See: https://bobcopeland.com/blog/2012/10/goto-in-bash/
# This function should be used solely for debugging purposes
#
# Example:
# basicGoTo end
# echo "this part will be skipped"
#
# end:
# echo "script end"
#
# Parameters:
# $1 - label to jump to
# $2 - path to the script from which the goto is called from
# ad $2: if the goto is called after changing the CWD, sed will
#        fail to find the script file. In such cases the second
#        parameter needs to be set


basicGoTo() {
    local label="$1"
    local srcpath="${2:-$0}"
    local command="$(sed -n "/$label:/{:a;n;p;ba};" "$srcpath" | grep -v ':$')"
    rlLogWarning "GOTO: jumping to $label"
    eval "$command"
    exit
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Execution
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 EXECUTION

This library supports direct execution. When run as a task, phases
provided in the PHASE environment variable will be executed.
Supported phases are:

=over

=item Create

Create a new empty file. Use FILENAME to provide the desired file
name. By default 'foo' is created in the current directory.

=item Test

Run the self test suite.

=back

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.

basicLibraryLoaded() {
    if rpm=$(rpm -q systemd); then
        rlLogDebug "Library systemd running with $rpm"
        return 0
    else
        rlLogError "Package coreutils not installed"
        return 1
    fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Branislav Blaskovic <bblaskov@redhat.com>

=back

=cut
