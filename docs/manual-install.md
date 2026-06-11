# Manual install (pass 1)

How to get the stack onto a blank Ubuntu box by hand, from the bundle, no
internet needed on the box. This is the procedure box-install.sh automates —
if a step isn't here, it shouldn't be in the installer either.

Assumes: Ubuntu Server 24.04, a sudo user, and the bundle pieces built by
`bundle/build.sh` for the box's architecture.

## 0. Build the bundle (on the laptop, has internet)

```bash
./bundle/build.sh --arch arm64    # VM on the Mac
./bundle/build.sh --arch amd64    # the x86 laptop
```

Pieces land in `bundle/dist/`. Everything below happens **on the box** —
nothing in this doc downloads anything.

## 1. Get the bundle over

Connected (Mode A):

```bash
scp -r bundle/dist/ user@<box-ip>:~/bundle
```

Air-gapped (Mode B): copy `dist/` to a USB stick, walk it over, mount, copy
to `~/bundle`.

All commands below run on the box, in `~/bundle`. The piece names share a
prefix — set it once (adjust version/arch to what you built):

```bash
cd ~/bundle
PREFIX=saleor-airgap-dev-arm64
```

## 2. Verify the bundle is complete and intact

```bash
sha256sum -c ${PREFIX}.SHA256SUMS
```

Every line must say `OK`. A USB stick that lied gets caught here, not at
2am inside a half-broken install.

## 3. Install k3s, fully offline

Binary into place, then the airgap images where k3s looks for them on
startup — that directory is the whole trick, k3s auto-imports any image
tarball it finds there, which is how its own pods (CoreDNS, Traefik,
local-path) start without a registry:

```bash
sudo install -m 755 ${PREFIX}-k3s /usr/local/bin/k3s
sudo mkdir -p /var/lib/rancher/k3s/agent/images
sudo cp ${PREFIX}-k3s-airgap-images.tar.zst /var/lib/rancher/k3s/agent/images/
```

Then the official installer in skip-download mode — it finds the binary
already present, touches no network, and writes the systemd unit (this is
what makes the install survive reboots):

```bash
chmod +x ${PREFIX}-k3s-install.sh
INSTALL_K3S_SKIP_DOWNLOAD=true ./${PREFIX}-k3s-install.sh
```

Wait a minute, then confirm the cluster is alive:

```bash
sudo k3s kubectl get nodes     # expect: Ready
sudo k3s kubectl get pods -A   # coredns, traefik, local-path, metrics — Running
```

To use `kubectl`/`helm` without sudo (fine for a lab box — `box-install.sh`
does this for you, including the `.bashrc` line):

```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

Skipping this is what the classic `localhost:8080 connection refused` error
from helm/kubectl means — no kubeconfig, so they aim at a default that
nothing listens on.

## 4. Install helm, import the app images

```bash
sudo install -m 755 ${PREFIX}-helm /usr/local/bin/helm

for f in ${PREFIX}-image-*.tar.zst; do
  zstd -dc "$f" | sudo k3s ctr images import -
done

sudo k3s ctr images ls | grep -E 'saleor|postgres|valkey'   # all four present
```

(`zstd` ships with Ubuntu 24.04. Alternative: drop the app tarballs into
`/var/lib/rancher/k3s/agent/images/` before step 3 and k3s imports them
itself at startup — probably what the playbook will do. Importing by hand
gives per-image feedback, better for this pass.)

## 5. Prove it's actually air-gap capable

One pod, pull policy `Never` — if the import worked this runs; if anything
still wants a registry it fails loudly:

```bash
sudo k3s kubectl run valkey-test --image=valkey/valkey:8.1-alpine \
  --image-pull-policy=Never --restart=Never -- sleep 5
sudo k3s kubectl get pod valkey-test    # Running, then Completed
sudo k3s kubectl delete pod valkey-test
```

## 6. Install the app

The chart travels in the installer piece of the bundle (or via the repo
during pass 1). Two values are required on purpose — there are no default
secrets:

```bash
helm install saleor ./chart \
  --set saleor.secretKey="$(openssl rand -hex 32)" \
  --set postgres.password="$(openssl rand -hex 16)"
kubectl get pods -w   # postgres/valkey first, migrate job, then api/worker/dashboard
```

> The chart is a pass-1 skeleton: every `TODO(pass 1)` comment in
> `chart/templates/` marks something to verify against the running app
> (env var names, health endpoint, dashboard runtime config, celery cmd).

## Reboot test

```bash
sudo reboot
# after it comes back:
sudo k3s kubectl get pods -A   # everything returns on its own
```

## Starting over / troubleshooting

- k3s logs: `journalctl -u k3s -f`
- A pod that won't start: `kubectl describe pod <name>` — if you see it
  trying to **pull**, an image is missing from the import or a tag doesn't
  match the bundle exactly.
- Full reset (the installer wrote an uninstaller): `sudo k3s-uninstall.sh`
  — removes k3s, all images, all volumes. On a VM, restoring the blank-OS
  snapshot is faster and cleaner.
