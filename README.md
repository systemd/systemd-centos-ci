# About

This project contains code to build, install and test [systemd](https://github.com/systemd/systemd/)
on test machines provisioned from a pool provided by the [CentOS CI](https://ci.centos.org/) project,
using their [Duffy](https://wiki.centos.org/QaWiki/CI/Duffy) API.

# Setup

The code in this repository is used from two sides; the slave control host (named `slave01` in the CentOS CI environment),
and on the provisioned machines themselves.

On the slave control host, the entry point for running new tests is called `slave-control.py`. This script uses
[Duffy](https://wiki.centos.org/QaWiki/CI/Duffy) to provision new machines, and then uses SSH to log into them and run
scripts from the `slave/` subdirectory.

# Duffy

Quoting their [Wiki](https://wiki.centos.org/QaWiki/CI/Duffy),

> Duffy is the middle layer running ci.centos.org that manages the provisioning, maintenance and teardown / rebuild of the Nodes (physical hardware for now, VMs coming soon) that are used to run the tests in the CI Cluster.

This project contains code to provision a new machine from the pool, and to either release one specific one or all of them.

See below for the usage of this tool.

# Usage

The only script end users should be accessing is `slave-control.py` on the `slave01` host.

```
$ ./slave-control.py --help
usage: slave-control.py [-h] [--ver VER] [--arch ARCH] [--host HOST] [--pr PR]
                        [--keep] [--kill-host KILL_HOST] [--kill-all-hosts]
                        [--debug]

optional arguments:
  -h, --help            show this help message and exit
  --ver VER             CentOS version
  --arch ARCH           Architecture
  --host HOST           Use an already provisioned build host
  --pr PR               Pull request ID
  --keep                Do not kill provisioned build host
  --kill-host KILL_HOST
                        Mark a provisioned host as done and bail out
  --kill-all-hosts      Mark all provisioned hosts as done and bail out
  --debug               Enable debug output
```

When called without parameters, it will build the current systemd master branch.
The `--keep` option is helpful during development.

# Jenkins glue

This script and the Jenkins execution environment are glued together with the following trivial shell script:

```sh
#!/bin/sh

ARGS=

if [ "$CHANGE_ID" ]; then
	ARGS="$ARGS --pr $CHANGE_ID "
fi

cd /home/systemd/systemd-centos-ci

./slave-control.py $ARGS
```

# Manually running the tests
```sh
# bootstrap
yum install -q -y git
git clone https://github.com/systemd/systemd-centos-ci
systemd-centos-ci/slave/bootstrap.sh pr:pr-number # for example pr:4456
systemctl reboot

# testsuite
systemd-centos-ci/slave/testsuite.sh
systemctl reboot

# system-tests
cd systemd-centos-ci/slave; ./system-tests.sh
systemctl poweroff
```
