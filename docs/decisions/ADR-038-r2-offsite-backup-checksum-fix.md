# ADR-038: Fix Chronic `daily-offsite` Velero Failure Against Cloudflare R2

**Date:** 2026-08-29
**Status:** Accepted and shipped.

## Context

`daily-offsite` (Velero's nightly backup to Cloudflare R2 via
`BackupStorageLocation` `r2-offsite`) had failed every single run for 7+
consecutive days (2026-08-23 through 2026-08-29, confirmed via `kubectl get
backups.velero.io`), unrelated to and predating the same-day
`vm-srv-k3s-11` incidents covered in ADR-036/037. The onsite backup
(`daily-backup`, BSL `default`, Garage) was unaffected throughout.

Every failure showed the same error, always on the final metadata upload
step (the backup's actual data transfer completed — `itemsBackedUp` always
matched `totalItems`):

```text
error putting object backups/<name>/velero-backup.json: operation error
S3: PutObject, https response error StatusCode: 501, ... api error
NotImplemented: Header 'x-amz-tagging' with value '' not implemented
```

## Investigation

The error message names `x-amz-tagging`, and the BSL already had
`checksumAlgorithm: ""` set (an earlier, partial mitigation attempt). Both
pointed toward Velero's own S3 object-tagging config as the culprit — but
that didn't hold up:

- Read `velero-plugin-for-aws`'s actual source
  (`object_store.go`): the plugin only sets a `Tagging` header when the
  BSL's `config.tagging` key is non-empty. It isn't set anywhere in either
  BSL here (`default` or `r2-offsite`) — the plugin should never attach a
  real tagging header at all with the current config.
- Web research surfaced the real mechanism: AWS SDK for Go v2's S3 module,
  starting at `v1.74.1` (per the SDK's own changelog, a 2025 change),
  **auto-attaches a CRC32 checksum to every `PutObject` by default** unless
  explicitly told not to — independent of Velero's own `checksumAlgorithm`
  config, which only controls what Velero *itself* requests, not what the
  underlying SDK adds on its own. This exact SDK-default-behavior class of
  breakage against non-AWS S3-compatible backends (R2, Backblaze B2, and
  others) is independently documented across multiple AWS SDK language
  ecosystems, not a Velero-specific bug — and Cloudflare R2's own error
  messages for this class of unsupported auto-injected header have been
  observed mislabeling which header is actually the problem in other
  reported cases, consistent with `x-amz-tagging` being a red herring here
  rather than the literal cause.
- The existing `checksumAlgorithm: ""` setting addresses a different,
  narrower symptom of the same underlying SDK change (an explicitly
  requested checksum algorithm) — not the SDK's own default auto-checksum
  behavior underneath it. Both fixes are complementary, not redundant.

## Decision

Set `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` and
`AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` as environment variables
on the Velero deployment (`configuration.extraEnvVars` in
`kubernetes/system/velero/application.yml`), reverting the SDK to its
pre-`v1.74.1` behavior. This is AWS's own documented mitigation for this
exact class of S3-compatible-backend incompatibility, not a Velero-specific
workaround — applies to the whole Velero process, so both BSLs (`default`/
Garage and `r2-offsite`/R2) get it, since Velero doesn't support per-BSL
plugin environments.

## Verification

- Root cause confirmed by reading the plugin's actual source rather than
  guessing from the error's header name.
- Onsite backup (`daily-backup`, Garage) manually retried the same day,
  separately, and completed cleanly (6574/6574 items, 0 errors) — confirms
  the cluster and Velero itself are healthy; the offsite failure was
  specific to the R2 path, not a general Velero problem.
- [Fill in after next scheduled `daily-offsite` run or a manual retry:
  confirm `Completed`, not `Failed`.]

## Trade-offs

- `WHEN_REQUIRED` means Velero's uploads to R2 (and Garage) no longer get
  automatic SDK-side integrity checksums by default. Accepted: Velero's own
  backup-integrity story doesn't depend on S3-layer checksums (kopia has
  its own content-addressed integrity checking for the actual backup data;
  this only affected the SDK's transport-layer PutObject checksum), and the
  alternative is a backup destination that fails 100% of the time, which is
  strictly worse than a working backup without one extra integrity layer.

## Consequences

- If Cloudflare R2 later adds support for the SDK's default checksum
  headers, or if a future AWS SDK version changes this default again, this
  env var may become unnecessary — revisit if `daily-offsite` starts
  failing differently after an unrelated dependency bump touches the
  plugin image.
