# Failover Runbook: Authelia's Postgres warm standby

Manual, deliberate failover to the `rpi-srv-02` physical-replication
standby built under
`docs/decisions/ADR-030-authelia-postgres-warm-standby.md`. Different
mechanism from `docs/runbooks/failover-headscale-vaultwarden.md` (that
one starts stopped containers; this one **promotes** an already-running
replica) but the same philosophy: manual, not automatic, to avoid
split-brain on hardware this small.

**Applies to Authelia's Postgres only.** Authelia's Redis session cache
has no standby of its own. A failover loses active sessions (everyone
logs in again), an accepted cost.

## What is running

| Piece | Where |
|---|---|
| Primary | CNPG `postgres-authelia` (namespace `database`), PostgreSQL 17.2, x86_64 |
| Standby | `rpi-srv-02` (10.0.20.3), Debian `postgresql-17` (17.x), aarch64, unit `postgres-authelia-standby` |
| PGDATA | `/mnt/ssd/postgres-authelia-standby/17/main` (USB SSD, never the SD card) |
| Replication path | standby -> `postgres-authelia-standby-replication` LoadBalancer `10.0.20.203:5432`, TLS, user `rpi02_replica`, slot `rpi02_standby_slot` |
| Standby settings | `override.conf` and `pg_hba.conf` in PGDATA, both managed by `ansible/roles/postgres_authelia_standby` |
| Alert | `AutheliaPostgresStandbyNotStreaming` (critical, Discord): slot inactive, more than 1 GiB behind, or missing, for 30 min |

The primary keeps at most 2 GB of WAL for the slot
(`max_slot_wal_keep_size` in `kubernetes/system/postgres/cluster.yml`). A
standby that is down longer than that loses its slot and has to be
reseeded (see "Reseed the standby" below).

Cross-architecture note: the primary is x86_64 and the standby aarch64.
Physical replication works because the on-disk format matches (64-bit,
little-endian, same alignment), the databases use the `C` collation (no
glibc collation drift) and the `authelia` database has only btree indexes
and no extensions (no `char` signedness dependency). Re-check this if an
extension such as `pg_trgm` is ever added.

## 0. Check the standby before you need it

On `rpi-srv-02` (LAN, or over Tailscale via the subnet route if the LAN
path is down):

```bash
sudo systemctl status postgres-authelia-standby
cd /tmp && sudo -u postgres psql -AtXc \
  "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn(), status FROM pg_stat_wal_receiver;"
```

Expected: `t|<lsn>|streaming`. From the cluster side:

```bash
kubectl -n database exec postgres-authelia-1 -c postgres -- psql -U postgres -xc \
  "SELECT application_name, client_addr, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

Expected: one row, `rpi-srv-02`, `streaming`, lag near 0. Do not fail
over onto a standby that is not streaming or whose lag is large: it is
missing recent writes.

## 1. Confirm the primary is down, not flaky

```bash
kubectl get cluster postgres-authelia -n database
kubectl get pods -n database -l cnpg.io/cluster=postgres-authelia
```

If the whole k3s cluster is unreachable, that is the signal: all three
k3s VMs are guests on `pve-mgmt-01` (`docs/HARDWARE.md`). In that case
Authelia is down too and there is nothing to repoint until the cluster
is back; promoting only helps if the cluster comes back without its
Postgres volume, or if a new Authelia is run outside the cluster.

## 2. Promote the standby

One-way door: a promoted standby cannot go back into recovery. Check
step 0 first.

```bash
cd /tmp && sudo -u postgres psql -AtXc "SELECT pg_promote();"        # t
sudo -u postgres psql -AtXc "SELECT pg_is_in_recovery();"            # f
```

Promotion deletes `standby.signal`. The role only writes that file right
after a seed, so a later run of `ansible/postgres-authelia-standby.yml` does
not drag the promoted instance back into recovery, but it would still
restart it on a config change: do not run the role against `rpi-srv-02`
until failback is done.

Promoted state:

- Archiving is off (`archive_mode = off` in the role's `override.conf`).
  Nothing backs up the promoted instance; take a `pg_dump` to the SSD
  after the first logins work and keep failback short.
- TLS is off. Authelia's storage config does not use TLS, so this matches
  how it talks to the CNPG primary today.
- `pg_hba.conf` admits only the `authelia` role on the `authelia` database
  from the three k3s node IPs (pod traffic leaving the cluster is SNATed
  to the node address).

## 3. Point Authelia at the standby

The `apps` namespace already allows Authelia to reach `10.0.20.3:5432`
(NetworkPolicy `allow-egress-authelia-pg-standby` in
`kubernetes/apps/network-policies-egress.yml`), and the Pi's host firewall
admits 5432 from the three k3s node IPs (`rpi_optimize_hostfw_extra_rules` in
`ansible/host_vars/rpi-srv-02.yml`), so only the address changes.

1. In `kubernetes/apps/authelia/configmap.yml` set
   `storage.postgres.address` to `'tcp://10.0.20.3:5432'`.
2. Ship it through a PR if ArgoCD is up. Break-glass: disable auto-sync
   on the Authelia Application first, or ArgoCD reverts the change, then
   `kubectl apply -f kubernetes/apps/authelia/configmap.yml`.
3. `kubectl -n apps rollout restart deployment/authelia`.

The `authelia` role and its password came over with `pg_basebackup` (it
is a physical copy), so the existing `authelia-secrets` keep working.

## 4. Verify from a real client

- `curl -s https://auth.woitzik.dev/api/health` returns `{"status":"OK"}`.
- A gated host (for example `https://bazarr.woitzik.dev/`) redirects to
  `auth.woitzik.dev`, and a real login with 2FA completes.
