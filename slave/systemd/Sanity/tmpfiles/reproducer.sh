#!/bin/bash

useradd foo;
groupadd bar;



cat <<\EOF > /etc/tmpfiles.d/hello.conf
D /run/hello  1777 foo bar -
f /run/hello/hello.test  1777 root bar -
z /run/hello/hello.test 1777 root root - -


EOF


sudo systemd-tmpfiles --create
ls -l  /run/hello/
