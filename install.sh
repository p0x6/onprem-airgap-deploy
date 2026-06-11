#!/usr/bin/env bash
set -euo pipefail

# install.sh — the one command the operator runs.
#
# UX + verification only. Host/cluster setup lives in the installer
# (box-install.sh today; the ansible playbook will take its place), runtime
# definition lives in the helm chart. This script checks prereqs, reads or
# creates config, invokes those two, smoke-tests the result, and writes a
# report file the operator can email out.
#
# Exit 0 means VERIFIED WORKING — not "script reached the end".

here="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-${here}/dist}"
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
note "bundle ${PREFIX}, ${avail_gb}GB free"

# --- [2/5] config ------------------------------------------------------------
step "[2/5] config (${CONFIG_FILE})"
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
source "$CONFIG_FILE"

# --- [3/5] host + cluster (the playbook's slot) ------------------------------
step "[3/5] k3s + images (box-install.sh)"
( cd "$BUNDLE_DIR" && "./${PREFIX}-box-install.sh" )

# --- [4/5] application -------------------------------------------------------
step "[4/5] app (helm upgrade --install)"
helm upgrade --install saleor "$CHART_DIR" \
  --set host="$SALEOR_HOST" \
  --set saleor.secretKey="$SECRET_KEY" \
  --set postgres.password="$POSTGRES_PASSWORD" \
  --timeout 15m --wait

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
check "postgres ready"       kubectl exec postgres-0 -- pg_isready -q
check "valkey answers PING"  bash -c 'kubectl exec deploy/valkey -- valkey-cli ping | grep -q PONG'
check "migrations complete"  bash -c '[[ "$(kubectl get job saleor-migrate -o jsonpath={.status.succeeded})" == 1 ]]'
check "all pods healthy"     bash -c '! kubectl get pods --no-headers | grep -vE "Running|Completed" | grep -q .'
# Through the real ingress: TLS, Host routing. (Plain http to the pod 301s —
# production saleor enforces SSL redirect; see NOTES.md #7.)
check "graphql answers"      bash -c "curl -sk -m 20 --resolve ${SALEOR_HOST}:443:127.0.0.1 \
  -X POST https://${SALEOR_HOST}/graphql/ -H 'Content-Type: application/json' \
  -d '{\"query\":\"{ shop { name } }\"}' | grep -q '\"name\"'"

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
    3. Keep ${CONFIG_FILE} safe. Upgrades reuse it; without it the
       database credentials are unrecoverable from this script.
    4. Email or archive the report: ${REPORT}
EOF
