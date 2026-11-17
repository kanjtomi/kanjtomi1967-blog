#!/bin/bash
# Run on Zadara: ssh tomi@10.10.11.6 'sudo bash -s' < nfs-csi-lab/zadara/setup-nfs.sh
# Creates a 20 GiB LV, mounts it at /srv/nfs/k8s and exports it over NFS to the
# RHEL k8s node only. Safe to run more than once.
set -euo pipefail
VG=ubuntu-vg; LV=k8s-nfs; SIZE=20G; DIR=/srv/nfs/k8s; CLIENT=192.168.0.200

if ! lvs "$VG/$LV" >/dev/null 2>&1; then
  lvcreate -n "$LV" -L "$SIZE" "$VG"
  mkfs.xfs -L k8s-nfs "/dev/$VG/$LV"
fi
mkdir -p "$DIR"
UUID=$(blkid -s UUID -o value "/dev/$VG/$LV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $DIR xfs defaults,nofail 0 2" >> /etc/fstab
mountpoint -q "$DIR" || mount "$DIR"

DEBIAN_FRONTEND=noninteractive apt-get install -y -q nfs-kernel-server >/dev/null
# no_root_squash: csi-driver-nfs creates and deletes one sub-directory per PV as root
EXPORT="$DIR $CLIENT(rw,sync,no_subtree_check,no_root_squash)"
grep -qxF "$EXPORT" /etc/exports || echo "$EXPORT" >> /etc/exports
systemctl enable --now nfs-server >/dev/null
exportfs -ra
exportfs -v
df -h "$DIR"
