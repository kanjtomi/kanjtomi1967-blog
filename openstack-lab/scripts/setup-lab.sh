#!/bin/bash
# Create the practice project "lab" and user "labuser" on this DevStack host.
# Run as the normal login user (tomi) on Zadara; uses sudo to borrow the stack user's admin credentials.
# Safe to re-run: existing project/user are kept, quota and openrc are refreshed.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENRC="$LAB_DIR/lab-openrc.sh"
AUTH_URL="http://10.10.11.6/identity"

# Reuse the existing password if the openrc already exists, so Horizon logins keep working.
if [ -f "$OPENRC" ] && grep -q '^export OS_PASSWORD=' "$OPENRC"; then
  LAB_PW=$(sed -n "s/^export OS_PASSWORD='\(.*\)'$/\1/p" "$OPENRC")
else
  LAB_PW=$(openssl rand -base64 18 | tr -d '/+=')
fi

sudo -u stack -H env LAB_PW="$LAB_PW" bash <<'EOS'
set -eo pipefail   # no -u: DevStack's openrc reads unset variables
cd /opt/stack/devstack
source openrc admin admin >/dev/null 2>&1

openstack project show lab >/dev/null 2>&1 || \
  openstack project create --domain default --description "OpenStack practice (openstack-lab)" lab >/dev/null
if openstack user show labuser >/dev/null 2>&1; then
  openstack user set --password "$LAB_PW" labuser
else
  openstack user create --domain default --project lab --password "$LAB_PW" labuser >/dev/null
fi
openstack role add --project lab --user labuser member

openstack quota set --instances 5 --cores 8 --ram 8192 \
  --volumes 5 --snapshots 5 --gigabytes 20 \
  --floating-ips 3 --networks 3 --subnets 3 --routers 2 \
  --secgroups 10 --secgroup-rules 50 lab
echo "project lab / user labuser / quota: ready"
EOS

umask 077
cat > "$OPENRC" <<EOF
# Credentials for the openstack-lab practice project. Keep this file private (mode 600).
export OS_AUTH_URL=$AUTH_URL
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_NAME=lab
export OS_PROJECT_DOMAIN_ID=default
export OS_USERNAME=labuser
export OS_USER_DOMAIN_ID=default
export OS_PASSWORD='$LAB_PW'
export OS_REGION_NAME=RegionOne
export OS_INTERFACE=public
if [ -n "\${PS1:-}" ]; then case "\$PS1" in "(lab) "*) ;; *) PS1="(lab) \$PS1" ;; esac; fi
EOF
chmod 600 "$OPENRC"
echo "wrote $OPENRC"

# shellcheck disable=SC1090
source "$OPENRC"
openstack token issue -f value -c project_id >/dev/null && echo "login as labuser: OK"
