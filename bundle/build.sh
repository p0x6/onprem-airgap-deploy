#!/usr/bin/env bash
set -euo pipefail

# Build the air-gap install bundle for one architecture.
#
# The bundle is emitted as PIECES, not one tarball: one file per image plus
# one installer tarball. Each piece stays well under GitHub's 2GB release
# asset limit, upgrades only reship the images that changed, and the
# MANIFEST + SHA256SUMS files let install.sh verify the set is complete and
# intact before it touches the box.
#
# Usage:
#   ./build.sh --arch amd64|arm64 [--out dist]
#
# Needs: docker, curl, zstd. Runs on the laptop or in CI — same script.
# THIS DOES NOT RUN ON THE TARGET BOX.

# latest stable as of 2026-06-11 (helm pinned to the 3.x line — still actively
# released alongside 4.x, and it's what the air-gap/chart docs all target)
K3S_VERSION="v1.36.1+k3s1"
HELM_VERSION="v3.21.0"
BUNDLE_VERSION="${BUNDLE_VERSION:-dev}"

# Pinned 2026-06-11
# All saleor images publish linux/amd64 + linux/arm64 (verified via registry manifests).
IMAGES=(
  ghcr.io/saleor/saleor:3.23.9
  ghcr.io/saleor/saleor-dashboard:3.23.8
  postgres:15-alpine
  valkey/valkey:8.1-alpine
  ghcr.io/kube-vip/kube-vip:v1.2.0   # HA control-plane VIP (multi-node)
  registry.k8s.io/descheduler/descheduler:v0.36.0   # rebalance after node recovery
  docker.io/library/registry:3.0.0   # in-enclave registry (multi-node)
)
CRANE_VERSION="v0.21.6"   # seeds the in-enclave registry from the tarballs

ARCH=""
OUT="dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || {
  echo "usage: $0 --arch amd64|arm64 [--out dist]" >&2; exit 2
}

# Build-machine prereqs only — the target box needs none of these (k3s brings
# its own containerd, and helm ships in the bundle as a static binary).
for tool in docker curl zstd sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool on the build machine: $tool" >&2; exit 1
  }
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
prefix="saleor-airgap-${BUNDLE_VERSION}-${ARCH}"

# --- k3s: binary + its own airgap images -----------------------------------
k3s_url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}"
k3s_bin="k3s"
[[ "$ARCH" == "arm64" ]] && k3s_bin="k3s-arm64"
echo ">> fetching k3s ${K3S_VERSION} (${ARCH})"
curl -fL "${k3s_url}/${k3s_bin}" -o "${OUT}/${prefix}-k3s"
curl -fL "${k3s_url}/k3s-airgap-images-${ARCH}.tar.zst" \
  -o "${OUT}/${prefix}-k3s-airgap-images.tar.zst"
# official installer, run offline with INSTALL_K3S_SKIP_DOWNLOAD=true —
# it creates the systemd unit, env file, and uninstall scripts
curl -fL "https://get.k3s.io" -o "${OUT}/${prefix}-k3s-install.sh"

# --- crane: static binary, pushes tarballs into the in-enclave registry -----
echo ">> fetching crane ${CRANE_VERSION} (${ARCH})"
crane_arch="$([[ "$ARCH" == "arm64" ]] && echo arm64 || echo x86_64)"
curl -fsL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${crane_arch}.tar.gz" \
  | tar -xzO crane > "${OUT}/${prefix}-crane"
chmod +x "${OUT}/${prefix}-crane"

# --- helm: static binary, goes to the box alongside k3s ---------------------
echo ">> fetching helm ${HELM_VERSION} (${ARCH})"
curl -fsL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -xzO "linux-${ARCH}/helm" > "${OUT}/${prefix}-helm"
chmod +x "${OUT}/${prefix}-helm"

