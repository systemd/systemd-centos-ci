# systemd CentOS CI under Vagrant

As the *standard* CentOS CI tests systemd on CentOS 7, which is quite old (and allows
us to test compatibility with older kernels), we need some way to do the opposite - i.e.
test systemd with the newest packages. To achieve this, we use
[Vagrant](https://www.vagrantup.com/) along with [vagrant-libvirt](https://github.com/vagrant-libvirt/vagrant-libvirt)
plugin to *easily* deploy libvirt VMs (with KVM acceleration) and run tests
on [Arch Linux](https://www.archlinux.org/).

The, so called, *pipeline* consists of following steps:

1. `vagrant-ci-wrapper.sh`

    This script is executed by our [Jenkins](https://jenkins.io/) job, and basically
    prepares a local copy of the systemd [repository](https://github.com/systemd/systemd),
    checks out a correct branch and executes the build script (see below) for
    each distribution we have configured for Vagrant.

    As Vagrant is not present in CentOS repositories, `vagrant-ci-wrapper.sh` also
    makes use of `vagrant-setup.sh`, which downloads & installs the [upstream RPM](https://www.vagrantup.com/downloads.html)
    provided by Vagrant, install libvirt & other dependencies, and compiles & installs
    the vagrant-libvirt plugin.

2. `vagrant-build.sh`

    The Vagrant VM management is done by `vagrant-build.sh`, which locates the correct
    Vagrantfile for provided distro tag, configures the environment appropriately,
    spins up the VM, executes a test script according to the environment, and cleans up
    the VM afterwards.

    The compilation itself (along with installation of build & test dependencies)
    is done during the VM provision phase using a provision script in a respective
    Vagrantfile, as these steps are distro-specific and the CI scripts should be
    (for the most part) distro-agnostic.

    So far there are two tests scripts, for testing with and without sanitizers:

    * `vagrant-test.sh`

        Test systemd without sanitizers - do a reboot after installation and run unit tests,
        fuzzers, and integration tests

    * `vagrant-test-sanitizers.sh`

        Test systemd with sanitizers ([Address Sanitizer](https://github.com/google/sanitizers/wiki/AddressSanitizer) and
        [Undefined Behavior Sanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html)).
        As running under sanitizers has a huge performance impact, we skip machine reboot,
        as this usually kills the machine or causes boot to timeout, and run only unit tests


As we run the CI usually dozens of times per day, we'd have to update the packages
in images each time (not counting the installation of build & test dependencies).
To avoid this, and boost the runtime of the CI, we periodically execute `vagrant-make-cache.sh`
which does these steps once in a few days, allowing us to reuse already up-to-date images
in our CI runs without wasting time.
