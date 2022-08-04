#!/bin/env python3.8
# pylint: disable=line-too-long,invalid-name,too-many-branches,too-many-statements,too-many-arguments
# pylint: disable=missing-function-docstring,missing-class-docstring,missing-module-docstring

import argparse
import logging
import os
import signal
import subprocess
import sys
import tempfile
import time

from duffy.client import DuffyClient
from duffy.client.main import DuffyAPIErrorModel

API_BASE = "https://duffy.ci.centos.org/api/v1"
GITHUB_BASE = "https://github.com/systemd/"
GITHUB_CI_REPO = "systemd-centos-ci"


class AgentControl():
    def __init__(self, artifacts_storage=None):
        # Should probably use a setter/getter in the future
        self.artifacts_storage = artifacts_storage
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
        # Deallocate the allocated node on script exit, if not requested otherwise
        if not self.keep_node:
            self.free_session()

    def allocate_node(self, pool):
        result = None
        payload = {
            "pool"     : pool,
            "quantity" : 1,
        }

        logging.info("Attempting to allocate a node from pool %s", pool)

        # Wait up to an 1 hour with a try every 5 seconds
        wait_delay = 5
        tries = int(3600 / wait_delay)
        for _try in range(1, tries):
            result = self._client.request_session([payload])
            if isinstance(result, DuffyAPIErrorModel):
                # Print the error only every minute to not unnecessarily spam the console
                if _try % 12 == 0:
                    logging.error("[Try %d/%d] Received an API error from the server: %s", _try, tries, result.error)
                time.sleep(wait_delay)
            else:
                break

        self._session_id = result.session.id
        self._node_hostname = result.session.nodes[0].hostname
        logging.info("Allocated node %s with session id %s", self._node_hostname, self._session_id)

        return self._node_hostname

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

        proc = subprocess.Popen(command, stdout=None, stderr=None, shell=False, bufsize=1)
        proc.communicate()
        proc.wait()

        return proc.returncode

    def execute_remote_command(self, node, command, expected_rc=0, artifacts_dir=None, ignore_rc=False):
        """Execute a command on a remote host

        Technically the function wraps the command in an ssh command and executes
        it locally

        Params:
        -------
        node : str
            Hostname of the node
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
        command_wrapper = [
            "/usr/bin/ssh", "-t",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=180",
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=2",
            "-l", "root",
            node, command
        ]

        logging.info("Executing a REMOTE command on node '%s': %s", node, command)
        rc = self.execute_local_command(command_wrapper)

        # Fetch artifacts if both remote and local dirs are set
        if artifacts_dir is not None and self.artifacts_storage is not None:
            arc = self.fetch_artifacts(node, artifacts_dir, self.artifacts_storage)
            if arc != 0:
                logging.warning("Fetching artifacts failed")

        if not ignore_rc and rc != expected_rc:
            raise Exception("Remote command exited with an unexpected return code "
                            f"(got: {rc}, expected: {expected_rc}), bailing out")
        return rc

    def fetch_artifacts(self, node, remote_dir, local_dir):
        """Fetch artifacts from remote host to a local directory

        Params:
        -------
        node : str
            Hostname of the node
        remote_dir : str
            Path of a remote (source) directory
        local_dir : str
            Path of a local (target) directory

        Returns:
        --------
        Return code of the underlying `scp` command
        """
        command = [
            "/usr/bin/scp", "-r",
            "-o UserKnownHostsFile=/dev/null",
            "-o StrictHostKeyChecking=no",
            f"root@{node}:{remote_dir}",
            local_dir
        ]

        logging.info("Fetching artifacts from node %s: (remote: %s, local: %s)",
                     node, remote_dir, local_dir)

        return self.execute_local_command(command)

    def free_session(self):
        if not self._session_id:
            return

        logging.info("Freeing session %s (with node %s)", self._session_id, self._node_hostname)
        self._client.retire_session(self._session_id)
        # TODO: error handling?
        self._session_id = None

    def reboot_node(self, node):
        """Reboot a node

        Params:
        -------
        node : str
            Hostname of the node

        Throws:
        -------
        An exception if the waiting timeout is reached
        """
        logging.info("Rebooting node %s", node)
        self.execute_remote_command(
                node,
                "systemd-analyze set-log-level debug; systemd-analyze set-log-target console; systemctl reboot",
                255,
                ignore_rc=True)
        time.sleep(30)

        self.wait_for_node(node, 10)

        # Give the node time to finish the booting process
        time.sleep(30)

    def wait_for_node(self, node, attempts):
        ping_command = ["/usr/bin/ping", "-q", "-c", "1", "-W", "10", node]
        for i in range(attempts):
            logging.info("Checking if the node %s is alive (try #%d)", node, i)
            rc = self.execute_local_command(ping_command)
            if rc == 0:
                break
            time.sleep(15)

        if rc != 0:
            raise Exception("Timeout reached when waiting for node to become online")

        logging.info("Node %s appears reachable again", node)

    def upload_file(self, node, local_source, remote_target):
        """Upload a file (or a directory) to a remote host

        Params:
        -------
        node : str
            Hostname of the node
        local_source : str
            Path of a local (local) directory
        remote_target : str
            Path of a remote (target) directory

        Returns:
        --------
        Return code of the underlying `scp` command
        """
        command = [
            "/usr/bin/scp", "-r",
            "-o UserKnownHostsFile=/dev/null",
            "-o StrictHostKeyChecking=no",
            local_source,
            f"root@{node}:{remote_target}"
        ]

        logging.info("Uploading file %s to node %s as %s", local_source, node, remote_target)

        return self.execute_local_command(command)

class SignalException(Exception):
    pass

def handle_signal(signum, frame):
    """Signal handler"""
    print(f"handle_signal: got signal {signum}")
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
    parser.add_argument("--vagrant", metavar="DISTRO_TAG", type=str, default="",
            help="Run testing in Vagrant VMs on a distro specified by given distro tag")
    parser.add_argument("--vagrant-sync", metavar="VAGRANTFILE", type=str, default="",
            help="Run a script which updates and rebuilds Vagrant images used by systemd CentOS CI")
    args = parser.parse_args()
    logging.info("%s", args)

    ac.keep_node = args.keep

    artifacts_dir = None
    node = None
    rc = 0

    try:
        # Workaround for Jenkins, which sends SIGTERM/SIGHUP
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGHUP, handle_signal)

        node = ac.allocate_node(args.pool)

        if node is None:
            logging.critical("Can't continue without a valid node")
            return 1

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

        # Let's differentiate between CentOS <= 7 (yum) and CentOS >= 8 (dnf)
        pkg_man = "yum" if "centos-7-" in args.pool else "dnf"
        # Clean dnf/yum caches to drop stale metadata and prevent unexpected
        # installation fails before installing core dependencies
        dep_cmd = f"{pkg_man} clean all && {pkg_man} makecache && {pkg_man} -y install bash git rsync"

        # Actual testing process
        logging.info("PHASE 1: Setting up basic dependencies to configure CI repository")
        command = f"{dep_cmd} && rm -fr {GITHUB_CI_REPO} && git clone {GITHUB_BASE}{GITHUB_CI_REPO}"
        ac.execute_remote_command(node, command)

        if args.ci_pr:
            logging.info("PHASE 1.5: Using a custom CI repository ref (PR#%s)", args.ci_pr)
            command = f"cd {GITHUB_CI_REPO} && git fetch -fu origin 'refs/pull/{args.ci_pr}/merge:pr' && git checkout pr"
            ac.execute_remote_command(node, command)

        if args.vagrant_sync:
            logging.info("PHASE 2: update & rebuild Vagrant images used by systemd CentOS CI")
            # We need the Duffy key to be able to upload to the CentOS CI artifact server
            key_file = tempfile.NamedTemporaryFile(mode="w")
            key_file.write(ac.duffy_key)
            key_file.flush()
            ac.upload_file(node, key_file.name, "/duffy.key")
            key_file.close()

            command = f"{GITHUB_CI_REPO}/vagrant/vagrant-make-cache.sh '{args.vagrant_sync}'"
            ac.execute_remote_command(node, command)
        elif args.vagrant:
            # If the Coveralls token is set, upload it to the node, so it can
            # be consumed by relevant tools
            if ac.coveralls_token:
                token_file = tempfile.NamedTemporaryFile(mode="w")
                token_file.write(ac.coveralls_token)
                token_file.flush()
                ac.upload_file(node, token_file.name, "/.coveralls.token")
                token_file.close()

            # Setup Vagrant and run the tests inside VM
            logging.info("PHASE 2: Run tests in Vagrant VMs")
            command = f"{GITHUB_CI_REPO}/vagrant/vagrant-ci-wrapper.sh -d '{args.vagrant}' -r '{remote_ref}' {args.bootstrap_args}"
            ac.execute_remote_command(node, command, artifacts_dir="~/vagrant-logs*")
        else:
            # Run tests directly on the provisioned machine
            logging.info("PHASE 2: Bootstrap (ref: %s)", remote_ref)
            command = f"{GITHUB_CI_REPO}/agent/{args.bootstrap_script} -r '{remote_ref}' {args.bootstrap_args}"
            ac.execute_remote_command(node, command, artifacts_dir="~/bootstrap-logs*")

            if not args.skip_reboot:
                ac.reboot_node(node)

            logging.info("PHASE 3: Upstream testsuite")
            command = f"{GITHUB_CI_REPO}/agent/{args.testsuite_script}"
            ac.execute_remote_command(node, command, artifacts_dir="~/testsuite-logs*")

    except SignalException:
        # Do a proper cleanup on certain signals
        # (i.e. continue with the `finally` section)
        logging.info("Ignoring received signal...")

    except Exception:
        if node and args.kdump_collect:
            logging.info("Trying to collect kernel dumps from %s:/var/crash", node)
            # Wait a bit for the reboot to kick in in case we got a kernel panic
            time.sleep(10)

            try:
                ac.wait_for_node(node, 10)

                if ac.fetch_artifacts(node, "/var/crash", os.path.join(artifacts_dir, "kdumps")) != 0:
                    logging.warning("Failed to collect kernel dumps from %s", node)
            except Exception:
                # Fetching the kdumps is a best-effort thing, there's not much
                # we can do if the machine is FUBAR
                pass

        logging.exception("Execution failed")
        rc = 1

    finally:
        # Return the loaned node back to the pool if not requested otherwise
        if not ac.keep_node:
            # Ugly workaround for current Jenkin's behavior, where the signal
            # is sent several times under certain conditions. This is already
            # filed upstream, but the fix is still incomplete. Let's just
            # ignore SIGTERM/SIGHUP until the cleanup is complete.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)

            ac.free_session()

            # Restore default signal handlers
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGHUP, signal.SIG_DFL)

        if os.path.isfile("utils/generate-index.sh") and artifacts_dir and not args.no_index:
            # Try to generate a simple HTML index with results
            logging.info("Attempting to create an HTML index page")
            command = ["utils/generate-index.sh", artifacts_dir, "index.html"]
            ac.execute_local_command(command)


    return rc

if __name__ == "__main__":
    sys.exit(main())
