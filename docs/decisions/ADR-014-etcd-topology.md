# ADR-014: etcd Topology — Restore Single-Server, or Commit to Real 3-Node HA

**Status:** Proposed — awaiting a decision. No changes made. This is a live finding, not
a hypothetical: the cluster's actual running configuration currently contradicts both
this repo's Terraform/Ansible source of truth and a previous ADR-level decision, and it
directly contributed to a real outage on 2026-07-09.

## Context

`docs/k3s-architecture.md` documents a **deliberate, incident-driven decision from
2026-06-23**: run k3s with exactly one control-plane/etcd server (`vm-srv-k3s-11`) and
two agent-only workers (`vm-srv-k3s-12`/`-13`). The doc states this in direct terms:
*"a prior attempt at 3-way embedded-etcd HA... 3 concurrent etcd writers produced enough
I/O contention to lock up the host... **Do not re-introduce multi-server etcd on this
hardware.**"* `ansible/k3s-cluster/inventory.yml` encodes the same thing — `.11` alone in
the `server` group, `.12`/`.13` in `agent`.

**The live cluster does not match this.** Checked directly on 2026-07-09:

```text
kubectl get nodes
vm-srv-k3s-11   Ready    control-plane,etcd,master
vm-srv-k3s-12   Ready    <none>
vm-srv-k3s-13   Ready    control-plane,etcd,master
```

Confirmed on `.13` itself (not just the node label): `k3s.service` (the **server** unit,
not `k3s-agent.service`) is installed, `enabled`, and has a live `/var/lib/rancher/k3s/server/db/etcd/`
directory with real raft data. This isn't a stale label — `.13` is a genuine second etcd
member, running durably, surviving reboots. Both `k3s.service` and `k3s-agent.service`
unit files exist on disk on `.13`, suggesting it was provisioned one way and later
converted to a server without the old unit being cleaned up. Exactly when or how this
happened wasn't pinned down — `.13`'s node age (16 days) is notably younger than `.11`'s
(40 days), which lines up roughly with the full host power-outage recovery a few weeks
back, but that's circumstantial, not confirmed root cause.

**This is silent drift away from an already-made, already-correct, incident-tested
decision — not a fresh 50/50 choice.** Whoever or whatever rebuilt `.13` at some point
put it back into the exact configuration the 2026-06-23 fix explicitly says not to use,
and nothing caught it until today.

### What it just did

At 16:34 today, a runaway CronJob (Renovate, unrelated OOM issue, see the sibling
write-up) spiked host load to ~29 and stalled `vm-srv-k3s-11`. Because `.13` is *also* a
real etcd member, that single node's distress was enough to break quorum — a 2-member
etcd cluster needs **both** members to reach consensus, so it has strictly *less* fault
tolerance than a 1-member cluster, not more. The API server returned `503` cluster-wide
for about a minute until the load subsided. With the documented 1-server design, the
exact same load spike on `.11` would have caused the same brief API disruption (it's
still the same single physical host, same SPOF) — but it would **not** have been made
worse by a second etcd member losing sync with it. The 2-node shape added a real failure
mode with zero corresponding benefit.

## The actual decision

Two honest options, not "keep the current live state" — the live state (2-member etcd)
is dominated by both alternatives below and shouldn't be chosen deliberately by anyone.

### Option A — Restore single-server etcd (recommended)

Revert `.13` to agent-only, matching what `inventory.yml` and `k3s-architecture.md`
already say should be true. Mechanically: drain `.13`, stop/disable `k3s.service`,
remove its etcd data dir, enable/start `k3s-agent.service` pointed at `.11`.

