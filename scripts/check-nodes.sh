#!/usr/bin/env bash
set -uo pipefail

# Preflight for the multi-node rig: are all nodes on the same network, can
# every node reach every other node, does the air gap hold on each, and
# (if given) does the cluster VIP answer from inside?
#
#   ./check-nodes.sh                            # default: .111 .112 .113
#   ./check-nodes.sh 192.168.56.111 192.168.56.112
#   VIP=192.168.56.200 ./check-nodes.sh
#
# Run BEFORE joining nodes to a cluster — a node that can't reach its peers
# fails as a cryptic etcd error later; here it's a visible ✗ now.
# Deliberately not set -e: report everything, then verdict.

NODE_USER="${NODE_USER:-bobby}"
VIP="${VIP:-}"
NODES=("$@")
[[ ${#NODES[@]} -gt 0 ]] || NODES=(192.168.56.111 192.168.56.112 192.168.56.113)

SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
fail=0
ok()  { printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; fail=1; }

echo "== reachability from this machine =="
declare -a alive=()
for ip in "${NODES[@]}"; do
  host="$($SSH "${NODE_USER}@${ip}" hostname 2>/dev/null)"
  if [[ -n "$host" ]]; then ok "${ip}  ssh ok  (${host})"; alive+=("$ip")
  else bad "${ip}  unreachable over ssh"; fi
done

echo "== same subnet =="
declare -a subnets=()
for ip in "${alive[@]}"; do
  net="$($SSH "${NODE_USER}@${ip}" "ip -4 -o addr show scope global | awk '{print \$4; exit}'" 2>/dev/null)"
  subnets+=("${net#*.*.*}")  # crude: compare a.b.c prefix below
  printf '  %s -> %s\n' "$ip" "$net"
done
prefixes="$(for ip in "${alive[@]}"; do echo "${ip%.*}"; done | sort -u)"
[[ "$(echo "$prefixes" | wc -l | tr -d ' ')" == "1" ]] \
  && ok "all on ${prefixes}.0/24" || bad "nodes span different subnets: $(echo $prefixes)"

echo "== node-to-node mesh =="
for src in "${alive[@]}"; do
  for dst in "${alive[@]}"; do
    [[ "$src" == "$dst" ]] && continue
    if $SSH "${NODE_USER}@${src}" "ping -c1 -W2 ${dst} >/dev/null 2>&1"; then
      ok "${src} -> ${dst}"
    else
      bad "${src} -> ${dst}  BLOCKED"
    fi
  done
done

if [[ -n "$VIP" ]]; then
  echo "== cluster VIP (${VIP}) from inside =="
  for ip in "${alive[@]}"; do
    if $SSH "${NODE_USER}@${ip}" "curl -ksm 5 https://${VIP}:6443/version >/dev/null 2>&1"; then
      ok "${ip} reaches the VIP"
    else
      bad "${ip} cannot reach the VIP"
    fi
  done
fi

echo "== air gap (internet must be unreachable) =="
for ip in "${alive[@]}"; do
  if $SSH "${NODE_USER}@${ip}" "curl -m 3 -s https://ghcr.io >/dev/null 2>&1"; then
    bad "${ip} CAN REACH THE INTERNET — gap broken"
  else
    ok "${ip} gap holds"
  fi
done

echo
[[ ${#alive[@]} -eq ${#NODES[@]} && $fail -eq 0 ]] \
  && { echo "PASS: ${#NODES[@]} nodes, full mesh, gap holds."; exit 0; } \
  || { echo "FAIL: fix the ✗ lines before joining nodes to a cluster."; exit 1; }
