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
| 2026-08-22 (morning) | 56% | 36.6 TB | 2,344 |
| 2026-08-22 (night, re-measured) | 56% | 36.6 TB (71,527,289 units) | 2,350 |

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

As of this writing (2026-08-22, re-measured same night after a host hang and hard
power-cycle -- see below): 56% used, 0 media errors, 100% available spare -- not in
warning range yet, but the trend above means this deserves checking again within
weeks, not months, especially once real historical Prometheus data (rather than
manual snapshots) makes the actual current rate visible instead of having to bound
it between two very different estimates.

**Re-measurement, same night, post-hard-reboot**: `percentage_used` is unchanged at
the 1%-resolution the counter reports (56%), and the raw `Data Units Written` moved
from 70,667,597 to 71,527,289 (+859,692 units, ~440 GB) over the ~12 hours between
this morning's pipeline-build reading and this one -- driven by today's own incident
and recovery work (a host hang, hard power-cycle, Kyverno/trivy-operator load
incident, extensive GitOps reconciliation), not representative of steady-state daily
usage, so not folded into the projection above as a new rate estimate. The
projection dates (~2026-09-19 recent-rate / ~2026-11-14 lifetime-rate) stand
unchanged -- meaningfully updating them needs either several more days of *settled*
operation, or the real Prometheus time series once it's reachable (see below).

