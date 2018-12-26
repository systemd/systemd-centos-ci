#!/usr/bin/env python2

from __future__ import print_function, with_statement
import argparse
import json
import logging
import subprocess
import sys
import time
import tempfile
import requests

API_BASE = "http://admin.ci.centos.org:8080"
DUFFY_KEY_FILE = "/home/systemd/duffy.key"
GITHUB_BASE = "https://github.com/systemd/"
GITHUB_CI_REPO = "systemd-centos-ci"

class AgentControl(object):
    def __init__(self, artifacts_storage=None):
        # Should probably use a setter/getter in the future
        self.artifacts_storage = artifacts_storage
        self._node = {}
        self._reboot_count = 0

        # Load duffy key
        with open(DUFFY_KEY_FILE, "r") as fh:
            self._duffy_key = fh.read().strip()

    def __del__(self):
        # Deallocate the allocated node on script exit, if not requested otherwise
        if self._node is not None and "ssid" in self._node:
            self.free_session(self._node["ssid"])

    def _execute_api_command(self, endpoint, payload={}):
        """Execute a Duffy command

        See also: https://wiki.centos.org/QaWiki/CI/Duffy

        Params:
        -------
        endpoint : str
            API endpoint to use, including a leading slash (e.g. /Inventory)
        payload : dict
            A dictionary of arguments for given request

        Returns:
        --------
        Server response as a stringified JSON
        """
        url = "{}{}".format(API_BASE, endpoint)
        payload["key"] = self._duffy_key
        logging.info("Duffy request URL: {}".format(url))

        r = requests.get(url, payload)

        return r.text

    def allocate_node(self, version, architecture, clean_on_exit=True):
        """Allocate a node with specified CentOS version and architecture

        Params:
        -------
        version : str/int
            CentOS version (e.g. 7)
        architecture: string
            Desired node architecture (e.g. x86_64)
        clean_on_exit : bool (default: True)
            If True, the node is automatically freed once the AgentControl
            object is deallocated

        Returns:
        --------
        A tuple with node hostname and ssid
        """
        payload = {
            "ver"  : version,
            "arch" : architecture
        }

        logging.info("Attempting to allocate a node ({} {})".format(version, architecture))
        res = self._execute_api_command("/Node/get", payload)
        jroot = json.loads(res)

        host = None
        ssid = None
        try:
            host = jroot["hosts"][0]
            ssid = jroot["ssid"]
        except (ValueError, IndexError):
            logging.error("Failed to allocated a node")
            return (None, None)

        if clean_on_exit:
            self._node["host"] = host
            self._node["ssid"] = ssid

        logging.info("Successfully allocated node '{}' ({})".format(host, ssid))

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
                logging.info("{} ({})".format(node[0], node[1]))

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
        logging.info("Executing a LOCAL command: {}".format(" ".join(command)))

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
            If not None and the `self.artifacts_dir` is set, all files from the
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

        logging.info("Executing a REMOTE command on node'{}': {}".format(node, command))
        rc = self.execute_local_command(command_wrapper)

        # Fetch artifacts if both remote and local dirs are set
        if artifacts_dir is not None and self.artifacts_storage is not None:
            arc = self.fetch_artifacts(node, artifacts_dir, self.artifacts_storage)
            if arc != 0:
                logging.warn("Fetching artifacts failed")

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

        logging.info("Fetching artifacts from node {}: (remote: {}, local: {})".format(
                node, remote_dir, local_dir))

        return self.execute_local_command(command)

    def free_all_nodes(self):
        """Return all nodes back to the pool"""
        nodes = self.allocated_nodes()

        for node in nodes:
            logging.info("Freeing node {} ({})".format(node["host"], node["ssid"]))
            self.free_session(node["ssid"])

    def free_session(self, node_ssid):
        """Return all nodes in a session back to the pool

        Params:
        -------
        node_ssid : str
            Session ID of the node allocation
        """
        logging.info("Freeing session {}".format(node_ssid))
        res = self._execute_api_command("/Node/done", {"ssid" : node_ssid})
        logging.info(res)

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
        logging.info("Rebooting node {}".format(node))
        self.execute_remote_command(node, "systemctl reboot", 255, ignore_rc=True)
        time.sleep(30)

        ping_command = ["/usr/bin/ping", "-q", "-c", "1", "-W", "10", node]
        for i in range(10):
            logging.info("Checking if the node {} is alive (try #{})".format(node, i))
            rc = self.execute_local_command(ping_command)
            if rc == 0:
                break;
            time.sleep(15)

        if rc != 0:
            raise Exception("Timeout reached when waiting for node to become online")

        logging.info("Node {} appears reachable again".format(node))
        # Give the node time to finish booting process
        time.sleep(30)


