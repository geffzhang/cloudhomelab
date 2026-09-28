# ADR-006: Nightly Backups to Tencent COS

**Status:** Accepted  
**Date:** 2026-07-23

## Context

The cluster is single-node with node-local (local-path) storage. There is no replicated volume and no HA, so a lost or rebuilt node loses everything on disk. Application data (the ChessKernel PostgreSQL database) must survive node loss and be restorable onto a fresh cluster. The backup target should cost little to nothing and be reachable from inside the cluster with standard tooling.

Options: a cloud provider's managed backup, an S3-compatible object store, or copying dumps to another host. Tencent COS was chosen because its S3-compatible API works with the standard `aws-cli` and keeps backups in the selected cloud account.

## Decision

Run a **nightly `CronJob` that `pg_dump`s the databases, gzips them, and uploads to Tencent COS** over its S3-compatible API, with a **14-day rotation** (`apps/chesskernel/backup-cronjob.yaml`).

- Schedule `0 3 * * *` (03:00 UTC), `concurrencyPolicy: Forbid` so runs never overlap.
- The job runs a `postgres:16-alpine` container, installs `aws-cli`, dumps `chesskernel` and `capoaberto_staging`, and uploads each gzip dump under its own COS prefix using the bucket region endpoint.
- Before upload it prunes by age, object count, and total-size caps; this bounds retention and storage use.
- COS credentials (Secret ID, Secret Key, region, bucket) come from the sealed secret `cos-backup-credentials` (see ADR-003).

Restore is a documented manual procedure (`gunzip | kubectl exec ... psql`) in the runbook.

## Consequences

- Data survives node loss: a rebuilt cluster is repopulated from git (manifests) plus the latest COS dump. This is what makes the node disposable despite local-path storage.
- Backups are only trustworthy if restores are exercised. The runbook mandates a quarterly restore drill into a scratch database; a dump that has never been restored is not a backup.
- Retention is 14 days by key-date pruning. Older history is not kept; this is acceptable for a homelab and can be extended by changing the cutoff.
- The COS Secret ID and Secret Key are credentials in the cluster and must be restricted to the backup bucket with minimum required permissions.
- Only PostgreSQL is backed up. Redis is a cache (regenerable), and Grafana/Prometheus data is observability history, not application data, so neither is included by design.