The hard power-cycle itself is the more interesting thing to have checked: unclean
shutdowns are harder on flash than clean ones, and this drive backs the entire host
with no fallback. `smartctl -a` post-reboot shows `Critical Warning: 0x00`, `Media
and Data Integrity Errors: 0`, `Error Information Log Entries: 0` -- genuinely
healthy, no damage found. Two lifetime counters worth tracking going forward now
that they've been read for the first time: `Power Cycles: 182` and
`Unsafe Shutdowns: 71` (both cumulative across this drive's whole life on this host,
not just tonight -- no prior baseline to diff against, but a real reliability signal
given this host's documented history of freezes, see ADR-023). A brief NVMe I/O
timeout/abort burst was logged in `dmesg` 6 minutes after tonight's boot completed
(23:05:31-23:06:13, all `Abort status: 0x0`, i.e. cleanly recovered) -- the same
post-reboot reconciliation-storm pattern REL-012c already exists to dampen for
trivy-operator specifically; this instance resolved on its own within ~5 minutes
with zero resulting errors, not chased further.

**Still open**: `smart_nvme_percentage_used`/`smart_nvme_available_spare_percent`
still aren't reaching Prometheus -- `node-exporter-pve` (`10.0.10.10:9100`) still
shows `down` in Prometheus's own target list, so `NVMeWearWarning`/`NVMeWearCritical`
exist as code but still don't actually fire. Checked one layer further than the
original finding: the `fwd_04a_srv_monitoring` MikroTik rule that's supposed to
allow this has been in git since long before this session (commit `65a65de`), which
means the live router likely never actually has it -- consistent with this repo's
known Terraform-state loss (state was wiped and needs re-import for dozens of
MikroTik/Proxmox resources, see `phase1/LEDGER.md`/`phase8/LEDGER.md` history) rather
than a rule nobody wrote. Not fixed directly -- MikroTik changes are Atlantis-only by
this repo's own hard rule (`CLAUDE.local.md`), and this needs a real Terraform state
audit, not a manual router edit. Folded into the maintenance-window runbook's
pre-check list below.

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

## Power and thermal efficiency

Reviewed for real headroom (lower power/heat without hurting performance), using
the RAPL power metrics built for Section G's power dashboard to actually measure
rather than guess.

**Current state (2026-08-22), measured live:**

- Governor: `schedutil` on all cores (dynamic, appropriate for a host mixing
  latency-sensitive services — Authelia, Traefik, ArgoCD — with idle periods;
  neither `performance` (wastes power sitting at max clocks) nor `powersave`
  (would hurt those latency-sensitive paths) would be a better default).
- CPU temp (Tctl): 62°C. NVMe temp: 54.85°C. Both comfortably below their
  respective throttle thresholds (this repo's own `ProxmoxHostHighTemp` alert
  fires at 85°C) — no thermal problem exists to fix, confirmed via `dmesg`
  showing zero throttle events.
- CPU package power draw (RAPL, measured directly): **10.15W average** over a
  10-second window at the host's current everyday load. For reference, this
  Ryzen 5825U's typical mobile/embedded TDP range is roughly 15-28W depending on
  cTDP configuration — 10W at ordinary load is already a reasonably efficient
  operating point, not an obviously wasteful one.

**Real finding: `amd_pstate=active` has never actually taken effect.**
`ansible/roles/pve_power` has deployed a GRUB drop-in
(`/etc/default/grub.d/amd_pstate.cfg`, created 2026-08-17) intending to switch
from software-driven `passive` mode to hardware-managed `active` mode (which
also enables EPP — Energy Performance Preference — a more responsive,
generally more power-efficient scheduling hint than passive mode's `schedutil`
alone). Checked live: the running kernel's `amd_pstate/status` is still
`passive`, and `/proc/cmdline` confirms it. Traced why: the host's last boot
was 2026-08-15, two days *before* the drop-in was even created — `update-grub`
has run since then (confirmed: `/boot/grub/grub.cfg` already contains
`amd_pstate=active` from the drop-in, correctly layered after the base
`amd_pstate=passive` default), but the host itself hasn't rebooted to actually
load that config. The fix has been fully ready and waiting for 5 days.

One silent consequence of this: `pve-cpu-power.service` (the unit that sets
EPP to `balance_power` on every boot) has been reporting `SUCCESS` this whole
time, but that's misleading — its `ExecStartPost` line swallows failures
(`|| true`) by design, and the EPP sysfs path
(`.../cpufreq/energy_performance_preference`) doesn't exist at all under
`passive` mode. The EPP setting has never once actually applied since this
role was written; it's been silently writing to a path that isn't there.

**Not applied — flagged for the operator, not decided unilaterally.** Loading
the pending `active` mode requires a host reboot, which takes down all 3 k3s
VMs and everything they run, however briefly. That's a real, if likely small
(minutes), user-facing outage, and per the operator's own standing instruction
this isn't a call to make without a green light. Expected payoff: AMD's own
guidance and general community benchmarking suggest `active` mode with EPP
typically yields modest additional efficiency over `passive` mode +
`schedutil` — real, but not transformative; this host is not currently in an
obviously wasteful state to begin with (see the 10.15W baseline above). The
10.15W figure is recorded specifically so a real before/after comparison is
possible whenever the reboot happens, rather than a vague "should be better."

**Investigated, not enough data yet**: whether PBS/vzdump's 03:00 nightly
schedule overlaps meaningfully with any lower-draw window worth aligning to.
No historical RAPL data exists yet to check this against (metrics collection
was only just built — see Section E/G — and is still blocked from reaching
Prometheus by the same unapplied `fwd_04a_srv_monitoring` Terraform firewall
rule as the rest of this host's metrics). 03:00 is already a reasonable choice
on general principle (low interactive-use hours for a single-operator
homelab) and there's no concrete evidence it's wrong — not changed without
real data to justify a change either way. Revisit once RAPL history actually
accumulates in Prometheus.

### Update, 2026-08-23: reboot done, a real governor/EPP bug found and fixed

The operator executed the reboot (`docs/RUNBOOK-maintenance-window-restart-
batch.md`). Confirmed live: `amd_pstate=active` genuinely in effect
(`scaling_driver` reads `amd-pstate-epp`, not the old `amd-pstate`), and the
`energy_performance_preference` sysfs path now exists and is readable, as
predicted above.

**A real bug the reboot exposed**: `scaling_available_governors` under active
mode is just `performance powersave` -- `schedutil` (this role's configured
governor) isn't offered under active mode at all. `pve-cpu-power.service`'s
`ExecStart` (`cpupower frequency-set -g schedutil`) failed (exit 237) every
time it ran post-reboot, which meant its `ExecStartPost` (the EPP-setting
line) never ran either -- EPP stayed at the driver's own default
(`balance_performance`), not the intended `balance_power`. Fixed by changing
`pve_power_cpu_governor` to `powersave` (the correct active-mode choice --
EPP does the actual fine-grained tuning from there) and re-running the role
live, no further reboot needed. Verified: `systemctl status
pve-cpu-power.service` now shows both `ExecStart` and `ExecStartPost`
succeeding, `scaling_governor` reads `powersave`, `energy_performance_
preference` reads `balance_power`.

**Power measurement, with an honest caveat**: three 10-second RAPL samples
right after the fix read 16.10W / 18.98W / 17.77W, then 15.46W on a fourth
sample a bit later -- all higher than the 10.15W baseline, which looks like a
regression at first glance but isn't a clean comparison: host load was
genuinely elevated during every one of these samples (1-min load average
11.65-15.20, all 3 k3s VMs' qemu processes visibly busy in `ps aux`, this
session's own concurrent Ansible/kubectl activity a real contributor) against
whatever quieter moment the original 10.15W figure was captured at ("the
host's current everyday load" -- not a controlled idle baseline either, in
fairness). The correctness of the fix itself isn't in question -- EPP and
governor are now verifiably set to the intended values, where before they
silently weren't (a strictly better starting point than before, regardless of
what the wattage happens to read under load) -- but a real, comparable
before/after number needs both sides measured at genuinely matched load, which
this pass didn't have. Recorded here rather than cherry-picking a flattering
number or omitting the result. **Follow-up**: re-sample RAPL during a genuinely
idle window (once `node-exporter-pve` actually reaches Prometheus -- still
blocked, see above -- this becomes a Grafana query instead of a manual SSH
sample, and idle-window comparisons get much easier).

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
