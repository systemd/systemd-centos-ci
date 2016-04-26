#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/hostnamectl
#   Description: Test for hostnamectl
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
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Inspiration from https://bazaar.launchpad.net/~ubuntu-branches/ubuntu/wily/systemd/wily/view/head:/debian/tests/hostnamed

PACKAGE="systemd"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "ORIG_HOST=`cat /etc/hostname`"
        rlRun -s "hostnamectl"
    rlPhaseEnd

    rlPhaseStartTest
        rlLog "status test"
        rlAssertGrep "Static hostname: $ORIG_HOST" "$rlRun_LOG"

        rlLog "set-hostname test"
        rlRun "hostnamectl set-hostname testhostname"
        rlAssertGrep "testhostname" "/etc/hostname"
        rlRun -s "hostnamectl"
        rlAssertGrep "Static hostname: testhostname" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "hostnamectl set-hostname $ORIG_HOST"
        rlRun -s "hostnamectl"
        rlAssertGrep "Static hostname: $ORIG_HOST" "$rlRun_LOG"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd

rlGetTestState
