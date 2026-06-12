#!/usr/bin/env bash
set -euo pipefail

# The host installer: runs ON the box, from inside the bundle directory.
# Self-contained bash on purpose: nothing to install before the installer.
#
#   sudo ./<prefix>-box-install.sh
#
# Roles (decided by files, not flags — see docs/multi-node.md):
#   no ./join.conf            -> first node. Becomes the server; with
#                                CLUSTER_VIP set, initializes an HA control
#                                plane (embedded etcd + kube-vip) and writes
#                                join.conf for the other boxes.
#   ./join.conf, ROLE=server  -> joins as an additional control-plane node.
#   ./join.conf, ROLE=agent   -> joins as a worker.
#
# Re-runnable: every step is safe to repeat.

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

say() { printf '\n>> %s\n' "$*"; }

sums=( *.SHA256SUMS )
[[ ${#sums[@]} -eq 1 && -f "${sums[0]}" ]] || {
  echo "expected exactly one .SHA256SUMS here — run me from the bundle dir" >&2
  exit 1
}
PREFIX="${sums[0]%.SHA256SUMS}"

# --- role -----------------------------------------------------------------
ROLE="first"
K3S_URL="" K3S_TOKEN=""
CLUSTER_VIP="${CLUSTER_VIP:-}"
# A first server's own dist dir contains the join.conf it WROTE (for other
# boxes) — don't let a re-run misread it and demote this box to a joiner.
# The cluster-init line in k3s config marks "I am the first server".
if grep -qs "^cluster-init" /etc/rancher/k3s/config.yaml; then
  CLUSTER_VIP="${CLUSTER_VIP:-$(sed -n 's/^CLUSTER_VIP=//p' ./join.conf 2>/dev/null)}"
elif [[ -f ./join.conf ]]; then
  # shellcheck source=/dev/null
  source ./join.conf            # K3S_URL, K3S_TOKEN, ROLE, CLUSTER_VIP
  [[ "$ROLE" == "server" || "$ROLE" == "agent" ]] || {
    echo "join.conf ROLE must be 'server' or 'agent', got '${ROLE}'" >&2; exit 1; }
fi
say "role: ${ROLE}${CLUSTER_VIP:+ (cluster VIP ${CLUSTER_VIP})}"

say "verifying bundle integrity (${PREFIX})"
sha256sum -c "${PREFIX}.SHA256SUMS"

say "installing k3s + helm binaries"
install -m 755 "${PREFIX}-k3s"  /usr/local/bin/k3s
install -m 755 "${PREFIX}-helm" /usr/local/bin/helm

say "staging ALL image tarballs for k3s auto-import"
# k3s imports everything in this dir at startup, into the containerd
# namespace the kubelet actually reads. Manual `ctr images import` looked
# successful but pods got ErrImageNeverPull — don't go back to it.
mkdir -p /var/lib/rancher/k3s/agent/images
cp "${PREFIX}-k3s-airgap-images.tar.zst" /var/lib/rancher/k3s/agent/images/
cp "${PREFIX}"-image-*.tar.zst /var/lib/rancher/k3s/agent/images/

say "writing k3s config (explicit node-ip — air-gapped LANs often have no"
say "default route, and k3s/flannel use it to autodetect the node IP)"
read -r iface nodeip < <(ip -4 -o addr show scope global \
  | awk '{split($4,a,"/"); print $2, a[1]; exit}')
[[ -n "${nodeip:-}" ]] || { echo "no global IPv4 address found on any interface" >&2; exit 1; }
mkdir -p /etc/rancher/k3s
{
  echo "node-ip: ${nodeip}"
  echo "flannel-iface: ${iface}"
  if [[ "$ROLE" != "agent" ]]; then
    # k3s rewrites k3s.yaml as 0600 on every start — a plain chmod doesn't
    # survive restarts/reboots; this does. Lab-box setting.
    echo 'write-kubeconfig-mode: "0644"'
  fi
  if [[ "$ROLE" == "first" && -n "$CLUSTER_VIP" ]]; then
    echo "cluster-init: true"            # embedded etcd instead of sqlite
  fi
  if [[ -n "$CLUSTER_VIP" && "$ROLE" != "agent" ]]; then
    echo "tls-san:"                      # API cert must be valid for the VIP
    echo "  - ${CLUSTER_VIP}"
  fi
} > /etc/rancher/k3s/config.yaml
echo "   using ${nodeip} on ${iface}"

# Mirror config: image pulls for these registries get served by the
# in-enclave registry (NodePort 30500 -> reachable at localhost on every
# node via kube-proxy). Image names never change. Written on every node;
# inert until the registry exists and the chart flips to IfNotPresent.
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  ghcr.io:
    endpoint: ["http://127.0.0.1:30500"]
  docker.io:
    endpoint: ["http://127.0.0.1:30500"]
  registry.k8s.io:
    endpoint: ["http://127.0.0.1:30500"]
EOF

# --- kube-vip: the floating control-plane address (first server only) ------
if [[ "$ROLE" == "first" && -n "$CLUSTER_VIP" ]]; then
  say "writing kube-vip manifest (VIP ${CLUSTER_VIP} on ${iface})"
  mkdir -p /var/lib/rancher/k3s/server/manifests
  cat > /var/lib/rancher/k3s/server/manifests/kube-vip.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-vip-role
rules:
  - apiGroups: [""]
    resources: ["services/status"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["list", "get", "watch", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list", "get", "watch", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list", "get", "watch", "update", "create"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["list", "get", "watch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
  - kind: ServiceAccount
    name: kube-vip
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: kube-vip
  template:
    metadata:
      labels:
        app: kube-vip
    spec:
      serviceAccountName: kube-vip
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - effect: NoSchedule
          operator: Exists
        - effect: NoExecute
          operator: Exists
      containers:
        - name: kube-vip
          image: ghcr.io/kube-vip/kube-vip:v1.2.0
          imagePullPolicy: Never
          args: ["manager"]
          env:
            # No default route on air-gapped boxes -> the ClusterIP
            # (10.43.0.1) route lookup fails before DNAT can rewrite it.
            # Talk to the local API server directly instead.
            - name: KUBERNETES_SERVICE_HOST
              value: "127.0.0.1"
            - name: KUBERNETES_SERVICE_PORT
              value: "6443"
            - name: vip_arp
              value: "true"
            - name: address
              value: "${CLUSTER_VIP}"
            - name: vip_interface
              value: "${iface}"
            - name: port
              value: "6443"
            - name: cp_enable
              value: "true"
            - name: cp_namespace
              value: kube-system
            - name: svc_enable
              value: "false"
            - name: vip_leaderelection
              value: "true"
          securityContext:
            capabilities:
              add: ["NET_ADMIN", "NET_RAW"]
EOF
fi

# --- in-enclave registry (first server hosts it; hostPath on this box) ------
# Multi-node only (CLUSTER_VIP set): single-node installs stay unchanged.
if [[ "$ROLE" == "first" && -n "$CLUSTER_VIP" ]]; then
  say "writing in-enclave registry manifest (NodePort 30500, storage on $(hostname))"
  mkdir -p /var/lib/rancher/k3s/server/manifests /var/lib/saleor-registry
  cat > /var/lib/rancher/k3s/server/manifests/registry.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: enclave-registry
  namespace: kube-system
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: enclave-registry
  template:
    metadata:
      labels:
        app: enclave-registry
    spec:
      nodeName: $(hostname)
      containers:
        - name: registry
          image: docker.io/library/registry:3.0.0
          imagePullPolicy: Never
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
      volumes:
        - name: data
          hostPath:
            path: /var/lib/saleor-registry
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: enclave-registry
  namespace: kube-system
spec:
  type: NodePort
  selector:
    app: enclave-registry
  ports:
    - port: 5000
      nodePort: 30500
EOF
fi

# --- run the official installer offline -----------------------------------
say "running k3s installer (offline mode, role: ${ROLE})"
chmod +x "${PREFIX}-k3s-install.sh"
SVC=k3s
case "$ROLE" in
  first)
    INSTALL_K3S_SKIP_DOWNLOAD=true "./${PREFIX}-k3s-install.sh"
    ;;
  server)
    INSTALL_K3S_SKIP_DOWNLOAD=true K3S_URL="" K3S_TOKEN="$K3S_TOKEN" \
      "./${PREFIX}-k3s-install.sh" server --server "$K3S_URL"
    ;;
  agent)
    SVC=k3s-agent
    INSTALL_K3S_SKIP_DOWNLOAD=true K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
      "./${PREFIX}-k3s-install.sh"
    ;;
esac
systemctl restart "$SVC"   # re-run case: pick up newly staged images

# --- verify, per role -------------------------------------------------------
if [[ "$ROLE" == "agent" ]]; then
  say "waiting for k3s-agent to settle (verification happens from a server)"
  active=""
  for _ in $(seq 1 24); do
    systemctl is-active --quiet k3s-agent && { active=yes; break; }
    sleep 5
  done
  [[ -n "$active" ]] || {
    echo "k3s-agent never went active; last logs:" >&2
    journalctl -u k3s-agent --no-pager | tail -25 >&2
    exit 1
  }
  say "PASS (agent): joined ${K3S_URL}. Confirm from a server: kubectl get nodes"
  exit 0
fi

say "waiting for node Ready (up to 180s)"
ready=""
for _ in $(seq 1 36); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then ready=yes; break; fi
  sleep 5
done
[[ -n "$ready" ]] || {
  echo "node never went Ready; last k3s logs:" >&2
  journalctl -u k3s --no-pager | tail -25 >&2
  exit 1
}
k3s kubectl get nodes   # version column must match the bundle's k3s

say "making kubectl/helm work for the login user (not just root)"
# Lab-box shortcut: world-readable admin kubeconfig. The real install.sh
# should revisit this (group perms or a copied ~/.kube/config).
chmod 644 /etc/rancher/k3s/k3s.yaml
if [[ -n "${SUDO_USER:-}" ]]; then
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  kline='export KUBECONFIG=/etc/rancher/k3s/k3s.yaml'
  grep -qxF "$kline" "${user_home}/.bashrc" 2>/dev/null \
    || echo "$kline" >> "${user_home}/.bashrc"
  echo "   added KUBECONFIG to ${user_home}/.bashrc (run: source ~/.bashrc)"
fi

say "waiting for app images to be visible to the kubelet (up to 120s)"
seen=0
for _ in $(seq 1 24); do
  seen=$(k3s crictl images 2>/dev/null | grep -cE 'saleor|postgres|valkey' || true)
  [[ "$seen" -ge 4 ]] && break
  sleep 5
done
k3s crictl images | grep -E 'saleor|postgres|valkey' || true
[[ "$seen" -ge 4 ]] || {
  echo "kubelet sees ${seen}/4 app images — import failed" >&2
  exit 1
}

say "verifying images are UNPACKED, not just present"
# A complete-but-unusable import is a real failure mode (NOTES.md #12):
# content all there, no snapshot, every pod dies at container-create.
bad="$(k3s ctr images check 2>/dev/null \
  | grep -E 'saleor|postgres|valkey|kube-vip|descheduler' \
  | awk '$NF == "false" {print $1}' | sort -u)"
if [[ -n "$bad" ]]; then
  echo "   not unpacked (re-import of known content skips unpacking):"
  echo "$bad" | sed 's/^/     /'
  echo "   repairing via direct platform import..."
  node_arch="$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')"
  for t in "${PREFIX}"-image-*.tar.zst; do
    zstd -dc "$t" | k3s ctr images import --platform "linux/${node_arch}" - >/dev/null 2>&1 || true
  done
  bad="$(k3s ctr images check 2>/dev/null \
    | grep -E 'saleor|postgres|valkey|kube-vip|descheduler' \
    | awk '$NF == "false" {print $1}' | sort -u)"
  if [[ -n "$bad" ]]; then
    echo "still not unpacked after repair:" >&2
    echo "$bad" >&2
    exit 1
  fi
  echo "   repaired."
fi
k3s kubectl delete pod valkey-test --ignore-not-found >/dev/null 2>&1
k3s kubectl run valkey-test --image=valkey/valkey:8.1-alpine \
  --image-pull-policy=Never --restart=Never -- sleep 3
if ! k3s kubectl wait pod/valkey-test \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s; then
  echo "litmus test FAILED:" >&2
  k3s kubectl describe pod valkey-test | tail -15 >&2
  exit 1
fi
k3s kubectl delete pod valkey-test >/dev/null

# --- first server: seed the in-enclave registry from the bundle -------------
if [[ "$ROLE" == "first" && -n "$CLUSTER_VIP" ]]; then
  say "seeding the in-enclave registry (idempotent — same blobs are no-ops)"
  install -m 755 "${PREFIX}-crane" /usr/local/bin/crane
  reg_ok=""
  for _ in $(seq 1 24); do
    curl -fsm 2 http://127.0.0.1:30500/v2/ >/dev/null 2>&1 && { reg_ok=yes; break; }
    sleep 5
  done
  if [[ -z "$reg_ok" ]]; then
    echo "   registry not answering on :30500 — seed skipped, re-run me later" >&2
  else
    for t in "${PREFIX}"-image-*.tar.zst; do
      # The fully-qualified ref rides inside the archive's index annotations
      ref="$(zstd -dc "$t" | tar -xO index.json 2>/dev/null | python3 -c '
import json, sys
try:
    idx = json.load(sys.stdin)
    for m in idx.get("manifests", []):
        n = m.get("annotations", {}).get("io.containerd.image.name")
        if n:
            print(n); break
except Exception:
    pass')"
      [[ -n "$ref" ]] || { echo "   no ref annotation in ${t} — skipped" >&2; continue; }
      path="${ref#*/}"   # mirror requests arrive without the registry host
      tmp="$(mktemp -d)"
      zstd -dc "$t" | tar -x -C "$tmp"
      # Some registries attach attestation referrers; docker save includes
      # them as a second index entry and crane refuses the ambiguity. Keep
      # only the named image entry.
      python3 - "$tmp/index.json" <<'PY'
import json, sys
p = sys.argv[1]
idx = json.load(open(p))
idx["manifests"] = [m for m in idx["manifests"]
                    if m.get("annotations", {}).get("io.containerd.image.name")]
json.dump(idx, open(p, "w"))
PY
      if crane push "$tmp" "127.0.0.1:30500/${path}" --insecure >/dev/null 2>&1; then
        echo "   seeded ${path}"
      else
        echo "   FAILED to seed ${path}" >&2
      fi
      rm -rf "$tmp"
    done
  fi
fi

# --- first server: write join.conf for the rest of the fleet ----------------
if [[ "$ROLE" == "first" && -n "$CLUSTER_VIP" ]]; then
  say "writing join.conf (carry this WITH the bundle to each new box — it"
  say "holds the cluster token; it must never travel by email)"
  token="$(cat /var/lib/rancher/k3s/server/node-token)"
  ( umask 077
    cat > ./join.conf <<EOF
# Copy this file, with the bundle, to each box joining the cluster.
# Set ROLE=server for control-plane nodes (keep the total count odd),
# ROLE=agent for workers. Then: sudo ./<prefix>-box-install.sh
K3S_URL=https://${CLUSTER_VIP}:6443
K3S_TOKEN=${token}
CLUSTER_VIP=${CLUSTER_VIP}
ROLE=server
EOF
  )
  [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" ./join.conf
fi

say "PASS (${ROLE}): node Ready, 4/4 images local, no-pull pod ran."
[[ -n "$CLUSTER_VIP" ]] && say "VIP: kubectl will answer at https://${CLUSTER_VIP}:6443 once kube-vip is up"
