#!/usr/bin/python

# This script uses the Duffy node management api to get fresh machines to run
# your CI tests on. Once allocated you will be able to ssh into that machine
# as the root user and setup the environ
#
# based on a script by Karanbir Singh
#

import os, json, urllib, subprocess, sys, argparse, fcntl, time

github_base = "https://github.com/systemd/"
git_name = "systemd-centos-ci"

def duffy_cmd(cmd, params):
	url_base = "http://admin.ci.centos.org:8080"
	url = "%s%s?%s" % (url_base, cmd, urllib.urlencode(params))
	print "Duffy API debug: url = " + url
	return urllib.urlopen(url).read()

def remote_exec(host, remote_cmd, logfile):
	cmd = [ '/usr/bin/ssh',
		'-t',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'StrictHostKeyChecking=no',
		'-l', 'root',
		host, remote_cmd ]

	l = "Executing remote command: '%s' on %s" % (remote_cmd, host)
	print l

	if logfile:
		logfile.write(l + "\n")
		logfile.write("======================================================\n");
		logfd = logfile.fileno()
	else:
		logfd = None

	p = subprocess.Popen(cmd, stdout = logfd, stderr = logfd, shell = False, bufsize = 1)
	p.communicate()
	p.wait()

	l = "Remote command finished: '%s' on %s, return code = %d" % (remote_cmd, host, p.returncode)
	print l

	if logfile:
		logfile.write(l + "\n")
		logfile.write("======================================================\n");

	if p.returncode != 0:
		raise Exception("Remote command returned code %d, bailing out." % p.returncode)

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('--log',  help = 'Logfile for command output')
	parser.add_argument('--ver',  help = 'CentOS version', default = '7')
	parser.add_argument('--arch', help = 'Architecture', default = 'x86_64')
	parser.add_argument('--host', help = 'Use an already provisioned build host')
	parser.add_argument('--keep', help = 'Do not kill provisioned build host')
	parser.add_argument('--pr',   help = 'Pull request ID')
	args = parser.parse_args()

	key = open("duffy.key", "r").read().rstrip()

	if args.log:
		logfile = open(args.log, "w")
	else:
		logfile = None

	if args.host:
		host = args.host
		ssid = None
	else:
		params = { "key": key, "ver": args.ver, "arch":  args.arch }
		data = duffy_cmd("/Node/get", params)

		json_data = json.loads(data)
		host = json_data['hosts'][0]
		ssid = json_data['ssid']

		print "Host provisioning successful, hostname = %s, ssid = %s" % (host, ssid)

	ret = 0

	try:
		cmd = "yum install -y git && git clone %s%s.git && %s/slave/bootstrap.sh %s" % (github_base, git_name, git_name, args.pr)
		remote_exec(host, cmd, logfile)

		for i in range(10):
			try:
				remote_exec(host, "journalctl -b --no-pager && reboot", logfile)
			except:
				pass

			# wait for the host to reappear
			time.sleep(60)

			cmd = "journalctl -b --no-pager"
			remote_exec(host, cmd, logfile)

			cmd = "systemctl --failed --all | grep -q '^0 loaded'"
			remote_exec(host, cmd, logfile)

	except Exception as e:
		l = "Execution failed! See logfile for details: %s" % str(e)
		if logfile:
			logfile.write("ERROR: " + l + "\n")

		ret = 255

	finally:
		if ssid:
			if args.keep:
				print "Keeping host %s" % host
			else:
				params = { "key": key, "ssid": ssid }
				duffy_cmd("/Node/done", params)
				print "Host %s marked as done, ssid = %s" % (host, ssid)

		logfile.close()

	sys.exit(ret)

if __name__ == "__main__":
	main()
