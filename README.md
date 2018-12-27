# About

This project contains code to build, install and test [systemd](https://github.com/systemd/systemd/)
on test machines provisioned from a pool provided by the [CentOS CI](https://ci.centos.org/) project,
using their [Duffy](https://wiki.centos.org/QaWiki/CI/Duffy) API.

# Setup

The code in this repository is used from two sides; the agent control host (named `slave01` in the CentOS CI environment),
and on the provisioned machines themselves.

On the agent control host, the entry point for running new tests is called `agent-control.py`. This script uses
[Duffy](https://wiki.centos.org/QaWiki/CI/Duffy) to provision new machines, and then uses SSH to log into them and run
scripts from the `agent/` subdirectory.

# Duffy

Quoting their [Wiki](https://wiki.centos.org/QaWiki/CI/Duffy),

> Duffy is the middle layer running ci.centos.org that manages the provisioning, maintenance and teardown / rebuild of the Nodes (physical hardware for now, VMs coming soon) that are used to run the tests in the CI Cluster.

This project contains code to provision a new machine from the pool, and to either release one specific one or all of them.

See below for the usage of this tool.

# Usage

The only script end users should be accessing is `agent-control.py` on the `slave01` host.

```
$ ./agent-control.py --help
usage: agent-control.py [-h] [--arch ARCH] [--branch BRANCH] [--ci-pr CI_PR]
                        [--free-all-nodes] [--free-session FREE_SESSION]
                        [--keep] [--list-nodes] [--pr PR] [--version VERSION]

optional arguments:
  -h, --help            show this help message and exit
  --arch ARCH           Architecture
  --branch BRANCH       Commit/tag/branch to checkout
  --ci-pr CI_PR         Pull request ID to check out (systemd-centos-ci
                        repository)
  --free-all-nodes      Free all currently provisioned nodes
  --free-session FREE_SESSION
                        Return nodes from a session back to the pool
  --keep                Do not kill provisioned build host
  --list-nodes          List currectly allocated nodes
  --pr PR               Pull request ID to check out (systemd repository)
  --version VERSION     CentOS version

```

When called without parameters, it will build the current systemd master branch.
The `--keep` option is helpful during development.

# Jenkins glue

The `agent-control.py` script and Jenkins are *glued* together using a simple shell script. See the [Jenkins Configuration](https://github.com/systemd/systemd-centos-ci/wiki/Jenkins-Configuration) wiki page for more information.

# Manually running the tests
```sh
# bootstrap
yum install -q -y git
git clone https://github.com/systemd/systemd-centos-ci
systemd-centos-ci/agent/bootstrap.sh pr:pr-number # for example pr:4456
systemctl reboot

# testsuite
systemd-centos-ci/agent/testsuite.sh
systemctl reboot

systemctl poweroff
```
