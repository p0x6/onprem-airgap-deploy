# Air-gapped on-prem deploy

Doing some role playing. I'm pretending I need to install ([Saleor](https://github.com/saleor/saleor): GraphQL API, Postgres, Valkey, Celery) to a bare-metal box with **no internet in either direction**. It should be more or less a 1 command install that can be done copying files from a USB to a server.

> **🆕 Multi-node.** The same bundle now builds an N-node k3s cluster.
> One command per box, the only difference being a `join.conf` file carried with the bundle. Still fully air-gapped: no internet anywhere at any point, the nodes just have to be on the same LAN.

> **🆕 HA / self-healing.** No single box whose death stops the cluster:
> etcd quorum across 3 servers, a floating virtual IP (kube-vip), pods spread across machines, an in-enclave registry (seeded from the bundle) so any pod can land on any node and find its image and the database itself is replicated: one PostgreSQL primary plus two streaming standbys (CloudNativePG), one per machine, with automatic standby promotion if the primary's machine dies. Power-cut a node and the service answers throughout, full redundancy is back in **~99 seconds**, and when the node returns the descheduler puts work back on it — no operator action anywhere in that sentence. Drills are scripted: `scripts/drill.sh <node>` kills a node for real and verifies the recovery.


The setup: a blank Ubuntu server, SSH only from inside the customer's network, zero outbound, and an operator who isn't an engineer but can run one command and email back whatever it prints. Everything in this repo follows from those constraints. The plan is in [PLAN.md](PLAN.md). The stuff that actually broke while building it is in [NOTES.md](NOTES.md), which is honestly the most interesting file here.

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

Config gets generated into `/etc/saleor/install.conf`, keep it, upgrades need it ([docs/config.md](docs/config.md) documents every line of it and of `join.conf`). When it prints `RESULT: VERIFIED`, the report file next to it is the proof.

**Multi-node:** install the first box with a VIP (`sudo CLUSTER_VIP=<free-LAN-ip> ./install.sh`) — it writes a `join.conf` next to its report. Carry that file, with the bundle, to each additional box and run the same `sudo ./install.sh`. `ROLE=server` in the file joins the control plane (keep the count odd), `ROLE=agent` joins a worker. See [docs/multi-node.md](docs/multi-node.md).

## How it works

```mermaid
flowchart TD
    subgraph BUILD["build side — has internet"]
        CI["laptop / CI<br/>bundle/build.sh --arch arm64|amd64"]
        BUNDLE["one tarball: k3s + helm + all images<br/>+ chart + scripts + SHA256SUMS"]
        CI --> BUNDLE
    end

    BUNDLE ==>|"USB walk-over (or scp)"| N1

    subgraph GAP["air-gapped LAN — no internet, ever"]
        N1["box 1: sudo ./install.sh<br/>checksums → k3s offline → images<br/>→ helm (migrations as hook) → smoke test"]
        N1 --> REPORT["RESULT: VERIFIED + report file<br/>exit 0 = verified, not 'script finished'"]
        N1 -.->|"join.conf + same bundle,<br/>same command"| N2["boxes 2..N<br/>HA: etcd quorum, kube-vip VIP,<br/>pods spread, auto-rebalance"]
        N1 --> REG["enclave registry<br/>seeded from the bundle, mirrors<br/>ghcr.io / docker.io / registry.k8s.io"]
        REG -.->|"LAN pulls, names unchanged"| N2
        HC["healthcheck.sh (day two)<br/>8 checks → report or support tarball"]
    end

    REPORT ==>|"USB out → email"| VENDOR["vendor gets the verdict —<br/>the human courier IS the network"]
    HC ==>|"USB out → email"| VENDOR
```

The operator runs `./healthcheck.sh`. Eight checks, one file out, a report when healthy, a support tarball (logs, describes, events) when not. That file goes out on a USB stick and gets emailed to me. The human courier
is the network.

Upgrades are just another bundle. Images accumulate in containerd, helm keeps revisions, migrations run as a pre-upgrade hook so new code never serves against an old schema. Rollback is `helm rollback` (the old images never left the box) plus a pre-upgrade pg_dump for the cases helm can't fix, helm rolls back code, not data. See [docs/upgrade-rollback.md](docs/upgrade-rollback.md).

Every command in there has been run for real, including the deliberately broken upgrade.

Images get a registry inside the gap: the install runs registry:3 on the first server and seeds it from the bundled tarballs (a static `crane` ships in the bundle — which doubles as an integrity check).
k3s mirrors ghcr.io / docker.io / registry.k8s.io to it, so image names never change and with `registry.enabled=true` pulls flip from Never to IfNotPresent and get answered from the LAN. Upgrades push images once instead of staging tarballs per box. `scripts/check-registry.sh` proves it. It delete an image from a node, watch a pod pull it back  then confirm the internet is still unreachable.

The database is replicated at the PostgreSQL layer, not the storage layer: CloudNativePG runs one primary and two streaming standbys, anti-affined so each lives on a different machine, each on its own local disk. The app only ever talks to the `rw` service, which always points at the current primary — when the primary's machine dies, the operator promotes a standby and the service follows. The operator itself runs two leader-elected replicas on different machines, because a single-replica operator can die with the node it was supposed to fail over.

## Layout

```
bundle/build.sh        builds the per-arch bundle. runs on the laptop/CI, never the box
bundle/box-install.sh  host installer: k3s + images + cluster roles. self-contained bash
bundle/push.sh         dev loop: rsync bundle + chart + scripts to the test boxes
install.sh             the one command the operator runs: config + install + smoke test + report
healthcheck.sh         day-two checks → report file or support bundle
chart/                 helm chart, the entire runtime definition
scripts/               test rig: clone VMs, network preflight, failure drills, registry test
docs/                  manual install runbook, upgrade/rollback, multi-node plan
.github/workflows/     tag a version → CI builds arm64 + amd64 bundles onto a Release
```

The layering rule: `install.sh` is UX and verification, `box-install.sh` is host setup and release shipping, the chart is the runtime. The box never needs the internet for anything — `imagePullPolicy: Never` everywhere on a single node, so a violation fails loudly instead of silently pulling; multi-node installs flip to `IfNotPresent` backed by the enclave registry, and the only reachable mirror is the one inside the gap. There's no ansible or any config-management tool in the bundle on purpose; NOTES.md #9 is the story of why I dropped it.

## Status

Single node, demonstrated on an air-gapped arm64 VM (VirtualBox host-only network, no route out): one-shot install from blank → VERIFIED, survives reboot, upgrade v0.1.0 → v0.2.0, a deliberately broken upgrade that failed without taking the running stack down, rollback, and a backup restore.

Multi-node, demonstrated on a 3-VM rig on the same gapped network: HA control plane (embedded etcd + kube-vip VIP), one-command joins from the same bundle, postgres pinned to a labeled data node with its backups, api spread across nodes, and a scripted power-cut drill — 99s to full redundancy with GraphQL answering throughout, automatic rejoin, automatic rebalance (descheduler), an in-enclave registry seeded from the bundle (`scripts/check-registry.sh` deletes an image from a node and watches a pod pull it back over the LAN), and a replicated 3-instance PostgreSQL cluster spread across the machines — the kill-the-primary's-machine drill is measured: standby promoted in ~89s under power loss, GraphQL answering after failover, old primary auto-resyncing as a standby on return.

Still to do: the x86_64 bare-metal pass on a real machine.
