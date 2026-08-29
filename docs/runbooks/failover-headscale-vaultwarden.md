# Failover Runbook: headscale + vaultwarden warm standby

Manual, deliberate failover to the `rpi-srv-02` standby built under
`docs/decisions/ADR-029-warm-standby-ha-headscale-vaultwarden.md`. Not
automatic by design — see that ADR for why. RTO target: a few minutes.
RPO target: seconds (last Litestream WAL segment shipped before the
primary went down).

**Applies to headscale and vaultwarden only.** Everything else on
`pve-mgmt-01` is still "recovery, not HA" — see `DISASTER-RECOVERY.md`.

## 0. Before you ever need this for real

Confirm the two one-time manual prerequisites are done (see
`ansible/roles/rpi_ha_standby/templates/README.md.j2`, also deployed live
to `/opt/ha-standby/README.md` on `rpi-srv-02`):

1. `private.key` + `noise_private.key` (headscale) and `rsa_key.pem`
   (vaultwarden) copied from the live pods to
   `/mnt/ssd/ha-standby/{headscale,vaultwarden}/data/` on `rpi-srv-02`.
   Without these, starting the standby mints fresh identity material —
   every existing tailnet device loses trust, every existing vaultwarden
   session/token invalidates.
2. `HEADSCALE_OIDC_CLIENT_SECRET` filled in at
   `/opt/ha-standby/headscale/.env` on `rpi-srv-02`.

If either is still blank, do them now, not mid-incident.

## 1. Confirm the primary is actually down, not just flaky

- `kubectl get pods -n apps -l app=headscale` / `-l app=vaultwarden` from
  wherever your kubeconfig still works. If the whole cluster is
  unreachable, that itself is the signal — all 3 k3s VMs are guests on
  `pve-mgmt-01` (`CLAUDE.local.md`), so a `pve-mgmt-01` outage takes all of
  them at once, headscale/vaultwarden included.
- Check the Proxmox host itself (console, IPMI/power state, ping) if
  `kubectl` is unreachable — don't fail over because of a laptop network
  blip on your end.
- **Once you decide to fail over, stop watching for the primary to come
  back mid-procedure.** A primary that un-hangs itself while the standby
  is also live is the split-brain case this design avoids by construction
  (only one writer, ever) — don't reintroduce it by racing the two.

## 2. Reach rpi-srv-02

Normal path: `ssh rpi-srv-02` (LAN, `ansible/inventory.ini`). If LAN
routing itself is part of the outage (seen before — see `phase8/LEDGER.md`,
2026-08-26), use the Tailscale path instead:
`ssh -i /root/.ssh/agent_key dw@<rpi-srv-02's 100.64.0.0/10 tailscale IP>`
(`tailscale status` on this agent's host, or David's own tailnet client,
resolves the current IP).

## 3. Bring the replica current

```bash
sudo litestream restore -if-replica-exists \
  -o /mnt/ssd/ha-standby/headscale/data/db.sqlite \
  sftp://litestream@localhost:22/headscale

sudo litestream restore -if-replica-exists \
  -o /mnt/ssd/ha-standby/vaultwarden/data/db.sqlite3 \
  sftp://litestream@localhost:22/vaultwarden
```

`-if-replica-exists` makes this a no-op instead of an error if a restore
already ran and the DB file is already present — safe to re-run.
Ownership: the vaultwarden DB file needs to end up owned
`{{ rpi_ha_standby_vaultwarden_uid }}:{{ rpi_ha_standby_vaultwarden_gid }}`
(1000:1000) to match the container's `user:` — `sudo chown 1000:1000
/mnt/ssd/ha-standby/vaultwarden/data/db.sqlite3` if `litestream restore`
(run as root) left it root-owned.

## 4. Start the standby containers

```bash
cd /opt/ha-standby
sudo docker compose pull   # catch up to whatever image tag is pinned now
sudo docker compose up -d
sudo docker compose logs -f --tail=50
```

Confirm both actually came up clean, not just "container running":

- headscale: `curl -s http://localhost:8082/health` → `{"status":"pass"}`
- vaultwarden: `curl -sI http://localhost:8083/` → `200`/`302`, not a
  connection refused/reset

If headscale logs show it generated new key files instead of reading the
ones you copied in step 0, **stop** — that means step 0.1 wasn't actually
done, or the files ended up in the wrong path
(`/mnt/ssd/ha-standby/headscale/data/`, matching `config.yaml`'s
`private_key_path`/`noise.private_key_path`). Fix that before continuing;
proceeding on freshly-minted keys means every device needs re-registration
regardless of whether you fix it later.

## 5. Flip traffic to rpi-srv-02

Both apps are reached through DNS + reverse-proxy pointed at the k3s
cluster today — that path is down along with the primary, so this step
repoints it at the standby directly:

