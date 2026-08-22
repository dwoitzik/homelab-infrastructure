# Hardware — constraints that shape this architecture

This document exists so a future agent (or a future David) doesn't reintroduce a fix
for a problem this hardware doesn't have, or a regression for one it does.

## Inventory

| Node | Role | Spec |
|---|---|---|
| `pve-mgmt-01` | Proxmox host, sole physical compute node | Single box — everything else (VMs, LXCs) runs on it |
| `vm-srv-k3s-11` | k3s control-plane (sole server) | VM, boot disk on `local-lvm` |
| `vm-srv-k3s-12`, `vm-srv-k3s-13` | k3s workers | VMs, same storage |
| `rpi-srv-01`, `rpi-srv-02` | DNS/edge (AdGuard + Unbound, VRRP-paired via keepalived) | RPi 4B, SD card boot |
| Boot/VM-image storage | `local-lvm` (LVM-thin, VG `pve`) | **DRAM-less consumer NVMe.** No onboard write cache — every sustained write burst hits raw flash directly. |
| Bulk/archive storage | `media`/`archive` ZFS pool | HDD-backed, ample capacity, slow — used deliberately for anything that doesn't need low latency (PBS backups, staging large restores) |
| Immich photo library | USB-attached storage, NFS-exported | Untouched by k3s cluster lifecycle — physically independent |

## The hard constraint: the boot NVMe is DRAM-less

This is the single fact that shapes the most architecture decisions in this repo. A
DRAM-less SSD has no onboard cache to absorb write bursts or buffer the FTL's mapping
table — every write, including small/random ones, goes essentially straight to flash.
Sustained high write-amplification workloads on this specific drive cause real,
measured degradation (45% wear, 26.9TB lifetime writes as of the 2026-08-13 recovery's
own SMART check) and, at worst, host-level I/O stalls severe enough to cause application
crash loops.

**What this ruled out:**

- **etcd as the k3s datastore.** etcd's own fsync-heavy write pattern (a `fdatasync` on
  every raft commit) is close to a worst-case workload for this drive. This is why the
  cluster runs a single k3s server with the embedded SQLite datastore instead — see
  `docs/decisions/ADR-015-k3s-datastore-sqlite.md` for the full reasoning and the real
  incident history (REL-012c and others) that established this empirically, not just in
  theory.
- **ZFS for the boot/VM-image pool.** ZFS's copy-on-write model and its own write
  amplification (especially under `zvol`-backed VM disks) compounded the problem rather
  than helping it. Replaced with LVM-thin (`local-lvm`), a lighter-weight fit for this
  specific constraint — no copy-on-write overhead, simpler write path.
- **Longhorn for k8s storage.** Its own replication traffic is additional sustained
  write load this drive can't absorb well, on top of being architecturally redundant on
  an effectively single-host topology anyway. Storage classes are `local-path`
  (node-pinned, for small/latency-sensitive state) and `nfs-client` (for shared/larger
  state, backed by the NFS server LXC, not this NVMe).

**What's still allowed on this drive, deliberately:** SQLite-backed application state
(Vaultwarden, Headscale, Garage metadata, Uptime Kuma, Mealie, Open WebUI) — these have
a much lighter write pattern than etcd or ZFS's own metadata overhead, and moving them
elsewhere wasn't justified by any measured problem.

## SSD wear tracking and replacement trigger

The boot/VM-image NVMe (`/dev/nvme0n1` on `pve-mgmt-01`) is an unbranded "AirDisk
512GB SSD" — not a known enterprise or major-consumer brand, worth naming explicitly
since it shapes how much to trust the endurance rating this projection depends on.

Two real SMART data points, nine days apart:

| Date | `percentage_used` | Lifetime writes | Power-on hours |
|---|---|---|---|
| 2026-08-13 | 45% | 26.9 TB | (not recorded that day) |
| 2026-08-22 | 56% | 36.6 TB | 2,344 |

That's **11 percentage points of wear and ~9.7TB written in 9 days** — a recent
observed rate of ~1.22%/day. The drive's full-life average (56% over 2,344 power-on
hours, ~98 days) works out to a slower ~0.57%/day. The two disagree by more than 2x,
and both are honest numbers from the same drive — the recent window overlaps almost
entirely with this repo's active disaster-recovery work (backup-chain rebuilds, LMDB
migration, repeated restore tests, today's own load incident), which is not
representative of ordinary steady-state homelab usage. The lifetime average dilutes
that same burst across the drive's whole history, which is *also* not a clean
steady-state number since a meaningful fraction of that history is this same recovery
mission.

