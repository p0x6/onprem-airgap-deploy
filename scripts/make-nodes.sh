#!/usr/bin/env bash
set -euo pipefail

# Clone N air-gapped test nodes from a prepared base VM.
#
#   ./make-nodes.sh 3        -> airgap-node1..3 on the airgapnet host-only
#                               network, hostnames set, IPs printed
#
# One-time prep (docs/multi-node.md): a powered-off VM named "airgap-base"
# on airgapnet, with your ssh key installed and NOPASSWD sudo for the node
# user. Clones inherit all of it.
#
# Clones start with identical machine-ids, which means identical DHCP
# client-ids and colliding leases — so nodes are processed one at a time:
# boot, set hostname, reset machine-id, reboot, then move on.

BASE="${BASE:-airgap-base}"
NET="${NET:-airgapnet}"
SUBNET="${SUBNET:-192.168.56}"
NODE_USER="${NODE_USER:-bobby}"
# Node n gets ${SUBNET}.$((STATIC_BASE+n)) — static, outside the DHCP range
# (.10-.100). etcd members register by IP, so node IPs must never move.
# Keep ${SUBNET}.200 free: that's the kube-vip address.
STATIC_BASE="${STATIC_BASE:-110}"
# Optional sizing override for clones (etcd wants headroom), e.g. VM_MEM=4096
VM_MEM="${VM_MEM:-}"
VM_CPUS="${VM_CPUS:-}"
COUNT="${1:?usage: $0 <count>}"

# VBox "080027AABB0C" -> arp output style "8:0:27:aa:bb:c"
mac_arp_format() {
  echo "$1" | tr 'A-F' 'a-f' \
    | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' \
    | awk -F: '{for(i=1;i<=6;i++) sub(/^0/,"",$i); print $1":"$2":"$3":"$4":"$5":"$6}'
}

# Ping-sweep the subnet to populate ARP, then look the MAC up. Slow and
# dumb and reliable.
find_ip() {
  local mac="$1" ip=""
  for _ in $(seq 1 40); do
    for i in $(seq 10 80); do ping -c1 -W1 -t1 "${SUBNET}.${i}" >/dev/null 2>&1 & done
    wait
    ip="$(arp -an | grep -i " at ${mac} " | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 3
  done
  return 1
}

command -v VBoxManage >/dev/null 2>&1 || {
  echo "missing prerequisite: VBoxManage -> brew install --cask virtualbox" >&2; exit 1; }
VBoxManage showvminfo "$BASE" >/dev/null 2>&1 || {
  echo "base VM '${BASE}' not found — run ./scripts/make-base.sh first" >&2; exit 1; }
[[ "$(VBoxManage showvminfo "$BASE" --machinereadable | grep '^VMState=')" == 'VMState="poweroff"' ]] || {
  echo "base VM '${BASE}' must be powered off before cloning" >&2; exit 1; }

summary=()
for n in $(seq 1 "$COUNT"); do
  name="airgap-node${n}"
  echo "== ${name} =="

  if VBoxManage showvminfo "$name" >/dev/null 2>&1; then
    echo "   already exists — skipping clone"
  else
    VBoxManage clonevm "$BASE" --name "$name" --register
  fi
  VBoxManage modifyvm "$name" --nic1 hostonlynet --host-only-net1 "$NET" --mac-address1 auto
  [[ -n "$VM_MEM"  ]] && VBoxManage modifyvm "$name" --memory "$VM_MEM"
  [[ -n "$VM_CPUS" ]] && VBoxManage modifyvm "$name" --cpus "$VM_CPUS"

  state="$(VBoxManage showvminfo "$name" --machinereadable | grep '^VMState=' )"
  [[ "$state" == 'VMState="running"' ]] || VBoxManage startvm "$name" --type headless >/dev/null

  mac="$(VBoxManage showvminfo "$name" --machinereadable | sed -n 's/^macaddress1="\(.*\)"/\1/p')"
  amac="$(mac_arp_format "$mac")"
  echo "   waiting for DHCP (mac ${amac})..."
  ip="$(find_ip "$amac")" || { echo "   never got an IP" >&2; exit 1; }
  echo "   up at ${ip} — setting identity"

  static_ip="${SUBNET}.$((STATIC_BASE + n))"
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${NODE_USER}@${ip}" "
    iface=\$(ip -4 -o addr show scope global | awk '{print \$2; exit}')
    printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      dhcp4: false\n      addresses: [${static_ip}/24]\n' \"\$iface\" \
      | sudo tee /etc/netplan/99-static.yaml >/dev/null
    sudo chmod 600 /etc/netplan/99-static.yaml
    sudo find /etc/netplan -name '*.yaml' ! -name '99-static.yaml' -delete
    sudo touch /etc/cloud/cloud-init.disabled 2>/dev/null || true
    sudo hostnamectl set-hostname ${name}
    sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
    sudo systemd-machine-id-setup >/dev/null 2>&1
    sudo reboot" || true   # ssh drops on reboot; that's fine

  echo "   waiting for ${name} at static ${static_ip}..."
  ok=""
  for _ in $(seq 1 40); do
    nc -z -G 2 "$static_ip" 22 2>/dev/null && { ok=yes; break; }
    sleep 3
  done
  [[ -n "$ok" ]] || { echo "   ${name} never came up at ${static_ip}" >&2; exit 1; }
  ssh-keygen -R "$static_ip" >/dev/null 2>&1 || true
  echo "   ready: ${name} @ ${static_ip}"
  summary+=("${name}  ${static_ip}")
done

echo
echo "== nodes =="
printf '%s\n' "${summary[@]}"
echo
echo "air gap check (should FAIL): ssh ${NODE_USER}@<ip> 'curl -m 3 https://ghcr.io'"
