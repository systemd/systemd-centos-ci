#!/bin/bash
# shellcheck disable=SC2181

# Note: this script MUST be self-contained - i.e. it MUST NOT source any
# external scripts as it is used as a bootstrap script, thus it's
# fetched and executed without rest of this repository
#
# Example usage in Jenkins
# #!/bin/sh
#
# set -e
#
# curl -q -o runner.sh https://../vagrant-make-cache.sh
# chmod +x runner.sh
# ./runner.sh
set -eu
set -o pipefail

at_exit() {
    # Correctly collect artifacts from all cron jobs and generate a nice
    # directory structure
    if find . -name "artifacts_*" | grep -q "."; then
        mkdir _artifacts_all
        mv artifacts_* _artifacts_all
        mv _artifacts_all artifacts_all

        utils/generate-index.sh artifacts_all index.html
    fi
}

trap at_exit EXIT

ARGS=()
EC=0

git clone https://github.com/systemd/systemd-centos-ci
cd systemd-centos-ci

set +e

(
    set -e
    echo "Updating the systemd Arch Linux image"

    # Generate a new image with '-new' suffix
    ./agent-control.py --version 8-stream --vagrant-sync Vagrantfile_archlinux_systemd ${ARGS:+"${ARGS[@]}"}
    # Check if it doesn't break anything
    ./agent-control.py --version 8-stream --no-index --vagrant arch-new ${ARGS:+"${ARGS[@]}"}
    ./agent-control.py --version 8-stream --no-index --vagrant arch-sanitizers-clang-new ${ARGS:+"${ARGS[@]}"}
    ./agent-control.py --version 8-stream --no-index --vagrant arch-sanitizers-gcc-new ${ARGS:+"${ARGS[@]}"}
    # Overwrite the production image with the just tested one. Since the CentOS CI
    # artifact server supports only rsync protocol, use a single-purpose script
    # to do that
    utils/artifacts-copy-file.sh vagrant_boxes/archlinux_systemd-new vagrant_boxes/archlinux_systemd
)
[[ $? -ne 0 ]] && EC=$((EC + 1))

(
    set -e
    echo "Updating the systemd/selinux Fedora Rawhide image"

    # Generate a new image with '-new' suffix
    ./agent-control.py --version 8-stream --vagrant-sync Vagrantfile_rawhide_selinux ${ARGS:+"${ARGS[@]}"}
    # Overwrite the production image with the just tested one. Since the CentOS CI
    # artifact server supports only rsync protocol, use a single-purpose script
    # to do that
    utils/artifacts-copy-file.sh vagrant_boxes/rawhide_selinux-new vagrant_boxes/rawhide_selinux
)
[[ $? -ne 0 ]] && EC=$((EC + 1))

exit $EC
