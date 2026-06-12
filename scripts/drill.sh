#!/usr/bin/env bash
set -uo pipefail

# Failure drill, as a repeatable test: hard power-cut a node, verify the
# cluster reacts correctly, bring the node back, verify it rejoins.
#
#   ./drill.sh airgap-node3        # any node; expectations auto-adjust:
#                                  #   normal node -> full self-heal expected
#                                  #   data node (label data=true) -> control
#                                  #     plane survives, app degrades HONESTLY
#
# Assumes the rig from make-nodes.sh (VM name == node hostname) and that
# kubectl works on the surviving server nodes. Exit 0 = drill passed.

NODE_USER="${NODE_USER:-bobby}"
NODES="${NODES:-192.168.56.111 192.168.56.112 192.168.56.113}"
TARGET="${1:?usage: $0 <node-name, e.g. airgap-node3>}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

say()  { printf '\n== %s ==\n' "$*"; }
fail() { echo "DRILL FAILED: $*" >&2; exit 1; }

# Pick an access node that is not the target
ACCESS=""
for ip in $NODES; do
  h="$($SSH "${NODE_USER}@${ip}" hostname 2>/dev/null)" || continue
  [[ "$h" != "$TARGET" ]] && { ACCESS="$ip"; break; }
done
[[ -n "$ACCESS" ]] || fail "no reachable access node that isn't the target"
K() { $SSH "${NODE_USER}@${ACCESS}" "env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

K get node "$TARGET" >/dev/null 2>&1 || fail "node ${TARGET} not in the cluster"
is_data="$(K get node "$TARGET" -o jsonpath='{.metadata.labels.data}' 2>/dev/null)"
if [[ "$is_data" == "true" ]]; then
  say "TARGET ${TARGET} IS THE DATA NODE — expecting honest degradation, not full self-heal"
else
  say "target ${TARGET} (access via ${ACCESS}) — expecting full self-heal"
fi

say "baseline"
K get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'

say "POWER CUT ${TARGET} ($(date +%T))"
VBoxManage controlvm "$TARGET" poweroff 2>/dev/null || fail "could not power off VM ${TARGET}"
t0=$(date +%s)

say "waiting for NotReady"
for _ in $(seq 1 40); do
  K get nodes --no-headers 2>/dev/null | grep "$TARGET" | grep -q NotReady && break
  sleep 5
done
echo "  NotReady after $(( $(date +%s) - t0 ))s"

say "waiting for pod eviction + reschedule"
# Pods on a dead node linger as Terminating forever (no kubelet left to
# confirm their death) — so the heal signal is replacement readiness:
# every Deployment/StatefulSet reports full READY, ghosts ignored.
all_ready() {
  K get deploy --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2]) exit 1}' \
  && K get sts --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2]) exit 1}'
}
healed=""
if [[ "$is_data" == "true" ]]; then
  # The database is pinned to the dead node: full readiness is impossible
  # by design. Ride out the eviction window, then make the honest checks.
  echo "  data node down — waiting out the eviction window, expecting degradation"
  sleep 390
  healed=yes
else
  for _ in $(seq 1 60); do
    all_ready && { healed=yes; break; }
    sleep 10
  done
fi
echo "  reschedule state reached after $(( $(date +%s) - t0 ))s"
K get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'

say "service check (GraphQL via ${ACCESS})"
resp="$(curl -sk -m 15 --resolve "saleor.local:443:${ACCESS}" -X POST \
  https://saleor.local/graphql/ -H 'Content-Type: application/json' \
  -d '{"query":"{ shop { name } }"}' 2>/dev/null | head -c 40)"
if [[ "$is_data" == "true" ]]; then
  echo "  data node down — app MAY be down, that's the honest part: '${resp:-no answer}'"
else
  [[ "$resp" == *'"name"'* ]] || fail "GraphQL stopped answering after non-data node loss"
  echo "  still answering: ${resp}"
fi

say "control plane check (kubectl via surviving node)"
K get nodes >/dev/null 2>&1 || fail "control plane unreachable — quorum lost?"
echo "  kubectl answers; quorum held"

say "bringing ${TARGET} back"
VBoxManage startvm "$TARGET" --type headless >/dev/null 2>&1
rejoined=""
for _ in $(seq 1 60); do
  ready="$(K get nodes --no-headers 2>/dev/null | grep -c ' Ready')"
  [[ "$ready" == "3" ]] && { rejoined=yes; break; }
  sleep 10
done
[[ -n "$rejoined" ]] || fail "${TARGET} did not rejoin"
echo "  rejoined, no operator action, total drill: $(( $(date +%s) - t0 ))s"

# With the rebalancer deployed, "recovered" includes getting work back
if [[ "$is_data" != "true" ]] && K -n kube-system get cronjob descheduler >/dev/null 2>&1; then
  say "waiting for automatic rebalance onto ${TARGET} (one descheduler cycle)"
  reb=""
  for _ in $(seq 1 80); do
    cnt="$(K get pods -o wide --no-headers 2>/dev/null \
      | awk -v n="$TARGET" '$3 == "Running" && $7 == n' | wc -l | tr -d ' ')"
    [[ "$cnt" -ge 1 ]] && { reb=yes; break; }
    sleep 15
  done
  [[ -n "$reb" ]] && echo "  ${cnt} pod(s) returned to ${TARGET}, no operator action" \
    || fail "nothing rebalanced onto ${TARGET} within the window"
fi

say "final state"
sleep 20
K get pods -o wide --no-headers | awk '{print "  "$1, $3, $7}'
[[ -n "$healed" ]] || fail "pods never reached the expected post-loss state"

say "DRILL PASSED (${TARGET}$( [[ "$is_data" == "true" ]] && echo ', data-node mode'))"
