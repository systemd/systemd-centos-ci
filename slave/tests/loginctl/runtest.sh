#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/loginctl
#   Description: loginctl test
#   Author: Branislav Blaskovic <bblaskov@redhat.com>
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
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="systemd"
USER=systemdtester
SESSION_NUM=3
SSH_OPTS="-o StrictHostKeyChecking=no"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlFileBackup --clean /root/.ssh
        rlRun "rm -fr /root/.ssh/*"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "useradd $USER"
        rlRun "ssh-keygen -t rsa -q -N '' -f ~/.ssh/id_rsa"
        rlRun "sudo -u $USER ssh-keygen -t rsa -q -N '' -f /home/$USER/.ssh/id_rsa"
        rlRun "cat /root/.ssh/id_rsa.pub >> /home/$USER/.ssh/authorized_keys"
        rlRun "cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys"
        rlRun "cat /home/$USER/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys"
        rlRun "chown -R $USER /home/$USER"
        rlRun "restorecon -v -R /home/$USER"
        rlRun "find /home/$USER"
        rlRun "pushd $TmpDir"
        rlServiceStart sshd
    rlPhaseEnd

    #
    # BASICS
    #
    rlPhaseStartTest "basics"
        rlRun "loginctl --help"
        rlRun "loginctl"
        for action in list-seats list-sessions list-users show-seat show-session show-user user-status
        do
            SYSTEMD_PAGER= rlRun "loginctl $action"
        done

        if rlIsRHEL 7; then
            rlRun -s "readlink -f `which systemd-loginctl`"
            rlLog "Check if systemd-loginctl points to loginctl binary"
            rlAssertGrep $(which loginctl) $rlRun_LOG
        fi
    rlPhaseEnd

    #
    # BASICS - no pager
    #
    rlPhaseStartTest "basics no pager"
        rlRun "loginctl --help"
        rlRun "loginctl"
        for action in list-seats list-sessions list-users show-seat show-session show-user user-status
        do
            rlRun "loginctl --no-pager $action"
        done

        if rlIsRHEL 7; then
            rlRun -s "readlink -f `which systemd-loginctl`"
            rlLog "Check if systemd-loginctl points to loginctl binary"
            rlAssertGrep $(which loginctl) $rlRun_LOG
        fi
    rlPhaseEnd

    #
    # ADVANCED - setup
    #
    rlPhaseStartTest "setup advanced"
        for i in `seq 1 $SESSION_NUM`
        do
            ssh $SSH_OPTS $USER@localhost 'sleep 1h' &
            sshPid=$!
            sleep 2
            rlRun "ps $sshPid" 0 "ssh connection for $USER is up and running"

            ssh $SSH_OPTS root@localhost 'sleep 1h' &
            sshPidRoot=$!
            sleep 2
            rlRun "ps $sshPidRoot" 0 "ssh connection for root is up and running"
        done
    rlPhaseEnd

    #
    # ADVANCED - testing
    #
    rlPhaseStartTest "advanced"
        rlLog "list-sessions check"
        rlRun -s "loginctl list-sessions"
        rlAssertGrep "$USER" $rlRun_LOG

        rlLog
        rlLog "list-users check"
        rlRun -s "loginctl list-users"
        rlAssertGrep "$(id -u root) root"  $rlRun_LOG
        rlAssertGrep "$(id -u $USER) $USER"  $rlRun_LOG

        rlLog
        rlLog "show-user check"
        rlRun -s "loginctl show-user $USER"
        rlAssertGrep "^UID=$(id -u $USER)$"  $rlRun_LOG
        rlAssertGrep "^GID=$(id -g $USER)$"  $rlRun_LOG
        rlAssertGrep "^Name=$USER$"  $rlRun_LOG

        rlLog
        rlLog "show-session check"
        for session in $(loginctl list-sessions | grep $USER | awk '{print $1}')
        do
            rlRun -s "loginctl show-session $session"
            rlAssertGrep "^Id=$session$"  $rlRun_LOG
            rlAssertGrep "^User=$(id -u $USER)$"  $rlRun_LOG
            rlAssertGrep "^Name=$USER$"  $rlRun_LOG
            rlAssertGrep "^Service=sshd$"  $rlRun_LOG
            rlAssertGrep "^Class=user$"  $rlRun_LOG
            rlAssertGrep "^Active=yes$"  $rlRun_LOG
            rlAssertGrep "^State=active$"  $rlRun_LOG
        done
    rlPhaseEnd

    #
    # ADVANCED - cleanup
    #
    rlPhaseStartTest "cleanup advanced"
        ps -u $USER | awk '{print $1}' | while read pid
        do
            test "$pid" = "PID" && continue
            rlRun "kill -9 $pid" 0-255
        done
        sleep 5
        rlRun "ps -u $USER" 1 "There are no processes for $USER"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlFileRestore
        rlServiceRestore sshd
        rlRun "userdel -r $USER"
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
