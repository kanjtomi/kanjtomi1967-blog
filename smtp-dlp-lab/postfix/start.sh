#!/bin/sh
# Postfix for the SMTP DLP lab (runs in the mta pod next to the dlp container).
#   :25              public listener; every message goes through the DLP proxy
#                    (smtpd_proxy_filter = before-queue, so a block is a 550 to the client)
#   127.0.0.1:10025  re-injection listener for messages the DLP proxy passed and for
#                    its notices; no filter here, otherwise mail would loop
# Everything is relayed to Mailpit, so nothing ever leaves the cluster.
set -e
apk add --no-cache -q postfix

postconf -e \
  "compatibility_level=3.6" \
  "myhostname=mail.corp.lab" \
  "mydomain=corp.lab" \
  "myorigin=\$mydomain" \
  "mydestination=" \
  "alias_maps=" \
  "alias_database=" \
  "inet_interfaces=all" \
  "inet_protocols=ipv4" \
  "mynetworks=127.0.0.0/8 10.244.0.0/16 192.168.0.0/24" \
  "smtpd_relay_restrictions=permit_mynetworks,reject" \
  "relayhost=[mailpit.smtp-dlp-lab.svc.cluster.local]:1025" \
  "smtp_host_lookup=native" \
  "message_size_limit=26214400" \
  "smtpd_proxy_timeout=120s" \
  "maillog_file=/dev/stdout"

postconf -M "smtp/inet=smtp inet n - n - - smtpd"
postconf -P "smtp/inet/smtpd_proxy_filter=127.0.0.1:10024"

postconf -M "127.0.0.1:10025/inet=127.0.0.1:10025 inet n - n - - smtpd"
postconf -P \
  "127.0.0.1:10025/inet/smtpd_proxy_filter=" \
  "127.0.0.1:10025/inet/mynetworks=127.0.0.0/8" \
  "127.0.0.1:10025/inet/smtpd_relay_restrictions=permit_mynetworks,reject" \
  "127.0.0.1:10025/inet/smtpd_recipient_restrictions=" \
  "127.0.0.1:10025/inet/smtpd_helo_restrictions="

# maillog_file needs the postlog service
postconf -M "postlog/unix-dgram=postlog unix-dgram n - n - 1 postlogd"

postfix check
exec postfix start-fg
