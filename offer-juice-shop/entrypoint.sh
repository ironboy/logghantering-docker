#!/bin/bash
set -e

touch /var/log/auth.log /var/log/syslog /var/log/juice-shop.log
rsyslogd

/var/ossec/bin/wazuh-control start

cd /juice-shop
exec /nodejs/bin/node /juice-shop/build/app.js >> /var/log/juice-shop.log 2>&1
