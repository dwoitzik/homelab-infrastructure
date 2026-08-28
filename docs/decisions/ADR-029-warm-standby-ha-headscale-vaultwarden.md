# ADR-029: Warm-Standby HA for Headscale + Vaultwarden on rpi-srv-02

**Date:** 2026-08-26
**Status:** Accepted (partially implemented — see Status below)

## Context

`pve-mgmt-01` is a documented single point of failure for the whole k3s cluster
(`CLAUDE.local.md`: "Zero-downtime HA is NOT achievable with this hardware — do not
pretend otherwise"). This has been a real, recurring pain point, not a hypothetical
one — a NetworkPolicy drift this same day took `cloudflared` and the Tailscale
subnet-router down for days, and every such incident requires someone noticing and
hand-diagnosing it with the whole cluster unreachable in the meantime.

The operator wants headscale and vaultwarden specifically to survive a `pve-mgmt-01`
outage, using `rpi-srv-02` (the RPi 4B carrying a dedicated USB SSD, already the
Tailscale HA exit-node failover peer, PR #544) as a standby host. An amendment
extended scope to consider Authelia too, with an explicit instruction to flag it
back rather than force a pattern onto it if its storage backend didn't fit.

True zero-downtime HA is out of scope on this hardware (consistent with the repo's
own established position) and isn't actually what a single-operator homelab needs —
it needs the outage to be short and the data loss to be near-zero, not automatic
failover with its own false-positive/split-brain risks on a stack this size.

## Decision

**Warm standby, manual failover.** Continuous data replication keeps the standby
current; a documented, human-triggered failover (not automatic) avoids split-brain
by construction — only one copy is ever accepting writes at a time, because starting
the standby containers is itself the first deliberate step of failover, not an
always-on second replica.

**Replication: Litestream, SQLite WAL streaming, primary → standby**, for headscale
and vaultwarden specifically. Both are single SQLite-backed processes with tiny
resource footprints — a clean fit for a tool built exactly for this. Chosen over
periodic Velero-restore failover because it gets RPO down to seconds instead of
"however old the last backup is," and over Postgres/real-DB replication because
there's no Postgres involved for either app.

**Replica destination: direct-LAN SFTP to rpi-srv-02, not via the tailnet.**
`HA-PLAN.md`'s own draft left this open ("reuses the existing tailscale SSH path...
or a new LAN port, decide at implementation time"). Decided: plain LAN SFTP
(10.0.20.3:22) — using Tailscale/Headscale's own control plane as a dependency for
*replicating headscale's own data* would be circular and fragile (if the tailnet
mesh itself is degraded, that's exactly when this replication matters most). The
restricted `litestream` SFTP user is chrooted, key-auth-only, no shell — scoped
tightly enough that a plain LAN path doesn't meaningfully widen the attack surface
versus tunneling it over Tailscale would have.

**Standby runtime: Docker on rpi-srv-02, containers present but stopped.**
`rpi-srv-02` isn't a k3s node and doesn't need to become one for two containers —
Docker's already there. Standby containers are defined but not started in normal
operation; starting them is the first step of the failover runbook.

## Authelia — investigated, explicitly scoped out of this ADR

Checked, not assumed: Authelia's `storage` config
(`kubernetes/apps/authelia/configmap.yml`) points at
`postgres-authelia-rw.database.svc.cluster.local` — CNPG-managed Postgres, not
SQLite (ADR-006). Litestream is SQLite-specific; it does not apply here at all.

Real options for a Postgres-backed warm standby (native streaming replication to an
ARM Postgres instance on rpi-srv-02, or WAL-shipping/replay in a similar spirit to
Litestream but Postgres-native) are a heavier, architecturally different lift —
different resource footprint on an RPi 4B, different failure modes, genuinely closer
to the "bigger ask" category the operator themselves used for Traefik/Garage/the
CNPG cluster in general than to headscale/vaultwarden's SQLite simplicity. Flagged
back to the operator (`phase8/QUESTIONS.md`, 2026-08-26 entry; ntfy sent) rather than
forcing the SQLite pattern or building a rushed Postgres-replication design under
this same pass. Not built here.

**Future candidates, explicitly not built, per the operator's own framing**:
Authelia (Postgres replication approach, pending operator input), Traefik, Garage,
and the CNPG Postgres cluster in general. All are architecturally bigger asks with
different failure modes than the SQLite sidecar pattern this ADR covers — real work,
not a natural extension of it.

## Status (2026-08-26)

Implemented and merged:

1. **Replica target on rpi-srv-02** (PR #581,
   `ansible/roles/litestream_standby/`) — a dedicated `litestream` system user,
   chrooted via an sshd Match block (`ForceCommand internal-sftp`, no shell/port
   forwarding), replica directories under `/mnt/ssd/litestream-replicas/`, the
   `litestream` binary itself installed on the host (needed for the manual
   `litestream restore` step in failover, not just the sidecars).
2. **Litestream sidecars on both Deployments** (PR #582,
   `kubernetes/apps/headscale/`, `kubernetes/apps/vaultwarden/`) — continuously
   shipping WAL segments to rpi-srv-02. Verified live: both sidecars logging real
   replica-sync activity, an SFTP check confirms replicated files actually landed,
   both apps still serving real traffic post-rollout. Host-key pinning (litestream's
   own docs call it "strongly recommended") was tried and reverted after a real,
   confirmed failure — see the comment in either `litestream-config.yml` for the
   full reasoning (a genuine Go-ssh-client/multi-host-key-type incompatibility, not
   skipped carelessly).

**Not yet built** (items 3-6 of the original implementation plan,
`phase8/HA-PLAN.md`, numbered here as originally listed there):

- Item 3: Docker-compose standby containers on rpi-srv-02 (`headscale-standby`,
  `vaultwarden-standby`), present but stopped.
- Item 4: the failover runbook itself
  (`docs/runbooks/failover-headscale-vaultwarden.md`).
- Item 5: `docs/DISASTER-RECOVERY.md` / `CLAUDE.local.md` updates reflecting the new
  standby capability.
- Item 6: the induced-failure verification pass (stop the primaries, confirm the
  standby serves real traffic, confirm failback is clean).

**A real gap found while starting item 3, disclosed rather than worked around**:
headscale's `private.key`/`noise_private.key` and vaultwarden's `rsa_key.pem` are
static identity/signing material that lives on the same PVC as the SQLite database
but *outside* it — Litestream only replicates the SQLite file, so these files are
not covered by the replication built so far. Without them, a standby restored from
the SQLite replica alone would generate fresh keys on first start, breaking every
existing device's trust relationship with headscale (a full tailnet re-registration)
and invalidating vaultwarden's existing auth tokens. Extracting these files to seed
the standby was attempted and correctly blocked by this agent's own credential-safety
tooling (the exact shape it exists to prevent — reading a key-shaped file out of a
running pod). Not routed around. **These three files still need a human to copy them
to rpi-srv-02 once, before the standby is genuinely usable** — a real, disclosed
prerequisite for item 6's verification pass, not a solved problem. They rotate
essentially never in practice, so this is a one-time bootstrap step, not an ongoing
burden — but it is a genuine gap, not a detail.

**Also found, unrelated to this work but discovered while testing it**: a
sustained (20+ minute) direct-LAN SSH connectivity failure to *both* Raspberry Pis
(port 22 times out from `pve` and from `ct-srv-claude-agent`, while ICMP to both
succeeds and `rpi-srv-02` remains fully reachable via its Tailscale address) and a
concurrent MagicDNS resolution failure on `ct-srv-claude-agent` for external
hostnames (public resolvers work fine directly). Confirmed this is not caused by
the sshd changes in this ADR — `sshd` on `rpi-srv-02` is verifiably healthy via the
Tailscale path. Reported to the operator via ntfy; not chased further here, as it's
a separate infrastructure issue from this ADR's own scope.

## Trade-offs (accepted)

- A second copy of both apps' identity/config to keep roughly in sync (the static
  key files above) — a one-time, essentially-never-repeated manual step, not an
  ongoing operational burden, but a real one.
- Host-key pinning was dropped for the SFTP replication path (see Status above) —
  accepted for a LAN-only hop already scoped by NetworkPolicy to exactly this one
  destination, with a key-auth-only, chrooted, shell-restricted account. Not
  accepted lightly; the alternative (narrowing rpi-srv-02's sshd host-wide) was
  judged a bigger, riskier change than this credential's actual threat model
  justifies.
- Failover requires a human, and takes on the order of minutes, not milliseconds —
  by design, not oversight. See Context above for why automatic failover was
  rejected.

## Consequences

- `kubernetes/apps/headscale/litestream-config.yml`,
  `kubernetes/apps/vaultwarden/litestream-config.yml`: new, per-app Litestream
  sidecar config.
- `kubernetes/apps/network-policies-egress.yml`: new `allow-egress-litestream-sftp`
  rule.
- `ansible/roles/litestream_standby/`, `ansible/litestream-standby.yml`: new,
  rpi-srv-02-only.
- `vault_litestream_ssh_private_key` added to Ansible Vault; the value actually
  consumed in-cluster lives in a Kubernetes Secret
  (`litestream-ssh-credentials`, `apps` namespace) created directly, not via
  HashiCorp Vault/ExternalSecrets — this agent's own Vault AppRole (`ADR-025`) is
  scoped to exactly `secret/garage` and `secret/homepage`, so that path wasn't
  available without expanding this agent's own credential scope, which this ADR
  deliberately did not do.
- Items 3-6 remain open — this ADR will need a follow-up status update (or a
  superseding entry) once they land.

## Status update, 2026-08-27: items 3, 4, 6 landed

- `ansible/roles/rpi_ha_standby/`, `ansible/rpi-ha-standby.yml`: docker-compose
  definitions for `headscale-standby`/`vaultwarden-standby` on `rpi-srv-02`,
  static config files mirroring the live k8s ConfigMaps, and data directories
  as the `litestream restore` target. Deliberately **deployed but never
  started** by this role or its playbook — starting the containers is the
  failover runbook's job, not something that happens at config-apply time
  (avoids ever having two writers live at once by construction, same
  reasoning as the rest of this ADR).
- `docs/runbooks/failover-headscale-vaultwarden.md`: the actual step-by-step
  runbook (item 4) — confirm-primary-down, reach `rpi-srv-02`,
  `litestream restore`, start the standby, flip AdGuard DNS rewrites +
  Cloudflare Tunnel target, verify against a real client, and the mirror-image
  failback.
- `DISASTER-RECOVERY.md` (§7b) and `CLAUDE.local.md` (Topology reality) updated to
  point at this ADR and the runbook as the one narrow exception to
  "recovery, not HA" (item 6).
- **Still open**: item 6's actual induced-failure verification pass (a real
  DNS/Cloudflare Tunnel flip against live traffic) — this is the highest-risk,
  least-rehearsed part of the design specifically because it touches live
  production routing. Deliberately not rehearsed silently against real
  traffic in this pass; see the runbook's own "Known gaps" section for why
  this should be a scheduled game-day exercise or a real incident, not a
  quiet test. The two one-time manual prerequisites (the 3 static identity
  files, the headscale OIDC client secret — see the runbook's step 0) are
  also still outstanding; both need the operator, not this agent (Vault
  AppRole scope and the credential-safety block already explained above).
- Authelia stays scoped out, unchanged from the entry above
  (`phase8/QUESTIONS.md`, 2026-08-26).