- On the Pi: `sudo -u postgres psql -d authelia -AtXc "SELECT count(*),
  max(time) FROM authentication_logs;"` shows the new login.

## Failback

Physical replication has no clean way back: the promoted Pi is now the
only copy with the latest writes, and the old primary (if it survived)
has diverged.

1. Keep Authelia on the Pi until the cluster is healthy again.
2. Dump the promoted instance:
   `sudo -u postgres pg_dump -Fc -d authelia -f /mnt/ssd/authelia-failback.dump`.
3. Rebuild CNPG `postgres-authelia` empty (turn off auto-sync on the
   `postgres-cluster` Application, delete the Cluster and its PVC, re-enable
   auto-sync so ArgoCD recreates it), copy the dump into the primary pod and
   restore it with
   `pg_restore --clean --if-exists --no-owner -U authelia -d authelia`
   (same approach as `DISASTER-RECOVERY.md` 5b, step 4). Compare
   `authentication_logs` and `totp_configurations` row counts against the Pi.
4. Revert the configmap address to
   `tcp://postgres-authelia-rw.database.svc.cluster.local:5432` and restart
   Authelia. Verify as in step 4.
5. Reseed the standby (next section). The promoted Pi data is not a valid
   base for a replica of the rebuilt primary.

## Reseed the standby

Needed after a failback, after the alert reports the slot missing or
lost, or after the SSD was replaced.

```bash
# on rpi-srv-02
sudo systemctl stop postgres-authelia-standby
sudo rm -rf /mnt/ssd/postgres-authelia-standby/17/main

# on the primary, only if the slot still exists
kubectl -n database exec postgres-authelia-1 -c postgres -- psql -U postgres -c \
  "SELECT pg_drop_replication_slot('rpi02_standby_slot');"

# from a fresh worktree at origin/main
cd ansible && ansible-playbook postgres-authelia-standby.yml
```

The role reseeds with `pg_basebackup` (about 600 MB), recreates the slot
and starts streaming. Verify with step 0.

## Taking the standby away for good

Drop the slot on the primary first, otherwise the primary keeps up to
2 GB of WAL for it. Then `systemctl disable --now
postgres-authelia-standby` and remove the data directory.

## Rehearsal (2026-11-27)

The live standby was never promoted. A throw-away copy was, on `rpi-srv-02`:

```bash
# pg_basebackup -X stream (temporary slot) from 10.0.20.203 into /mnt/ssd/pg-rehearsal,
# the live standby's override.conf and pg_hba.conf with port 5499, no TCP listener,
# its own socket and no slot; standby.signal; pg_ctl start; pg_promote(); checks; rm -rf.
```

| Step | Result |
|---|---|
| `pg_basebackup` | 49 MB in 1.8 s |
| Start as standby | `in_recovery=t`, WAL receiver `streaming` |
| `pg_promote(true, 60)` | 0.64 s to `in_recovery=f`, timeline 2 |
| Write test | `CREATE TABLE`/`INSERT`/`DROP` committed in `authelia` |
| Privileges | `authelia` role has INSERT/UPDATE/DELETE on every table |
| Schema | Authelia migration version 29, same as the primary |
| Data | `authentication_logs` 26 rows (newest 2026-11-23 15:27 UTC), `totp_configurations` 1, `user_preferences` 1, `webauthn_credentials` 0: identical to the primary |
| Consistency | `amcheck` `bt_index_check(heapallindexed)` on all 246 btree indexes, no errors |
| Cleanup | copy stopped and deleted; the primary shows only `rpi02_standby_slot`, standby still streaming |

What it found: the Pi's host firewall (`inet hostfw`, policy drop) did not admit
5432, so a promoted standby would have been unreachable for Authelia; a TCP connect
from `vm-srv-k3s-11` to `10.0.20.3:5432` timed out. Fixed with the extra rule above.

A live switch of Authelia to the Pi was not done: physical replication has no
failback other than dump, rebuild of the CNPG primary and reseed (above), which is far
riskier than the promotion it would prove. The scratch copy exercises the same binary,
data and settings; the network path is checked separately with a connection from a
k3s node after the firewall change.

## Known gaps

- The live switch (configmap address, Authelia restart) is not rehearsed; see the
  rehearsal section for why.
- Redis (Authelia's session cache) has no standby; sessions are lost on
  failover.
- Failback is a dump and restore, not a resync.
