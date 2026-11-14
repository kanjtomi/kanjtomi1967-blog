#!/bin/bash
# Container entrypoint for the strongSwan pod.
# Builds the route-based tunnel side, then runs charon and loads the config.
# Idempotent: the pod's network namespace survives container restarts, so
# everything below must tolerate already-existing interfaces/addresses/routes.
set -euo pipefail

# The strongSwan project's own image (strongx509/strongswan) is built without
# IKEv1, so this runs on Alpine, whose strongswan package has both IKEv1 and
# IKEv2. Installed at start instead of building an image (no podman/registry);
# needs outbound internet through the pod's normal eth0. iproute2 is required
# because busybox `ip` cannot create xfrm interfaces.
command -v swanctl >/dev/null || apk add --no-cache -q strongswan iproute2

# Tunnel interface (Linux counterpart of the Cisco's Tunnel10). Packets routed
# into ipsec0 are encrypted by the SA with if_id 42; ESP leaves via net1.
ip link del ipsec0 2>/dev/null || true
ip link add ipsec0 type xfrm dev net1 if_id 42
ip addr replace 169.254.200.2/30 dev ipsec0
# 1400 leaves room for ESP + outer IP headers inside a 1500-byte LAN frame.
ip link set ipsec0 mtu 1400 up

# Test network behind this end, and the route to the Cisco's test network.
ip addr replace 172.16.12.1/24 dev lo
ip route replace 172.16.11.0/24 dev ipsec0

/usr/lib/strongswan/charon &
CHARON_PID=$!

for _ in $(seq 1 30); do
  swanctl --stats >/dev/null 2>&1 && break
  sleep 1
done
swanctl --load-all

wait "$CHARON_PID"
