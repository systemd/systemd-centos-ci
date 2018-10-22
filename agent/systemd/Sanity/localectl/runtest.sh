#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/localectl
#   Description: Test for localectl
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

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        rlAssertRpm "selinux-policy"
        rlRun "rpm -Va" 0,1
        rlRun "ls -laZ /etc/locale.conf"

        rlFileBackup "/etc/locale.conf"
        rlFileBackup "/etc/vconsole.conf"
    rlPhaseEnd

    rlPhaseStartTest

        rlRun -s "localectl"
        rlAssertGrep "System Locale:" "$rlRun_LOG"

        rlRun "localectl set-locale LANG=C LC_CTYPE=en_US.UTF-8"
        rlRun -s "localectl"
        rlAssertGrep "LANG=C" "$rlRun_LOG"
        rlAssertGrep "LC_CTYPE=en_US.UTF-8" "$rlRun_LOG"

        rlRun "localectl set-locale LANG=C LC_CTYPE=sk_SK.UTF-8"
        rlRun -s "localectl"
        rlAssertGrep "LC_CTYPE=sk_SK.UTF-8" "$rlRun_LOG"

        rlRun "localectl set-x11-keymap et pc101"
        rlRun -s "localectl"
        rlAssertGrep "X11 Layout: et" "$rlRun_LOG"
        rlAssertGrep "X11 Model: pc101" "$rlRun_LOG"


    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "localectl set-x11-keymap us"
        rlFileRestore
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
