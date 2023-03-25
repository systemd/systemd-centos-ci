#!/bin/env python3.9
# pylint: disable=line-too-long,invalid-name,too-many-branches,too-many-statements,too-many-arguments,too-many-instance-attributes
# pylint: disable=missing-function-docstring,missing-class-docstring,missing-module-docstring

import argparse
import logging
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

from duffy.client import DuffyClient
from duffy.client.main import DuffyAPIErrorModel
from httpx import HTTPStatusError, TimeoutException

API_BASE = "https://duffy.ci.centos.org/api/v1"
GITHUB_BASE = "https://github.com/systemd/"
GITHUB_CI_REPO = "systemd-centos-ci"


class AgentControl():
    def __init__(self, artifacts_storage=None):
        self.artifacts_storage = artifacts_storage
        self.interactive = False
        self.keep_node = False
        self._node_hostname = None
        self._session_id = None
        self._reboot_count = 0

        # Load Duffy key
        self.duffy_key = os.environ.get("CICO_API_KEY")
        self.coveralls_token = os.environ.get("COVERALLS_REPO_TOKEN")

        if not self.duffy_key:
            logging.fatal("Invalid Duffy key")
            sys.exit(1)

        self._client = DuffyClient(API_BASE, "systemd", self.duffy_key)

    def __del__(self):
        if not self._session_id:
            return

        # Deallocate the allocated node on script exit, if not requested otherwise
        if not self.keep_node:
            self.free_session()
        else:
            logging.info("Not returning the node %s back to the pool", self.node)

    @property
    def node(self):
        return self._node_hostname

    def allocate_node(self, pool):
        result = None
        payload = {
            "pool"     : pool,
            "quantity" : 1,
        }

        logging.info("Attempting to allocate a node from pool %s", pool)

        # Wait up to 2 hours with a try every 5 seconds
        wait_delay = 5
        tries = int(7200 / wait_delay)
        for _try in range(1, tries):
            error = None

            try:
                result = self._client.request_session([payload])
            except HTTPStatusError as e:
                error = f"Error response {e.response.status_code} while requesting {e.request.url!r}."
            except TimeoutException as e:
                error = f"Timeout while requesting {e.request.url!r}"

            if isinstance(result, DuffyAPIErrorModel):
                error = result.error

            if error is not None:
                # Print the error only every minute to not unnecessarily spam the console
                if _try == 1 or _try % 12 == 0:
                    logging.error("[Try %d/%d] Received an API error from the server: %s", _try, tries, error)

                time.sleep(wait_delay)
            else:
                break

        self._session_id = result.session.id
        self._node_hostname = result.session.nodes[0].hostname
        assert self.node, "Can't continue without a valid node"
        logging.info("Allocated node %s with session id %s", self.node, self._session_id)

        logging.info("Checking if node %s is reachable over ssh", self.node)
        reachable = False
        for _ in range(10):
            if self.execute_remote_command("true", ignore_rc=True) == 0:
                reachable = True
                break

            time.sleep(5)

        if not reachable:
            raise RuntimeError(f"Node {self.node} doesn't appear to be reachable over ssh")

    def execute_local_command(self, command):
        """Execute a command on the local machine

        Params:
        -------
        command : list of strings
            The command to execute; must be in a format expected by subprocess.Popen,
            i.e. list of tokens (strings)

        Returns:
        --------
        Exit code of the command
        """
        logging.info("Executing a LOCAL command: %s", " ".join(command))

        # pylint: disable=R1732
        proc = subprocess.Popen(command, stdout=None, stderr=None, shell=False)

        return proc.wait()

    def execute_remote_command(self, command, expected_rc=0, artifacts_dir=None, ignore_rc=False):
        """Execute a command on a remote host

        Technically the function wraps the command in an ssh command and executes
        it locally

        Params:
        -------
        command : str
            Command to execute on the remote host
        expected_rc : int (default: 0)
            Expected return code
        artifacts_dir : str (default: None)
            If not None and `self.artifacts_storage` is set, all files from the
            `artifacts_dir` directory on the remote host will be downloaded into
            the local `self.artifacts_storage` directory after the command is
            finished
        ignore_rc : bool (default: False)
            If True, the `execute_remote_command` throws an exception if the
            remote command fails

        Returns:
        --------
        Return code of the remote command

        Throws:
        -------
        An exception if the `ignore_rc` is False and the return code != `expected_rc`
        """
        assert self.node, "Can't continue without a valid node"

        timeout = False

        command_wrapper = [
            "/usr/bin/ssh", "-t",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=180",
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=30",
            "-l", "root",
            self.node, command
        ]

        logging.info("Executing a REMOTE command on node '%s': %s", self.node, command)
        try:
            rc = self.execute_local_command(command_wrapper)
        except AlarmException:
            # Delay the timeout exception, so we can fetch artifacts first
            timeout = True

        # Fetch artifacts if both remote and local dirs are set
        if artifacts_dir is not None and self.artifacts_storage is not None:
            arc = self.fetch_artifacts(artifacts_dir, self.artifacts_storage)
            if arc != 0:
                logging.warning("Fetching artifacts failed")

        if timeout:
            raise AlarmException()

        if not ignore_rc and rc != expected_rc:
            raise RuntimeError("Remote command exited with an unexpected return code "
                               f"(got: {rc}, expected: {expected_rc}), bailing out")
        return rc

    def fetch_artifacts(self, remote_dir, local_dir):
        """Fetch artifacts from remote host to a local directory

        Params:
        -------
        remote_dir : str
            Path of a remote (source) directory
        local_dir : str
            Path of a local (target) directory

        Returns:
        --------
        Return code of the underlying `scp` command
        """
        assert self.node, "Can't continue without a valid node"

        command = [
            "/usr/bin/scp", "-r",
            "-o UserKnownHostsFile=/dev/null",
            "-o StrictHostKeyChecking=no",
            f"root@{self.node}:{remote_dir}",
            local_dir
        ]

        logging.info("Fetching artifacts from node %s: (remote: %s, local: %s)",
                     self.node, remote_dir, local_dir)

        return self.execute_local_command(command)

    def free_session(self):
        if not self._session_id:
            return

        # Try a bit harder when retiring the session, since the API might return an error
        # when attempting to do so, leaving orphaned sessions laying around taking
        # precious resources
        for i in range(10):
            logging.info("Freeing session %s (with node %s) [try %d/10]", self._session_id, self.node, i)

            # pylint: disable=W0703
            try:
                result = self._client.retire_session(self._session_id)
                if isinstance(result, DuffyAPIErrorModel):
                    # A particularly ugly workaround for an issue in Duffy where a session
                    # might not get released even after a successful API call. Let's make
                    # sure the session is released by making multiple calls until the API
                    # returns an error that the session is already released.
                    # See: https://github.com/CentOS/duffy/issues/558
                    if re.search(r"session \d+ is retired", result.error.detail):
                        logging.info("Session %s was successfully freed", self._session_id)
                        break

                    logging.debug("Received an API error from the server: %s", result.error)
            except Exception:
                logging.debug("Got an exception when trying to free a session, ignoring...", exc_info=True)

            time.sleep(.5)

        self._session_id = None
        self._node_hostname = None

    def reboot_node(self):
        """Reboot the node

        Throws:
        -------
        An exception if the waiting timeout is reached
        """
        assert self.node, "Can't continue without a valid node"

        logging.info("Rebooting node %s", self.node)
        self.execute_remote_command(
                "systemd-analyze set-log-level debug; systemd-analyze set-log-target console; systemctl reboot",
                255,
                ignore_rc=True)
        time.sleep(30)

        self.wait_for_node(10)

        # Give the node time to finish the booting process
        time.sleep(30)

    def wait_for_node(self, attempts):
        assert self.node, "Can't continue without a valid node"

        ping_command = ["/usr/bin/ping", "-q", "-c", "1", "-W", "10", self.node]
        for i in range(attempts):
            logging.info("Checking if the node %s is alive (try #%d)", self.node, i)
            rc = self.execute_local_command(ping_command)
            if rc == 0:
                break
            time.sleep(15)

        if rc != 0:
            raise RuntimeError("Timeout reached when waiting for node to become online")

        logging.info("Node %s appears reachable again", self.node)

    def upload_file(self, local_source, remote_target):
        """Upload a file (or a directory) to a remote host

        Params:
        -------
        local_source : str
            Path of a local (local) directory
        remote_target : str
            Path of a remote (target) directory

        Returns:
        --------
        Return code of the underlying `scp` command
        """
        assert self.node, "Can't continue without a valid node"

        command = [
            "/usr/bin/scp", "-r",
            "-o UserKnownHostsFile=/dev/null",
            "-o StrictHostKeyChecking=no",
            local_source,
            f"root@{self.node}:{remote_target}"
        ]

        logging.info("Uploading file %s to node %s as %s", local_source, self.node, remote_target)

        if self.execute_local_command(command) != 0:
            raise RuntimeError(f"Failed to upload file {local_source} to {self.node}")

