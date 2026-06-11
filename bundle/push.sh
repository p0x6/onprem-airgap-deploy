#!/usr/bin/env bash
set -euo pipefail

# Dev courier: sync the bundle pieces + chart to the box over the host-only
# network. Stand-in for the USB walk-over while iterating.
#
# Usage: ./push.sh [user@host]     (default: bobby@192.168.56.11)

TARGET="${1:-bobby@192.168.56.11}"
cd "$(dirname "$0")/dist"

# Refresh checksums first — box-install.sh is a symlink here and edits to it
# would otherwise make the SHA256SUMS stale on the box.
sums=( *.SHA256SUMS )
PREFIX="${sums[0]%.SHA256SUMS}"
sha256sum "${PREFIX}"-* > "${PREFIX}.SHA256SUMS"

rsync -av --copy-links ./ "${TARGET}:dist/"
rsync -av --delete ../../chart/ "${TARGET}:chart/"
rsync -av ../../install.sh ../../healthcheck.sh "${TARGET}:"

echo ">> pushed. On the box: sudo ./dist/${PREFIX}-box-install.sh"
echo ">>        then:        helm install saleor ./chart ..."
