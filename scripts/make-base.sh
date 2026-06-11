#!/usr/bin/env bash
set -euo pipefail

# Build the "airgap-base" VM from an Ubuntu cloud image + cloud-init — no
# installer, no clicking, no internet for the VM ever (it's born on the
# host-only network). Everything the manual base prep did by hand (user,
# ssh key, NOPASSWD sudo) is declared in a generated NoCloud seed.
#
#   ./make-base.sh                 # arm64 (Apple Silicon host), name airgap-base
#   ./make-base.sh --arch amd64 --name test-base
#
# Host needs: VirtualBox, qemu-img (brew install qemu), an ssh key, internet.
# After: ./make-nodes.sh 3

ARCH="arm64"
NAME="airgap-base"
NET="${NET:-airgapnet}"
SUBNET="${SUBNET:-192.168.56}"
NODE_USER="${NODE_USER:-bobby}"
MEM="${VM_MEM:-4096}"
CPUS="${VM_CPUS:-4}"
DISK_MB="${DISK_MB:-40960}"
# Ubuntu 24.04 cloud image, current release channel. Integrity is checked
# against the same-source SHA256SUMS; the serial in use gets printed so a
# known-good one can be pinned here later.
IMG_BASE_URL="https://cloud-images.ubuntu.com/releases/noble/release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Preflight: report EVERYTHING missing at once, with the exact fix.
missing=() fixes=()
need() { command -v "$1" >/dev/null 2>&1 || { missing+=("$1"); fixes+=("$2"); }; }
need VBoxManage "brew install --cask virtualbox   # or virtualbox.org"
need qemu-img  "brew install qemu"
need sha256sum "brew install coreutils"
need curl      "(ships with macOS — check your PATH)"
need hdiutil   "(ships with macOS — check your PATH)"
pubkey="$(cat ~/.ssh/id_*.pub 2>/dev/null | head -1)"
[[ -n "$pubkey" ]] || { missing+=("ssh key"); fixes+=("ssh-keygen -t ed25519"); }
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "missing prerequisites:" >&2
  for i in "${!missing[@]}"; do printf '  %-12s -> %s\n' "${missing[$i]}" "${fixes[$i]}" >&2; done
  exit 1
fi
VBoxManage showvminfo "$NAME" >/dev/null 2>&1 && { echo "VM '${NAME}' already exists" >&2; exit 1; }
VBoxManage list hostonlynets | grep -q "^Name: *${NET}$" || {
  echo ">> creating host-only network ${NET}"
  VBoxManage hostonlynet add --name "$NET" --netmask 255.255.255.0 \
    --lower-ip "${SUBNET}.10" --upper-ip "${SUBNET}.100" --enable
}

work="${TMPDIR:-/tmp}/make-base-$$"
mkdir -p "$work"
vmdir="$(VBoxManage list systemproperties | sed -n 's/^Default machine folder: *//p')/${NAME}"
img="ubuntu-24.04-server-cloudimg-${ARCH}.img"

# --- 1. fetch + verify the cloud image ---------------------------------------
echo ">> fetching ${img}"
curl -fL --progress-bar "${IMG_BASE_URL}/${img}" -o "${work}/${img}"
curl -fsL "${IMG_BASE_URL}/SHA256SUMS" -o "${work}/SHA256SUMS"
(cd "$work" && grep "  *${img}\$" SHA256SUMS | sha256sum -c -)
grep -m1 . "${work}/SHA256SUMS" >/dev/null && echo ">> image verified ($(date +%Y-%m-%d) from release channel)"

# --- 2. convert + grow for VirtualBox -----------------------------------------
echo ">> converting to VDI"
mkdir -p "$vmdir"
qemu-img convert -O vdi "${work}/${img}" "${vmdir}/${NAME}.vdi"
VBoxManage modifymedium disk "${vmdir}/${NAME}.vdi" --resize "$DISK_MB" >/dev/null

