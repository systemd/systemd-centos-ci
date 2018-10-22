#!/usr/bin/sh

set -e

# Prepare environment
git clone https://github.com/beakerlib/beakerlib.git
make -C beakerlib
make -C beakerlib install

# WORKAROUND: Replace all rlIsRHEL calls with rlIsCentos
echo 'rlIsRHEL() { rlIsCentOS "$@"; }' >> /usr/share/beakerlib/testing.sh

# Workaround for obsolete rhts-environment.sh
touch /usr/bin/rhts-environment.sh

# Append 'rlGetTestState' to each test, so it returns a correct exit code
while read file; do
    if ! grep -Pzq "rlGetTestState[[:space:]]*\z" "$file"; then
        echo -ne "\nrlGetTestState\n" >> "$file"
    fi
done <<< "$(find systemd/ -type f -name "runtest.sh")"

set +x

declare -i EC=0

# Run testsuite
for t in $(find systemd/Sanity -mindepth 1 -maxdepth 1 -type d); do
    pushd $t

    # Install test dependencies
    if [ -f Makefile ]; then
        DEPS="$(awk '
            match($0, /\"Requires:[[:space:]]*(.*)\"/, m) {
                print m[1];
            }' Makefile)"
        if [ ! -z "$DEPS" ]; then
            yum -y -q install $DEPS
        fi
    fi

    # Execute the test
    ./runtest.sh
    if [ $? -ne 0 ]; then
        EC=1
    fi

    popd
done

exit $EC
