#!/usr/bin/python

# GPLv2 etc.

import os, json, urllib, subprocess, sys, argparse, fcntl, time

github_base = "https://github.com/systemd/"
git_name = "systemd-centos-ci"

def duffy_cmd(cmd, params):
	url_base = "http://admin.ci.centos.org:8080"
	url = "%s%s?%s" % (url_base, cmd, urllib.urlencode(params))
	print "Duffy API debug: url = " + url
	return urllib.urlopen(url).read()

def remote_exec(host, remote_cmd, logfile, expected_ret = 0):
	cmd = [ '/usr/bin/ssh',
		'-t',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'ConnectTimeout=180',
		'-l', 'root',
		host, remote_cmd ]

	l = ">>> Executing remote command: '%s' on %s" % (remote_cmd, host)
	print l

	if logfile:
		logfile.write(l + "\n")
		logfile.write("======================================================\n");
		logfd = logfile.fileno()
	else:
		logfd = None

	start = time.time()

	p = subprocess.Popen(cmd, stdout = logfd, stderr = logfd, shell = False, bufsize = 1)
	p.communicate()
	p.wait()

	end = time.time()

	l = "<<< Remote command finished after %.1f seconds, return code = %d" % (end - start, p.returncode)
	print l

	if logfile:
		logfile.write(l + "\n")
		logfile.write("======================================================\n");

	if p.returncode != expected_ret:
		raise Exception("Remote command returned code %d, bailing out." % p.returncode)

def reboot_host(host, logfile):
	# the reboot command races against the graceful exit, so ignore the return code in this case
	remote_exec(host, "journalctl -b --no-pager && reboot", logfile, 255)

	# wait for the host to reappear
	time.sleep(60)

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
		params = { "key": key, "ver": args.ver, "arch": args.arch }
		data = duffy_cmd("/Node/get", params)

		json_data = json.loads(data)
		host = json_data['hosts'][0]
		ssid = json_data['ssid']

		print "Duffy: Host provisioning successful, hostname = %s, ssid = %s" % (host, ssid)

	ret = 0

	try:
		cmd = "yum install -y git && git clone %s%s.git && %s/slave/bootstrap.sh %s" % (github_base, git_name, git_name, args.pr)
		remote_exec(host, cmd, logfile)
		reboot_host(host, logfile)

		cmd = "%s/slave/testsuite.sh" % git_name
		remote_exec(host, cmd, logfile)
		reboot_host(host, logfile)

#		cmd = "%s/slave/cockpit.sh" % git_name
#		remote_exec(host, cmd, logfile)

		for i in range(3):
			cmd = "exit `journalctl --list-boots | wc -l`"
			remote_exec(host, cmd, logfile, i + 1)

			reboot_host(host, logfile)

			cmd = "journalctl -b --no-pager"
			remote_exec(host, cmd, logfile)

			cmd = "systemctl --failed --all | grep -q '^0 loaded'"
			remote_exec(host, cmd, logfile)

	except Exception as e:
		l = "XXX Execution failed! See logfile for details: %s" % str(e)
		if logfile:
			logfile.write("ERROR: %s\n" % l)

		ret = 255

	finally:
		if ssid:
			if args.keep:
				print "Keeping host %s" % host
			else:
				params = { "key": key, "ssid": ssid }
				duffy_cmd("/Node/done", params)
				print "Duffy: Host %s marked as done, ssid = %s" % (host, ssid)

		logfile.close()

	sys.exit(ret)

if __name__ == "__main__":
	main()
