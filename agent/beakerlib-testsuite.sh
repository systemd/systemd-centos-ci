#!/usr/bin/sh

SCRIPT_PATH="$(dirname $0)"
. "$SCRIPT_PATH/common.sh" "beakerlib-testsuite-logs" || exit 1

set -e
cd "$SCRIPT_PATH"

# Prepare environment
test -e beakerlib && rm -fr beakerlib
git clone https://github.com/beakerlib/beakerlib.git
make --quiet -C beakerlib
make --quiet -C beakerlib install

# WORKAROUND: Replace all rlIsRHEL calls with rlIsCentOS
echo 'rlIsRHEL() { rlIsCentOS "$@"; }' >> /usr/share/beakerlib/testing.sh

# Workaround for obsolete rhts-environment.sh
touch /usr/bin/rhts-environment.sh

# Append 'rlGetTestState' to each test, so it returns a correct exit code
while read file; do
    if ! grep -Pzq "rlGetTestState[[:space:]]*\z" "$file"; then
        echo -ne "\nrlGetTestState\n" >> "$file"
    fi
done <<< "$(find systemd/ -type f -name "runtest.sh")"

set +e

# Run the testsuite
for t in $(find systemd/Sanity -mindepth 1 -maxdepth 1 -type d); do
    pushd $t >/dev/null

    # Install test dependencies
    if [ -f Makefile ]; then
        DEPS="$(awk '
            match($0, /\"Requires:[[:space:]]*(.*)\"/, m) {
                print m[1];
            }' Makefile)"
        if [ ! -z "$DEPS" ]; then
            exectask "$t - dependencies" "${t##*/}-deps.log" "yum -y -q install $DEPS"
        fi
    fi

    # Execute the test
    exectask "$t" "${t##*/}.log" "./runtest.sh"

    popd >/dev/null
done

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"
echo
echo "FAILED TASKS:"
echo "-------------"
for task in "${FAILED_LIST[@]}"; do
    echo  "$task"
done

exit $FAILED
