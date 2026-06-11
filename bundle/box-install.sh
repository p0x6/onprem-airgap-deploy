#!/usr/bin/env bash
set -euo pipefail

# The host installer: runs ON the box, does docs/manual-install.md steps 2–5
# (everything except the chart — that's helm's job, driven by install.sh).
# Self-contained bash on purpose: nothing to install before the installer.
# Run it from inside the bundle directory:
#
#   sudo ./<prefix>-box-install.sh
#
# Re-runnable: every step is safe to repeat.

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

say() { printf '\n>> %s\n' "$*"; }

# Work out the bundle prefix from the checksums file in the current dir
sums=( *.SHA256SUMS )
[[ ${#sums[@]} -eq 1 && -f "${sums[0]}" ]] || {
  echo "expected exactly one .SHA256SUMS here — run me from the bundle dir" >&2
  exit 1
}
PREFIX="${sums[0]%.SHA256SUMS}"

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
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: ${nodeip}
flannel-iface: ${iface}
# k3s rewrites k3s.yaml as 0600 on every start — a plain chmod doesn't
# survive restarts/reboots; this does. Lab-box setting.
write-kubeconfig-mode: "0644"
EOF
echo "   using ${nodeip} on ${iface}"

say "running k3s installer (offline mode — uses the binary above)"
chmod +x "${PREFIX}-k3s-install.sh"
INSTALL_K3S_SKIP_DOWNLOAD=true "./${PREFIX}-k3s-install.sh"
systemctl restart k3s   # re-run case: pick up newly staged images

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

say "litmus test: pod with imagePullPolicy=Never"
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

say "PASS: node Ready, 4/4 images local to the kubelet, no-pull pod ran."
