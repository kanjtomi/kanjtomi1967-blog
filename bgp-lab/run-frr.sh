#!/bin/bash
# Start (or restart) the FRR container for the BGP lab on the RHEL host.
#   bash /root/bgp-lab/run-frr.sh
#
# The container gets its own LAN address (192.168.0.210) through a macvlan
# network on enp3s0, so it sits on the LAN as a separate router next to the
# Cisco. No NAT (which would break eBGP TTL/next-hop handling) and no firewalld
# change on the host. Routes FRR learns are installed only in the container's
# own network namespace, never in the host's routing table.
# Note: with macvlan the host itself cannot reach 192.168.0.210; use
# `podman exec -it frr-bgp vtysh` instead.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=quay.io/frrouting/frr:10.4.1

if ! podman network exists bgp-lan; then
  podman network create -d macvlan -o parent=enp3s0 \
    --subnet 192.168.0.0/24 --gateway 192.168.0.1 bgp-lan
fi

podman rm -f frr-bgp >/dev/null 2>&1 || true
podman run -d --name frr-bgp --hostname frr-bgp \
  --network bgp-lan --ip 192.168.0.210 \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  -v "$PWD/frr:/etc/frr:Z" \
  --restart unless-stopped \
  "$IMAGE"
