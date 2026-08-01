# Garage/Velero Design Session — REL-003 + REL-073

**Date**: 2026-07-17
**Status**: Proposal only — no changes applied
**Decision authority**: User

---

## Problem Statement

Two related issues create structural fragility in the backup/recovery chain:

### REL-003: Backup Circularity

Velero backs up into Garage S3, which runs inside the cluster it's backing up.
From-scratch bootstrap is impossible without surviving cluster state:

```text
Cluster lost → Garage PVC lost → Velero backup bucket gone → nothing to restore from
```

The Cloudflare R2 offsite location (`r2-offsite` BSL) exists in config but
is deliberately not active (waiting on real Account ID + API token).
PBS backs up VM/LXC disks, but PBS runs on the same host — simultaneous
total host + USB HDD loss is unrecoverable at the VM layer.

### REL-073: Torn-State Hazard (caused 07-12 corruption)

Two PVCs with different storage backends, different rollback fates:

| PVC | Storage | Location | Rollback fate |
|---|---|---|---|
| `garage-meta` | `local-path` | k3s node (`.13`) | Node-pinned, survives if node survives |
| `garage-data` | NFS (`nfs-client`) | `ct-srv-nfs-01` | Survives if NFS LXC survives |

On 2026-07-12, an unclean Garage shutdown (OOM kill) left `db.sqlite`
corrupted. The metadata (SQLite, bucket/key ownership, access grants) and
the actual object data were on different volumes with different failure
modes — a partial restore or node loss would leave one without the other,
with no clean way to reconcile them.

The current state (post-fix):

- `garage-meta`: `local-path` PVC, 2Gi, node-pinned
- `garage-data`: NFS PV `garage-data-archive` at `10.0.20.100:/archive-garage-data`, 150Gi
- Velero excludes both via `backup.velero.io/backup-volumes-excludes: data,meta`

---

## Options

### Option A: Consolidate meta + data on one volume with shared snapshot fate

**What**: Move `garage-meta` from `local-path` to NFS (same backend as
`garage-data`), or move `garage-data` from NFS to `local-path`. Both PVCs
on the same storage class → same snapshot/restore fate.

| Dimension | Assessment |
|---|---|
| **Resource cost** | Zero — no new hardware or storage |
| **Migration risk** | Medium. Moving meta to NFS: Garage SQLite on NFS was accepted risk (documented in DR doc Tier 4), but the 07-12 corruption incident showed NFS locking is not harmless. Moving data to local-path: would require a new 150Gi+ disk on the k3s node — not feasible on current 512GB SSD without displacing other workloads. |
| **Downtime** | ~5 min. Stop Garage deployment, `kubectl cp` meta data to new PVC, restart. |
| **New storage needed?** | No (meta→NFS) or yes (data→local-path, needs ~150Gi free) |
| **Full-cluster-loss recovery** | Partial improvement. Both PVCs have the same restore path, but if both are in-cluster (NFS or local-path), the circularity of REL-003 remains. |

**Verdict**: Fixes REL-073 (torn-state) but not REL-003 (circularity). NFS
for SQLite is proven fragile — the 07-12 corruption was on NFS-backed data.
Moving data to local-path requires hardware you don't have yet.

### Option B: External (off-cluster) target for Velero

**What**: Activate the existing `r2-offsite` BSL. Velero dual-targets:
in-cluster Garage for speed + off-cluster Cloudflare R2 for bootstrap.
Also makes Garage's own bucket redundant.

| Dimension | Assessment |
|---|---|
| **Resource cost** | ~$0.015/GB/month on R2 (egress free). At current backup size (~5-10Gi), negligible. |
| **Migration risk** | Low. Config exists (`r2-backuplocation.yml`, `offsite-schedule.yml`). Needs real Cloudflare R2 credentials. The `offsite-schedule` already scopes to apps/vault/database/argocd (excludes large PVCs like `media`). |
| **Downtime** | Zero — additive, no existing backup path changes. |
| **New storage needed?** | Cloudflare R2 account (free tier covers current scale). |
| **Full-cluster-loss recovery** | BREAKS THE CIRCULARITY. Cluster lost → Garage gone → Velero still has offsite copy on R2. Bootstrap path: rebuild cluster → ArgoCD → Velero → restore from R2. |

