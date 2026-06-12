# Multi-node: plan

Next implementation.

Goal: the same air-gapped install, but across several Ubuntu boxes forming one **HA** k3s cluster. No single box whose death stops the cluster. Everything stays offline. Nodes only ever talk to each other over the LAN.

## What stays the same

- The bundle, build.sh, CI — untouched. Same pieces go to every node.
- The chart — zero edits for scheduling; the replicas/autoscaling config from 0.3.0 becomes real capacity instead of concurrency management.
- healthcheck.sh — kubectl sees the whole cluster from the server node.
- The no-default-route/node-ip lesson — applies to every node, already handled by box-install.sh writing config.yaml per node.

## The three new problems

1. **Images must exist on every node.** Each node has its own containerd, and `imagePullPolicy: Never` means a pod scheduled onto a node without the image just dies. v1 answer: stage the same tarballs into `/var/lib/rancher/k3s/agent/images/` on every node (it's what the install already does — just do it everywhere).

The grown-up answer at
>3 nodes is a private registry inside the enclave (registry:2 seeded from the bundle, nodes pull over the LAN via registries.yaml) 

2. **Storage is node-pinned.** local-path PVCs live on one node's disk. v1 answer: label one box the data node and pin postgres to it with a nodeSelector. Distributed storage (Longhorn) only if node-loss-survival for the DB becomes a requirement. Postgres prefers its own replication anyway.

3. **The control plane needs a quorum and a stable address.** One server = the cluster dies with it. HA means 3 server nodes with replicated embedded etcd — quorum is a majority, so odd numbers only, and 3 tolerates losing exactly one. (2 servers is *worse* than 1: a majority of 2 is 2, so either box dying stops etcd.) And with three servers, "the server's IP" stops being a thing — agents, kubeconfigs, and operators need a virtual IP that floats to a live server: **kube-vip**, ARP-based, works on a plain LAN with no internet, costs one more image in the bundle. The API cert needs the VIP as a SAN (`tls-san` in k3s config) or kubectl will refuse it.

## Phases

**Local test rig.** Three VMs on the same host-only network (192.168.56.0/24, no internet path). `scripts/make-nodes.sh` clones them from a prepared base VM — see "Test rig prep" below.

Acceptance: 3 boxes, each reachable over ssh from the Mac, none able to reach the internet.

**Join support in the installer.** The first install runs as today plus `cluster-init: true` (embedded etcd instead of SQLite), and once its node is Ready it writes a `join.conf` (the cluster URL — the VIP once it exists — + the token from `/var/lib/rancher/k3s/server/node-token`, + `ROLE=server|agent`) next to the install report. Adding a node = copy the bundle *and that one file* to the new box, set ROLE, run the same `sudo ./install.sh`.

join.conf present with ROLE=agent -> stage binary + images, join as agent, skip helm/chart (apps install once, from the first server).

join.conf present with ROLE=server -> same, but join as an additional control-plane node (k3s handles etcd replication itself).

Absent -> today's behavior, become the first server.

Why a file, not the report or a flag or a prompt: the report gets *emailed* — a join token is a credential and must never ride in it; join.conf stays on the USB path, which is already the trust boundary, and nobody has to transcribe a 100-char token by hand on an air-gapped site. The file is also the role declaration, so install.sh stays a zero-argument, non-interactive command — prompts would add operator-created failure modes, leave no record (the config file *is* the record), and break the scripted from-blank tests and the ssh loop for joining nodes. If a genuinely human choice ever shows up: prompt only when the value is missing AND stdin is a TTY, write the answer into the config, never ask again.

Acceptance: `kubectl get nodes` on the server shows 3 Ready nodes, installed from the same bundle, no internet.

**HA control plane.** All three rig nodes install with ROLE=server (k3s servers also run workloads, so no capacity is wasted). kube-vip goes in as a host-layer concern, not a chart concern: build.sh adds its image to the bundle, box-install.sh drops its manifest into `/var/lib/rancher/k3s/server/manifests/` (k3s auto-applies that dir) on server nodes, and the VIP address becomes a config value (something outside the DHCP range, e.g. 192.168.56.200). k3s config gains `tls-san: <VIP>` so the API cert is valid for it. join.conf and the operator's kubeconfig point at the VIP, never at a node. etcd snapshots (k3s takes them automatically on servers) get added to the backup CronJob's hostPath so the support loop carries cluster state out, not just the database.

Acceptance: `kubectl` works against the VIP; power off ANY ONE node and kubectl still answers, the VIP has moved, and scheduling still works.

**Pin postgres, spread the rest.** Chart: `postgres.nodeSelector` value (default empty = single-node unchanged); label the server node `data=true`. Backup CronJob pins with it (same hostPath node as the PVC). Scale api to 3 with the HPA. Acceptance: api pods land on different nodes (`kubectl get pods -o wide`), GraphQL still answers via any node's IP (traefik's svclb listens on all of them).

**The failure drills.** Two of them, because they prove different things.

