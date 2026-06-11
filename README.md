# Air-gapped on-prem deploy

I'm playing a vendor shipping a containerized Django stack ([Saleor](https://github.com/saleor/saleor): GraphQL API, Postgres, Valkey, Celery) to a bare-metal box with **no internet in either direction**, and supporting it without ever touching the machine.

The setup: a blank Ubuntu server, SSH only from inside the customer's network, zero outbound, and an operator who isn't an engineer but can run one command and email back whatever it prints. Everything in this repo follows from those constraints. The plan is in [PLAN.md](PLAN.md). The stuff that actually broke while building it is in [NOTES.md](NOTES.md), which is honestly the most interesting file here.

## How it works

```
Laptop / CI (has internet)
│   bundle/build.sh --arch arm64|amd64
│   → k3s binary + airgap images, app images (docker save → zstd),
│     helm chart, install scripts, SHA256SUMS
▼   USB walk-over (or scp, same thing)
Air-gapped box
    sudo ./install.sh
    → verify checksums → k3s offline install → images into containerd
    → helm install (migrations run as a hook) → smoke test
    → RESULT: VERIFIED + a report file. Exit 0 means verified, not
      "the script finished".
```

The operator runs `./healthcheck.sh`. Eight checks, one file out, a report when healthy, a support tarball (logs, describes, events) when not. That file goes out on a USB stick and gets emailed to me. The human courier
is the network.

Upgrades are just another bundle. Images accumulate in containerd, helm keeps revisions, migrations run as a pre-upgrade hook so new code never serves against an old schema. Rollback is `helm rollback` (the old images never left the box) plus a pre-upgrade pg_dump for the cases helm can't fix, helm rolls back code, not data. See [docs/upgrade-rollback.md](docs/upgrade-rollback.md).

Every command in there has been run for real, including the deliberately broken upgrade.

## Layout

```
bundle/build.sh        builds the per-arch bundle. runs on the laptop/CI, never the box
bundle/box-install.sh  host installer: k3s + images. self-contained bash
bundle/push.sh         dev loop: rsync bundle + chart + scripts to the test box
install.sh             the one command the operator runs: config + install + smoke test + report
healthcheck.sh         day-two checks → report file or support bundle
chart/                 helm chart, the entire runtime definition
docs/                  manual install runbook, upgrade/rollback procedure
.github/workflows/     tag a version → CI builds arm64 + amd64 bundles onto a Release
```

The layering rule: `install.sh` is UX and verification, `box-install.sh` is host setup and release shipping, the chart is the runtime. The box never needs the internet for anything — `imagePullPolicy: Never` everywhere, so a violation fails loudly instead of silently pulling. There's no ansible or any config-management tool in the bundle on purpose; NOTES.md #9 is the story of why I dropped it.

## Quick start

Grab the one tarball for your arch from [Releases](../../releases), or build
it yourself on a machine with internet and docker:

```bash
./bundle/build.sh --arch amd64        # or arm64 → bundle/dist/release/<name>.tar.gz
```

Get it onto the box (USB or scp), then on the box:

```bash
tar xzf saleor-airgap-*.tar.gz
cd saleor-airgap-*/
sudo ./install.sh
```

Config gets generated into `/etc/saleor/install.conf`, keep it, upgrades need it. When it prints `RESULT: VERIFIED`, the report file next to it is the proof, and `https://saleor.local/dashboard/` works from any machine on the box's network (needs a hosts-file entry, and the cert is self-signed so the browser will complain once).

## Status

All of this has been demonstrated on an air-gapped arm64 VM (VirtualBox host-only network, no route out): one-shot install from blank → VERIFIED, survives reboot, upgrade v0.1.0 → v0.2.0, a deliberately broken upgrade that failed without taking the running stack down, rollback, and a backup restore.

Still to do: the x86_64 bare-metal pass on a real machine.
