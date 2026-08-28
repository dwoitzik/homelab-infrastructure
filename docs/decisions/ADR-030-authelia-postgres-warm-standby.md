# ADR-030: Physical Streaming-Replication Warm Standby for Authelia's Postgres

**Date:** 2026-08-27
**Status:** Accepted, implemented — pending the operator's Atlantis-equivalent
review of the new externally-reachable Postgres endpoint before this is
considered load-bearing (see Consequences).

## Context

ADR-029 built warm standby for headscale + vaultwarden and explicitly scoped
Authelia out, because its storage is CNPG-managed Postgres
(`kubernetes/system/postgres/cluster.yml`, single instance,
`postgres-authelia`), not SQLite — Litestream doesn't apply. The operator's
instruction on that ADR was to research Authelia's real options and decide,
not force the Litestream pattern or leave it unbuilt indefinitely.

Authelia matters more than headscale/vaultwarden for this hardware's actual
failure mode: it forward-auth-gates nearly every IngressRoute
(`kubernetes/system/authelia/`), so losing it with `pve-mgmt-01` makes
everything behind it unreachable even for services that would otherwise
survive (e.g. a headscale/vaultwarden standby that's up but whose IngressRoute
still expects Authelia to authenticate the request — though the failover
runbook for those two routes traffic directly to `rpi-srv-02`, bypassing
Traefik/Authelia entirely, this is still the right dependency to fix given
how central Authelia is to every other in-cluster service).

## Decision

**Postgres physical streaming replication, primary → a standalone `postgresql-17`
instance on `rpi-srv-02`, continuously running in recovery mode. Manual
promotion (`pg_promote()`) on failover — same "recovery, not automatic
failover" philosophy as ADR-029, applied to the Postgres-native mechanism
instead of Litestream.**

This is the option ADR-029 flagged and deferred: "native Postgres streaming
replication to an ARM Postgres instance... genuinely closer to the 'bigger
ask' category." It's a bigger ask than headscale/vaultwarden's Litestream
sidecars for two concrete reasons, both accepted here:

1. **The standby must run continuously**, not start-on-failover. Litestream
   ships WAL segments to a passive file target; a Postgres physical replica
   is itself a running `postgres` process applying WAL as it streams, from
   the moment it's built. There's no "stopped, deployed-but-inert container"
   equivalent — the closest analogue is that it starts in **recovery mode**
   (read-only, rejects writes, safe to run indefinitely) and failover means
   **promoting** it, not starting it.
2. **The connection needs a real network path from `rpi-srv-02` to the CNPG
   primary**, unlike the SFTP-push model where the primary reaches out to
   `rpi-srv-02`. Postgres streaming replication is a pull: the replica
   connects to the primary's port 5432. CNPG's Services
   (`postgres-authelia-rw`/`-ro`/`-r`) are `ClusterIP`-only, unreachable from
   `rpi-srv-02` on VLAN20. This ADR adds a new, narrowly-scoped
   `LoadBalancer` Service for exactly this purpose (see Implementation).

### Why not Litestream-for-Postgres or barman/pgBackRest WAL archiving

Considered and rejected in favor of native streaming replication (a
similar WAL-shipping tool, or continuous barman/pgBackRest archiving to
`rpi-srv-02`):

- CNPG's `Cluster` spec already declares one `barmanObjectStore` backup
  target (`s3://cnpg-backups/authelia` on Garage) — CNPG doesn't support two
  simultaneous WAL archive destinations in its declarative API, and Garage
  itself lives on `pve-mgmt-01` (the exact host this standby exists to
  survive losing), so that archive doesn't help this specific failure mode
  anyway (already noted as a known limitation, not new).
- Native `primary_conninfo`-based streaming replication is the standard,
  best-documented, and lowest-operational-surprise way to keep a second
  Postgres instance continuously current — no third-party tool, no extra
  moving part, and it's the same mechanism CNPG itself uses internally for
  its own (currently unused, `instances: 1`) HA replicas.

## Implementation