Drill 1: kill a non-data node mid-traffic. Acceptance: api pods reschedule onto survivors (images are there — that's the point of staging them everywhere), GraphQL keeps answering, kubectl via the VIP never blinks, healthcheck reports the lost node. Bring it back, watch it rejoin with no operator action. This is the self-healing claim, demonstrated.

Drill 2: kill the DATA node. Acceptance is honesty: the control plane survives (VIP moves, kubectl fine), api pods reschedule and then crash-loop because the database is gone, healthcheck says exactly that, and recovery is the documented restore (new pin label, pg dump restore). This drill exists to show where self-healing ENDS until the storage phase — and to have rehearsed the recovery.

**In-enclave registry (committed, next).** Per-node tarball staging officially got old: one image restaged to three nodes three times in a day.

The design:
registry:2 as a host-layer manifest pinned to the data node (hostPath storage), exposed cluster-wide via NodePort so every node reaches it at localhost. k3s `registries.yaml` on every node sets the local registry as a MIRROR for ghcr.io / registry.k8s.io / docker.io — image names in the chart don't change at all. The bundle gains a static `crane` binary; the install seeds the registry by pushing the bundled tarballs once. The chart's pull policy flips to IfNotPresent when `registry.enabled`: a node missing an image pulls it from the mirror over the LAN. Trade being accepted: the loud-failure property of `Never` softens — the real enforcement is that the gap has no route out anyway. Bootstrap stays tarball-based (k3s's own images + the registry image itself arrive by file, as today).

**Self-healing data**
The shape: CNPG operator + its postgres image in the bundle, the chart's postgres StatefulSet replaced by a CNPG Cluster (2–3 instances, anti-affinity across nodes, each on its own local-path volume, streaming replication between them), app DATABASE_URL pointed at the rw service. The pg_dump CronJob stays (now against the rw service); the data=true label keeps meaning "where backup files land on disk."

**Quick win, immediately: etcd snapshots into the support story.** k3s already snapshots etcd every 12h on the servers (/var/lib/rancher/k3s/server/db/snapshots) — healthcheck.sh gains a "recent etcd snapshot exists" check, and the recovery posture becomes statable with numbers: RPO ≤24h app data / ≤12h cluster state, RTO = the rehearsed restore.

## Recovering from quorum loss

Two of three servers down = the API stops serving (etcd needs a majority). The data is safe; the cluster is paused, not broken. Three tiers:

1. **The nodes can come back** (power event — the usual case): start them. Quorum re-forms by itself the moment a second voter is up. Nothing else.
2. **The lost servers are gone for good, one survivor remains:** the survivor has complete data (a minority that never served cannot have diverged). Tell it to stop waiting for the dead:

`systemctl stop k3s && k3s server --cluster-reset && systemctl start k3s` it serves again as a 1-member cluster. Rebuild quorum by joining replacement boxes (bundle + join.conf, ROLE=server, back to an odd count).

3. **All servers gone:** fresh box + bundle, then `k3s server --cluster-reset --cluster-reset-restore-path=<etcd snapshot>` restores cluster state; the pg dump restore brings back the app's data. This is why install.sh primes a first backup AND an etcd snapshot, and why healthcheck refuses to call a system healthy without fresh copies of both.

## Stuck pods after a node returns

A pod that was marked for eviction while its node was dead can wedge when the node comes back — deletionTimestamp set, volume mounts failing, going nowhere, and kubernetes will wait forever. healthcheck flags any pod stuck terminating >5 minutes. The fix is one command, and it is safe: the controller (or the CNPG operator) recreates the pod immediately:

```bash
kubectl delete pod <name> --force --grace-period=0
```

Seen in the wild here: the database primary's pod, wedged on its returned node while the cluster status still claimed it healthy. With the two-replica operator and working failover this state is a nuisance, not an outage. The cluster has already moved on to a promoted primary.

## Test rig prep (one-time, manual)

The clone script needs a base VM to copy. Make it once:

1. New VirtualBox VM "airgap-base": Ubuntu Server (24.04 this time and verify with `lsb_release -a`, see NOTES.md), openssh-server enabled, attached to the `airgapnet` host-only network.
2. In it: `ssh-copy-id` your key, and passwordless sudo for the automation: `echo "bobby ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/bobby`
3. Power it off. That's it. never boot it again except to update it. Clones inherit everything.

Then: `scripts/make-nodes.sh 3` → airgap-node1..3, cloned, MAC-randomized, hostnames set, machine-ids reset (duplicate machine-ids = duplicate DHCP leases — the script handles it), IPs printed at the end.

## Adding and removing nodes (day two)

**Add:** carry the bundle plus the server's `join.conf` to the new box, run the same install. It joins, the installer stages images locally, pods land on it as needed. Nothing happens on the existing nodes.

**Remove, gracefully:**

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # evict pods
kubectl delete node <node>                                        # forget it
# then on the box itself: k3s-agent-uninstall.sh (agents get the agent
# variant of the uninstaller)
```

The drain fails by design if the node is the pinned data node postgres has nowhere to go. Moving the data node is a real migration (backup, re-pin, restore), not a drain.

**Remove, because it died:** pods already rescheduled (that's P4's drill);
`kubectl delete node <node>` clears the stale entry. If it comes back later it just rejoins.

**Server nodes and quorum.** With HA, no single server is special — but the *count* is. Three servers tolerate losing exactly one; while one is down, etcd has no spare votes, so replace dead servers promptly (drain/delete as above, then a fresh box joins with ROLE=server). Never run an even number, and never remove a server without checking the others are healthy first — dropping from 3 to 2 healthy is fine, from 2 to 1 kills quorum and stops the cluster. The data node remains the one box whose loss hurts (see the storage phase): control-plane HA moves the brain off any single machine, not the database.
