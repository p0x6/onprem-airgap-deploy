#!/usr/bin/env bash
set -uo pipefail

# healthcheck.sh — the day-two support loop.
#
# Run by the operator (no arguments, no expertise):   sudo ./healthcheck.sh
# Always produces exactly ONE file to carry out and email:
#   healthy  -> healthcheck-report-<ts>.txt
#   problems -> support-bundle-<ts>.tar.gz  (report + logs + describes + events)
# Exit 0 only when every check passes.
#
# Deliberately not `set -e`: a health check must keep checking past failures.

here="$(cd "$(dirname "$0")" && pwd)"
ts="$(date +%Y%m%d-%H%M%S)"
REPORT="${here}/healthcheck-report-${ts}.txt"
CONFIG_FILE="${CONFIG_FILE:-/etc/saleor/install.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/saleor}"
MAX_BACKUP_AGE_H="${MAX_BACKUP_AGE_H:-26}"   # nightly + slack
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SALEOR_HOST=saleor.local
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

[[ $EUID -eq 0 ]] || echo "note: not running as root — k3s journal capture may be incomplete" >&2

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

{
  echo "saleor health report — $(date -Is) — host $(hostname)"
  echo "k3s: $(k3s --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
  echo
} > "$REPORT"

# --- the checks ---------------------------------------------------------------
check "k3s service active"    systemctl is-active --quiet k3s
check "node Ready"            bash -c 'kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"'
check "all pods healthy"      bash -c '! kubectl get pods --no-headers 2>/dev/null | grep -vE "Running|Completed" | grep -q .'
db_check() {
  # HA mode: CNPG cluster — require quorum of ready instances + primary up.
  if kubectl get cluster saleor-db >/dev/null 2>&1; then
    local ready want primary
    ready="$(kubectl get cluster saleor-db -o jsonpath='{.status.readyInstances}' 2>/dev/null)"
    want="$(kubectl get cluster saleor-db -o jsonpath='{.spec.instances}' 2>/dev/null)"
    primary="$(kubectl get pod -l cnpg.io/cluster=saleor-db,cnpg.io/instanceRole=primary -o name 2>/dev/null | head -1)"
    local nodes need
    nodes="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')"
    need=$(( want / 2 + 1 )); [[ "$nodes" -lt "$need" ]] && need="$nodes"
    [[ "$need" -lt 1 ]] && need=1
    [[ -n "$primary" && "${ready:-0}" -ge "$need" ]] \
      && kubectl exec "${primary#pod/}" -- pg_isready -q >/dev/null 2>&1
  else
    kubectl exec postgres-0 -- pg_isready -q >/dev/null 2>&1
  fi
}
check "database reachable"    db_check
check "valkey answers PING"   bash -c 'kubectl exec deploy/valkey -- valkey-cli ping 2>/dev/null | grep -q PONG'
check "graphql answers"       bash -c "curl -sk -m 20 --resolve ${SALEOR_HOST}:443:127.0.0.1 \
  -X POST https://${SALEOR_HOST}/graphql/ -H 'Content-Type: application/json' \
  -d '{\"query\":\"{ shop { name } }\"}' | grep -q '\"data\":{\"shop\"'"
check "disk <90% used on /"   bash -c '[[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 90 ]]'
stuck_pods_check() {
  # Pods wedged mid-deletion (e.g. evicted during a node bounce) can sit
  # forever holding a service hostage. Fix: kubectl delete pod <p> --force
  local now stuck
  now="$(date +%s)"
  stuck="$(kubectl get pods -o json 2>/dev/null | python3 -c "
import json, sys, datetime
now = $(date +%s)
try:
    pods = json.load(sys.stdin)['items']
except Exception:
    sys.exit(0)
for p in pods:
    ts = p['metadata'].get('deletionTimestamp')
    if not ts: continue
    t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    if now - t > 300:
        print(p['metadata']['name'])
")"
  [[ -z "$stuck" ]]
}
check "no pods stuck terminating >5m" stuck_pods_check