**Projection, both bounds stated rather than false-precision averaged**: at the
lifetime-average rate, `percentage_used` reaches 90% around **2026-11-14** (~11
weeks out); at the recent 9-day rate, around **2026-09-19** (~4 weeks out). Reality
is most likely somewhere between these once the recovery work itself tapers off, but
neither bound is "someday" — even the slower one is under three months.

**Replacement trigger** (the concrete, actionable rule Section G asked for, not a
predicted date to just wait for):

- **Warning** at `percentage_used >= 80` OR `available_spare < 50` — start sourcing a
  replacement drive, not urgent same-week but don't defer past this point.
- **Replace now** at `percentage_used >= 90` OR `available_spare < 10` OR any
  `media_errors > 0` — the drive backs literally everything (all 3 k3s VMs, every
  LXC, `local-lvm`) with no separate physical fallback (see Topology reality below);
  waiting for an actual failure here is not an acceptable risk on a single-disk host.
- PrometheusRule alerts for both thresholds exist in
  `kubernetes/system/monitoring/hardware-temp-alerts.yml` (name predates this addition,
  covers more than temperature now) as `NVMeWearWarning`/`NVMeWearCritical`, using the
  `smart_nvme_percentage_used` and
  `smart_nvme_available_spare_percent` metrics built in Section E — currently blocked
  from reaching Prometheus by the same unapplied `fwd_04a_srv_monitoring` Terraform
  firewall rule as the rest of the host-level metrics pipeline (see
  `phase8/LEDGER.md`), so they exist as code but aren't live-firing yet.

As of this writing (2026-08-22): 56% used, 0 media errors, 100% available spare —
not in warning range yet, but the trend above means this deserves checking again
within weeks, not months, especially once real historical Prometheus data (rather
than two manual snapshots) makes the actual current rate visible instead of having
to bound it between two very different estimates.

### Write-rate reduction (operator decision: not replacing the drive)

Given the projection above, the operator decided to keep this drive rather than
replace it, and asked for every reasonable lever to reduce the ongoing *write rate*
to stretch the timeline. `percentage_used` cannot be reduced (it's a lifetime
counter), so this section is entirely about slowing how fast it climbs.

**Applied:**

- **`vm.swappiness` lowered from 10 to 5** (`ansible/roles/pve_power`). Found live
  6.6GiB of the host's 8GiB swap in active use (`vmstat` si/so columns showing
  ongoing swap-in/out, not just historically-allocated-and-idle) -- every swapped
  page is a write to this same NVMe. Not dropped to the more aggressive "1" some
  tuning guides suggest: this host has real, documented history of memory pressure
  under load, and over-tuning swappiness trades swap I/O for OOM-kill risk, a worse
  trade on a host that showed real fragility earlier the same day this change was
  made. Doesn't evict what's already in swap, only slows the rate of new pages being
  pushed out — the reduction shows up gradually, not immediately.
