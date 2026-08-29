# ADR-038: Fix Chronic `daily-offsite` Velero Failure Against Cloudflare R2

**Date:** 2026-08-29
**Status:** Accepted and shipped. Investigation went through one wrong turn,
kept in this ADR rather than rewritten away.

## Context

`daily-offsite` (Velero's nightly backup to Cloudflare R2 via
`BackupStorageLocation` `r2-offsite`) had failed every run for 7+
consecutive days (2026-08-23 through 2026-08-29, confirmed via `kubectl get
backups.velero.io`), unrelated to and predating the same-day
`vm-srv-k3s-11` incidents covered in ADR-036/037. The onsite backup
(`daily-backup`, BSL `default`, Garage) was unaffected throughout.

Every failure showed the same error, always on the final metadata upload
step (the backup's actual data transfer always completed —
`itemsBackedUp`/PodVolumeBackups always matched their totals):

```text
error putting object backups/<name>/velero-backup.json: operation error
S3: PutObject, https response error StatusCode: 501, ... api error
NotImplemented: Header 'x-amz-tagging' with value '' not implemented
```

## First attempt (wrong, corrected the same day)

The initial hypothesis: AWS SDK for Go v2's S3 module, starting at
`v1.74.1` (a 2025 default-behavior change per the SDK's own changelog),
auto-attaches a CRC32 checksum to every `PutObject` by default —
independent of Velero's own `checksumAlgorithm` config. This is a real,
independently-documented class of breakage against non-AWS S3-compatible
backends generally. `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` /
`AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` were set via
`configuration.extraEnvVars` to revert this.

Shipped, verified live on the running pod (env vars present, pod recreated
with them), then re-tested against R2 with a full manual retry — **`daily-
offsite` failed again, identical error.** Wrong theory for this specific
bug. The env vars are kept (harmless, AWS's own documented general
hardening), but they are not what fixed this.

(Along the way, this same PR also hit and fixed an unrelated shape bug —
this chart's `configuration.extraEnvVars` is a flat key/value map, not a
list of `{name, value}` objects, confirmed by reading the actual pinned
chart's template. The first commit used the wrong shape and silently
rendered zero env vars; the fix was verified with a local `helm template`
render before shipping, which is also what caught the checksum theory
being wrong before it caused more churn.)

## Real root cause (verified against the actual tagged plugin source)

Read `velero-plugin-for-aws`'s source directly at the exact tag in use
(`v1.14.2`, not `main` — the two differ here):

```go
// v1.14.2, velero-plugin-for-aws/object_store.go
func (o *ObjectStore) PutObject(bucket, key string, body io.Reader) error {
    input := &s3.PutObjectInput{
        Bucket:  aws.String(bucket),
        Key:     aws.String(key),
        Body:    body,
        Tagging: aws.String(o.tagging),
    }
    ...
```

`Tagging` is set **unconditionally** on every `PutObject` call, with no
empty-string guard. `o.tagging` defaults to `""` when the BSL's `tagging`
config key isn't set (it isn't, for either BSL here) — so every single
`PutObject` this plugin makes sends a literal, empty `x-amz-tagging`
header. Garage (the onsite backend) evidently tolerates this; Cloudflare R2
hard-rejects it with `501 NotImplemented`, matching the error exactly.

The plugin's `main` branch already has the fix:

```go
// main branch, same file
if o.tagging != "" {
    input.Tagging = aws.String(o.tagging)
}
```

with a comment explicitly naming this exact failure mode ("some
S3-compatible backends... reject requests that carry these headers with
empty values"). **No tagged release includes this fix yet** — `v1.14.2` is
still the latest tag as of this change (checked directly against the
project's GitHub releases).

## Decision

Pin the `velero-plugin-for-aws` initContainer to
`release-1.14-dev@sha256:cf0eaabef943c5780f23741194bec77c30fd4590be3203b5afed49c9e6dddb36`
— the project's own rolling dev build tracking the 1.14 release line on
Docker Hub, updated 2026-08-28 (the day before this fix), digest-pinned for
reproducibility despite the tag itself being mutable upstream.

This is a deliberate, temporary deviation from this repo's normal
pinned-tagged-release convention. Accepted because a backup destination
that has failed 100% of the time for a week outweighs the reproducibility
risk of one digest-pinned dev-build initContainer. **Revisit and move back
to a tagged release once `v1.14.3+` (or whatever version ships this fix)
is published** — check the plugin's release notes for a
`tagging`/`x-amz-tagging` fix mention before bumping back to a normal
pinned release.

## Verification

- Root cause confirmed against the actual tagged source, not inferred from
  the error's header name or assumed from an unreleased branch.
- Onsite backup (`daily-backup`, Garage) manually retried the same day,
  separately, completed cleanly (6574/6574 items, 0 errors) — confirms the
  cluster and Velero itself are healthy; the failure was specific to the R2
  path via this specific plugin bug.
- [Fill in after deploying the digest-pinned image and re-running
  `daily-offsite`: confirm `Completed`, not `Failed`.]

## Trade-offs

- Using a dev-tracking image instead of a tagged release, even
  digest-pinned, means picking up whatever else is on that build —
  accepted as temporary and explicitly flagged for revisit, not a
  permanent state.
- The `WHEN_REQUIRED` checksum env vars from the first attempt stay in
  place even though they didn't fix this bug — real, AWS-documented
  compatibility hardening for S3-compatible backends generally, no reason
  to remove them.

## Consequences

- Revisit this ADR once a tagged `velero-plugin-for-aws` release ships the
  `o.tagging != ""` guard — move off the dev-build pin at that point.
