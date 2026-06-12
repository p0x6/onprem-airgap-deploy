#!/usr/bin/env bash
set -uo pipefail

# Test the in-enclave registry, end to end. The headline check is the real
# thing: delete an image from a node's containerd, schedule a pod that needs
# it there, and verify it comes back via a LAN pull from the registry —
# the air gap never involved.
#
#   ./check-registry.sh                 # defaults to the rig nodes
#   NODES="ip ip ip" ./check-registry.sh
#
# Exit 0 = registry is serving pulls. Deliberately not set -e.

NODE_USER="${NODE_USER:-bobby}"
NODES="${NODES:-192.168.56.111 192.168.56.112 192.168.56.113}"
# Small image, quick pull, and losing it is harmless (it re-pulls):
TEST_IMAGE="${TEST_IMAGE:-docker.io/valkey/valkey:8.1-alpine}"
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

fail=0
ok()  { printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; fail=1; }

first="${NODES%% *}"
K() { $SSH "${NODE_USER}@${first}" "env KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

echo "== registry pod =="
state="$(K -n kube-system get pods -l app=enclave-registry --no-headers 2>/dev/null | awk '{print $3}')"
[[ "$state" == "Running" ]] && ok "enclave-registry Running" || bad "registry pod state: ${state:-missing}"

echo "== mirror config + reachability from every node =="
for ip in $NODES; do
  $SSH "${NODE_USER}@${ip}" "grep -q 30500 /etc/rancher/k3s/registries.yaml" 2>/dev/null \
    && ok "${ip} has registries.yaml mirrors" || bad "${ip} missing mirror config"
  $SSH "${NODE_USER}@${ip}" "curl -fsm 3 http://127.0.0.1:30500/v2/ >/dev/null" 2>/dev/null \
    && ok "${ip} reaches the registry at localhost:30500" || bad "${ip} cannot reach the registry"
done

echo "== catalog (seeded content) =="
cat_json="$($SSH "${NODE_USER}@${first}" "curl -fsm 5 http://127.0.0.1:30500/v2/_catalog" 2>/dev/null)"
repos="$(echo "$cat_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["repositories"]))' 2>/dev/null)"
echo "  catalog: ${cat_json:-unreadable}"
[[ "${repos:-0}" -ge 5 ]] && ok "${repos} repositories seeded" || bad "expected >=5 seeded repositories, found ${repos:-0}"

echo "== THE test: remove an image from a node, pull it back via the mirror =="
# Pick the last node (usually emptiest); pin the pod there.
target=""; for ip in $NODES; do target="$ip"; done
tname="$($SSH "${NODE_USER}@${target}" hostname 2>/dev/null)"
echo "  target node: ${tname} (${target})"
$SSH "${NODE_USER}@${target}" "sudo k3s ctr images rm ${TEST_IMAGE} >/dev/null 2>&1; sudo k3s ctr images ls -q | grep -q '^${TEST_IMAGE}\$'" \
  && bad "could not remove ${TEST_IMAGE} from ${tname} (in use? try another TEST_IMAGE)" \
  || ok "removed ${TEST_IMAGE} from ${tname}'s containerd"

K delete pod registry-pull-test --ignore-not-found >/dev/null 2>&1
K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: registry-pull-test}
spec:
  nodeName: ${tname}
  restartPolicy: Never
  containers:
    - name: t
      image: ${TEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "2"]
EOF
pulled=""
for _ in $(seq 1 24); do
  phase="$(K get pod registry-pull-test -o jsonpath='{.status.phase}' 2>/dev/null)"
  [[ "$phase" == "Succeeded" || "$phase" == "Running" ]] && { pulled=yes; break; }
  sleep 5
done
if [[ -n "$pulled" ]]; then
  ok "pod pulled ${TEST_IMAGE} from the enclave registry and ran"
else
  bad "pull-back failed: $(K get pod registry-pull-test --no-headers 2>/dev/null)"
  K describe pod registry-pull-test 2>/dev/null | tail -5
fi
K delete pod registry-pull-test --ignore-not-found >/dev/null 2>&1

echo "== air gap still holds =="
for ip in $NODES; do
  $SSH "${NODE_USER}@${ip}" "curl -m 3 -s https://ghcr.io >/dev/null 2>&1" \
    && bad "${ip} CAN REACH THE INTERNET" || ok "${ip} gap holds"
done

echo
[[ $fail -eq 0 ]] && { echo "PASS: the enclave registry serves pulls, gap intact."; exit 0; } \
                  || { echo "FAIL: fix the ✗ lines."; exit 1; }
