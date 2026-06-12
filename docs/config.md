# The two config files

The whole system is driven by two small files. No flags, no prompts — these files ARE the interface. If you know what's in them, you know everything the install can be told.

## install.conf — the box's contract

Lives at `/etc/saleor/install.conf` on the **first server** (a single-box install is the same thing). Joining boxes don't have one — their config lives on the first server, and that's the point. Root-owned, mode 600: it contains credentials.

`install.sh` generates it on first run with sane defaults and generated secrets. You only ever touch it to change something.

What a converted cluster's file looks like:

```bash
SALEOR_HOST=saleor.local
SECRET_KEY=7f4738554a7cbbe4e7c6e8a3ab633dae...
POSTGRES_PASSWORD=f2e77e4bf114e8f5dd05266c186ca604
CLUSTER_VIP=192.168.56.200
REBALANCE_SCHEDULE="*/1 * * * *"
```

Every key, what it does, and whether you may touch it:

| Key | Default | What it does |
|---|---|---|
| `SALEOR_HOST` | `saleor.local` | The hostname the TLS ingress answers to and the self-signed cert is issued for. Machines on the LAN need a hosts-file entry pointing it at any node. |
| `SECRET_KEY` | generated | Django's secret. **Never change after install.** |
| `POSTGRES_PASSWORD` | generated | The database password. **Never change after install** — the database was initialized with it, and a rerun cannot rotate it. |
| `CLUSTER_VIP` | *(absent)* | **Adding this line and rerunning `./install.sh` IS the conversion to a cluster**: etcd, kube-vip on this address, the enclave registry, the replicated database (dump taken first, automatically), cluster sizing, and `join.conf` written for the other boxes. Must be a free IP on the same LAN, outside any DHCP range — ask whoever owns the network. |
| `API_REPLICAS` | `3` | Cluster only. API replica count requested at conversion; the rebalancer spreads them as boxes join. |
| `WORKER_REPLICAS` | `2` | Cluster only. Same, for the celery workers. |
| `REBALANCE_SCHEDULE` | `"*/10 * * * *"` | Cluster only. How often the cluster re-spreads work after a node joins or returns. The default is the right production laziness; demos use `"*/1 * * * *"`. |

Rule of thumb: **generated lines are forever, optional lines are yours.** And keep the file — upgrades reuse it, and without it the database credentials are unrecoverable.

## join.conf — the cluster's invitation

The first server's conversion writes it next to the bundle pieces (`dist/join.conf`, same directory as the `.SHA256SUMS` file). To add a box: copy it, **with the bundle**, into that same bundle directory on the new machine. Its presence is the role declaration — `install.sh` sees the file and joins the cluster; no file means "become a first server."

It contains the cluster join token, which is a **credential**. It rides the USB stick with the bundle. It never goes in an email, a ticket, or a chat — this is exactly why it's a file and not a line in the install report, because reports get emailed.

What it looks like:

```bash
K3S_URL=https://192.168.56.200:6443
K3S_TOKEN=K10c84f8a72b...::server:e9d1f2...
CLUSTER_VIP=192.168.56.200
ROLE=server
```

| Key | What it is |
|---|---|
| `K3S_URL` | The cluster's address — always the VIP, never a specific box's IP, so the file stays valid no matter which machines exist by the time it's used. |
| `K3S_TOKEN` | The join credential. Treat like a password. |
| `CLUSTER_VIP` | Carried along so joining boxes know the VIP too. |
| `ROLE` | **The one line you edit, per box.** `server` joins the control plane — keep the total server count odd (3 tolerates losing 1). `agent` joins as a worker only — add as many as you like, they don't vote in quorum. |

One `join.conf` serves every box that ever joins — next year's expansion box uses the same file (the token doesn't expire by default). If the token must be rotated, regenerate it on the first server and re-copy.

## The flows, end to end

**Single box** — nothing to prepare. `sudo ./install.sh` writes `install.conf` itself. Done.

**Convert to a cluster** — add the `CLUSTER_VIP=` line to `/etc/saleor/install.conf`, then `sudo ./install.sh`. It writes `dist/join.conf` when it finishes.

**Every additional box** — copy `join.conf` next to the bundle, set `ROLE` if it shouldn't be a server, then `sudo ./install.sh`.
