# systemd CentOS CI debugging

If the systemd CentOS CI job is failing for your systemd PR, it may become
difficult to debug the root cause without proper logs, in some cases.
To make this somewhat easier without creating a separate PR in the systemd
CentOS CI repo and then pointing it to your systemd PR, you can make use of so
called *pre* and *post* tasks for each CI phase.

For the standard CentOS CI runs (i.e. the **CentOS 7 job**) this means you have
pre/post tasks for the *bootstrap* and *testsuite* phase. All these task scripts
have to exist in the root of the systemd repository to be taken into consideration.

- `.centosci-pre-bootstrap`
  executed right after the systemd repository is cloned and checked out into
  the respective PR branch; can be used to tweak the systemd compilation by
  adding additional meson arguments via `MESON_ARGS` variable

- `.centosci-post-bootstrap`
  executed right before systemd reboot, i.e. after everything is compiled and
  installed; can be used to tweak kernel arguments and other configuration

- `.centosci-pre-testsuite`
  executed after installing test dependencies and before running any tests

- `.centosci-post-testsuite`
  executed after running all tests

TBD