# Cluster-state backups: k3s snapshots etcd every 12h on HA servers. Only
# checked where the snapshot dir exists (HA servers) — single-node installs
# use sqlite and have no etcd to snapshot.
ETCD_SNAP_DIR=/var/lib/rancher/k3s/server/db/snapshots
# (the -d test needs root to pass — unprivileged runs skip this check)
if [[ -d "$ETCD_SNAP_DIR" ]]; then
  etcd_check() {
    local newest age_h
    newest="$(ls -t "$ETCD_SNAP_DIR" 2>/dev/null | head -1)"
    [[ -n "$newest" ]] || return 1
    age_h=$(( ($(date +%s) - $(stat -c %Y "$ETCD_SNAP_DIR/$newest")) / 3600 ))
    [[ "$age_h" -le 13 ]]
  }
  check "recent etcd snapshot (<13h)" etcd_check
fi

newest_backup="$(ls -t "$BACKUP_DIR"/saleor-*.sql.gz 2>/dev/null | head -1)"
backup_check() {
  # Not the data node? The dump files live elsewhere — ask the cluster
  # when the backup job last succeeded instead of checking local disk.
  if [[ -z "$newest_backup" ]] && kubectl get cronjob postgres-backup >/dev/null 2>&1; then
    local last age_h
    last="$(kubectl get cronjob postgres-backup -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null)"
    [[ -n "$last" ]] || return 1
    age_h=$(( ($(date +%s) - $(date -d "$last" +%s)) / 3600 ))
    [[ "$age_h" -le "$MAX_BACKUP_AGE_H" ]]
    return
  fi
  [[ -n "$newest_backup" ]] || return 1
  gzip -t "$newest_backup" 2>/dev/null || return 1
  local age_h=$(( ($(date +%s) - $(stat -c %Y "$newest_backup")) / 3600 ))
  [[ "$age_h" -le "$MAX_BACKUP_AGE_H" ]]
}
check "recent backup (<${MAX_BACKUP_AGE_H}h, valid gzip)" backup_check

total_checks="$(grep -cE '^(PASS|FAIL)' "$REPORT" 2>/dev/null || echo '?')"

# --- report footer -------------------------------------------------------------
{
  echo
  echo "backups:"; ls -lh "$BACKUP_DIR" 2>/dev/null || echo "  (none found at ${BACKUP_DIR})"
  echo; echo "pods:"; kubectl get pods -o wide 2>&1
  echo; echo "disk:"; df -h /
} >> "$REPORT" 2>&1

# --- verdict: one file out, either way -----------------------------------------
if [[ ${#fails[@]} -eq 0 ]]; then
  echo
  echo "HEALTHY — all $(grep -c '^PASS' "$REPORT") checks passed."
  echo "If asked for it, email this file: ${REPORT}"
  exit 0
fi

# Problems: assemble the support bundle (the report travels inside it).
bundle="${here}/support-bundle-${ts}.tar.gz"
work="$(mktemp -d)"
cp "$REPORT" "$work/report.txt" 2>/dev/null
{
  kubectl get all -A
  echo; kubectl get events --sort-by=.lastTimestamp | tail -50
} > "$work/cluster-state.txt" 2>&1
kubectl describe pods > "$work/describe-pods.txt" 2>&1
mkdir -p "$work/logs"
for p in $(kubectl get pods --no-headers 2>/dev/null | awk '{print $1}'); do
  kubectl logs "$p" --tail=200 > "$work/logs/${p}.log" 2>&1
  kubectl logs "$p" --previous --tail=100 > "$work/logs/${p}.previous.log" 2>/dev/null
done
journalctl -u k3s --no-pager 2>/dev/null | tail -300 > "$work/k3s-journal.txt"
df -h > "$work/disk.txt" 2>&1
tar -czf "$bundle" -C "$work" .
rm -rf "$work"
rm -f "$REPORT"   # it's inside the bundle — keep "one file out" literal

echo
echo "PROBLEMS FOUND (${#fails[@]} of ${total_checks} checks failed):"
printf '  - %s\n' "${fails[@]}"
echo
echo "Email this file to the vendor: ${bundle}"
exit 1
