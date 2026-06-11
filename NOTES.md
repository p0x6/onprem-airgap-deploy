# NOTES

Things that broke during pass 1 and what fixed them. Setup: arm64 Ubuntu VM
in VirtualBox on my Mac, host-only network for the air gap.

## 1. ctr images import looks fine but pods can't use the images

Imported the app images with `k3s ctr images import`, `ctr images ls` showed all four, and a test pod with `imagePullPolicy: Never` still failed with ErrImageNeverPull. The kubelet doesn't see what ctr imports (different containerd namespace, and docker 29's save format might be part of it too). Fix was to stop importing by hand and just drop the tarballs into  `/var/lib/rancher/k3s/agent/images/` before k3s starts itt imports everything in that dir itself, same way it loads its own images.

Also:
check with `crictl images`, not `ctr images ls`. crictl shows what the kubelet actually sees.

## 2. My "offline" install had downloaded k3s from the internet

The node reported v1.35.5+k3s1 but the bundle ships v1.36.1. v1.35.5 is what the k3s stable channel serves, so the installer had quietly downloaded it instead of using the bundle binary (the skip-download flag wasn't in effect). Accidental but useful discovery: checking the version against the bundle is a cheap way to prove an install was actually offline.

## 3. Air gapped doesn't mean no network card

I detached the VM's network adapter to simulate the gap and k3s wouldn't run at all. It needs a real interface to bind to. Real air-gapped servers sit on a LAN with no route out, they're not cable-less. Host-only networkg in VirtualBox is the right model: I can ssh in from the Mac, but there's no path to the internet.

## 4. k3s needs a default route to figure out its own IP

Even with the host-only network up, k3s still failed to start: no default route, and k3s/flannel use the default route to autodetect the node IP. You'd never hit this on a normal network because there's always one.
Fix: write `node-ip` and `flannel-iface` into `/etc/rancher/k3s/config.yaml` (box-install.sh now does this automatically from the detected interface).

## 5. Saleor wants extra env vars in production mode, and the job hook deleted the evidence

With DEBUG=False, Saleor refuses to start without `ALLOWED_CLIENT_HOSTS` (its own variable, separate from Django's `ALLOWED_HOSTS`) and `RSA_PRIVATE_KEY` for JWT signing. The annoying part wasn't the vars, it was the debugging: the migration job crash-looped, helm waited 10 minutes on the hook, then the job's deadline deleted the failed pod *with the logs in it*, so all helm could say was "timed out". Got the real traceback by running the same container as a plain pod. The RSA key is generated in the chart now and reused on upgrades via `lookup` — a fresh key every upgrade would log everyone out.

## 6. Pre-upgrade hooks run before the new secrets exist

Added the RSA key to the secret, referenced it from the migrate job, got CreateContainerConfigError. Pre-upgrade hooks run *before* the upgrade applies the new manifests, so the new secret key wasn't in the cluster yet when the job started. Fix: make the secret itself a hook with a lower weight so it lands first. One extra gotcha inside the fix: the upgrade that converted the secret into a hook also deleted it at the end (helm prunes resources that leave the release, and hooks aren't part of the release), so it took one more upgrade to heal itself.

## 7. Saleor 301s plain http when DEBUG=False

First GraphQL curl came back `301 -> https`. Production Saleor forces SSL redirect — correct behind the TLS ingress (traefik sends
X-Forwarded-Proto), but a smoke test that hits the pod directly over http has to send that header itself or it looks like a failure when nothing is wrong. install.sh's smoke test needs this baked in.

## 8. chmod on the kubeconfig doesn't survive restarts

k3s regenerates k3s.yaml with 0600 on every service start, so my chmod 644 quietly vanished at the first reboot and everything run as the normal user got permission denied. The real setting is `write-kubeconfig-mode: "0644"` in /etc/rancher/k3s/config.yaml the box-install.sh writes it now. Another case of "fixed it once by hand" not being fixed at all on a box that has to survive unattended reboots.

## 9. Shipping the config-management tool is harder than shipping the app

Planned an Ansible playbook that would also run locally on the box for the true air-gap mode. Dropped it: Ansible is a Python app, so bundling it means shipping wheels that match the target's Python exactly — and my "24.04" VM turned out to be 22.04 with Python 3.10, which would have silently broken wheels built for 3.12. The container images don't care about any of this, which is the whole point of containers. Kept the install as self-contained bash (what real vendors ship into air gaps) and left Ansible as what it actually is in these environments: the customer's fleet tool, run inside their enclave with their own mirrors.

## 10. --reuse-values ignores the new chart's defaults

Added new values keys in chart 0.3.0 (replicas/autoscaling blocks) and upgraded with `--reuse-values` like always — template exploded with a nil pointer, because that flag replays the old release's values and never sees the new chart's defaults. The fix is `--reset-then-reuse-values` (new defaults underneath, old overrides on top). Notably the operator path was never exposed: install.sh passes explicit values every time, so only my dev shortcut could hit this.

## 11. Rollback doesn't clean up the failed upgrade's hook job

The migrate job was hooked on post-install,pre-upgrade. `helm rollback` is neither, so after the broken-image upgrade the dead ErrImageNeverPull pod just sat there through a successful rollback and healthcheck flagged the cluster as unhealthy when it wasn't. Added pre-rollback to the hook list: rollbacks now re-run migrations from the good revision and the before-hook-creation policy sweeps the corpse.
