#!/usr/bin/env bash
set -euo pipefail

# install.sh — the one command the operator runs.
#
# UX + verification only. Host/cluster setup lives in box-install.sh,
# runtime definition lives in the helm chart. This script checks prereqs,
# reads or creates config, invokes those two, smoke-tests the result, and
# writes a report file the operator can email out.
#
# Exit 0 means VERIFIED WORKING — not "script reached the end".

here="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-${here}/dist}"
# Release-download layout: all assets in one dir, installer tarball extracted
# in place — the pieces sit next to this script instead of under dist/.
if [[ ! -d "$BUNDLE_DIR" ]] && compgen -G "${here}/*.SHA256SUMS" >/dev/null; then
  BUNDLE_DIR="$here"
fi
CHART_DIR="${CHART_DIR:-${here}/chart}"
CONFIG_FILE="${CONFIG_FILE:-/etc/saleor/install.conf}"
REPORT="${REPORT:-${here}/install-report-$(date +%Y%m%d-%H%M%S).txt}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

fails=()
check() {  # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${label}" | tee -a "$REPORT"
  else
    echo "FAIL  ${label}" | tee -a "$REPORT"
    fails+=("$label")
  fi
}

[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo $0" >&2; exit 1; }

# Any failure still produces a report file — the operator always has
# something to email out, even when the install dies before verification.
on_failure() {
  local rc=$?
  trap - ERR EXIT
  [[ $rc -eq 0 ]] && exit 0
  {
    echo "saleor install report — $(date -Is)"
    echo "RESULT: FAILED before verification completed (exit ${rc})"
    echo
    kubectl get pods -o wide 2>&1 || echo "(cluster not reachable)"
    echo
    kubectl get events --sort-by=.lastTimestamp 2>/dev/null | tail -20
    for p in $(kubectl get pods --no-headers 2>/dev/null \
        | grep -vE "Running|Completed" | awk '{print $1}'); do
      echo "--- logs: $p"
      kubectl logs "$p" --tail=30 2>&1 || true
    done
  } > "$REPORT" 2>&1
  printf '\n==> RESULT: FAILED — report: %s\n' "$REPORT"
  echo "    send that file to the vendor"
  exit "$rc"
}
trap on_failure ERR EXIT

# --- [1/5] prereqs -----------------------------------------------------------
step "[1/5] checking prereqs"
[[ -d "$BUNDLE_DIR" ]] || { echo "bundle dir not found: $BUNDLE_DIR" >&2; exit 1; }
[[ -d "$CHART_DIR"  ]] || { echo "chart dir not found: $CHART_DIR" >&2; exit 1; }
sums=( "$BUNDLE_DIR"/*.SHA256SUMS )
[[ ${#sums[@]} -eq 1 && -f "${sums[0]}" ]] || {
  echo "expected exactly one .SHA256SUMS in $BUNDLE_DIR" >&2; exit 1; }
PREFIX="$(basename "${sums[0]}" .SHA256SUMS)"
avail_gb="$(df --output=avail -BG / | tail -1 | tr -dc 0-9)"
[[ "$avail_gb" -ge 10 ]] || { echo "need >=10GB free on /, have ${avail_gb}GB" >&2; exit 1; }
# Multi-node: a join.conf next to the bundle means this box joins an
# existing cluster instead of becoming one (see docs/multi-node.md).
JOIN_ROLE=""
[[ -f "$BUNDLE_DIR/join.conf" ]] \
  && JOIN_ROLE="$(sed -n 's/^ROLE=//p' "$BUNDLE_DIR/join.conf" | head -1)"
note "bundle ${PREFIX}, ${avail_gb}GB free${JOIN_ROLE:+, joining cluster as ${JOIN_ROLE}}"

# --- [2/5] config ------------------------------------------------------------
step "[2/5] config (${CONFIG_FILE})"
if [[ -n "$JOIN_ROLE" ]]; then
  note "joining box — app config and secrets live on the first server; none here"
  SALEOR_HOST="${SALEOR_HOST:-saleor.local}"   # smoke test needs the hostname
else
# Refuse to invent new secrets over an existing installation: the database
# was initialized with the old ones, and fresh values can only break auth.
# (Learned live: a config/database mismatch shows up as a crash-looping
# migration job, nothing clearer.)
if [[ ! -f "$CONFIG_FILE" ]] && command -v k3s >/dev/null 2>&1 \
   && k3s kubectl get secret saleor-secrets >/dev/null 2>&1; then
  echo "ERROR: an existing installation was found but ${CONFIG_FILE} is missing." >&2
  echo "Refusing to generate new secrets over a live database." >&2
  echo "Restore the config file from backup, or wipe first: k3s-uninstall.sh" >&2
  exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  note "none found — generating. KEEP THIS FILE: upgrades reuse it, and the"
  note "postgres password cannot be changed by rerunning this script."
  mkdir -p "$(dirname "$CONFIG_FILE")"
  ( umask 077
    cat > "$CONFIG_FILE" <<EOF
SALEOR_HOST=saleor.local
SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
EOF
  )
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"   # may set CLUSTER_VIP for HA first-server installs
fi

# --- [3/5] host + cluster ------------------------------------------------------
step "[3/5] k3s + images (box-install.sh)"
( cd "$BUNDLE_DIR" && CLUSTER_VIP="${CLUSTER_VIP:-}" "./${PREFIX}-box-install.sh" )

# Agents have no API server — their verification IS box-install's PASS; the
# cluster-side proof comes from `kubectl get nodes` on a server.
if [[ "$JOIN_ROLE" == "agent" ]]; then
  trap - ERR EXIT
  {
    echo "saleor install report — $(date -Is)"
    echo "bundle: ${PREFIX}"
    echo "role:   agent (joined $(sed -n 's/^K3S_URL=//p' "$BUNDLE_DIR/join.conf"))"
    echo "k3s-agent: $(systemctl is-active k3s-agent)"
  } > "$REPORT"
  step "RESULT: VERIFIED (agent joined) — report: ${REPORT}"
  note "confirm from any server node: kubectl get nodes"
  exit 0
fi

# --- [4/5] application -------------------------------------------------------
if [[ -n "$JOIN_ROLE" ]]; then
  step "[4/5] app — skipped (already installed cluster-wide from the first server)"
else
  step "[4/5] app (helm upgrade --install)"
  # helm --wait is silent for minutes; narrate what it's waiting on so a
  # stuck install is visible in 20s, not at the timeout.
  # Cluster installs (VIP set) get the cluster features without extra
  # flags — the config file is the contract, the operator shouldn't have
  # to repeat what it already says. That includes the replicated database:
  # fresh installs get it from birth; an existing single-instance database
  # gets the full documented cutover (dump -> bootstrap -> restore), here,
  # automatically — never silently, never without the dump first.
  cluster_flags=()
  if [[ -n "${CLUSTER_VIP:-}" ]]; then
    # Cluster sizing included: extra replicas stack on the first box and
    # the rebalancer spreads them as nodes join — scale-out IS the join.
    # Override in install.conf: API_REPLICAS / WORKER_REPLICAS.
    # Backups still land on ONE box's disk (this one) — that is all the
    # data=true label means now; the database itself is replicated.
    kubectl label node "$(hostname)" data=true --overwrite >/dev/null 2>&1 || true
    cluster_flags=(--set registry.enabled=true --set rebalance.enabled=true
                   --set postgres.ha.enabled=true
                   --set-json 'postgres.nodeSelector={"data":"true"}' 
                   --set api.replicas="${API_REPLICAS:-3}"
                   --set worker.replicas="${WORKER_REPLICAS:-2}")
    # demo/ops pacing knob, e.g. REBALANCE_SCHEDULE="*/1 * * * *" in install.conf
    [[ -n "${REBALANCE_SCHEDULE:-}" ]] \
      && cluster_flags+=(--set rebalance.schedule="$REBALANCE_SCHEDULE")
    if kubectl get sts postgres >/dev/null 2>&1 \
       && ! kubectl get cluster saleor-db >/dev/null 2>&1; then
      step "[4a/5] existing database -> replicated (automatic cutover)"
      note "taking the pre-cutover dump first"
      kubectl delete job pre-ha-dump --ignore-not-found >/dev/null 2>&1
      kubectl create job --from=cronjob/postgres-backup pre-ha-dump >/dev/null
      kubectl wait --for=condition=complete job/pre-ha-dump --timeout=180s >/dev/null
      kubectl delete job pre-ha-dump >/dev/null
      dump="$(ls -t /var/backups/saleor/saleor-*.sql.gz | head -1)"
      note "dump: ${dump}"
      helm upgrade saleor "$CHART_DIR" \
        --set host="$SALEOR_HOST" \
        --set saleor.secretKey="$SECRET_KEY" \
        --set postgres.password="$POSTGRES_PASSWORD" \
        "${cluster_flags[@]}" --no-hooks --timeout 5m >/dev/null
      note "waiting for the replicated database"
      want="$(kubectl get cluster saleor-db -o jsonpath='{.spec.instances}')"
      for _ in $(seq 1 45); do
        r="$(kubectl get cluster saleor-db -o jsonpath='{.status.readyInstances}' 2>/dev/null)"
        note "  instances ready: ${r:-0}/${want}"
        [[ "$r" == "$want" ]] && break
        sleep 10
      done
      [[ "$(kubectl get cluster saleor-db -o jsonpath='{.status.readyInstances}' 2>/dev/null)" == "$want" ]] \
        || { echo "replicated database never became ready" >&2; exit 1; }
      note "restoring the dump into the new primary"
      P="$(kubectl get pod -l cnpg.io/cluster=saleor-db,cnpg.io/instanceRole=primary -o name | head -1)"
      gunzip -c "$dump" | kubectl exec -i "${P#pod/}" -- psql -q -U postgres -d saleor >/dev/null 2>&1
      note "restored; the hooked upgrade below re-points the app"
    fi
  fi
  helm upgrade --install saleor "$CHART_DIR" \
    --set host="$SALEOR_HOST" \
    --set saleor.secretKey="$SECRET_KEY" \
    --set postgres.password="$POSTGRES_PASSWORD" \
    "${cluster_flags[@]}" \
    --timeout 15m --wait &
  helm_pid=$!
  while kill -0 "$helm_pid" 2>/dev/null; do
    sleep 20
    kill -0 "$helm_pid" 2>/dev/null || break
    pending="$(kubectl get pods --no-headers 2>/dev/null \
      | grep -vE 'Running|Completed' | awk '{printf "%s(%s) ", $1, $3}' || true)"
    note "waiting on: ${pending:-final checks}"
  done
  wait "$helm_pid"
  # post-cutover: running pods still hold the old DATABASE_URL — re-roll
  if kubectl get cluster saleor-db >/dev/null 2>&1; then
    kubectl rollout restart deploy/saleor-api deploy/saleor-worker deploy/saleor-beat >/dev/null 2>&1 || true
    kubectl rollout status deploy/saleor-api --timeout=300s >/dev/null 2>&1 || true
  fi
fi

# --- [5/5] smoke test + report -----------------------------------------------
trap - ERR EXIT   # from here on the smoke test owns reporting and exit codes
step "[5/5] smoke test"
{
  echo "saleor install report — $(date -Is)"
  echo "bundle: ${PREFIX}"
  echo "k3s:    $(k3s --version | head -1)"
  echo "helm:   $(helm version --short 2>/dev/null)"
  echo "release: $(helm list --no-headers 2>/dev/null | head -1)"
  echo
} > "$REPORT"

check "node Ready"           kubectl wait --for=condition=Ready node --all --timeout=60s
smoke_db() {
  if kubectl get cluster saleor-db >/dev/null 2>&1; then
    p="$(kubectl get pod -l cnpg.io/cluster=saleor-db,cnpg.io/instanceRole=primary -o name 2>/dev/null | head -1)"
    [[ -n "$p" ]] && kubectl exec "${p#pod/}" -- pg_isready -q
  else
    kubectl exec postgres-0 -- pg_isready -q
  fi
}
check "postgres ready"       smoke_db
check "valkey answers PING"  bash -c 'kubectl exec deploy/valkey -- valkey-cli ping | grep -q PONG'
check "migrations complete"  bash -c '[[ "$(kubectl get job saleor-migrate -o jsonpath={.status.succeeded})" == 1 ]]'
check "all pods healthy"     bash -c '! kubectl get pods --no-headers | grep -vE "Running|Completed" | grep -q .'
# Through the real ingress: TLS, Host routing. (Plain http to the pod 301s —
# production saleor enforces SSL redirect; see NOTES.md #7.)
# retried: on a freshly JOINED node the local ingress (svclb) takes ~a
# minute to start — a single early curl false-fails (seen live on node2)
graphql_smoke() {
  for _ in $(seq 1 9); do
    curl -sk -m 20 --resolve "${SALEOR_HOST}:443:127.0.0.1" \
      -X POST "https://${SALEOR_HOST}/graphql/" -H 'Content-Type: application/json' \
      -d '{"query":"{ shop { name } }"}' | grep -q '"name"' && return 0
    sleep 10
  done
  return 1
}
check "graphql answers"      graphql_smoke

{ echo; kubectl get pods -o wide; } >> "$REPORT" 2>&1

if [[ ${#fails[@]} -gt 0 ]]; then
  {
    echo; echo "=== FAILURE DETAIL ==="
    kubectl get events --sort-by=.lastTimestamp | tail -20
    for p in $(kubectl get pods --no-headers | grep -vE "Running|Completed" | awk '{print $1}'); do
      echo "--- logs: $p"
      kubectl logs "$p" --tail=30 2>&1 || true
    done
  } >> "$REPORT" 2>&1
  step "RESULT: FAILED (${#fails[@]} of 6 checks) — report: ${REPORT}"
  note "send that file to the vendor"
  exit 1
fi

# Day-two baselines exist from minute one: the operator should never have
# an install whose first backup is scheduled for 2am.
step "priming first backup + etcd snapshot (best effort)"
if kubectl get cronjob postgres-backup >/dev/null 2>&1; then
  kubectl delete job initial-backup --ignore-not-found >/dev/null 2>&1
  kubectl create job --from=cronjob/postgres-backup initial-backup >/dev/null 2>&1 \
    && kubectl wait --for=condition=complete job/initial-backup --timeout=180s >/dev/null 2>&1 \
    && kubectl delete job initial-backup >/dev/null 2>&1 \
    && note "first database backup taken" || note "backup priming skipped (see healthcheck later)"
fi
if [[ -d /var/lib/rancher/k3s/server/db/etcd ]]; then
  k3s etcd-snapshot save --name install-baseline >/dev/null 2>&1 \
    && note "etcd snapshot taken" || note "etcd snapshot skipped"
fi

step "RESULT: VERIFIED — report: ${REPORT}"
box_ip="$(awk '/node-ip/{print $2}' /etc/rancher/k3s/config.yaml 2>/dev/null || true)"
cat <<EOF

    What to do now:
    1. kubectl/helm in YOUR shell (this install ran as root):
         source ~/.bashrc
       New logins pick it up automatically.
    2. Dashboard, from a machine on this network:
         add "${box_ip:-<this-box-ip>} ${SALEOR_HOST}" to that machine's hosts file,
         then browse to https://${SALEOR_HOST}/dashboard/
         (self-signed certificate — the browser will warn once)
    3. $(if [[ -n "$JOIN_ROLE" ]]; then
         echo "Config and secrets live on the FIRST server (${CONFIG_FILE} there)."
       else
         echo "Keep ${CONFIG_FILE} safe. Upgrades reuse it; without it the"
         printf '       %s' "database credentials are unrecoverable from this script."
       fi)
    4. Email or archive the report: ${REPORT}
EOF