**Verdict**: Directly solves REL-003. Minimal risk, additive only.
The existing R2 config is ready — needs credentials and a "go".

### Option C: PBS as the cluster-independent recovery layer (instead of / alongside Velero)

**What**: Lean into PBS as the primary from-scratch recovery path.
PBS already backs up all VMs/LXCs (including the k3s VMs that carry
Garage's data). Velero becomes a convenience layer for single-app restore,
not the bootstrap path.

| Dimension | Assessment |
|---|---|
| **Resource cost** | Already have PBS + 2TB USB HDD. No new hardware. |
| **Migration risk** | Low — PBS backup is already live and verified (2026-07-06 Atlantis test). |
| **Downtime** | N/A — this is a recovery-path change, not a live migration. |
| **New storage needed?** | No (but offsite PBS fallback — the Google Drive sync — is disabled and impractical per DR doc). |
| **Full-cluster-loss recovery** | PBS restores k3s VMs including Garage PVC data → Garage starts → Velero has its bucket → full app restore works. **Gap**: if PBS USB HDD is also lost, same problem as before. But this is strictly better than the current state. |

**Verdict**: Already the real bootstrap path (DR Tier 1-4). Velero is
Tier 5, only if Garage survived. PBS is the actual safety net. The
circularity is a Velero-level problem, not a PBS-level one.

### Option D: Combine B + C (recommended)

**What**: Activate R2 offsite for Velero (breaks circularity) AND
acknowledge PBS as the primary VM-level recovery layer. Velero becomes
the single-app/namespace convenience tool with a real offsite target.

This covers both issues:

- **REL-003** (circularity): R2 offsite means Velero can bootstrap without
  a surviving cluster. PBS handles VM-level recovery.
- **REL-073** (torn-state): Keep meta+data on separate volumes for now
  (Option A's NFS-for-meta risk isn't worth it). Add a note to DR doc:
  if Garage PVCs are lost, rebuild Garage from scratch (re-create buckets
  via Terraform, re-import, let ESO re-seed keys) rather than attempting
  a partial PVC restore that could leave metadata/data inconsistent.

| Dimension | Assessment |
|---|---|
| **Resource cost** | R2 free tier (~$0/month at current scale) |
| **Migration risk** | Near-zero — additive config only |
| **Downtime** | Zero |
| **New hardware** | None |
| **Full-cluster-loss** | PBS restores VMs → cluster up → ArgoCD → Velero from R2 → apps restored. Both layers have independent recovery paths. |

---

## Recommendation

**Option D: B + C combined.** Activate R2 offsite (B) as the immediate
action — it's config-only, zero risk, closes the circularity. Keep PBS
as the primary VM-level recovery path (C) — it's already there and
verified. Defer Option A (meta consolidation) until a 4TB SSD arrives,
at which point local-path for both becomes feasible without displacing
other workloads.

**Specific next steps** (if you approve):

1. Get Cloudflare R2 Account ID + API token
2. Populate `kubernetes/system/velero/r2-backuplocation.yml` with real values
3. Populate `kubernetes/system/velero/external-secret.yml` (or use existing
   `velero-r2-credentials` Secret)
4. Apply the `daily-offsite` Schedule (already committed)
5. Run one test backup to R2, verify with `velero backup describe`
6. Update DISASTER-RECOVERY.md Tier 5 to document the R2 path
7. Add REL-073 note: Garage rebuild from scratch (Terraform + ESO re-seed)
   is the preferred recovery over partial PVC restore

**Deferred**: Option A (meta consolidation) — revisit when 4TB SSD arrives.
Until then, document the torn-state risk and the Garage-from-scratch
recovery procedure as the mitigation.
