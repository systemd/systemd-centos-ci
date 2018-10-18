#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/systemd/Sanity/timedatectl
#   Description: Test for timedatectl
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
        rlAssertRpm chrony
        rlFileBackup --clean "/var/lib/chrony/drift" "/etc/chrony.keys"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        rlRun -s "timedatectl"
        sed -i "s/Timezone/Time zone/" $rlRun_LOG
        rlRun "TZ_ORIG=$( awk '/Timezone/ {print $2}' $rlRun_LOG )"
        [[ -z $TZ_ORIG ]] && rlRun "TZ_ORIG=$( awk '/Time zone/ {print $3}' $rlRun_LOG )"


        rlServiceStart chronyd
        rlServiceStart systemd-timedated
        timedatectl set-ntp false
        rlLog "date = `date`"
    rlPhaseEnd

    rlPhaseStartTest "Timezones"
        rlAssertGrep "Local time:" "$rlRun_LOG"

        rlRun "timedatectl set-timezone Europe/Moscow"
        rlRun -s "timedatectl"
        rlAssertGrep "Time[ ]*zone: Europe/Moscow" "$rlRun_LOG"
        rlRun -s "ls -l /etc/localtime"
        rlAssertGrep "/usr/share/zoneinfo/Europe/Moscow" "$rlRun_LOG"

        rlRun "timedatectl set-timezone 'America/Edmonton'"
        rlRun "date"
        rlRun "date | grep 'M[SD]T'"
        rlRun "timedatectl set-timezone UTC"
        rlRun "date | grep 'UTC'"
        rlRun "timedatectl set-timezone $TZ_ORIG"
    rlPhaseEnd

    rlPhaseStartTest "Timezones count"
        count=`timedatectl list-timezones | wc -l`
        if [[ "$count" -ge "300" ]];then
            rlPass "count TZ = $count"
        else
            rlFail "only $count TZ"
        fi
    rlPhaseEnd

    if [ `uname -m` != s390x ] ; then # because: BZ#1261095
    rlPhaseStartTest 'wtf set-local-rtc'
        rlRun "timedatectl set-local-rtc 1"
        rlRun "timedatectl | grep 'RTC in local TZ.*yes'"
        rlRun "timedatectl | grep 'Warning'"
        rlRun "timedatectl set-local-rtc 0"
        rlRun "timedatectl | grep 'RTC in local TZ.*no'"
    rlPhaseEnd
    fi

    rlPhaseStartTest "timedatectl crashes under certain locales [BZ#1503942]"
        for locale in $(localectl --no-pager list-locales); do
            rlRun "LANG=$locale timedatectl"
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "timedatectl set-timezone $TZ_ORIG"
        rlRun "timedatectl set-ntp on"
        rlServiceRestore chronyd
        rlServiceRestore systemd-timedated
        rlFileRestore
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
        rlLog "date = `date`"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