class SignalException(Exception):
    pass

class AlarmException(Exception):
    pass

def handle_signal(signum, _frame):
    """Signal handler"""
    print(f"handle_signal: got signal {signum}")

    if signum == signal.SIGALRM:
        raise AlarmException()

    # Raise the exception only for the first signal we handle, to avoid raising
    # exceptions in the exception handler
    if not hasattr(handle_signal, "handled"):
        handle_signal.handled = True
        raise SignalException()

def main():
    # Setup logging
    logging.basicConfig(level=logging.INFO,
            format="%(asctime)-14s [%(module)s/%(funcName)s] %(levelname)s: %(message)s")

    ac = AgentControl()

    # Parse command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-args", metavar="ARGUMENTS", type=str, default="",
            help="Additional optional arguments passed to the --bootstrap-script")
    parser.add_argument("--bootstrap-script", metavar="SCRIPT", type=str, default="bootstrap.sh",
            help="Script which prepares the baremetal machine")
    parser.add_argument("--branch",
            help="Commit/tag/branch to checkout")
    parser.add_argument("--ci-pr", metavar="PR",
            help="Pull request ID to check out (systemd-centos-ci repository)")
    parser.add_argument("--kdump-collect", action="store_const", const=True,
            help="Attempt to collect kernel dumps generated by kdump")
    parser.add_argument("--keep", action="store_const", const=True,
            help="Do not kill provisioned build host")
    parser.add_argument("--no-index", action="store_const", const=True,
            help="Don't generate the artifact HTML page")
    parser.add_argument("--pr",
            help="Pull request ID to check out (systemd repository)")
    parser.add_argument("--pool", metavar="POOL_NAME",
            help="Name of the machine pool to allocate a machine from")
    parser.add_argument("--skip-reboot", action="store_const", const=True,
            help="Skip reboot between bootstrap and test phases (on baremetal machines)")
    parser.add_argument("--testsuite-script", metavar="SCRIPT", type=str, default="testsuite.sh",
            help="Script which runs tests on the bootstrapped machine")
    parser.add_argument("--timeout", metavar="MINUTES", type=int, default=0,
            help="Set a timeout for the test run (in minutes)")
    parser.add_argument("--vagrant", metavar="DISTRO_TAG", type=str, default="",
            help="Run testing in Vagrant VMs on a distro specified by given distro tag")
    parser.add_argument("--vagrant-sync", metavar="VAGRANTFILE", type=str, default="",
            help="Run a script which updates and rebuilds Vagrant images used by systemd CentOS CI")
    args = parser.parse_args()
    logging.info("%s", args)

    ac.keep_node = args.keep

    artifacts_dir = None
    rc = 0

    # pylint: disable=W0703
    try:
        # Workaround for Jenkins, which sends SIGTERM/SIGHUP
        for s in [signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGALRM]:
            signal.signal(s, handle_signal)

        ac.allocate_node(args.pool)

        if args.timeout > 0:
            logging.info("Setting timeout to %d minutes", args.timeout * 60)
            signal.alarm(args.timeout * 60)

        # Figure out a systemd branch to compile
        if args.pr:
            remote_ref = f"pr:{args.pr}"
        elif args.branch:
            remote_ref = args.branch
        else:
            remote_ref = ""

        # Setup artifacts storage
        artifacts_dir = tempfile.mkdtemp(prefix="artifacts_", dir=".")
        ac.artifacts_storage = artifacts_dir

        if not "centos-7-" in args.pool:
            # Note: re-execute the user session, as the package update triggered by cloud-init
            # might have pulled a newer systemd package with some incompatible changes
            # for the user sessions.
            # See: https://pagure.io/centos-infra/issue/865#comment-810347
            logging.info("Wait until the machine is fully initialized")
            dnf_wait = "bash -c 'while pgrep -a dnf; do sleep 1; done'"
            ac.execute_remote_command(f"systemd-run --wait -p Wants=cloud-init.target -p After=cloud-init.target -- {dnf_wait} && systemctl --user daemon-reexec")

        # Let's differentiate between CentOS <= 7 (yum) and CentOS >= 8 (dnf)
        pkg_man = "yum" if "centos-7-" in args.pool else "dnf"
        # Clean dnf/yum caches to drop stale metadata and prevent unexpected
        # installation fails before installing core dependencies
        dep_cmd = f"{pkg_man} clean all && {pkg_man} makecache && {pkg_man} -y install bash git rsync"

        # Actual testing process
        logging.info("PHASE 1: Setting up basic dependencies to configure CI repository")
        command = f"{dep_cmd} && rm -fr {GITHUB_CI_REPO} && git clone {GITHUB_BASE}{GITHUB_CI_REPO}"
        ac.execute_remote_command(command)

        if args.ci_pr:
            logging.info("PHASE 1.5: Using a custom CI repository ref (PR#%s)", args.ci_pr)
            command = f"cd {GITHUB_CI_REPO} && git fetch -fu origin 'refs/pull/{args.ci_pr}/merge:pr' && git checkout pr"
            ac.execute_remote_command(command)

        if args.vagrant_sync:
            logging.info("PHASE 2: update & rebuild Vagrant images used by systemd CentOS CI")
            # We need the Duffy SSH key to be able to upload to the CentOS CI artifact server
            if os.path.isfile("/duffy-ssh-key/ssh-privatekey"):
                ac.upload_file("/duffy-ssh-key/ssh-privatekey", "/root/.ssh/duffy.key")
            else:
                ac.upload_file(os.path.expanduser("~/.ssh/id_rsa"), "/root/.ssh/duffy.key")

            ac.execute_remote_command("chmod 0600 /root/.ssh/duffy.key")

            command = f"{GITHUB_CI_REPO}/vagrant/vagrant-make-cache.sh '{args.vagrant_sync}'"
            ac.execute_remote_command(command)
        elif args.vagrant:
            # If the Coveralls token is set, upload it to the node, so it can
            # be consumed by relevant tools
            if ac.coveralls_token:
                with tempfile.NamedTemporaryFile(mode="w") as token_file:
                    token_file.write(ac.coveralls_token)
                    token_file.flush()
                    ac.upload_file(token_file.name, "/.coveralls.token")

            # Setup Vagrant and run the tests inside VM
            logging.info("PHASE 2: Run tests in Vagrant VMs")
            command = f"{GITHUB_CI_REPO}/vagrant/vagrant-ci-wrapper.sh -d '{args.vagrant}' -r '{remote_ref}' {args.bootstrap_args}"
            ac.execute_remote_command(command, artifacts_dir="~/vagrant-logs*")
        else:
            # Run tests directly on the provisioned machine
            logging.info("PHASE 2: Bootstrap (ref: %s)", remote_ref)
            command = f"{GITHUB_CI_REPO}/agent/{args.bootstrap_script} -r '{remote_ref}' {args.bootstrap_args}"
            ac.execute_remote_command(command, artifacts_dir="~/bootstrap-logs*")

            if not args.skip_reboot:
                ac.reboot_node()

            logging.info("PHASE 3: Upstream testsuite")
            command = f"{GITHUB_CI_REPO}/agent/{args.testsuite_script}"
            ac.execute_remote_command(command, artifacts_dir="~/testsuite-logs*")

    except SignalException:
        if not ac.keep_node:
            ac.free_session()

    except Exception as e:
        if ac.node and args.kdump_collect:
            logging.info("Trying to collect kernel dumps from %s:/var/crash", ac.node)
            # Wait a bit for the reboot to kick in in case we got a kernel panic
            time.sleep(10)

            try:
                ac.wait_for_node(10)

                if ac.fetch_artifacts("/var/crash", os.path.join(artifacts_dir, "kdumps")) != 0:
                    logging.warning("Failed to collect kernel dumps from %s", ac.node)
            except Exception:
                # Fetching the kdumps is a best-effort thing, there's not much
                # we can do if the machine is FUBAR
                pass

        if isinstance(e, AlarmException):
            logging.error("Execution failed: timeout reached")
            rc = 124
        else:
            logging.exception("Execution failed")
            rc = 1

    finally:
        if os.path.isfile("utils/generate-index.sh") and artifacts_dir and not args.no_index:
            # Try to generate a simple HTML index with results
            logging.info("Attempting to create an HTML index page")
            command = ["utils/generate-index.sh", artifacts_dir, "index.html"]
            ac.execute_local_command(command)

    return rc

if __name__ == "__main__":
    sys.exit(main())
