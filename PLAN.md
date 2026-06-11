# Air-gapped deploy

## The setup

I'm playing the vendor. I ship a containerized Django backend (GraphQL API, Postgres, Redis, Celery) to a customer who gives me:

- a blank bare-metal Linux server, reachable over SSH only from inside their network
- zero outbound internet from that box
- an operator who isn't an engineer, but can run one command and email me whatever it prints

I have to be able to install from a portable bundle, ship upgrades, roll back a bad upgrade, and support the install without ever SSHing in myself.

## What I'm actually deploying

[Saleor](https://github.com/saleor/saleor). It's an open-source e-commerce platform, but that's not why I picked it — the stack is: Django, GraphQL, Postgres, Redis, Celery workers, all shipped as container images. That's near enough token-for-token the stack I care about, so getting Saleor running air-gapped is a miniature of the real customer install.

Runtime is **k3s** (single-node Kubernetes), not docker compose. k3s is genuinely good for this: one binary plus an official airgap-images tarball, installs with no network at all, runs as a single systemd unit, and containerd + local-path storage + Traefik ingress come built in. Packaging unit is a Helm chart — or plain manifests if Helm fights me. I'll decide Saturday morning and not carry both.

Hardware: Initially on maybe a VirtualBox VM that I disable internet for but then I'll probably wipe an old laptop and install Ubuntu Server 24.04. That makes "bare metal" literally true. I'll need a second box or a re-wipe for the air-gapped pass.

The VM on my Mac is arm64, the old laptop is x86_64. So the install has to support **both architectures**. Everything downstream playbook, chart, install.sh, healthcheck will stay arch-independent.

## What I'm building

1. **Manual install first, by hand.** k3s installed offline (binary + airgap images), then Saleor running as k8s workloads: API, Celery worker, dashboard, Postgres on a PVC, Redis. Ingress with a self-signed cert. Survives a reboot (k3s's systemd unit gives me this). Nightly pg_dump via a CronJob.

2. **A portable bundle.** One tarball that carries everything: k3s binary, k3s airgap images, the app images (`docker save` → `ctr images import`), the Helm chart, a values/env template, and the install scripts. Has to install with zero outbound network. All on a USB drive. Built per-architecture — same build script produces an arm64 bundle (the VM) or an x86_64 one (the laptop).

3. **An Ansible playbook** that does what pass 1 did by hand. Idempotent — second run changes nothing. Roles: `base`, `k3s`, `app` (image import + chart install), `ingress`. Secrets in ansible-vault. Two modes: over SSH from my laptop (connected on-prem), and `connection: local` on the box itself (true air gap).

4. **`install.sh`** — the one command the operator runs. Checks prereqs, reads config, calls the playbook (local mode by default), then runs a smoke test: pods Ready, GraphQL answers on localhost, migrations done, DB and Redis reachable. Writes a report file either way — versions and pod status on success, log tail on failure. Exit 0 only if actually verified. Aiming for ~100 lines; it's a UX layer, no install logic lives here.

5. **Upgrade and rollback, actually demonstrated.** New version arrives as another bundle; upgrade = import images + `helm upgrade` with migrations as a hook/Job. Rollback = `helm rollback` (old images are still in containerd) plus the DB backup taken before the upgrade. Both get run for real, not just written.

6. **`healthcheck.sh`** — the day-two support loop. Something a non-engineer can run: checks pod states, disk, DB connectivity, whether last night's backup exists. Writes one report file they can carry out on USB and email me. If anything's wrong it bundles up pod logs, describes, and events into a single support tarball, one file out, success or failure.

7. **CI that builds the releases.** GitHub Actions matrix. one native amd64 runner, one arm64 — both running the same `bundle/build.sh`. Tag a version and the bundles get attached to a GitHub Release; that *is* the vendor release pipeline, and bundle v2 for the upgrade test is just the next tag.


## How it fits together

```
Laptop / GitHub Actions (build machine, has internet)
│
├── builds bundle: k3s binary + airgap images tar
│   + docker save → app image tars + Helm chart + values template
│   + playbook + install.sh  (everything travels together)
│
▼  Mode A: scp + SSH (connected on-prem — vendor has access)
▼  Mode B: USB walk-over, run locally (true air gap)
Bare-metal Ubuntu box
├── install.sh → ansible-playbook (connection: local in Mode B)
│     └── ends with smoke test → writes install report
├── systemd → k3s (single node)
│     ├── ctr images import ← bundled tarballs (no registry anywhere)
│     └── helm install saleor ← bundled chart
│           ├── saleor-api        Deployment
│           ├── saleor-worker     Deployment
│           ├── saleor-dashboard  Deployment
│           ├── postgres          StatefulSet + PVC
│           ├── redis             Deployment
│           └── migrations        Job (helm hook)
├── Traefik ingress — TLS, self-signed cert
├── CronJob — nightly pg_dump → /var/backups
└── healthcheck.sh → report file / support bundle
                          │
                          ▼  (USB out, emailed from a connected machine)
                   Vendor gets the verdict — the human courier IS the network
```

The layering rule, which is the actual judgment being demonstrated here: `install.sh` is UX and verification, Ansible is host setup and release shipping, the Helm chart is the runtime definition. Ansible doesn't micromanage pods and the shell script doesn't contain install logic.

Two flavors of "air-gapped" worth keeping straight, because people conflate them. *No outbound* (no Docker Hub, no PyPI, no telemetry) is what breaks most software and is usually what "offline install" means — in k8s terms it specifically means no image pulls ever: everything pre-imported into containerd, `imagePullPolicy` set so nothing reaches for a registry. *No inbound either* is the true air gap — the vendor never touches the machine, so the install has to verify itself and the verdict has to leave as a file someone carries. Mode B is the literal version; Mode A is the managed-on-prem variant for customers who allow vendor access.

## Done means

- A blank box with no network in either direction reaches a working install from `./install.sh` run locally, no manual fixes beyond providing config, no image ever pulled.
- The same repo builds a working bundle for both arm64 and x86_64 — arch is a build-time flag, not a fork.
- The install verifies itself — exit 0 means the smoke test passed, not that the script ran to the end.
- The playbook is idempotent and works in both SSH and local modes.
- Upgrade *and* rollback both demonstrated for real, including the failed-upgrade → rollback → restore path.
- healthcheck.sh produces something a non-engineer could email me; a forced failure produces a complete support bundle.
