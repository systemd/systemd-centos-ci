#!/bin/bash

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../upstream-vagrant-rawhide-selinux.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

ARGS=()

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

./agent-control.py --version 8 --vagrant rawhide-selinux ${ARGS:+"${ARGS[@]}"}
