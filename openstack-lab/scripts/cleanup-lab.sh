#!/bin/bash
# Delete everything inside the "lab" project. With --all, also delete the project and labuser.
# Run as tomi on Zadara after the lab has been set up.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB_DIR/lab-openrc.sh" || { echo "lab-openrc.sh not found - run setup-lab.sh first"; exit 1; }

echo "== servers"
for id in $(openstack server list -f value -c ID); do openstack server delete --wait "$id"; done
echo "== floating ips"
for id in $(openstack floating ip list -f value -c ID); do openstack floating ip delete "$id"; done
echo "== volume snapshots"
for id in $(openstack volume snapshot list -f value -c ID); do openstack volume snapshot delete "$id"; done
for i in $(seq 1 30); do [ -z "$(openstack volume snapshot list -f value -c ID)" ] && break; sleep 2; done
echo "== volumes"
for id in $(openstack volume list -f value -c ID); do openstack volume delete "$id"; done
echo "== images owned by lab"
PID=$(openstack token issue -f value -c project_id)
for id in $(openstack image list --private -f value -c ID); do
  [ "$(openstack image show "$id" -f value -c owner)" = "$PID" ] && openstack image delete "$id"
done
echo "== routers"
for r in $(openstack router list -f value -c ID); do
  for p in $(openstack port list --router "$r" --device-owner network:router_interface -f value -c ID); do
    openstack router remove port "$r" "$p"
  done
  openstack router unset --external-gateway "$r" 2>/dev/null
  openstack router delete "$r"
done
echo "== networks"
for id in $(openstack network list --project "$PID" -f value -c ID); do openstack network delete "$id"; done
echo "== security groups (except default)"
for id in $(openstack security group list --project "$PID" -f value -c ID -c Name | awk '$2 != "default" {print $1}'); do
  openstack security group delete "$id"
done
echo "== keypairs"
for k in $(openstack keypair list -f value -c Name); do openstack keypair delete "$k"; done
rm -f ~/.ssh/lab-key ~/.ssh/lab-key.pub

if [ "${1:-}" = "--all" ]; then
  echo "== project lab and user labuser"
  sudo -u stack -H bash -c 'cd /opt/stack/devstack && source openrc admin admin >/dev/null 2>&1 && openstack user delete labuser && openstack project delete lab'
  rm -f "$LAB_DIR/lab-openrc.sh"
fi
echo "cleanup done"
