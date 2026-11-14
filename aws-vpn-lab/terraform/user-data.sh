#!/bin/bash
# First boot: install strongSwan and the XFRM interface for the Cisco tunnel.
# The swanctl connection (with the PSK) is pushed later by scripts/configure-vpn.ps1,
# so no secret lives in user data.
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y charon-systemd strongswan-swanctl

cat > /etc/sysctl.d/90-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system

# Route-based tunnel: xfrm interface ipsec0 (if_id 42), inner 169.254.201.2/30,
# home networks routed into it. Recreated on every boot.
cat > /usr/local/sbin/xfrm-cisco-up <<'EOF'
#!/bin/bash
set -e
DEV=$(ip -4 route show default | awk '{print $5; exit}')
ip link show ipsec0 >/dev/null 2>&1 || ip link add ipsec0 type xfrm dev "$DEV" if_id 42
ip addr replace 169.254.201.2/30 dev ipsec0
ip link set ipsec0 up mtu 1400
for net in 10.10.10.0/24 10.10.11.0/24; do ip route replace "$net" dev ipsec0; done
EOF
chmod 755 /usr/local/sbin/xfrm-cisco-up

cat > /etc/systemd/system/xfrm-cisco.service <<'EOF'
[Unit]
Description=XFRM interface for the home Cisco VPN
After=network-online.target
Wants=network-online.target
Before=strongswan.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xfrm-cisco-up
ExecStop=/sbin/ip link del ipsec0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xfrm-cisco.service
systemctl enable strongswan.service
