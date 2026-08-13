# Garage

Self-hosted S3-compatible object storage. Backs Terraform state, Loki chunk storage,
Velero backups, and CNPG's continuous WAL archiving — this is load-bearing
infrastructure, not just an app.

## Storage — two very different PVs

- **`garage-data` (bulk objects, 150Gi): a static PV pointing directly at the
  `/archive-garage-data` NFS export.** This is *not* provisioned/managed by k8s in the
  normal sense — it's physically the same directory Garage has always used, on a disk
  that survives independently of the k3s cluster's own lifecycle. A full k3s rebuild
  does not touch this data at all; there is nothing to "restore" here under normal
  circumstances.
- **`garage-meta` (LMDB metadata, small): a regular `local-path` PVC.** This *does* need
  restoring after a cluster rebuild — it's node-local and gets wiped along with
  everything else on that node's disk.

## How to restore

Only `garage-meta` needs it. Copy the preserved metadata DB onto the PVC, restart. Sanity
check by standing up a temporary Garage instance bind-mounted read-only against the
restored `garage-meta` + the live (untouched) `garage-data` and confirming
`garage bucket list` shows the expected buckets with plausible object counts — a
structural file-format check alone isn't enough here, since a subtly-wrong metadata
restore would look fine until something actually tries to read an object.

## Known gotchas

- **Never edit a Garage access key's secret with `--show-secret` unredirected** — it
  prints the actual secret value to stdout. Always pipe straight to a file.
- Vault's stored `secret/garage` access keys can drift out of sync with what Garage
  itself actually has (found twice this recovery, for both Velero's and the pve-exporter/
  CNPG backup keys) — if a consumer gets `403 AccessDenied: No such key`, check
  `garage key list` against what Vault has before assuming the consumer's config is
  wrong.
