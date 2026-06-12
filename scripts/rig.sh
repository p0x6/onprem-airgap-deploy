#!/usr/bin/env bash
set -uo pipefail

# Rig power management — the knob for "just turn them back on".
#
#   ./rig.sh status                  # VM state + cluster view
#   ./rig.sh start  [node ...]       # power on (default: all), wait for Ready
#   ./rig.sh stop   [node ...]       # graceful ACPI shutdown
#   ./rig.sh restart [node ...]      # stop, then start, then wait
#
# Nodes default to airgap-node1..3. Waiting for Ready needs at least two
# servers up (quorum) — the script says so instead of hanging.

NODES_DEFAULT="airgap-node1 airgap-node2 airgap-node3"
ACCESS="${ACCESS:-192.168.56.111}"
NODE_USER="${NODE_USER:-bobby}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

cmd="${1:-status}"; shift || true
nodes=("$@"); [[ ${#nodes[@]} -gt 0 ]] || read -ra nodes <<< "$NODES_DEFAULT"

vmstate() { VBoxManage showvminfo "$1" --machinereadable 2>/dev/null | grep '^VMState=' | cut -d'"' -f2; }

k_nodes() {
  for ip in 111 112 113; do
    out="$($SSH "${NODE_USER}@192.168.56.${ip}" \
      'env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes --no-headers' 2>/dev/null)" \
      && { echo "$out"; return 0; }
  done
  return 1
}

case "$cmd" in
  status)
    for n in $(echo "$NODES_DEFAULT"); do printf '  %-14s %s\n' "$n" "$(vmstate "$n" || echo unknown)"; done
    echo "  cluster:"
    k_nodes 2>/dev/null | sed 's/^/    /' || echo "    (API unreachable — fewer than 2 servers up?)"
    ;;
  start|restart)
    if [[ "$cmd" == "restart" ]]; then
      for n in "${nodes[@]}"; do
        [[ "$(vmstate "$n")" == "running" ]] && { echo "stopping ${n}"; VBoxManage controlvm "$n" acpipowerbutton 2>/dev/null; }
      done
      for n in "${nodes[@]}"; do
        for _ in $(seq 1 30); do [[ "$(vmstate "$n")" == "poweroff" ]] && break; sleep 2; done
      done
    fi
    for n in "${nodes[@]}"; do
      [[ "$(vmstate "$n")" == "running" ]] && { echo "${n} already running"; continue; }
      echo "starting ${n}"
      VBoxManage startvm "$n" --type headless >/dev/null 2>&1
      sleep 3
      [[ "$(vmstate "$n")" == "running" ]] || { echo "  retry"; sleep 5; VBoxManage startvm "$n" --type headless 2>&1 | tail -1; }
    done
    echo "waiting for cluster Ready (needs >=2 servers for quorum)..."
    for i in $(seq 1 40); do
      ready="$(k_nodes 2>/dev/null | grep -c ' Ready' || true)"
      [[ "${ready:-0}" -ge 1 ]] && printf '  %s/3 Ready (%ss)\n' "$ready" "$((i*10))"
      [[ "${ready:-0}" == "3" ]] && { echo "all Ready."; exit 0; }
      sleep 10
    done
    echo "not all nodes Ready — ./rig.sh status for details"
    exit 1
    ;;
  stop)
    for n in "${nodes[@]}"; do
      echo "stopping ${n}"; VBoxManage controlvm "$n" acpipowerbutton 2>/dev/null
    done
    ;;
  *) echo "usage: $0 status|start|stop|restart [node ...]" >&2; exit 2 ;;
esac
