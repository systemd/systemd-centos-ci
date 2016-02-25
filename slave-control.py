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

def host_done(key, ssid):
	params = { "key": key, "ssid": ssid }
	duffy_cmd("/Node/done", params)
	print "Duffy: Host with ssid %s marked as done" % ssid

def log_msg(msg, logfile):
	print msg

	if logfile:
		logfile.write(msg + "\n")
		logfile.write("======================================================\n");

def remote_exec(host, remote_cmd, logfile, expected_ret = 0):
	cmd = [ '/usr/bin/ssh',
		'-t',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'ConnectTimeout=180',
		'-l', 'root',
		host, remote_cmd ]

	log_msg(">>> Executing remote command: '%s' on %s" % (remote_cmd, host), logfile)

	if logfile:
		logfd = logfile.fileno()
	else:
		logfd = None

	start = time.time()

	p = subprocess.Popen(cmd, stdout = logfd, stderr = logfd, shell = False, bufsize = 1)
	p.communicate()
	p.wait()

	end = time.time()

	log_msg("<<< Remote command finished after %.1f seconds, return code = %d" % (end - start, p.returncode), logfile)

	if p.returncode != expected_ret:
		raise Exception("Remote command returned code %d, bailing out." % p.returncode)

def ping_host(host, logfile)
	cmd = [ '/usr/bin/ping', '-c', '1', host ]

	p = subprocess.Popen(cmd, stdout = logfd, stderr = logfd, shell = False, bufsize = 1)
	p.communicate()
	p.wait()

	log_msg("Host %s appears reachable again", logfile)

def reboot_host(host, logfile):
	# the reboot command races against the graceful exit, so ignore the return code in this case
	remote_exec(host, "journalctl -b --no-pager && reboot", logfile, 255)

	time.sleep(30)
	ping_host(host, logfile)
	time.sleep(20)

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('--log',            help = 'Logfile for command output')
	parser.add_argument('--ver',            help = 'CentOS version', default = '7')
	parser.add_argument('--arch',           help = 'Architecture', default = 'x86_64')
	parser.add_argument('--host',           help = 'Use an already provisioned build host')
	parser.add_argument('--pr',             help = 'Pull request ID')
	parser.add_argument('--keep',           help = 'Do not kill provisioned build host', action = 'store_const', const = True)
	parser.add_argument('--kill-host',      help = 'Mark a provisioned host as done and bail out')
	parser.add_argument('--kill-all-hosts', help = 'Mark all provisioned hosts as done and bail out', action = 'store_const', const = True)
	args = parser.parse_args()

	key = open("duffy.key", "r").read().rstrip()

	if args.log:
		logfile = open(args.log, "w")
	else:
		logfile = None

	if args.kill_host:
		host_done(key, args.kill_host)
		return 0

	if args.kill_all_hosts:
		params = { "key": key }
		json_data = duffy_cmd("/Inventory", params)
		data = json.loads(json_data)

		for host in data:
			host_done(key, host[1])

		return 0

	if args.host:
		host = args.host
		ssid = None
	else:
		params = { "key": key, "ver": args.ver, "arch": args.arch }
		json_data = duffy_cmd("/Node/get", params)
		data = json.loads(json_data)

		host = data['hosts'][0]
		ssid = data['ssid']

		print "Duffy: Host provisioning successful, hostname = %s, ssid = %s" % (host, ssid)

	ret = 0

	start = time.time()

	try:
		cmd = "yum install -y git && git clone %s%s.git && %s/slave/bootstrap.sh %s" % (github_base, git_name, git_name, args.pr)
		remote_exec(host, cmd, logfile)
		reboot_host(host, logfile)

		cmd = "%s/slave/testsuite.sh" % git_name
		remote_exec(host, cmd, logfile)
		reboot_host(host, logfile)

#		cmd = "%s/slave/cockpit.sh" % git_name
#		remote_exec(host, cmd, logfile)

		for i in range(2):
			cmd = "exit `journalctl --list-boots | wc -l`"
			remote_exec(host, cmd, logfile, i + 1)

			reboot_host(host, logfile)

			cmd = "journalctl -b --no-pager"
			remote_exec(host, cmd, logfile)

			cmd = "systemctl --failed --all | grep -q '^0 loaded'"
			remote_exec(host, cmd, logfile)

		log_msg("All tests succeeded.", logfile)

	except Exception as e:
		log_msg("Execution failed! See logfile for details: %s" % str(e), logfile)
		ret = 255

	finally:
		if ssid:
			if args.keep:
				print "Keeping host %s, ssid = %s" % (host, ssid)
			else:
				host_done(key, ssid);

		end = time.time()
		log_msg("Total time %.1f seconds" % (end - start), logfile)

		if logfile:
			logfile.close()

	sys.exit(ret)

if __name__ == "__main__":
	main()
