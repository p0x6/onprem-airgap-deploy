# Upgrade and rollback

How a new version reaches the box, how it goes wrong safely, and how to get back.

## How an upgrade ships

A new version is just another bundle, built the same way:

```bash
BUNDLE_VERSION=v2 ./bundle/build.sh --arch <arch>
```

Only pieces that changed need to travel (that's why the bundle is per-piece files with a manifest, not one fat tarball). On the box:

1. New image tarballs (if any) go to `/var/lib/rancher/k3s/agent/images/`, then `sudo systemctl restart k3s` to import them. Old images stay in containerd.
2. New chart replaces `~/chart`.
3. Same single command as the install: `sudo ./install.sh` (it's `helm upgrade --install` underneath — install and upgrade are the same path on purpose).

The migrate job runs as a pre-upgrade hook: migrations apply BEFORE the new code rolls out. On a version with no new migrations it's a ~10 second no-op.

## Before every upgrade: backup

```bash
kubectl create job --from=cronjob/postgres-backup pre-upgrade-backup
kubectl wait --for=condition=complete job/pre-upgrade-backup --timeout=120s
kubectl delete job pre-upgrade-backup
ls -t /var/backups/saleor/ | head -1   # note this filename
```

TODO: fold this into install.sh's upgrade path so it's not a separate step.

## When an upgrade fails

A bad image tag (or any pod that can't start) shows up as the migrate job stuck in `ErrImageNeverPull` / `CrashLoopBackOff` and helm timing out. The release is marked `failed` — but the previous revision is intact, and so are the previous images in containerd (nothing deletes them).

```bash
helm history saleor          # find the last good revision
helm rollback saleor <rev> --timeout 10m
./healthcheck.sh             # verify, don't assume
```

Rollback re-runs the migrate hook from the good revision (no-op) and rolls the deployments back to the old images — which import from nowhere, because they never left the box.

**The honest caveat: `helm rollback` does not roll back the database.**
Django migrations are generally forward-only. If the failed upgrade got far enough to apply schema changes the old code can't live with, restore the pre-upgrade dump:

```bash
# scorched-earth restore (app stopped first):
kubectl scale deploy saleor-api saleor-worker --replicas=0
kubectl exec -i postgres-0 -- dropdb   -U saleor --if-exists saleor
kubectl exec -i postgres-0 -- createdb -U saleor saleor
gunzip -c /var/backups/saleor/<pre-upgrade-dump>.sql.gz \
  | kubectl exec -i postgres-0 -- psql -q -U saleor saleor
kubectl scale deploy saleor-api saleor-worker --replicas=1
```

Most failed upgrades never reach migrations (image won't start, config rejected), so most rollbacks are helm-only. The dump is for the rest.

## Verify a backup restores WITHOUT touching the live DB

Worth doing periodically — a backup that exists isn't a backup that works:

```bash
kubectl exec postgres-0 -- createdb -U saleor restore_check
gunzip -c /var/backups/saleor/<dump>.sql.gz \
  | kubectl exec -i postgres-0 -- psql -q -U saleor restore_check
kubectl exec postgres-0 -- psql -U saleor restore_check \
  -c "select count(*) from django_migrations;"   # non-zero = real schema
kubectl exec postgres-0 -- dropdb -U saleor restore_check
```