# --- app images: one piece per image ----------------------------------------
# Always save by the PLATFORM digest, never the multi-arch tag: newer docker
# can export an index-shaped archive (esp. when the registry attaches
# attestations, e.g. registry.k8s.io) whose layer chain is incomplete — it
# imports cleanly on the box, then dies at container-create with
# "parent snapshot ... does not exist". Found the hard way; see NOTES.md.
for img in "${IMAGES[@]}"; do
  safe="$(echo "$img" | tr '/:' '__')"
  echo ">> saving ${img} (linux/${ARCH})"
  repo="${img%%:*}"
  digest="$(docker manifest inspect "$img" 2>/dev/null | python3 -c "
import json, sys
try:
    m = json.load(sys.stdin)
    for e in m.get('manifests', []):
        p = e.get('platform', {})
        if p.get('architecture') == '${ARCH}' and p.get('os') == 'linux':
            print(e['digest']); break
except Exception:
    pass")"
  if [[ -n "$digest" ]]; then
    # Purge any prior pull of the multi-arch tag — a stale index in the
    # store makes docker save export 2 manifest entries (breaks crane push)
    docker image rm -f "$img" >/dev/null 2>&1 || true
    docker pull "${repo}@${digest}"
    docker tag "${repo}@${digest}" "$img"
  else
    docker pull --platform "linux/${ARCH}" "$img"   # single-platform image
  fi
  docker save "$img" | zstd -T0 -f -o "${OUT}/${prefix}-image-${safe}.tar.zst"
  docker image rm "$img" >/dev/null || true   # keep CI runner disk in check
done

# No config-management tooling ships in the bundle, deliberately: Ansible is
# a Python app, and wheels couple the bundle to the target's Python version
# (22.04=3.10, 24.04=3.12). The installer is self-contained bash instead.

# --- installer: chart + scripts ----------------------------------------------
installer_parts=()
for p in chart install.sh healthcheck.sh; do
  [[ -e "${repo_root}/${p}" ]] && installer_parts+=("$p")
done
if [[ ${#installer_parts[@]} -gt 0 ]]; then
  echo ">> packing installer: ${installer_parts[*]}"
  tar -C "$repo_root" -czf "${OUT}/${prefix}-installer.tar.gz" "${installer_parts[@]}"
else
  echo ">> WARNING: no installer assets exist yet (chart/, install.sh)" >&2
fi

# --- pass-1 box helper (manual install without the chart) -------------------
install -m 755 "$(dirname "$0")/box-install.sh" "${OUT}/${prefix}-box-install.sh"

# --- manifest + checksums ----------------------------------------------------
(cd "$OUT" && ls "${prefix}"-* > "${prefix}.MANIFEST")
(cd "$OUT" && sha256sum "${prefix}"-* > "${prefix}.SHA256SUMS")

# --- single-file release: extract anywhere, run ./install.sh -----------------
# One tar.gz per arch with everything inside, under a top-level dir. ~760MB
# today — if it ever nears GitHub's 2GB asset cap, ship the pieces instead.
echo ">> assembling release tarball"
stage_root="$(mktemp -d)"
stage="${stage_root}/${prefix}"
mkdir -p "$stage"
cp "${OUT}/${prefix}"-* "$stage/"
rm -f "${stage}/${prefix}-installer.tar.gz"
tar -xzf "${OUT}/${prefix}-installer.tar.gz" -C "$stage"   # chart/ install.sh healthcheck.sh
(cd "$stage" && ls "${prefix}"-* > "${prefix}.MANIFEST" \
             && sha256sum "${prefix}"-* > "${prefix}.SHA256SUMS")
mkdir -p "${OUT}/release"
tar -czf "${OUT}/release/${prefix}.tar.gz" -C "$stage_root" "${prefix}"
(cd "${OUT}/release" && sha256sum "${prefix}.tar.gz" > "${prefix}.tar.gz.sha256")
rm -rf "$stage_root"

echo ">> done: $(ls "$OUT" | wc -l | tr -d ' ') pieces in ${OUT}/, release tarball in ${OUT}/release/"
