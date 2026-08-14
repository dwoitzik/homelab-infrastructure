# ADR-016: Move Headscale off the k3s cluster to rpi-srv-02

**Date:** 2026-08-14
**Status:** Accepted (decision only — migration not yet executed, see Consequences)

## Context

`pve-mgmt-01` is the sole physical compute node for the entire homelab (see
`docs/HARDWARE.md` — this is documented, deliberate, not an oversight: real HA is not
achievable with this hardware, so the design target is fast recovery, not zero downtime).
Every k3s-hosted service, including Headscale (the Tailscale control plane gating remote
access to this whole network), goes down together if that one host goes down.

David has now attached a USB-SATA SSD (111.8G, confirmed live via `lsblk`: `sda`, `usb`
transport, unpartitioned, nothing on it yet) to `rpi-srv-02`, one of the two Raspberry Pi
4Bs that currently only run AdGuard + Unbound (VRRP-paired with `rpi-srv-01` via
keepalived). `docs/HARDWARE.md` already flagged this SSD as a candidate for running a
service independently of the Proxmox host, naming Vaultwarden or Headscale as examples.
Phase 6 (`/root/phase6/BRIEFING-V2.md` §4.2) asks explicitly whether the RPis are being
used well or just running DNS "because they always have," and whether the LXC/VM split
and single-host topology has genuine gaps worth closing.

Two real candidates, both named in HARDWARE.md:

- **Vaultwarden** (password manager). Tier-1 data — 267 ciphers, one of the two acceptance
  tests for this entire recovery. Currently on Longhorn (replicated within the cluster,
  backed up via Velero/Kopia, already proven restorable this recovery). Losing it, even
  briefly, is high-stakes: it is exactly the kind of thing you need *when other
  infrastructure is already broken*.
- **Headscale** (Tailscale control plane). Currently a 5Gi `local-path` PVC (not even
  Longhorn-replicated), small SQLite-backed dataset. Losing the control plane temporarily
  degrades to: existing Tailscale peer sessions keep working (nodes don't instantly lose
  connectivity to each other), but *new* device registration/re-auth and DERP coordination
  stop. Meaningfully less catastrophic than losing password access mid-incident.

## Decision

Migrate **Headscale**, not Vaultwarden, off the k3s cluster onto `rpi-srv-02`'s new SSD,
as a plain Docker Compose service (matching the RPi nodes' existing pattern — AdGuard/
Unbound already run this way there, not k3s).

Vaultwarden stays on the cluster. Its resilience story (Longhorn replication + Velero/
Kopia backup, both already proven this recovery) is adequate for its risk profile, and the
downside of a botched live migration of the actual password-vault data is asymmetric with
the upside of moving it off a single physical host that already has other redundancy
mechanisms in front of it.

## Reasons

- **Blast radius of getting the migration wrong.** Headscale's dataset is small and
  low-consequence to have brief hiccups in (SQLite backup + restore is cheap to verify).
  Vaultwarden's is Tier-1 acceptance-tested data; the recovery's own non-negotiables
  require proving the cipher count matches before and after any migration touching it —
  worth doing eventually, not worth rushing into the same session this was decided.
- **Value of being reachable when Proxmox is down.** Headscale is the control plane for
  the *access path* used to reach and fix everything else, including this agent's own
  Tailscale identity. Keeping it available independent of the node most likely to need a
  reboot or maintenance is a genuine operational win, not just a resilience exercise.
- **The RPis are already the redundancy pattern in this homelab.** DNS (AdGuard/Unbound)
  is VRRP-paired across both Pis specifically so losing one doesn't take down name
  resolution (demonstrated live, LEDGER Entry 45). Extending that same "small, critical,
  independent-of-Proxmox" pattern to Headscale is consistent with the existing design
  philosophy, not a new one.
- **rpi-srv-02 already runs Docker**, so this doesn't introduce a new runtime — same
  operational model as the DNS stack already there.

## Trade-offs

- Headscale moves outside GitOps/ArgoCD's reach — becomes Ansible/Docker Compose-managed
  like the rest of the RPi fleet, not `kubectl`/ArgoCD-managed. Consistent with how
  Atlantis itself was already moved off-cluster (ADR-012) for a similar reason (a service
  that other infrastructure depends on shouldn't be able to take itself down by breaking
  its own host).
- RPi SD card write-fragility doesn't apply here (the whole point of the new SSD is to get
  Headscale's writes off the SD card), but the USB3 SSD's own sustained-write
  characteristics haven't been benchmarked yet the way the Immich USB stick was
  (`docs/HARDWARE.md` §benchmarks) — should be done before trusting it with anything
  bigger than Headscale's small SQLite file.
- Loses Longhorn's replication (Headscale's PVC isn't Longhorn today anyway — it's
  `local-path` — so this is not a regression, just not yet in the eventual Velero/Kopia
  backup story either; needs its own backup plan post-migration, e.g. a simple cron
  `sqlite3 .backup` to Garage, mirroring the pattern used elsewhere).

## Consequences

**Not yet executed.** This ADR records the decision; the actual migration (partition +
format the SSD, install Headscale via Docker Compose on `rpi-srv-02`, back up the existing
`headscale-data` PVC, migrate the SQLite DB, cut over DNS, verify every existing Tailscale
node can still re-register, decommission the in-cluster deployment) is queued as follow-up
work, not rushed into the same pass as the decision — this is Tier-1-adjacent
infrastructure (it gates remote access) and deserves its own careful, verified pass rather
than being bundled into an already-large session.

Until executed: `docs/HARDWARE.md`'s SSD status line reflects "attached, unpartitioned,
nothing built on it" — accurate as of this writing. Revisit this ADR's status once the
migration actually happens.
