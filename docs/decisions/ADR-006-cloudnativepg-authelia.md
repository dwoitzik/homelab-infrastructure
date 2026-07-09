# ADR-006: CloudNativePG for Authelia's Postgres backend

**Date:** 2026-06-15
**Status:** Accepted

## Context

Authelia's Postgres backend originally ran as a bare `StatefulSet` (manually wired
Service + PVC, Bitnami-derived image). It worked, but every operational concern around it
was hand-rolled: no WAL archiving, no PITR, backups meant a manual `pg_dump` or nothing.
Image availability was already a recurring pain point — the StatefulSet had been through
several image swaps (ECR public, then Docker Hub) after Bitnami deprecated its free
ECR/Docker Hub images, each requiring a manual manifest fix to keep the pod scheduling.

Options considered:

- Keep the bare StatefulSet, bolt on a CronJob for `pg_dump` backups
- Adopt CloudNativePG (CNPG), a Kubernetes-native Postgres operator
- Move Authelia's backend to an external/managed Postgres — not realistic on this
  hardware, there is no managed DB in this homelab

## Decision

Deploy the CloudNativePG operator (`kubernetes/system/cloudnative-pg/application.yml`) and
replace Authelia's bare StatefulSet with a CNPG `Cluster` resource
(`kubernetes/system/postgres/cluster.yml`), configured with WAL archiving to Garage S3,
7-day retention, and PITR support. The old StatefulSet manifests were deleted from the
repo only after the data migration to the new `postgres-authelia-rw` Service endpoint was
confirmed working — the Authelia configmap cutover was a deliberately separate commit.

## Reasons

CNPG turns Postgres from a hand-maintained pet into a managed resource: it owns the
read/write Service split (`-rw`/`-ro`/`-r`), Prometheus monitoring (PodMonitor + Grafana
dashboard ship with it), and — the actual motivation — WAL archiving/PITR via barman,
which the bare StatefulSet had none of. It's a CNCF operator with an active release
cadence, which sidesteps the exact problem that kept breaking the old setup (upstream
image deprecations forcing manual fixes). For a single-instance homelab Postgres, CNPG's
HA features (replicas, automatic failover) go mostly unused, but the backup/PITR machinery
alone justifies the operator's footprint.

## Trade-offs

- Adds an operator (CNPG controller + CRDs) as a new system-level dependency that must
  itself stay healthy for Postgres to be manageable
- WAL archiving to Garage S3 makes Postgres backup availability dependent on Garage's
  in-cluster uptime — the same circular-dependency risk already flagged for Velero
  (Garage backs up into itself; see the Garage circularity design discussion)
- WAL archiving alone is not a restorable backup without a base backup to restore
  from — a `ScheduledBackup` resource has since been added (`postgres-authelia-backup`,
  running daily), so PITR now has a real base backup + WAL chain behind it, not just
  the PVC-level Velero/PBS copies.

## Consequences

`postgres-authelia` is now a CNPG `Cluster`, monitored via the bundled PodMonitor and
Grafana dashboard. Any future Postgres workload in this cluster should default to CNPG
rather than a bare StatefulSet.