if __name__ == "__main__":
    # Setup logging
    logging.basicConfig(level=logging.INFO,
            format="%(asctime)-14s [%(module)s/%(funcName)s] %(levelname)s: %(message)s")

    # Parse command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", default="x86_64",
            help="Architecture")
    parser.add_argument("--branch",
            help="Commit/tag/branch to checkout")
    parser.add_argument("--ci-pr",
            help="Pull request ID to check out (systemd-centos-ci repository)")
    parser.add_argument("--free-all-nodes", action="store_const", const=True,
            help="Free all currently provisioned nodes")
    parser.add_argument("--free-session",
            help="Return nodes from a session back to the pool")
    parser.add_argument("--keep", action="store_const", const=True,
            help="Do not kill provisioned build host")
    parser.add_argument("--list-nodes", action="store_const", const=True,
            help="List currectly allocated nodes")
    parser.add_argument("--pr",
            help="Pull request ID to check out (systemd repository)")
    parser.add_argument("--version", default = "7",
            help="CentOS version")
    args = parser.parse_args()

    ac = AgentControl()

    if args.free_session:
        ac.free_session(args.free_session)
        sys.exit(0)

    if args.free_all_nodes:
        ac.free_all_nodes()
        sys.exit(0)

    if args.list_nodes:
        ac.allocated_nodes(verbose=True)
        sys.exit(0)

    node, ssid = ac.allocate_node(args.version, args.arch, not args.keep)

    if node is None or ssid is None:
        logging.critical("Can't continue without a valid node")
        sys.exit(1)

    try:
        # Figure out a systemd branch to compile
        if args.pr:
            branch = "pr:{}".format(args.pr)
        elif args.branch:
            branch = args.branch
        else:
            branch = ""

        # Setup artifacts storage
        artifacts_dir = tempfile.mkdtemp(prefix="artifacts_", dir=".")
        ac.artifacts_storage = artifacts_dir

        # Actual testing process
        logging.info("PHASE 1: Setting up basic dependencies to configure CI repository")
        command = "yum -y install git && git clone {}{}".format(GITHUB_BASE, GITHUB_CI_REPO)
        ac.execute_remote_command(node, command)

        if args.ci_pr:
            logging.info("PHASE 1.5: Using a custom CI repository branch (PR#{})".format(args.ci_pr))
            command = "cd {} && git fetch -fu origin 'refs/pull/{}/merge:pr' && " \
                      "git checkout pr".format(GITHUB_CI_REPO, args.ci_pr)
            ac.execute_remote_command(node, command)

        logging.info("PHASE 2: Bootstrap (branch: {})".format(branch))
        command = "{}/agent/bootstrap.sh {}".format(GITHUB_CI_REPO, branch)
        ac.execute_remote_command(node, command, artifacts_dir="~/bootstrap-logs*")

        ac.reboot_node(node)

        logging.info("PHASE 3: Upstream testsuite")
        command = "{}/agent/testsuite.sh".format(GITHUB_CI_REPO)
        ac.execute_remote_command(node, command, artifacts_dir="~/testsuite-logs*")

    except Exception as e:
        logging.exception("Execution failed")
        sys.exit(1)
