#!/bin/env python3
# pylint: disable=line-too-long,invalid-name
# pylint: disable=missing-function-docstring,missing-class-docstring,missing-module-docstring

from __future__ import absolute_import, print_function, with_statement

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict

import requests

API_BASE = "http://admin.ci.centos.org:8080"
GITHUB_BASE = "https://github.com/systemd/"
GITHUB_CI_REPO = "systemd-centos-ci"


class AgentControl():
    def __init__(self, artifacts_storage=None):
        # Should probably use a setter/getter in the future
        self.artifacts_storage = artifacts_storage
        self.keep_node = False
        self._node = {}
        self._reboot_count = 0

        # Load Duffy key
        self.duffy_key = os.environ.get("CICO_API_KEY")
        self.coveralls_token = os.environ.get("COVERALLS_REPO_TOKEN")

        if not self.duffy_key:
            logging.fatal("Invalid Duffy key")
            sys.exit(1)

    def __del__(self):
        # Deallocate the allocated node on script exit, if not requested otherwise
        if self._node is not None and "ssid" in self._node and not self.keep_node:
            self.free_session(self._node["ssid"])

    def _execute_api_command(self, endpoint, payload=None, include_api_key=True):
        """Execute a Duffy command

        See also: https://wiki.centos.org/QaWiki/CI/Duffy

        Params:
        -------
        endpoint : str
            API endpoint to use, including a leading slash (e.g. /Inventory)
        payload : dict
            A dictionary of arguments for given request
        include_api_key: bool (default: True)
            If True, includes the API key in the request

        Returns:
        --------
        Server response as a stringified JSON
        """
        payload = payload or {}
        url = "{}{}".format(API_BASE, endpoint)
        if include_api_key:
            payload["key"] = self.duffy_key
        logging.info("Duffy request URL: %s", url)

        r = requests.get(url, params=payload)

        return r.text

    def allocate_node(self, version, architecture, flavor=None):
        """Allocate a node with specified CentOS version and architecture

        Params:
        -------
        version : str/int
            CentOS version (e.g. 7)
        architecture: string
            Desired node architecture (e.g. x86_64, ppc64le, ...)
        flavor: string (Default: None)
            OpenNebula VM flavor, if requesting a VM (e.g. tiny, medium, ...)

        Returns:
        --------
        A tuple with node hostname and ssid
        """
        jroot = None
        payload = {
            "ver"  : version,
            "arch" : architecture
        }

        if flavor:
            payload["flavor"] = flavor

        logging.info("Attempting to allocate a node (version: %s, arch: %s, flavor: %s)",
                     version, architecture, flavor if flavor else "n/a")

        # When the machine pool runs out of pre-installed machines, Duffy returns
        # an error (Insufficient Nodes in READY State) which is not a valid
        # JSON object. Let's attempt to handle that and give Duffy some breathing
        # time to allocate more machines.
        # The last value (0) is there to allow one last try after the last wait
        for timeout in [60, 300, 600, 1800, 3600, 0]:
            try:
                res = self._execute_api_command("/Node/get", payload)
                jroot = json.loads(res)

                if not "hosts" in jroot or not "ssid" in jroot:
                    raise ValueError

                break
            except ValueError:
                logging.error("Received unexpected response from the server: %s", res)
                logging.info("Waiting %d seconds before another retry", timeout)

            time.sleep(timeout)

        host = None
        ssid = None
        try:
            if not jroot:
                raise ValueError("Duffy didn't return any nodes")

            host = jroot["hosts"][0]
            ssid = jroot["ssid"]
        except (ValueError, IndexError):
            logging.error("Failed to allocated a node")
            return (None, None)

        logging.info("Successfully allocated node '%s' (%s)", host, ssid)

        return (host, ssid)

    def allocated_nodes(self, verbose=False):
        """List nodes currently allocated for the current API key

        Params:
        -------
        verbose : bool (default: False)
            If True, returned nodes are also printed to the standard output

        Returns:
        --------
        List of nodes, where each node is a dict with host and ssid keys
        """
        res = self._execute_api_command("/Inventory")
        jroot = json.loads(res)

        if verbose:
            logging.info("Allocated nodes:")

        nodes = []
        for node in jroot:
            if verbose:
                logging.info("%s (%s)", node[0], node[1])

            nodes.append({"host" : node[0], "ssid" : node[1]})

        return nodes

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
                            "(got: {}, expected: {}), bailing out".format(rc, expected_rc))
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
            "root@{}:{}".format(node, remote_dir), local_dir
        ]

        logging.info("Fetching artifacts from node %s: (remote: %s, local: %s)",
                     node, remote_dir, local_dir)

        return self.execute_local_command(command)

    def free_all_nodes(self):
        """Return all nodes back to the pool"""
        nodes = self.allocated_nodes()

        for node in nodes:
            logging.info("Freeing node %s (%s)", node["host"], node["ssid"])
            self.free_session(node["ssid"])

    def free_session(self, node_ssid):
        """Return all nodes in a session back to the pool

        Params:
        -------
        node_ssid : str
            Session ID of the node allocation
        """
        if not node_ssid:
            return

        logging.info("Freeing session %s", node_ssid)
        res = self._execute_api_command("/Node/done", {"ssid" : node_ssid})
        logging.info(res)

    def list_all_nodes(self):
        """List all available nodes in the inventory"""
        res = self._execute_api_command("/Inventory", include_api_key=False)
        jroot = json.loads(res)

        # Schema taken from https://github.com/CentOS/duffy/blob/master/duffy/api_v1/views.py#L172
        schema = OrderedDict([
            ("ID",       "{:>3}"),
            ("hostname", "{:10}"),
            ("ip",       "{:15}"),
            ("chassis",  "{:8}"),
            ("ucnt",     "{:4}"),  # usage count
            ("state",    "{:16}"),
            ("comment",  "{:8}"),
            ("dist",     "{:3}"),
            ("release",  "{:3}"),
            ("ver",      "{:10}"),
            ("arch",     "{:10}"),
            ("pool",     "{:4}"),
            ("cons",     "{:5}"), # console port
            ("flavor",   "{:8}")
        ])
        format_str = " ".join(schema.values())

        logging.info("%s", format_str.format(*schema.keys()))
        for node in jroot:
            logging.info("%s", format_str.format(*node[0:14]))

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
            local_source, "root@{}:{}".format(node, remote_target)
        ]

        logging.info("Uploading file %s to node %s as %s", local_source, node, remote_target)

        return self.execute_local_command(command)