- **AdGuard DNS rewrites** (`ansible/roles/adguard/templates/AdGuardHome.yaml.j2`,
  applied on both `rpi-srv-01` and `rpi-srv-02` — primary and replica
  AdGuard instances, per `CLAUDE.md`'s "known facts" section): change the
  `headscale.woitzik.dev` / `vault.woitzik.dev` rewrite targets from the
  Traefik LB IP to `rpi-srv-02`'s LAN IP (`10.0.20.3`), on **both**
  AdGuard instances — internal LAN clients resolve through these, and
  they can disagree if only one is updated.
- **Cloudflare Tunnel** (`terraform/stacks/cloudflare/main.tf`), for
  access from outside the LAN: change the ingress hostname's target
  service from the in-cluster Traefik address to
  `http://10.0.20.3:8082` (headscale) / `http://10.0.20.3:8083`
  (vaultwarden). This is a Terraform-managed resource behind Atlantis —
  either run this through the normal PR → `atlantis plan`/`apply` flow if
  time allows, or apply it directly via `cloudflared`/dashboard as a
  break-glass exception and reconcile the Terraform state afterward. Note
  which one you did in `phase8/LEDGER.md` either way.
- Port numbers match `ansible/roles/rpi_ha_standby/defaults/main.yml`
  (`rpi_ha_standby_headscale_host_port: 8082`,
  `rpi_ha_standby_vaultwarden_host_port: 8083`) — re-check there if they've
  since changed.

## 6. Verify from a real client, not just curl

- A tailnet device that was already registered: confirm it still shows
  connected in `headscale nodes list` (run inside the `headscale-standby`
  container: `docker exec headscale-standby headscale nodes list`) and
  that traffic actually flows to another tailnet peer.
- A vaultwarden client (browser extension or app): confirm login with an
  **existing** account works and the real vault entries are present (not
  an empty/fresh vault — that would mean step 3's restore didn't actually
  point at real data).
- **New device registration / OIDC login will not work** during a real
  `pve-mgmt-01` outage — Authelia is itself a k3s workload on the same
  host you just lost. This is a known, accepted gap (see ADR-029), not a
  bug in this runbook. Only already-registered devices/sessions keep
  working.

## Failback (once pve-mgmt-01 is back)

Mirror image, done deliberately:

1. Confirm the primary's own pods are healthy again
   (`kubectl get pods -n apps -l app=headscale`, same for vaultwarden) —
   don't flip traffic back to something still crash-looping.
2. **Stop the standby containers first**, before flipping DNS/Tunnel back
   — `sudo docker compose stop` in `/opt/ha-standby`. This guarantees the
   standby stops accepting writes before the primary starts accepting
   them again, so there's never a window with two live writers.
3. Reverse step 5's DNS rewrites and Cloudflare Tunnel target back to the
   in-cluster Traefik address, on both AdGuard instances.
4. Verify from a real client again (same checks as step 6), now against
   the primary.
5. **Data reconciliation check**: because the standby was never a second
   writer (only one side ever accepted writes, by construction), there
   should be nothing to reconcile — the primary's data is simply however
   current it was when it went down, plus whatever it's received since
   coming back. Confirm this is actually true rather than assuming it:
   diff a few known records (e.g. `headscale nodes list` node count,
   vaultwarden item count via the client UI) between what the standby
   showed at the end of step 6 and what the primary shows now. Any
   mismatch means something unexpected happened during the outage and
   needs investigating before calling failback complete.
6. Litestream on the primary resumes shipping WAL segments to
   `rpi-srv-02` automatically (it's a sidecar in the same pod spec,
   unaffected by any of this) — confirm with a fresh
   `ls -la /mnt/ssd/litestream-replicas/{headscale,vaultwarden}/` shortly
   after and check the newest generation's mtime is recent.
7. Log the incident: what triggered it, how long the standby actually
   served traffic, whether anything in this runbook was wrong or
   out of date, in `phase8/LEDGER.md` and (if this runbook needs a
   correction) as a follow-up PR against this file.

## Known gaps, disclosed not hidden

- The 3 static identity files (step 0.1) are a manual, one-time bootstrap
  — no automated sync keeps them current if they were ever rotated
  (they rotate essentially never in practice for these two apps).
- `headscale-config.yaml.j2`/`headscale-policy.hujson.j2` in
  `ansible/roles/rpi_ha_standby/templates/` are hand-kept in sync with
  the live `kubernetes/apps/headscale/config.yml` ConfigMap — a config
  change on the primary that isn't mirrored here will only surface at
  failover time. Check both files match before relying on this in a real
  incident, especially after any headscale config PR.
- No induced-failure test has been run against a real DNS/Tunnel flip yet
  (see `docs/decisions/ADR-029-warm-standby-ha-headscale-vaultwarden.md`
  for what *has* been verified — replica plumbing, data flowing, both
  primary apps unaffected). Steps 5-6 above are the highest-risk,
  least-rehearsed part of this runbook precisely because that flip
  touches live production DNS/routing; the first time it's actually run
  should be either a deliberate, scheduled game-day exercise (see
  `docs/RECOVERY-REPORT-2026-08-13.md` and the quarterly DR game-day
  cadence added in commit `5d65817`) or a real incident, not something to
  rehearse silently against live traffic.
