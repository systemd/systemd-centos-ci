# About

This project contains code to build, install and test [systemd](https://github.com/systemd/systemd/)
on test machines provisioned from a pool provided by the [CentOS CI](https://wiki.centos.org/QaWiki/CI) project,
using their [Duffy](https://wiki.centos.org/QaWiki/CI/Duffy) API.

As of right now these scripts provide CI for [upstream](https://github.com/systemd/systemd)
on CentOS Stream 8 and Arch Linux, and for [RHEL downstream](https://github.com/redhat-plumbers)
on supported CentOS releases.

# Structure

The main entrypoint is the `agent-control.py` script, which is responsible for
getting a provisioned machine from the Duffy pool, run the respective CI scripts,
and gather results. To make this work with GitHub pull requests, the `jenkins/`
directory contains *glue* scripts which generate a correct set of arguments for
the `agent-control.py` script for each PR.

The CI scripts are scattered among several directories:

* `agent/`

    Bootstrap and test runner scripts used to run tests directly on the provisioned
    machines (i.e. for running tests on CentOS (Stream) X).

* `common/`

    Various *libraries* and support functions used by other scripts.

* `jenkins/`

    Scripts which are responsible for feeding `agent-control.py` correct parameters
    based on data from the Jenkins GitHub plugin.

    These scripts are used directly in the *Execute shell* step of each Jenkins job
    in following manner:

```bash
#!/bin/sh

set -e

curl -q -o runner.sh https://raw.githubusercontent.com/systemd/systemd-centos-ci/main/jenkins/runners/upstream-centos8.sh
chmod +x runner.sh
./runner.sh
```

* `utils/`

    Various utility scripts used by the pipeline.

* `vagrant/`

    Setup, build, and test runner scripts to test systemd on other distributions than CentOS
    using Vagrant VMs.

# Pipelines

Jenkins instance: https://jenkins-systemd.apps.ocp.cloud.ci.centos.org/

## Upstream on CentOS Stream 8 (upstream-centos8)

```
agent-control.py +-> agent/bootstrap.sh +-> reboot +-> agent/testsuite.sh
```

To test compatibility of the upstream systemd with older kernels, this job builds, installs, and
tests an upstream PR on a CentOS Stream 8 baremetal machine.

To achieve this, `agent-control.py` runs `agent/bootstrap.sh` script to fetch, build, and install
the respective PR (along with other necessary dependencies), reboots the machine, and executes
`agent/testsuite.sh` to to the actual testing.

## Downstream (RHEL) on CentOS 7 and CentOS Stream 8/9 (rhelX-centosX)

The same worklflow as above, but for systemd in RHEL:

  * [RHEL 7/CentOS 7](https://github.com/redhat-plumbers/systemd-rhel7)

```
agent-control.py +-> agent/bootstrap-rhel7.sh +-> reboot +-> agent/testsuite-rhel7.sh
```

  * [RHEL 8/CentOS Stream 8](https://github.com/redhat-plumbers/systemd-rhel8)

```
agent-control.py +-> agent/bootstrap-rhel8.sh +-> reboot +-> agent/testsuite-rhel8.sh
```

  * [RHEL 9/CentOS Stream 9](https://github.com/redhat-plumbers/systemd-rhel9)

```
agent-control.py +-> agent/bootstrap-rhel9.sh +-> reboot +-> agent/testsuite-rhel9.sh
```

## Upstream on Arch Linux using Vagrant (upstream-vagrant-archlinux)

To achieve the exact opposite of the testing on CentOS Stream 8, this pipeline check the compatibility
of systemd with the latest versions of kernel and other components. As the CentOS CI
pool provides only CentOS machines, this pipeline introduces an intermediary in form of
a [Vagrant](https://www.vagrantup.com) VM along with [vagrant-libvirt](https://github.com/vagrant-libvirt/vagrant-libvirt)
plugin to spin up a virtual machine in which we do the actual testing.

### Structure

Each VM consists of two images: the base image (Vagrant Box) and a runtime image.

Vagrant Box templates are stored under `vagrant/boxes/` and the images themselves
are rebuilt every few days by a separate job to keep the package set up-to-date,
but to not slow down the CI pipeline.

The templates for each VM used in the CI can be found in `vagrant/vagrantfiles/`.
As the majority of the current (single) Vagrantfile remains identical across several
instances of the VMs except for the bootstrap phase, the bootstrap scripts were
separated into their own directory - `vagrant/bootstrap_scripts/` and the Vagrantfile
itself is now parametrized, to avoid code duplication.

The test scripts are in the `vagrant/test_scripts/` directory, and follow the
same naming convention as the bootstrap scripts above, except for being prefixed
with `test-`.

### Pipeline

```
agent-control.py +-> vagrant/vagrant-ci-wrapper.sh +-> vagrant/vagrant-build.sh +-> [reboot] +-> vagrant/test_scripts/test-<distro>-<type>.sh
                        +               ^                +                 ^
                        |               |                |                 |
                        v               +                v                 +
                     vagrant/vagrant-setup.sh          vagrant/vagrantfiles/Vagrantfile_<distro>
                                                         +                 ^
                                                         |                 |
                                                         v                 +
                                                       vagrant/bootstrap-scripts/<distro>-<type>.sh

```

The pipeline consists of several steps (scripts):

1. `vagrant/vagrant-ci-wrapper.sh`

    This script acts as a bootstrap where it checks out the systemd repository
    on a revision based on information passed down by the respective Jenkins
    glue script, configures the underlying system for Vagrant (by calling
    `vagrant/vagrant-setup.sh`) and the test suite, and starts the VM build process
    by executing `vagrant/vagrant-build.sh`

2. `vagrant/vagrant-build.sh`

    Builds a *runtime* VM image based on the base one (Vagrant Box). The Vagrantfile
    for each VM (`vagrant/vagrantfiles/`) can reference an external bootstrap script
    (`vagrant/bootstrap_scripts/`) making itself reusable for multiple different
    scenarios.

    When the VM is built, the local systemd repo is mounted into it over NFS
    and the bootstrap script is executed, which builds the checked out revision
    and makes other necessary changes to the VM itself.

    After this step the VM is rebooted (*reloaded* in the Vagrant terms) and the
    test runner script (`vagrant/test_scripts/*.sh`) is executed inside.

## Upstream on Arch Linux with sanitizers using Vagrant (upstream-vagrant-archlinux-sanitizers)

To tackle the question of security a little bit, this job does *almost* the same thing
as the one above, but here systemd is compiled with [Address Sanitizer](https://github.com/google/sanitizers/wiki/AddressSanitizer)
and [Undefined Behavior Sanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html). In this
case we skip the *reboot* step of the pipeline, since we don't install the compiled
systemd revision anyway.

## (Auxiliary) Rebuild the Vagrant images (vagrant-make-cache)

```
agent-control.py +-> vagrant/vagrant-make-cache.sh
```

To keep the images up-to-date but to not slow every CI pipeline down while doing so,
this job's sole purpose is to rebuild the base images (Vagrant Boxes) every few days
(based on Jenkins cron) and upload it to the artifacts server, where it can be
used by the respective Vagrantfile.

## (Auxiliary) Mirror the Copr repo with CentOS (Stream) dependencies (reposync)

```
utils/reposync.sh
```

We need a couple of newer dependencies for systemd on CentOS (Stream) to cover the most
recent features. For this we have a bunch of Copr repositories [0][1] with necessary packages.

[0] https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos8/ \
[1] https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-centos-ci-centos9/

However, we found out that the infrastructure Copr is running in is quite unreliable
so a fair share of our jobs was failing just because they couldn't install dependencies.
Having a local mirror in the CentOS CI infrastructure definitely helps in this case and
the purpose of this script is to update it every few hours (again, using Jenkins cron).

## (Auxiliary) CI for the CI repository (ci-build)

To make sure changes to this repository don't break the CI pipeline, this job
provides a way to run a specific revision of the CI scripts (from a PR) against
the main branch of the respective systemd repository.

As this requires twiddling around with various bits and knobs given which part
of the CI pipeline we want to test (instead of just running everything and pointlessly
waiting many hours until it finishes), the job configuration is stored in the Jenkins
job itself and thus requires access to the instance.

