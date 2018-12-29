#!/usr/bin/env python

from __future__ import print_function
import json
import requests
import sys

class GithubStatus(object):
    API_BASE = "https://api.github.com"
    VALID_STATUSES = ["error", "failure", "pending", "success"]

    def __init__(self, token_file, repo):
        self._repo = repo
        with open(token_file, "r") as fp:
            self._gh_token = fp.readline().strip()

    def set_status(self, commit, state, target_url, description, context="default"):
        """Set GitHub CI status for a specific commit

        See: https://developer.github.com/v3/repos/statuses/#create-a-status

        Args:
            commit (str): SHA hash of the target commit
            state (str): desired state (error, failure, pending, success)
            target_url (str): URL of the results page
            description: short description of the state
            context: basically the CI system name

        """
        if state not in GithubStatus.VALID_STATUSES:
            raise Exception("Invalid state '{}'".format(state))

        url = "{}/repos/{}/statuses/{}".format(GithubStatus.API_BASE, self._repo, commit)
        print(url)
        headers = {
            "Authorization" : "token {}".format(self._gh_token),
            "Accept" : "application/vnd.github.v3+json",
        }
        payload = {
            "state" : state,
            "target_url" : target_url,
            "description" : description,
            "context" : context
        }

        # TODO: error handling
        res = requests.post(url, data=json.dumps(payload), headers=headers)
        jroot = json.loads(res.text)

        print(res.text)

        return (jroot["state"] == state)

if __name__ == "__main__":
    ghs = GithubStatus("/home/systemd/.github_token", "systemd/systemd")

    if len(sys.argv) != 6:
        print("Usage: {} <commit> <state> <target_url> <description> <context>".format(sys.argv[0]))
        sys.exit(1)

    sys.exit(not ghs.set_status(*sys.argv[1:]))
