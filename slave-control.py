#!/usr/bin/python

# GPLv2 etc.

import os, json, urllib, subprocess, sys, argparse, fcntl, time

github_base = "https://github.com/systemd/"
git_name = "systemd-centos-ci"

debug = False
reboot_count = 0

def dprint(msg):
	global debug

	if debug:
		print "Debug:: " + msg

def duffy_cmd(cmd, params):
	url_base = "http://admin.ci.centos.org:8080"
	url = "%s%s?%s" % (url_base, cmd, urllib.urlencode(params))
	dprint("Duffy API url = " + url)
	return urllib.urlopen(url).read()

def host_done(key, ssid):
	params = { "key": key, "ssid": ssid }
	duffy_cmd("/Node/done", params)
	print "Duffy: Host with ssid %s marked as done" % ssid

def exec_cmd(cmd):
	dprint("Executing command: '%s'" % ("' '".join(cmd)))

	p = subprocess.Popen(cmd, stdout = None, stderr = None, shell = False, bufsize = 1)
	p.communicate()
	p.wait()

	return p.returncode

def remote_exec(host, remote_cmd, expected_ret = 0):
	cmd = [ '/usr/bin/ssh',
		'-t',
		'-o', 'UserKnownHostsFile=/dev/null',
		'-o', 'StrictHostKeyChecking=no',
		'-o', 'ConnectTimeout=180',
		'-o', 'TCPKeepAlive=yes',
		'-o', 'ServerAliveInterval=2',
		'-l', 'root',
		host, remote_cmd ]

	print(">>> Executing remote command: '%s' on %s" % (remote_cmd, host))

	start = time.time()
	ret = exec_cmd(cmd)
	end = time.time()

	print("<<< Remote command finished after %.1f seconds, return code = %d" % (end - start, ret))

	if ret != expected_ret:
		raise Exception("Remote command returned code %d, expected %d. Bailing out." % (ret, expected_ret))

def ping_host(host):

	cmd = [ '/usr/bin/ping', '-q', '-c', '1', '-W', '10', host ]
	print("Pinging host %s ..." % host)

	for i in range(20):
		ret = exec_cmd(cmd)
		if ret == 0:
			break;

	if ret != 0:
		raise Exception("Timeout waiting for ping")

	print("Host %s appears reachable again" % host)

def reboot_host(host):
	global reboot_count

	print("Rebooting host %s ..." % host)

	# the reboot command races against the graceful exit, so ignore the return code in this case
	remote_exec(host, "journalctl --no-pager -b && reboot", 255)

	time.sleep(30)
	ping_host(host)
	time.sleep(20)

	reboot_count += 1

def main():
	global debug
	global reboot_count

	parser = argparse.ArgumentParser()
	parser.add_argument('--ver',            help = 'CentOS version', default = '7')
	parser.add_argument('--arch',           help = 'Architecture', default = 'x86_64')
	parser.add_argument('--host',           help = 'Use an already provisioned build host')
	parser.add_argument('--pr',             help = 'Pull request ID to check out')
	parser.add_argument('--branch',         help = 'Commit/tag/branch to checkout')
	parser.add_argument('--keep',           help = 'Do not kill provisioned build host', action = 'store_const', const = True)
	parser.add_argument('--kill-host',      help = 'Mark a provisioned host as done and bail out')
	parser.add_argument('--kill-all-hosts', help = 'Mark all provisioned hosts as done and bail out', action = 'store_const', const = True)
	parser.add_argument('--debug',          help = 'Enable debug output', action = 'store_const', const = True)
	args = parser.parse_args()

	key = open("duffy.key", "r").read().rstrip()

	debug = args.debug

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
		if args.pr:
			branch="pr:%s" % args.pr
		elif args.branch:
			branch = args.branch
		else:
			branch = ''

		cmd = "yum install -y git && git clone %s%s.git && %s/slave/bootstrap.sh %s" % (github_base, git_name, git_name, branch)
		remote_exec(host, cmd)
		reboot_host(host)

		cmd = "%s/slave/testsuite.sh" % git_name
		remote_exec(host, cmd)
		reboot_host(host)

		cmd = "cd %s/slave; ./system-tests.sh" % git_name
		remote_exec(host, cmd)
		reboot_host(host)

		for i in range(4):
			cmd = "exit `journalctl --list-boots | wc -l`"
			remote_exec(host, cmd, reboot_count)

			reboot_host(host)

			cmd = "systemctl --failed --all | grep -q '^0 loaded'"
			remote_exec(host, cmd)

		print("All tests succeeded.")

	except Exception as e:
		print("Execution failed! See logfile for details: %s" % str(e))
		ret = 255

	finally:
		if ssid:
			if args.keep:
				print "Keeping host %s, ssid = %s" % (host, ssid)
			else:
				host_done(key, ssid);

		end = time.time()
		print("Total time %.1f seconds" % (end - start))

	sys.exit(ret)

if __name__ == "__main__":
	main()
