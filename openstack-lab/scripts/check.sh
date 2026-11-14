#!/bin/bash
# Check the state of the openstack-lab exercises. Read-only.
# Usage: bash scripts/check.sh <2-7|all>
set -uo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$LAB_DIR/lab-openrc.sh" 2>/dev/null || { echo "lab-openrc.sh not found - run scripts/setup-lab.sh first"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  OK  $1"; PASS=$((PASS+1)); }
ng()  { echo "  NG  $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ng "$1"; fi; }

fip_of() { openstack server show "$1" -f json -c addresses 2>/dev/null | grep -oE '172\.24\.4\.[0-9]+' | head -1; }
ssh_vm() { ssh -n -i ~/.ssh/lab-key -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "cirros@$1" "$2"; }

check2() {
  echo "[02] network and router"
  chk "network lab-net exists"                       "openstack network show lab-net"
  chk "lab-subnet is 192.168.50.0/24"                "[ \"\$(openstack subnet show lab-subnet -f value -c cidr)\" = 192.168.50.0/24 ]"
  chk "lab-subnet gateway is 192.168.50.1"           "[ \"\$(openstack subnet show lab-subnet -f value -c gateway_ip)\" = 192.168.50.1 ]"
  chk "lab-router has external gateway on public"    "openstack router show lab-router -f json -c external_gateway_info | grep -q \"\$(openstack network show public -f value -c id)\""
  chk "lab-router has an interface on lab-subnet"    "openstack port list --router lab-router -f value -c 'Fixed IP Addresses' | grep -q 192.168.50.1"
}

check3() {
  echo "[03] security group and keypair"
  chk "security group lab-sg exists"                 "openstack security group show lab-sg"
  chk "lab-sg allows ICMP in"                        "openstack security group rule list lab-sg --ingress --protocol icmp -f value -c ID | grep -q ."
  chk "lab-sg allows TCP 22 in"                      "openstack security group rule list lab-sg --ingress --protocol tcp -f value -c 'Port Range' | grep -q '22:22'"
  chk "keypair lab-key is registered"                "openstack keypair show lab-key"
  chk "private key ~/.ssh/lab-key exists"            "[ -f ~/.ssh/lab-key ]"
}

check4() {
  echo "[04] instance and floating IP"
  chk "lab-vm1 is ACTIVE"                            "[ \"\$(openstack server show lab-vm1 -f value -c status)\" = ACTIVE ]"
  chk "lab-vm1 has an address on lab-net"            "openstack server show lab-vm1 -f json -c addresses | grep -q 192.168.50."
  chk "lab-vm1 uses lab-sg"                          "openstack server show lab-vm1 -f value -c security_groups | grep -q lab-sg"
  local fip; fip=$(fip_of lab-vm1)
  if [ -n "$fip" ]; then
    ok "lab-vm1 has floating IP $fip"
    chk "ping $fip"                                  "ping -c2 -W2 $fip"
    chk "ssh cirros@$fip with lab-key"               "ssh_vm $fip true"
  else
    ng "lab-vm1 has a floating IP"
  fi
}

check5() {
  echo "[05] volume"
  chk "volume lab-vol1 exists (1GB)"                 "[ \"\$(openstack volume show lab-vol1 -f value -c size)\" = 1 ]"
  chk "lab-vol1 is detached (available)"             "[ \"\$(openstack volume show lab-vol1 -f value -c status)\" = available ]"
  chk "snapshot lab-vol1-snap is available"          "[ \"\$(openstack volume snapshot show lab-vol1-snap -f value -c status)\" = available ]"
}

check6() {
  echo "[06] instance snapshot"
  chk "image lab-vm1-snap is active"                 "[ \"\$(openstack image show lab-vm1-snap -f value -c status)\" = active ]"
  chk "lab-vm2 is ACTIVE"                            "openstack server show lab-vm2 -f value -c status | grep -qE 'ACTIVE|VERIFY_RESIZE'"
  chk "lab-vm2 was booted from lab-vm1-snap"         "openstack server show lab-vm2 -f value -c image | grep -q lab-vm1-snap"
  local fip; fip=$(fip_of lab-vm2)
  if [ -n "$fip" ]; then
    chk "marker.txt survived into lab-vm2"           "ssh_vm $fip 'cat /home/cirros/marker.txt' | grep -q hello-from-vm1"
  else
    ng "lab-vm2 has a floating IP"
  fi
}

check7() {
  echo "[07] resize"
  chk "lab-vm2 flavor is m1.small"                   "openstack server show lab-vm2 -f value -c flavor | grep -q m1.small"
  chk "lab-vm2 resize is confirmed (ACTIVE)"         "[ \"\$(openstack server show lab-vm2 -f value -c status)\" = ACTIVE ]"
}

case "${1:-all}" in
  2|3|4|5|6|7) "check$1" ;;
  all) for n in 2 3 4 5 6 7; do "check$n"; done ;;
  *) echo "usage: $0 <2-7|all>"; exit 2 ;;
esac
echo "result: $PASS OK, $FAIL NG"
[ "$FAIL" -eq 0 ]
