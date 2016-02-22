#!/usr/bin/python

# This script uses the Duffy node management api to get fresh machines to run
# your CI tests on. Once allocated you will be able to ssh into that machine
# as the root user and setup the environ
#
# based on a script by Karanbir Singh
#

import json, urllib, subprocess, sys

key = open("duffy.key", "r").read().rstrip()

def duffy_cmd(cmd, params):
	url_base = "http://admin.ci.centos.org:8080"
	url = "%s%s?%s" % (url_base, cmd, urllib.urlencode(params))
	print "debug:: url = " + url
	return urllib.urlopen(url).read()

ver = "7"
arch = "x86_64"
count = 1

git_url = "https://github.com/systemd/systemd-centos-ci.git"

params = { "key": key, "ver": ver, "count": count, "arch":  arch }
data = duffy_cmd("/Node/get", params)

b = json.loads(data)
for h in b['hosts']:
	cmd = "ssh -t -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@%s 'echo %s'" % (h, git_url)
	print "debug:: cmd = " + cmd
	rtn_code = subprocess.call(cmd, shell=True)

params = { "key": key, "ssid": b['ssid'] }
data = duffy_cmd("/Node/done", params)

sys.exit(rtn_code)
