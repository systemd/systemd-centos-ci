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
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="systemd"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm $PACKAGE
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        rlRun "useradd foo"
        rlRun "groupadd bar" 0,9
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

    rlPhaseStartTest "RFE: option 'e' [BZ#1225739]"
        TMPFILES_CONF="$(mktemp /etc/tmpfiles.d/dir-age-XXX.conf)"
        TMPFILES_DIR="$(mktemp -d -u /tmpfiles-age-XXX)"

        # This shouldn't happen, but just in case
        if [[ -d $TMPFILES_DIR ]]; then
            rm -fr "$TMPFILES_DIR"
        fi

        rlRun "echo 'e $TMPFILES_DIR/ - - - 5s' > '$TMPFILES_CONF'"
        rlRun "TMPFILES_DIR=$TMPFILES_DIR"
        rlRun "test ! -d '$TMPFILES_DIR'"
        # Note: This will fail until BZ#1445732 is fixed
        rlRun "systemd-tmpfiles --create"
        rlRun "test ! -d '$TMPFILES_DIR'"
        rlRun "mkdir '$TMPFILES_DIR'"
        rlRun "touch '$TMPFILES_DIR/test'"
        rlRun "ls -l '$TMPFILES_DIR'"
        rlRun "sleep 6"
        rlRun "ls -l '$TMPFILES_DIR'"
        rlRun "systemd-tmpfiles --clean"
        rlRun "test ! -f  '$TMPFILES_DIR/test'"
        # Cleanup
        rlRun "rm -fv '$TMPFILES_CONF'"
        rlRun "rm -frv '$TMPFILES_DIR'"
    rlPhaseEnd

    rlPhaseStartTest "systemd-tmpfiles will not update existing journal files [BZ#1411199]"
        journalctl --header | grep "File Path" | grep -q "/var/log/journal"
        JCTL_EC=$?
        if [[ -d /var/log/journal && $JCTL_EC -eq 0 ]]; then
            rlLogInfo "[WARNING] Persistent journal is active"
            rlRun "journalctl --header"
            rlRun "ls -la /var/log"
            rlRun "rm -fr /var/log/journal"
            rlRun "systemctl restart systemd-journald.service"
        fi

        MACHINE_ID="$(cat /etc/machine-id)"
        JOURNAL_DIR="/var/log/journal"
        JOURNAL_SUBDIR="/var/log/journal/$MACHINE_ID"
        JOURNAL_FILE="$JOURNAL_SUBDIR/system.journal"
        JOURNAL_NOACL_FILE="$JOURNAL_SUBDIR/test.journal"

        if [[ -z $MACHINE_ID ]]; then
            rlFail "Couldn't get machine ID from /etc/machine-id"
        fi

        rlRun "rm -fr $JOURNAL_DIR"
        rlRun "mkdir -p $JOURNAL_SUBDIR"
        rlRun "touch $JOURNAL_FILE"
        rlRun "touch $JOURNAL_NOACL_FILE"
        rlRun "getfacl $JOURNAL_DIR"
        rlRun "getfacl $JOURNAL_SUBDIR"
        rlRun "getfacl $JOURNAL_FILE"

        rlLogInfo "Machine ID: $MACHINE_ID"
        rlRun "systemd-tmpfiles --create --prefix $JOURNAL_DIR"
        rlRun -s "getfacl $JOURNAL_FILE"
        rlAssertGrep " group: systemd-journal$" "$rlRun_LOG"
        rlAssertGrep "^group:adm:r--$" "$rlRun_LOG"
        rlAssertGrep "^group:wheel:r--$" "$rlRun_LOG"
        rlRun -s "getfacl -s $JOURNAL_NOACL_FILE"
        rlRun "[[ ! -s $rlRun_LOG ]]" 0 "$JOURNAL_NOACL_FILE should have no ACLs"
        rlRun -s "getfacl $JOURNAL_SUBDIR"
        rlAssertGrep "^group:adm:r-x$" "$rlRun_LOG"
        rlAssertGrep "^group:wheel:r-x$" "$rlRun_LOG"
        rlRun -s "getfacl $JOURNAL_DIR"
        rlAssertGrep "^default:group:adm:r-x$" "$rlRun_LOG"
        rlAssertGrep "^default:group:wheel:r-x$" "$rlRun_LOG"
        rlAssertGrep "^group:adm:r-x$" "$rlRun_LOG"
        rlAssertGrep "^group:wheel:r-x$" "$rlRun_LOG"

        rlRun "rm -fr $JOURNAL_DIR"
    rlPhaseEnd

    if rlIsRHEL 7; then
        PHASES="RW-ONLY ALL"
    else
        # Since systemd-237+ root-owned read-only files are removed by default
        # See: https://github.com/systemd/systemd/commit/a083b4875e8dec5ce5379d8bc437d750cd338c37
        PHASES="ALL"
    fi

    for phase in $PHASES; do
        rlPhaseStartTest "Introduce TMPFILES_AGE_ALL [BZ#1533638] - PHASE: $phase"
            # Setup
            TMPFILES_CONF="$(mktemp /etc/tmpfiles.d/TMPFS_AGE_ALL-XXX.conf)"
            TMPFILES_DIR="$(mktemp -d /tmpfiles-age_ALL-XXX)"
            rlRun "echo 'v $TMPFILES_DIR 1777 root root 5s' > '$TMPFILES_CONF'"
            rlRun "touch $TMPFILES_DIR/root-{rw,ro}"
            rlRun "chmod 600 $TMPFILES_DIR/root-rw"
            rlRun "chmod 400 $TMPFILES_DIR/root-ro"
            rlRun "ls -la $TMPFILES_DIR"

            # Test
            rlRun "sleep 6"
            if [[ $phase == "RW-ONLY" ]]; then
                # TMPFILES_AGE_ALL is unset, ignore read-only files
                rlRun "systemd-tmpfiles --clean --prefix $TMPFILES_DIR"
                rlRun "[ ! -f $TMPFILES_DIR/root-rw ]" 0 "RW file SHOULD NOT exist"
                rlRun "[ -f $TMPFILES_DIR/root-ro ]" 0 "RO file SHOULD exist"
            else
                # TMPFILES_AGE_ALL is set, delete everything
                rlRun "TMPFILES_AGE_ALL=1 systemd-tmpfiles --clean --prefix $TMPFILES_DIR"
                rlRun "[ ! -f $TMPFILES_DIR/root-rw ]" 0 "RW file SHOULD NOT exist"
                rlRun "[ ! -f $TMPFILES_DIR/root-ro ]" 0 "RO file SHOULD NOT exist"
            fi

            rlRun "ls -la $TMPFILES_DIR"

            # Cleanup
            rlRun "rm -frv $TMPFILES_DIR $TMPFILES_CONF"
        rlPhaseEnd
    done

    rlPhaseStartTest "tmpfiles: use safe_glob() [BZ#1436004]"
        TMPFILES_CONF="$(mktemp /etc/tmpfiles.d/recursiveXXX.conf)"
        TEMP_ROOT_DIR="$(mktemp -d)"
        TEMP_TEST_DIR="$TEMP_ROOT_DIR/test"
        DIR_TO_REMOVE="$TEMP_TEST_DIR/.dir1"
        DIR_TO_KEEP="$TEMP_TEST_DIR/dir2"
        FILE_TO_REMOVE="$TEMP_TEST_DIR/.file1"
        FILE_TO_KEEP="$TEMP_TEST_DIR/file2"

        # Setup
        echo "R $TEMP_TEST_DIR/.* - - - - -" > $TMPFILES_CONF
        rlRun "cat $TMPFILES_CONF"
        rlRun "mkdir $TEMP_TEST_DIR $DIR_TO_REMOVE $DIR_TO_KEEP"
        rlRun "touch $FILE_TO_REMOVE $FILE_TO_KEEP"
        rlRun "ls -laR $TEMP_ROOT_DIR"
        rlAssertExists "$DIR_TO_REMOVE"
        rlAssertExists "$DIR_TO_KEEP"
        rlAssertExists "$FILE_TO_REMOVE"
        rlAssertExists "$FILE_TO_KEEP"

        # Test
        rlRun "systemd-tmpfiles --remove --prefix $TEMP_TEST_DIR/"
        rlRun "ls -laR $TEMP_ROOT_DIR"
        rlAssertNotExists "$DIR_TO_REMOVE"
        rlAssertExists "$DIR_TO_KEEP"
        rlAssertNotExists "$FILE_TO_REMOVE"
        rlAssertExists "$FILE_TO_KEEP"
        rlAssertExists "$TEMP_TEST_DIR"

        # Cleanup
        rlRun "rm -frv $TEMP_ROOT_DIR $TMPFILES_CONF"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "userdel -r foo"
        rlRun "groupdel bar" 0,8
        rlRun "rm -r $TmpDir /etc/tmpfiles.d/hello*.conf" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
