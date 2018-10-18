#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Library/basic
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

# Include Beaker environment
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="systemd"
PHASE=${PHASE:-Test}

rlJournalStart
    rlPhaseStartSetup
        rlRun "rlImport systemd/basic"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
    rlPhaseEnd

    rlPhaseStartTest "Version comparison"
        rlLog "Current is higher"
        rlRun "systemdVersionCompare gt 200-30.el7" 0
        rlRun "systemdVersionCompare lt 200-30.el7" 1
        rlRun "systemdVersionCompare ge 200-30.el7" 0
        rlRun "systemdVersionCompare le 200-30.el7" 1
        rlRun "systemdVersionCompare eq 200-30.el7" 1

        rlLog "Current is lower"
        rlRun "systemdVersionCompare gt 999-30.el7" 1
        rlRun "systemdVersionCompare lt 999-30.el7" 0
        rlRun "systemdVersionCompare ge 999-30.el7" 1
        rlRun "systemdVersionCompare le 999-30.el7" 0
        rlRun "systemdVersionCompare eq 999-30.el7" 1

        rlLog "Current is equal"
        ver=$(rpm -q systemd --qf "%{VERSION}-%{RELEASE}")
        rlRun "systemdVersionCompare gt $ver" 1
        rlRun "systemdVersionCompare lt $ver" 1
        rlRun "systemdVersionCompare ge $ver" 0
        rlRun "systemdVersionCompare le $ver" 0
        rlRun "systemdVersionCompare eq $ver" 0
    rlPhaseEnd

    rlPhaseStartTest
        rlLog "systemd architecture: $(systemdArch)"
    rlPhaseEnd


    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