class SignalException(Exception):
    pass

def handle_signal(signum, frame):
    """Signal handler"""
    print("handle_signal: got signal {}".format(signum))
    raise SignalException()

def main():
    # Setup logging
    logging.basicConfig(level=logging.INFO,
            format="%(asctime)-14s [%(module)s/%(funcName)s] %(levelname)s: %(message)s")

    # Parse command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", default="x86_64",
            help="Architecture")
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
    parser.add_argument("--flavor", default=None,
            help="VM flavor (not applicable to all supported architectures)")
    parser.add_argument("--free-all-nodes", action="store_const", const=True,
            help="Free all currently provisioned nodes")
    parser.add_argument("--free-session", metavar="SESSION_ID",
            help="Return nodes from a session back to the pool")
    parser.add_argument("--keep", action="store_const", const=True,
            help="Do not kill provisioned build host")
    parser.add_argument("--list-nodes", choices=["owned", "all"], nargs="?", type=str, const="owned",
            help="List currently allocated nodes (owned) or all nodes in the inventory (all)")
    parser.add_argument("--no-index", action="store_const", const=True,
            help="Don't generate the artifact HTML page")
    parser.add_argument("--pr",
            help="Pull request ID to check out (systemd repository)")
    parser.add_argument("--skip-reboot", action="store_const", const=True,
            help="Skip reboot between bootstrap and test phases (on baremetal machines)")
    parser.add_argument("--testsuite-script", metavar="SCRIPT", type=str, default="testsuite.sh",
            help="Script which runs tests on the bootstrapped machine")
    parser.add_argument("--vagrant", metavar="DISTRO_TAG", type=str, default="",
            help="Run testing in Vagrant VMs on a distro specified by given distro tag")
    parser.add_argument("--vagrant-sync", metavar="VAGRANTFILE", type=str, default="",
            help="Run a script which updates and rebuilds Vagrant images used by systemd CentOS CI")
    # 'version' must be a string, as we want to support "8-stream" as well
    parser.add_argument("--version", default="8-stream",
            help="CentOS version")
    args = parser.parse_args()
    logging.info("%s", args)

    ac = AgentControl()
    ac.keep_node = args.keep

    if args.free_session:
        ac.free_session(args.free_session)
        return 0

    if args.free_all_nodes:
        ac.free_all_nodes()
        return 0

    if args.list_nodes:
        if args.list_nodes == "owned":
            ac.allocated_nodes(verbose=True)
        else:
            ac.list_all_nodes()

        return 0

    artifacts_dir = None
    node = None
    ssid = None
    rc = 0

    try:
        # Workaround for Jenkins, which sends SIGTERM/SIGHUP
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGHUP, handle_signal)

        node, ssid = ac.allocate_node(args.version, args.arch, args.flavor)

        if node is None or ssid is None:
            logging.critical("Can't continue without a valid node")
            return 1

        # Figure out a systemd branch to compile
        if args.pr:
            remote_ref = "pr:{}".format(args.pr)
        elif args.branch:
            remote_ref = args.branch
        else:
            remote_ref = ""

        # Setup artifacts storage
        artifacts_dir = tempfile.mkdtemp(prefix="artifacts_", dir=".")
        ac.artifacts_storage = artifacts_dir

        # Let's differentiate between CentOS <= 7 (yum) and CentOS >= 8 (dnf)
        pkg_man = "yum" if args.version in ["6", "7"] else "dnf"
        # Clean dnf/yum caches to drop stale metadata and prevent unexpected
        # installation fails before installing core dependencies
        dep_cmd = "{0} clean all && {0} makecache && {0} -y install bash git rsync".format(pkg_man)

        # Actual testing process
        logging.info("PHASE 1: Setting up basic dependencies to configure CI repository")
        command = "{0} && rm -fr {1} && git clone {2}{1}".format(dep_cmd, GITHUB_CI_REPO, GITHUB_BASE)
        ac.execute_remote_command(node, command)

        if args.ci_pr:
            logging.info("PHASE 1.5: Using a custom CI repository ref (PR#%s)", args.ci_pr)
            command = "cd {} && git fetch -fu origin 'refs/pull/{}/merge:pr' && " \
                      "git checkout pr".format(GITHUB_CI_REPO, args.ci_pr)
            ac.execute_remote_command(node, command)

        if args.vagrant_sync:
            logging.info("PHASE 2: update & rebuild Vagrant images used by systemd CentOS CI")
            # We need the Duffy key to be able to upload to the CentOS CI artifact server
            key_file = tempfile.NamedTemporaryFile(mode="w")
            key_file.write(ac.duffy_key)
            key_file.flush()
            ac.upload_file(node, key_file.name, "/duffy.key")
            key_file.close()

            command = "{}/vagrant/vagrant-make-cache.sh '{}'".format(GITHUB_CI_REPO, args.vagrant_sync)
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
            command = "{}/vagrant/vagrant-ci-wrapper.sh -d '{}' -r '{}' {}".format(GITHUB_CI_REPO, args.vagrant, remote_ref, args.bootstrap_args)
            ac.execute_remote_command(node, command, artifacts_dir="~/vagrant-logs*")
        else:
            # Run tests directly on the provisioned machine
            logging.info("PHASE 2: Bootstrap (ref: %s)", remote_ref)
            command = "{}/agent/{} -r '{}' {}".format(GITHUB_CI_REPO, args.bootstrap_script, remote_ref, args.bootstrap_args)
            ac.execute_remote_command(node, command, artifacts_dir="~/bootstrap-logs*")

            if not args.skip_reboot:
                ac.reboot_node(node)

            logging.info("PHASE 3: Upstream testsuite")
            command = "{}/agent/{}".format(GITHUB_CI_REPO, args.testsuite_script)
            ac.execute_remote_command(node, command, artifacts_dir="~/testsuite-logs*")

    except SignalException:
        # Do a proper cleanup on certain signals
        # (i.e. continue with the `finally` section)
        logging.info("Ignoring received signal...")

    except Exception:
        if args.kdump_collect:
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
        if ssid and not ac.keep_node:
            # Ugly workaround for current Jenkin's behavior, where the signal
            # is sent several times under certain conditions. This is already
            # filed upstream, but the fix is still incomplete. Let's just
            # ignore SIGTERM/SIGHUP until the cleanup is complete.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)

            ac.free_session(ssid)

            # Restore default signal handlers
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGHUP, signal.SIG_DFL)

        if os.path.isfile("utils/generate-index.sh") and not args.no_index:
            # Try to generate a simple HTML index with results
            logging.info("Attempting to create an HTML index page")
            command = ["utils/generate-index.sh", artifacts_dir, "index.html"]
            ac.execute_local_command(command)


    return rc

if __name__ == "__main__":
    sys.exit(main())
