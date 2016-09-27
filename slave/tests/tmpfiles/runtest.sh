#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/tmpfiles
#   Description: Test for BZ#1365870 (Systemd-tmpfiles does not set owner/group defined)
#   Author: Branislav Blaskovic <bblaskov@redhat.com>
#   Some parts based on script by: Jakub Martisko <jamartis@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2016 Red Hat, Inc.
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

PACKAGE="systemd"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        rlRun "useradd foo"
        rlRun "groupadd bar"
    rlPhaseEnd

    rlPhaseStartTest "bug 1365870"

cat <<\EOF > /etc/tmpfiles.d/hello.conf
D /run/hello  1777 foo bar -
f /run/hello/hello.test  1777 root bar -
z /run/hello/hello.test 1777 root root - -
EOF

        rlRun "systemd-tmpfiles --create"
        rlRun -s "ls -al /run/hello/"
        rlAssertGrep "foo.*bar.*\.$" $rlRun_LOG
        rlAssertGrep "root.*root.*hello.test$" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "bug 1296288"

cat <<\EOF > /etc/tmpfiles.d/hello2.conf
D /run/hello2  1777 foo bar -
f /run/hello2/hello2.test  1777 root bar -
L+ /run/hello2/hello2.link - root bar - /run/hello2/hello2.test
z /run/hello2/hello2.test 1777 root root - -
z /run/hello2/hello2.link - foo bar - -
EOF


        rlRun "systemd-tmpfiles --create"
        rlRun -s "ls -l  /run/hello2/"
        rlAssertGrep "root.*root.* hello2.test$" $rlRun_LOG
        rlAssertGrep "root.*root.* hello2.link -> /run/hello2/hello2.test$" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "userdel -r foo"
        rlRun "groupdel bar"
        rlRun "rm -r $TmpDir /etc/tmpfiles.d/hello*.conf" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd

rlGetTestState