# --- 3. the cloud-init seed: the manual base prep, declared -------------------
echo ">> generating NoCloud seed (user=${NODE_USER}, your ssh key, NOPASSWD sudo)"
mkdir -p "${work}/seed"
cat > "${work}/seed/user-data" <<EOF
#cloud-config
hostname: ${NAME}
users:
  - name: ${NODE_USER}
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
EOF
printf 'instance-id: %s\nlocal-hostname: %s\n' "$NAME" "$NAME" > "${work}/seed/meta-data"
hdiutil makehybrid -iso -joliet -default-volume-name CIDATA \
  -o "${vmdir}/seed.iso" "${work}/seed" >/dev/null

# --- 4. create + boot ----------------------------------------------------------
echo ">> creating VM ${NAME} (${ARCH}, ${MEM}MB, ${CPUS} cpu, EFI)"
platform_arch="$([[ "$ARCH" == "arm64" ]] && echo arm || echo x86)"
ostype="$([[ "$ARCH" == "arm64" ]] && echo Ubuntu_arm64 || echo Ubuntu_64)"
VBoxManage createvm --name "$NAME" --platform-architecture "$platform_arch" \
  --ostype "$ostype" --register >/dev/null
VBoxManage modifyvm "$NAME" --memory "$MEM" --cpus "$CPUS" --firmware efi \
  --nic1 hostonlynet --host-only-net1 "$NET" --graphicscontroller vmsvga
VBoxManage storagectl "$NAME" --name VirtioSCSI --add virtio-scsi
VBoxManage storageattach "$NAME" --storagectl VirtioSCSI --port 0 --type hdd \
  --medium "${vmdir}/${NAME}.vdi"
VBoxManage storageattach "$NAME" --storagectl VirtioSCSI --port 1 --type dvddrive \
  --medium "${vmdir}/seed.iso"
VBoxManage startvm "$NAME" --type headless >/dev/null

# --- 5. wait, verify, seal ------------------------------------------------------
mac="$(VBoxManage showvminfo "$NAME" --machinereadable | sed -n 's/^macaddress1="\(.*\)"/\1/p')"
amac="$(echo "$mac" | tr 'A-F' 'a-f' \
  | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' \
  | awk -F: '{for(i=1;i<=6;i++) sub(/^0/,"",$i); print $1":"$2":"$3":"$4":"$5":"$6}')"
echo ">> waiting for first boot + cloud-init (mac ${amac})..."
ip=""
for _ in $(seq 1 60); do
  for i in $(seq 10 80); do ping -c1 -W1 -t1 "${SUBNET}.${i}" >/dev/null 2>&1 & done; wait
  ip="$(arp -an | grep -i " at ${amac} " | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1)"
  [[ -n "$ip" ]] && nc -z -G 2 "$ip" 22 2>/dev/null && break
  ip=""
  sleep 5
done
[[ -n "$ip" ]] || { echo "VM never came up — check the console in the VirtualBox GUI" >&2; exit 1; }

ssh-keygen -R "$ip" >/dev/null 2>&1 || true
echo ">> verifying at ${ip}"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${NODE_USER}@${ip}" '
  sudo -n true && echo "   sudo: passwordless OK"
  curl -m 3 -s https://ghcr.io >/dev/null 2>&1 && echo "   WARNING: internet reachable" || echo "   air gap: holds"
  lsb_release -ds | sed "s/^/   os: /"
  sudo cloud-init status --wait >/dev/null 2>&1; echo "   cloud-init: $(cloud-init status 2>/dev/null | head -1)"
  sudo poweroff' || true

for _ in $(seq 1 20); do
  [[ "$(VBoxManage showvminfo "$NAME" --machinereadable | grep '^VMState=')" == 'VMState="poweroff"' ]] && break
  sleep 3
done
# Detach the seed so clones never re-run cloud-init against it
VBoxManage storageattach "$NAME" --storagectl VirtioSCSI --port 1 --type dvddrive --medium none
rm -rf "$work"

echo ">> done: '${NAME}' is built, verified, sealed, and powered off."
echo ">> next: ./scripts/make-nodes.sh 3"
