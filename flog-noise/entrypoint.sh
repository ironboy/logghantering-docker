#!/bin/bash
set -e

mkdir -p /var/log/flog
rsyslogd

/var/ossec/bin/wazuh-control start

flog -l -w -d 2s -f apache_combined -o /var/log/flog/apache.log -t log &
flog -l -w -d 3s -f rfc3164         -o /var/log/flog/syslog.log -t log &
flog -l -w -d 4s -f json            -o /var/log/flog/json.log   -t log &

wait
