#!/bin/bash
set -e

touch /var/log/auth.log /var/log/syslog
rsyslogd

/var/ossec/bin/wazuh-control start

exec /usr/sbin/sshd -D
