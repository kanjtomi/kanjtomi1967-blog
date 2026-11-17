#!/bin/bash
# Run on Zadara: ssh tomi@10.10.11.6 'sudo bash -s' < smb-csi-lab/zadara/setup-smb.sh
# Creates a 20 GiB LV at /srv/smb/k8s and shares it over SMB as //10.10.11.6/k8s
# for the RHEL k8s node only, as the local user k8s-smb. The password is
# generated once and kept only in /root/k8s-smb-password.txt (and in the k8s
# Secret smb-csi-lab/smb-creds). Safe to run more than once.
set -euo pipefail
VG=ubuntu-vg; LV=k8s-smb; SIZE=20G; DIR=/srv/smb/k8s; USER_=k8s-smb
PWFILE=/root/k8s-smb-password.txt; SHARECONF=/etc/samba/k8s-share.conf

if ! lvs "$VG/$LV" >/dev/null 2>&1; then
  lvcreate -n "$LV" -L "$SIZE" "$VG"
  mkfs.xfs -L k8s-smb "/dev/$VG/$LV"
fi
mkdir -p "$DIR"
UUID=$(blkid -s UUID -o value "/dev/$VG/$LV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $DIR xfs defaults,nofail 0 2" >> /etc/fstab
mountpoint -q "$DIR" || mount "$DIR"

DEBIAN_FRONTEND=noninteractive apt-get install -y -q samba >/dev/null
id "$USER_" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_"
chown "$USER_:$USER_" "$DIR"; chmod 0770 "$DIR"

if [ ! -s "$PWFILE" ]; then
  umask 077; openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-24 > "$PWFILE"
fi
PW=$(cat "$PWFILE")
printf '%s\n%s\n' "$PW" "$PW" | smbpasswd -a -s "$USER_" >/dev/null
smbpasswd -e "$USER_" >/dev/null

cat > "$SHARECONF" <<CONF
# k8s smb-csi-lab share (managed by smb-csi-lab/zadara/setup-smb.sh)
[k8s]
   path = $DIR
   valid users = $USER_
   force user = $USER_
   read only = no
   browseable = no
   create mask = 0664
   directory mask = 0775
   hosts allow = 192.168.0.200 127.0.0.1
   hosts deny = ALL
CONF
grep -qxF "include = $SHARECONF" /etc/samba/smb.conf || printf '\ninclude = %s\n' "$SHARECONF" >> /etc/samba/smb.conf
testparm -s >/dev/null 2>&1 || { echo "testparm failed"; exit 1; }
systemctl disable --now nmbd >/dev/null 2>&1 || true   # NetBIOS name service is not needed
systemctl enable smbd >/dev/null; systemctl restart smbd
smbclient -L localhost -U "$USER_%$PW" -m SMB3 2>/dev/null | grep -E "^\s+k8s" || true
df -h "$DIR"
