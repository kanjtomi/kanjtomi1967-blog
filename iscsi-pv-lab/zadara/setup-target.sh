#!/bin/bash
# Run on Zadara: ssh tomi@10.10.10.4 'sudo bash -s' < iscsi-pv-lab/zadara/setup-target.sh
# Adds one LIO iSCSI target for the home k8s cluster,
# next to (not touching) the targets Cinder (lioadm) creates for OpenStack volumes.
set -euo pipefail
VG=ubuntu-vg
LV=k8s-iscsi-pv1
IQN=iqn.2026-11.local.kanjhome.zadara:k8s-pv1
PORTAL=10.10.11.6
INITIATOR=iqn.1994-05.com.redhat:f4128de7e8e   # redhat.kanjhome.local

lvs "$VG/$LV" >/dev/null 2>&1 || lvcreate -y -L 10G -n "$LV" "$VG"

T() { targetcli "$@" 2>&1 | grep -v -e 'prefs.bin' -e dbroot -e 'warn(' || true; }
targetcli ls /backstores/block/$LV >/dev/null 2>&1 || T /backstores/block create name=$LV dev=/dev/$VG/$LV
targetcli ls /iscsi/$IQN >/dev/null 2>&1 || {
  T /iscsi create $IQN
  # replace the default 0.0.0.0 portal with the static VLAN 10 address only
  T /iscsi/$IQN/tpg1/portals delete 0.0.0.0 3260
  T /iscsi/$IQN/tpg1/portals create $PORTAL 3260
  T /iscsi/$IQN/tpg1/luns create /backstores/block/$LV
  T /iscsi/$IQN/tpg1/acls create $INITIATOR
}
T saveconfig
systemctl enable rtslib-fb-targetctl.service >/dev/null 2>&1 || true
targetcli ls /iscsi/$IQN 2>/dev/null
ss -ltn | grep 3260
