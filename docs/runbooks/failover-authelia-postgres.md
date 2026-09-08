# Failover Runbook: Authelia's Postgres warm standby

Manual, deliberate failover to the `rpi-srv-02` physical-replication
standby built under
`docs/decisions/ADR-030-authelia-postgres-warm-standby.md`. Different
mechanism from `docs/runbooks/failover-headscale-vaultwarden.md` (that
one starts stopped containers; this one **promotes** an already-running
replica) but the same philosophy: manual, not automatic, to avoid
split-brain on hardware this small.

**Applies to Authelia's Postgres only.** Authelia's Redis session cache
has no standby of its own — a failover here loses active sessions
(everyone re-authenticates), which is an accepted, minor cost, not a
gap to fix here.

## 0. Before you ever need this for real

Confirm the standby is actually caught up and running, not just
installed:

```bash
ssh rpi-srv-02  # or the Tailscale path if LAN routing is down, see the
                # headscale/vaultwarden runbook's own note on this
sudo systemctl status postgres-authelia-standby
sudo -u postgres psql -c "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();"
```

`pg_is_in_recovery()` should return `t` (still a replica). If the
service isn't running or `pg_last_wal_replay_lsn()` looks stale/stuck,
fix that first — do not fail over onto a standby that isn't actually
current.

## 1. Confirm the primary is actually down, not just flaky

Same check as the headscale/vaultwarden runbook: `kubectl get pods -n
database -l app=headscale` — no wait, wrong app. For Authelia's Postgres:

```bash
kubectl get cluster postgres-authelia -n database
kubectl get pods -n database -l cnpg.io/cluster=postgres-authelia
```

If the whole k3s cluster is unreachable, that's the signal — all 3 VMs
are guests on `pve-mgmt-01` (`CLAUDE.local.md`).

## 2. Promote the standby

```bash
sudo -u postgres psql -c "SELECT pg_promote();"
```

This is a one-way door — a promoted replica cannot be un-promoted back
into recovery mode. Confirm before running it, not after:

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# should now return f
```

## 3. Point Authelia at the standby

Authelia's Postgres connection lives in
`kubernetes/apps/authelia/configmap.yml`
(`storage.postgres.address`/`host`). If the k3s cluster itself is down
(the primary failure mode this exists for), Authelia is down too and
there's nothing to repoint yet — this step matters for a narrower case:
the Postgres primary specifically failed (disk, corruption, `pve-mgmt-01`
degraded but the VMs still up) while the rest of the cluster is fine.

1. Edit `configmap.yml`'s Postgres host to `10.0.20.3` (rpi-srv-02's LAN
   IP), port `5432`.
2. Apply: `kubectl apply -f kubernetes/apps/authelia/configmap.yml -n
   apps` (or via the normal PR → ArgoCD sync path if there's time —
   break-glass direct apply is for genuine urgency).
3. Restart Authelia so it picks up the new connection:
   `kubectl rollout restart deployment/authelia -n apps`.

**The rpi02_replica role has no login/database access beyond
replication** (ADR-030) — Authelia itself needs the real `authelia`
application role's credentials, which live in the primary's own
`postgres-authelia-user` Secret and were carried over verbatim by
`pg_basebackup` (it's a physical copy, every role/password on the
primary exists identically on the promoted standby). No separate
credential to provision here.

## 4. Verify from a real client, not just `pg_is_in_recovery()`

- Log into Authelia (`auth.woitzik.dev`) with a real account — confirm
  it actually authenticates, not just that the login page loads.
- Check a couple of known users/config values are present:
  `sudo -u postgres psql -d authelia -c "SELECT COUNT(*) FROM
  identity_verification_tokens;"` (or any table you know has real
  rows) — confirms this is real data, not an empty fresh cluster.

## Failback (once the primary is back)

Physical streaming replication has **no clean live resync** — unlike
the headscale/vaultwarden runbook's litestream-based failback, there's
no "just stop the standby and let the primary catch up." A promoted
replica and a primary that kept running independently are now two
diverged timelines.

1. **Do not just restart the old primary's CNPG Cluster and assume it
   reconciles.** If it wrote anything at all after the standby was
   promoted, its data has diverged from what's now authoritative
   (the promoted rpi-srv-02 instance).
2. Treat the **promoted rpi-srv-02 instance as the new source of
   truth**. Take a fresh `pg_dump` (or a CNPG-triggered base backup once
   the operator reconciles) from it.
3. Rebuild the CNPG `postgres-authelia` cluster from that dump — same
   restore pattern as `docs/RECOVERY.md` §5 (scale down / restore into
   PVC / verify against real content, not just "pod is Running").
4. Point Authelia back at the in-cluster CNPG service
   (`postgres-authelia-rw.database.svc.cluster.local`), restart the
   Deployment.
5. Rebuild `rpi-srv-02`'s standby as a fresh replica of the new primary
   (re-run `ansible/postgres-authelia-standby.yml` after clearing its
   old PGDATA — it's now a promoted-and-diverged copy, not a valid
   replica base for the new primary).
6. Log the incident: how long the standby served, whether any writes
   happened on the standby after promotion that need manual
   reconciliation into the new primary (check application-level audit
   logs, not just row counts), in `phase8/LEDGER.md`.

## Known gaps, disclosed not hidden

- No induced-failure test has been run against this standby yet (real
  primary-down + real promote + real Authelia repoint). Same reasoning
  as the headscale/vaultwarden runbook: this should be a deliberate
  game-day exercise, not a silent test against a live auth system every
  other app in the cluster depends on.
- Redis (Authelia's session cache) has no standby — active sessions are
  lost on failover regardless of how clean the Postgres side is.
- Failback has no clean automated path (see above) — budget real time
  for it, not a five-minute mirror-image of failover.
