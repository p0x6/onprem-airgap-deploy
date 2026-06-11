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
check "database reachable"    kubectl exec postgres-0 -- pg_isready -q
check "valkey answers PING"   bash -c 'kubectl exec deploy/valkey -- valkey-cli ping 2>/dev/null | grep -q PONG'
check "graphql answers"       bash -c "curl -sk -m 20 --resolve ${SALEOR_HOST}:443:127.0.0.1 \
  -X POST https://${SALEOR_HOST}/graphql/ -H 'Content-Type: application/json' \
  -d '{\"query\":\"{ shop { name } }\"}' | grep -q '\"name\"'"
check "disk <90% used on /"   bash -c '[[ "$(df --output=pcent / | tail -1 | tr -dc 0-9)" -lt 90 ]]'

newest_backup="$(ls -t "$BACKUP_DIR"/saleor-*.sql.gz 2>/dev/null | head -1)"
backup_check() {
  [[ -n "$newest_backup" ]] || return 1
  gzip -t "$newest_backup" 2>/dev/null || return 1
  local age_h=$(( ($(date +%s) - $(stat -c %Y "$newest_backup")) / 3600 ))
  [[ "$age_h" -le "$MAX_BACKUP_AGE_H" ]]
}
check "recent backup (<${MAX_BACKUP_AGE_H}h, valid gzip)" backup_check

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
echo "PROBLEMS FOUND (${#fails[@]} of 8 checks failed):"
printf '  - %s\n' "${fails[@]}"
echo
echo "Email this file to the vendor: ${bundle}"
exit 1