- **`trivy-operator` concurrency lowered from 3 to 1** (`OPERATOR_CONCURRENT_
  SCAN_JOBS_LIMIT`), applied while the operator is already paused (see ADR-023's
  2026-08-22 update). Researched whether trivy-operator supports batched/scheduled
  scanning instead of its default event-triggered model — it doesn't; periodic
  rescanning is an open, unimplemented upstream feature request
  ([aquasecurity/trivy-operator#1696](https://github.com/aquasecurity/trivy-operator/issues/1696),
  [#744](https://github.com/aquasecurity/trivy-operator/issues/744)), not a config
  option in the deployed version. Concurrency is the lever actually available:
  serializing scan jobs doesn't reduce total bytes written, but spreads the same
  work over more wall-clock time instead of bursting several concurrent image-layer
  extractions at once — which is specifically what pegged NVMe queue depth during
  the 2026-08-22 incident.

**Investigated, found not to apply (corrected an assumption rather than acting on
it):** Loki's and Prometheus's TSDB/chunk storage are both already on the
`nfs-client` storage class (CT220's disk), not this NVMe — confirmed by reading
their actual `storageClassName` values, not assumed. Shortening their retention
periods (both currently 30d) would reduce load on the NFS server, but has no effect
on this drive's wear. Not changed, since the reasoning behind investigating them no
longer applies.

**Investigated, deliberately not changed:**

- **Container log rotation** (kubelet `--container-log-max-size`/`--container-log-
  max-files`): using k3s/containerd defaults (10Mi/5 files), no override found, no
  obviously-misconfigured verbose logging found across the repo's manifests either.
  Tuning this further needs a kubelet restart on the control-plane node — the same
  risk class as the still-blocked egress-selector-mode restart (real bugs already
  documented in the vendored k3s-ansible role for incremental changes to a running
  host). Not worth that risk for a marginal gain on already-reasonable defaults.
- **ArgoCD reconciliation interval** (`timeout.reconciliation: 300s`): reviewed —
  this drives apiserver LIST/diff overhead (CPU/network), not NVMe writes directly;
  only *actually correcting* drift generates a write, and that write comes from
  whatever's being corrected, not from the reconciliation check itself. Low expected
  payoff for this specific goal against a real loss of drift-detection responsiveness
  — not changed.
- **vzdump (nightly backup) frequency**: backups write to `local-pbs`
  (PBS, on the separate HDD `archive` pool per this doc's Inventory table above),
  not this NVMe — the wear-relevant cost is read I/O plus LVM-thin snapshot
  copy-on-write amplification for any VM writes that happen *during* the backup
  window, not the backup's own write destination. Reducing backup frequency would
  reduce that COW-amplification window, but at a direct RPO cost — and this entire
  recovery mission has been built around proving the backup chain trustworthy.
  Deliberately not touched without the operator's own explicit sign-off; flagging
  the tradeoff here rather than either making the call unilaterally or silently
  skipping it.
- **ZFS ARC/dirty-data tuning**: already extensively tuned from a prior incident
  (`arc_max`, `prefetch_disable`, `dirty_data_max`, `txg_timeout`,
  `zfs_vdev_async_write_max_active` — see `ansible/roles/pve_power/defaults/
  main.yml`). No further headroom identified without diminishing returns.

**Honesty note on the earlier Section G right-sizing pass**: that work
(`feat/section-g-right-sizing`) bumped four Kubernetes pod memory *requests* --
a scheduling hint inside the k3s guests, not a change to actual memory consumption,
and entirely unrelated to the Proxmox host's own swap (a different memory domain).
It does not reduce host swap and was never going to; the swappiness change above is
the real lever for that specific problem. Correcting this here since the operator's
original request assumed a connection between the two that doesn't actually hold.

## Topology reality — this is not an HA cluster

`pve-mgmt-01` is a single point of failure for compute. There is no way to make this
genuinely zero-downtime with this hardware, and no configuration should pretend
otherwise. The actual design target is **fast, tested recovery**, not high availability
— every stateful component has a documented restore procedure (see per-service READMEs
under `kubernetes/apps/*/README.md` and `kubernetes/system/*/README.md`), backups are
proven restorable (not just scheduled), and the RTO/RPO this implies is measured in
minutes-to-hours for a full rebuild, not seconds of failover.

The two RPis are the one piece of real redundancy in this homelab: DNS (AdGuard +
Unbound) is VRRP-paired between them via keepalived, so losing either one individually
doesn't take down name resolution for the network. This was demonstrated live during the
2026-08-13 recovery (LEDGER Entry 45) — stopping the standby's DNS service had zero
impact on the network's actual resolution path, because the VIP stayed on the primary
throughout.

RPi SD cards are write-fragile — the same general class of concern as the boot NVMe, at
smaller scale. They run DNS/edge only, never databases or heavy logging. David has
attached a USB-SATA adapter + SSD to `rpi-srv-02` (2026-08-14: confirmed live, `sda`,
111.8G, `usb` transport, no partition table or filesystem yet — nothing built on it) to
reduce this risk and potentially support running a service independently of the main
Proxmox host (e.g. Vaultwarden or Headscale). See the §4.2 architecture review for
whether/what to place on it — do not assume a filesystem exists without checking.

## What NOT to do to this hardware

- Don't reintroduce etcd, ZFS on the boot pool, or Longhorn without a specific, measured
  reason that outweighs the write-amplification history above — "it's the more standard
  choice" is not sufficient justification given this drive's specific failure mode.
- Don't schedule heavy, bursty write workloads (large image pulls, ML model downloads,
  bulk backups) without considering contention — this recovery's own bulk 30-app
  ApplicationSet deploy caused several Postgres instances' `initdb` to get interrupted
  purely from simultaneous I/O contention, not a bug in any individual app.
- Don't put databases or write-heavy state on the Immich USB stick or the RPi SD cards —
  both are fine for their current, deliberately write-once/read-many or read-mostly
  roles, not for anything else.
