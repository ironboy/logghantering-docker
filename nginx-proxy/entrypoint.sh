#!/bin/bash
set -e

touch /var/log/nginx/access.log /var/log/nginx/error.log
rsyslogd

/var/ossec/bin/wazuh-control start

exec nginx -g 'daemon off;'