- **Resource cost:** None — this *reduces* load (one fewer etcd writer contending for
  the same shared NVMe that already has a documented I/O-stall history, see
  `docs/OPERATIONS.md`'s Proxmox-freeze writeup).
- **Fault tolerance:** None gained or lost versus today's *intended* design — `mini` is
  a single physical host either way, and zero-downtime HA was never achievable on this
  hardware to begin with. A host-level failure takes out all three k3s VMs regardless of
  etcd member count, since they all live on the same disk. Multi-member etcd only
  protects against a *single-VM*-level failure while the host stays healthy — a narrower
  and less likely failure mode than the host-level and resource-contention issues this
  repo has actually hit repeatedly (the etcd heartbeat/election timeout tuning documented
  inline in `ansible/k3s-cluster/inventory.yml`, the ZFS ARC-pressure host freeze, today's
  renovate incident).
- **Downside:** None identified. This is restoring a decision already made for good,
  documented reasons.

### Option B — Real 3-member HA using the RPi nodes

Add `rpi1`/`rpi2` as genuine etcd members alongside `.11`, giving true majority-quorum
tolerance (any one of three can fail without losing the control plane).

- **Resource cost:** Low compute-wise (etcd itself is light), but two hard blockers:
  - **RPi SD cards are write-fragile, and this repo already treats that as a hard
    guardrail, not a soft preference.** etcd's raft log is fsync-heavy, exactly the write
    pattern that kills SD cards fastest. Doing this safely means USB-SSD boot for both
    RPis first — a real prerequisite project, not a config flag.
  - The RPis currently run AdGuard + Unbound — the whole network's DNS path. Adding a
    k3s control-plane/etcd role to them mixes two critical-path responsibilities on the
    same small boxes: a k3s/etcd problem could now plausibly degrade DNS, and vice versa.
    That's a real increase in blast radius for a system that's deliberately kept simple
    today.
  - Network latency from RPi-to-`mini` adds jitter to etcd's raft consensus. This repo's
    etcd config (`ansible/k3s-cluster/inventory.yml`) already had to loosen the default
    heartbeat/election timeouts (100ms→500ms, 1000ms→5000ms) just to tolerate *local*
    NVMe I/O stalls on one host — a cross-host link to lower-powered ARM boards is a
    plausible new source of the same class of instability, on a different axis than what
    that tuning fixed.
- **Fault tolerance gained:** Real — survives one VM or the RPi hardware failing
  independently, not just a documentation/config guarantee. But it does **not** protect
  against the actual biggest risk this repo has already accepted and documented: `mini`
  itself going down, which still takes out `.11` and both agent workers regardless of
  where etcd's other 2 members live.
- **Recommendation if chosen:** Don't do this until the RPis are on USB-SSD boot. Until
  then this option isn't safely available, only theoretically.

## Recommendation

**Option A.** This repo already made this call once, with a real incident behind it, and
wrote it down clearly. The right fix here is closing the drift, not re-opening the
debate — the live outage today is fresh evidence the original reasoning was correct, not
new evidence that 2-node was a reasonable place to land. Option B is worth keeping on the
roadmap (real HA has genuine value), but only after the RPi SD-card constraint is solved
as its own project — bundling it into an urgent fix would be trading a known-bad state
for an untested one.

## Not addressed here

- *Why* `.13` ended up as a server isn't confirmed — worth a short investigation
  (`journalctl`/Ansible run history around `.13`'s 16-day-old provisioning) before
  applying Option A, so whatever caused the drift gets closed too, not just its symptom.
- This ADR doesn't cover the Garage circularity / NFS SPOF question — separate
  known design session, not conflated here.

## Update 2026-07-09: Option A attempted, rolled back

A real attempt at Option A was made the same day this ADR was written. Pre-flight
backups were taken (fresh etcd snapshot on `.11` + Proxmox VM snapshots of both `.11`
and `.13`), then `.13` was cordoned and drained as the first mechanical step.

The drain alone — before any etcd member was actually removed — was enough to take the
API server unavailable cluster-wide and spike `.12`'s load to 29+. Same signature as the
renovate-triggered incident that originally surfaced this ADR: a load event on the
shared NVMe degrading the whole control plane, not something specific to etcd surgery
itself. Uncordoning `.13` didn't recover it; the API stayed degraded and load kept
climbing for several minutes afterward.

Rolled back cleanly via the pre-op snapshots — both VMs restored, cluster back to 3/3
Ready. The rollback itself had a real cost worth recording plainly: it reverted `.11`
and `.13`'s disk state to the snapshot point, which (since those two VMs are the etcd
members) reverted etcd's stored state for the entire cluster to that point in time, not
just those two nodes. Anything written after the snapshot and before the rollback —
local-path-backed services scheduled on those nodes specifically (Vaultwarden, Gitea,
Headscale, Garage metadata, Uptime Kuma, Authelia's auth logs were all on `.13`;
Tailscale subnet-router state was on `.11`) — is at risk for that window. GitOps-managed
manifests (ArgoCD-tracked resources) self-healed automatically once ArgoCD reconciled
against git; two manual bootstrap-only Application manifests (files with no parent
Application watching them) did not and had to be manually re-applied.

**Conclusion for the next attempt:** this cluster falls over on a plain `kubectl drain`
of one node — that's a lower bar than etcd member removal itself. The host's shared-NVMe
I/O fragility has to be resolved first (hardware cooling fix + the PBS `bwlimit`/`ionice`
load-smoothing already in place, proven effective over a real multi-night baseline) before
etcd surgery is safe to attempt again. Option A is now downstream of the cooling fix, not
an independent, schedulable task — attempting it again before that's confirmed stable
would just repeat this same outcome.

## Plan for the next attempt (added 2026-07-12)

Approved in principle, deliberately not scheduled yet — this is downstream of the
cooling fix per the conclusion above, and both surgeries touch `.11`/`.13` (the etcd
members), so they go in the **same maintenance window**, not two separate ones: fresh
snapshots taken once, both fixes applied, one recovery plan if something goes wrong.

**Step 0 — clear the `home.lan` search-domain drift first, before touching etcd.**
Root-caused separately (see `docs/AUDIT.md` REL-068 / the 2026-07-10 DNS sweep):
Proxmox's cloud-init generator falls back to the PVE node's own configured search
domain (`pvesh get /nodes/pve-mgmt-01/dns` → `home.lan`) whenever a VM's
`initialization.dns.domain` is left unset — confirmed live, not RouterOS/DHCP as
originally suspected. `domain = ""` is already declared in
`terraform/stacks/proxmox/vm.tf` for all 3 k3s VMs, but that block is in
`lifecycle.ignore_changes`, so it has zero effect on the already-provisioned VMs by
itself. The actual fix, both parts done in the same window as the etcd work below:

1. `pvesh set /nodes/pve-mgmt-01/dns -search ""` — clears the PVE node's own default.
   No Terraform resource models this (same class of gap as `vzdump.conf`/`local-pbs`'s
   password, see `IAC-GAPS.md` item 6); one-time manual host config, document it there
   once done.
2. Cloud-init regen + network re-apply on `.11`, `.12`, `.13` so their live netplan
   config actually drops `search: home.lan` — this is the part that touches all 3 VMs,
   including both etcd members, hence bundling with the etcd window rather than doing
   it standalone.

Doing this *before* the etcd member change (not after, not in parallel) means the etcd
surgery itself starts from a clean, already-verified-stable network config, rather than
debugging two changes at once if something goes wrong mid-window.

**Not urgent on its own.** The `.home.lan` NXDOMAIN traffic (27% of all DNS queries,
confirmed 2026-07-10) is a cosmetic cost in the meantime, not a functional one — unbound
answers it locally at ~2ms via the existing static-zone fix (REL-059), so nothing is
slow or broken, it's just wasted query volume. No reason to rush this ahead of the
cooling fix just to silence it.

**Trigger condition to actually schedule this window:** hardware cooling fix confirmed
stable (a real multi-night baseline showing peak temp reliably under the
`ProxmoxHostHighTemp` 85°C/3min threshold, not just one or two good nights) — same bar
already stated above for Option A itself. When that's met, this becomes: fresh Proxmox
VM snapshots of `.11`/`.13` → DNS fix (steps 1-2 above) → verify cluster still healthy →
etcd single-server revert (Option A, full mechanic already documented earlier in this
ADR) → verify → done. One window, one set of snapshots, one rollback plan if either part
goes wrong.