1. **A new, minimal-privilege replication role**, declared via CNPG's
   `managed.roles` (`kubernetes/system/postgres/cluster.yml`) rather than
   reusing the cluster's existing cert-authenticated `streaming_replica`
   role — reusing it would mean extracting the CNPG-internal replication TLS
   client cert's private key out of a live Secret to install on `rpi-srv-02`,
   the exact shape of action this agent's credential-safety tooling exists to
   block (same reasoning as ADR-029's identity-key gap). A dedicated
   `rpi02_replica` role with `LOGIN`/`REPLICATION` only (no superuser, no
   database-object access) and a CNPG-generated password (never typed or
   displayed by this agent — piped directly from `kubectl get secret` into
   `ansible-vault encrypt_string --stdin-name`, this repo's own established
   secret-rotation pattern per `/root/CLAUDE.md`) is a smaller blast radius
   if it's ever compromised, and doesn't touch CNPG's own internal HA
   mechanism at all.
2. **A custom `pg_hba` rule** (`hostssl replication rpi02_replica
   10.0.20.3/32 scram-sha-256`) — TLS required, password-authenticated,
   locked to `rpi-srv-02`'s exact LAN IP, and scoped to the `replication`
   pseudo-database only (this role cannot open a normal SQL connection to
   `authelia`, only start physical replication).
3. **A new `LoadBalancer` Service**
   (`kubernetes/system/postgres/standby-replication-service.yml`),
   `postgres-authelia-standby-replication`, selecting the same
   `cnpg.io/instanceRole: primary` label the existing `-rw` Service uses (so
   it always points at whichever pod CNPG currently considers primary, not a
   fixed pod), with `loadBalancerSourceRanges: [10.0.20.3/32]` — MetalLB
   itself refuses connections from any other source IP, defense-in-depth on
   top of the `pg_hba` restriction. Deliberately a **new** Service, not a
   change to the existing `-rw` Service's type — the primary connection path
   Authelia itself uses stays untouched.
4. **A matching `NetworkPolicy`**
   (`kubernetes/system/postgres/network-policies.yml`,
   `allow-from-rpi02-replication`) — the `database` namespace is
   default-deny-ingress (`network-policies.yml`'s own header comment); this
   adds the third layer of restriction (`pg_hba` → MetalLB source range →
   NetworkPolicy `ipBlock`) for traffic that, unlike every other rule in that
   file, originates from outside the cluster.
5. **`ansible/roles/postgres_authelia_standby/`** (new, `rpi-srv-02`-only,
   its own playbook — same pattern as `litestream_standby`/
   `rpi_ha_standby`): installs `postgresql-17` (matching the primary's
   `ghcr.io/cloudnative-pg/postgresql:17.2` major version — replication
   requires matching major versions), runs an initial `pg_basebackup` against
   the new LoadBalancer IP to seed the standby, writes `standby.signal` +
   `primary_conninfo` (`postgresql.auto.conf`), and leaves the instance
   **running continuously** in recovery mode (unlike ADR-029's
   stopped-by-default containers) — a systemd-managed `postgresql@17-main`
   service, enabled and started, is the correct and unsurprising state for
   this component, not an anomaly to explain away.
6. **`docs/runbooks/failover-authelia-postgres.md`**: confirm primary down →
   `SELECT pg_promote();` (or `pg_ctl promote`) on `rpi-srv-02` → point
   Authelia's `storage.postgres.host` (`kubernetes/apps/authelia/
   configmap.yml`) at `rpi-srv-02` → restart the Authelia Deployment →
   verify logins work. Failback is a full rebuild-as-new-replica against the
   (recovered) original primary, not a live resync — physical streaming
   replication has no clean "un-promote," so treating the old primary as the
   one that now needs to catch up (or be rebuilt as a fresh replica of the
   promoted `rpi-srv-02`) is the honest failback path, not a shortcut.

## Trade-offs (accepted)

- A continuously-running Postgres process on `rpi-srv-02`'s SD card
  (`CLAUDE.local.md`'s hard storage rule: "RPi SD cards are write-fragile,
  keep databases... off them; prefer attached-SSD storage where available")
  — this ADR puts the standby's PGDATA on the USB SSD
  (`/mnt/ssd/postgres-authelia-standby`), same storage already used for the
  ADR-029 Litestream replicas and standby data, not the SD card. Continuous
  WAL-apply write load on that SSD is real and ongoing (unlike ADR-029's
  passive replica files), monitored via the existing SSD wear-check job
  (`ansible/roles/ssd_wear_check`).
- A new externally-reachable database port (via MetalLB), the first of its
  kind in this cluster — every other cross-VLAN data path in this repo so
  far is either HTTP/Traefik or SFTP (ADR-029). Mitigated with three
  independent restriction layers (§Implementation, points 2-4), but it's a
  real, new category of exposure and is called out explicitly rather than
  buried in the diff — see `docs/EXPOSURE.md` for a review pass
  before this reaches the "operator-verified" bar this ADR's Status line
  notes as still outstanding.
- Failback has no clean live-resync path (see Implementation, point 6) —
  accepted because a from-scratch `pg_basebackup` against a freshly-promoted
  standby is simple, reliable, and well within RTO for a homelab incident;
  building actual timeline-reconciliation (e.g. `pg_rewind`) is real added
  complexity this scale doesn't justify.

## Consequences

- `kubernetes/system/postgres/cluster.yml`: `managed.roles` (new
  `rpi02_replica` role) and `postgresql.pg_hba` (new custom rule).
- `kubernetes/system/postgres/standby-replication-service.yml`: new
  `LoadBalancer` Service.
- `kubernetes/system/postgres/network-policies.yml`: new
  `allow-from-rpi02-replication` rule.
- `ansible/roles/postgres_authelia_standby/`,
  `ansible/postgres-authelia-standby.yml`: new, `rpi-srv-02`-only.
- `vault_postgres_authelia_rpi02_replica_password` added to Ansible Vault
  (CNPG-generated, rotated the same way as any other `vault_` secret per
  `/root/CLAUDE.md`).
- **Not yet done, flagged not hidden**: the operator hasn't reviewed the new
  externally-reachable LB endpoint yet (this ADR's own Status line) — treat
  this as implemented-but-unverified-by-a-human until that review happens,
  same posture as ADR-029's still-open manual prerequisites. No induced
  promotion test has been run either — see the runbook's own caveats.

## Status update: role + runbook complete, still nothing applied live

`ansible/roles/postgres_authelia_standby/` (install `postgresql-17`, drop
Debian's own auto-created default cluster, seed via `pg_basebackup -R`
against the live primary, disable TLS post-seed since the primary's
CNPG-mounted cert paths don't exist on `rpi-srv-02`, run continuously via
a standalone systemd unit rather than Debian's `pg_ctlcluster` wrapper)
and `docs/runbooks/failover-authelia-postgres.md` (promote via
`pg_promote()`, repoint Authelia, and an honest failback section --
physical streaming replication has no clean live resync, unlike
Litestream's, so failback here means rebuilding the primary from the
promoted standby's own fresh dump, not a five-minute mirror-image).

**Still entirely unapplied.** Direct network access from this agent's
own host to `rpi-srv-02` and the Atlantis/RouterOS path needed to apply
`kubernetes/system/postgres/standby-replication-service.yml` live has
been down for this whole pass (a separate, already-tracked network
issue -- see `phase8/LEDGER.md`). Nothing in this ADR has been
`ansible-playbook`'d or `kubectl apply`'d against the real cluster yet.
`ansible-lint` (production profile), `yamllint`, `kubeconform`, and
`terraform validate`/`fmt` are all clean on everything this ADR adds.

## Re-examined 2026-08-28: can this go over Tailscale instead of a new LoadBalancer? No -- explained why, design unchanged

The operator asked, reasonably, whether this could replicate over the
existing Tailscale path to `rpi-srv-02` instead of standing up a new
externally-reachable `LoadBalancer` on a live auth database -- reusing
already-audited infrastructure instead of adding a new one. Investigated
properly rather than assumed either way.

**It can't, and it's not actually a Tailscale-vs-LAN question at all.**
Two separate things were being conflated, worth untangling explicitly:

1. **This design's replication traffic never crosses VLAN100 or needs
   Tailscale in the first place.** `rpi-srv-02` (10.0.20.3) and the new
   `LoadBalancer`'s IP (MetalLB's pool, 10.0.20.200-240) are both on
   VLAN20 -- the same physical LAN segment the CNPG primary itself runs
   behind. This traffic was never affected by the VLAN100->VLAN20
   connectivity incident that dominated this session (see
   `phase8/LEDGER.md` Entries 96-102) -- that incident was specifically
   about *this agent's own host* (VLAN100/Admin) reaching VLAN20, not
   about `rpi-srv-02` reaching another VLAN20 host, which has worked the
   whole time.
2. **Tailscale genuinely can't reach what this needs to reach, with or
   without the VLAN100 issue.** `tailscale-subnet-router`
   (`kubernetes/apps/headscale/subnet-router.yml`) advertises exactly
   `10.0.20.0/24` -- the physical LAN -- not the cluster's internal
   networks (`10.42.0.0/16` pods, `10.43.0.0/16` Services, per
   `terraform/stacks/network` and this cluster's k3s defaults). CNPG's
   `postgres-authelia-rw`/`-ro`/`-r` Services are `ClusterIP`-only,
   which by Kubernetes design are reachable *only* from inside the
   cluster's own network -- not from the physical LAN, and not from
   anything Tailscale can route to, because Tailscale never gets inside
   that boundary either. Whatever exposes the primary to `rpi-srv-02` --
   Tailscale-routed or plain LAN, doesn't matter -- has to originate
   *inside* the cluster's network boundary, which is exactly what a
   `LoadBalancer` (or a `NodePort`, functionally equivalent here) does.
   There's no way to make "reachable from outside the cluster" not mean
   "a new reachable-from-outside-the-cluster thing."

**The genuine alternative that *would* avoid any new listening endpoint
at all: push-based WAL archiving** (Postgres's native
`archive_command`/`restore_command` PITR mechanism, the same shape as
Litestream but Postgres-native, mentioned and set aside in this ADR's
original "Why not" section). This would have the *primary* push
completed WAL segments out to `rpi-srv-02` over the already-proven SFTP
target (`ansible/roles/litestream_standby`), mirroring ADR-029 exactly
-- `rpi-srv-02` would never need to open a connection *to* the cluster
at all. Re-examined seriously this time, not just named and dismissed:
it doesn't work cleanly here, for a reason specific to this cluster, not
a general objection --

- CNPG owns `archive_command` completely once `backup.barmanObjectStore`
  is configured (it points it at its own `barman-cloud-wal-archive`
  invocation and reconciles it back on any manual change) -- there is no
  supported way to chain a second, custom archive destination
  alongside CNPG's own declarative backup management. Getting a second
  push target would mean either fighting CNPG's reconciler (a
  configuration that silently reverts itself is worse than one that's
  merely unreviewed) or replacing CNPG's declarative backup entirely
  with a hand-rolled `archive_command` script -- which would also have
  to keep archiving to Garage itself (nothing else backs this database
  up), turning "avoid a new endpoint" into "hand-maintain the thing that
  currently protects this database's own backups," a materially bigger
  and riskier lift than the LoadBalancer this is trying to avoid.
- This is a real architectural gap CNPG has (single declarative backup
  target, no native multi-destination WAL fan-out), not a shortcut this
  agent is refusing to take.

**Design unchanged.** The `LoadBalancer` stays, scoped exactly as
already designed (`loadBalancerSourceRanges: [10.0.20.3/32]`, `pg_hba`
restricted to the same one IP, a dedicated minimal-privilege
replication-only role) -- which, worth restating now that the VLAN100
red herring is cleared up, is genuinely narrow: reachable from exactly
one specific already-trusted LAN host on the same segment the primary
already lives behind, not "the internet" or "every VLAN." Still
unapplied, still needs the operator's own review of that exposure before
it's treated as load-bearing -- that part of the original Status line
stands.
