#!/usr/bin/python

# This script uses the Duffy node management api to get fresh machines to run
# your CI tests on. Once allocated you will be able to ssh into that machine
# as the root user and setup the environ
#
# based on a script by Karanbir Singh
#

import json, urllib, subprocess, sys, argparse

github_base = "https://github.com/systemd/"
git_name = "systemd-centos-ci"

def duffy_cmd(cmd, params):
	url_base = "http://admin.ci.centos.org:8080"
	url = "%s%s?%s" % (url_base, cmd, urllib.urlencode(params))
	print "debug:: url = " + url
	return urllib.urlopen(url).read()

def remote_exec(host, cmd, log):
	ssh_cmd = "ssh -t -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@%s '%s'" % (host, cmd)
	print "debug:: cmd = " + ssh_cmd

	try:
		output = subprocess.check_output(ssh_cmd, shell = True)

		if log:
			log.write(output)
			log.close

	except subprocess.CalledProcessError as e:
		if log:
			log.write(str(e))
			log.write(e.output)
			log.close

		raise

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('--log',  help = 'Logfile for command output')
	parser.add_argument('--ver',  help = 'CentOS version', default = '7')
	parser.add_argument('--arch', help = 'Architecture', default = 'x86_64')
	parser.add_argument('--host', help = 'Use an already provisioned build host')
	parser.add_argument('--pr',   help = 'Pull request ID')
	args = parser.parse_args()

	key = open("duffy.key", "r").read().rstrip()

	if args.log:
		log = open(args.log, "w")
	else:
		log = None

	if args.host:
		host = args.host
		ssid = None
	else:
		params = { "key": key, "ver": args.ver, "arch":  args.arch }
		data = duffy_cmd("/Node/get", params)

		json_data = json.loads(data)
		host = json_data['hosts'][0]
		ssid = json_data['ssid']

	ret = 0

	try:
		bootstrap_cmd = "yum install -y git && git clone %s%s.git && %s/slave/bootstrap.sh %s" % (github_base, git_name, git_name, args.pr)
		remote_exec(host, bootstrap_cmd, log)

	except Exception as e:
		print "Execution failed! See logfile for details: %s" % str(e)
		ret = 255

	finally:
		if ssid:
			params = { "key": key, "ssid": ssid }
			duffy_cmd("/Node/done", params)

	sys.exit(ret)

if __name__ == "__main__":
	main()
