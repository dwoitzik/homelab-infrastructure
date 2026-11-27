# Failover Runbook: headscale + vaultwarden warm standby

> **Status (2026-11-27):** the standby can take over with `pve-mgmt-01` down. Its TLS front
> end (`ha-standby-proxy`, Caddy on `rpi-srv-02`) holds a certificate pushed from the
> cluster, the router moves public headscale traffic to it by itself while the standby
> runs, and one playbook moves LAN/tailnet DNS (ADR-088). Rehearsed end to end with real
> tailnet clients on 2026-11-27 (see "Rehearsal 2" at the end).

Manual, deliberate failover to the `rpi-srv-02` standby built under
`docs/decisions/ADR-029-warm-standby-ha-headscale-vaultwarden.md`. Not
automatic by design — see that ADR for why. RTO target: a few minutes.
RPO target: seconds (last Litestream WAL segment shipped before the
primary went down).

**Applies to headscale and vaultwarden only.** Everything else on
`pve-mgmt-01` is still "recovery, not HA" — see `DISASTER-RECOVERY.md`.

## 0. Before you ever need this for real

On `rpi-srv-02` the role deploys, from Ansible Vault:

1. `noise_private.key` (headscale) in `/mnt/ssd/ha-standby/headscale/data/` and
   `rsa_key.pem` (vaultwarden) in `/mnt/ssd/ha-standby/vaultwarden/data/`, byte copies of
   the primary's files. Without them a started standby mints fresh identity material:
   every tailnet device loses trust in the control server, every vaultwarden session
   token becomes invalid. headscale 0.29 uses only the Noise key; `private.key` is a
   leftover path in the config and does not exist on the primary either.
2. `HEADSCALE_OIDC_CLIENT_SECRET` in `/opt/ha-standby/headscale/.env`.

Check they match the primary before relying on them (hashes only, nothing printed):

```bash
kubectl -n apps exec deploy/headscale -c litestream -- sha256sum /var/lib/headscale/noise_private.key
kubectl -n apps exec deploy/vaultwarden -c litestream -- sha256sum /data/rsa_key.pem
ssh rpi-srv-02 'sudo sha256sum /mnt/ssd/ha-standby/headscale/data/noise_private.key /mnt/ssd/ha-standby/vaultwarden/data/rsa_key.pem'
```

If a key on the primary is ever rotated, re-encrypt it into
`vault_headscale_noise_private_key` / `vault_vaultwarden_rsa_key_pem` (pipe it from the
pod into `ansible-vault encrypt_string --stdin-name`, never through a file) and rerun
`ansible/rpi-ha-standby.yml`.

## 1. Confirm the primary is actually down, not just flaky

- `kubectl get pods -n apps -l app=headscale` / `-l app=vaultwarden` from
  wherever your kubeconfig still works. If the whole cluster is
  unreachable, that itself is the signal — all 3 k3s VMs are guests on
  `pve-mgmt-01` (`docs/HARDWARE.md`), so a `pve-mgmt-01` outage takes all of
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

Restore from the replica files on the Pi itself (the SFTP URL needs the sidecars'
private key, which root on the Pi does not have). `litestream restore` refuses to
overwrite an existing file, so the data directories must hold no database first:

```bash
sudo ls /mnt/ssd/ha-standby/headscale/data /mnt/ssd/ha-standby/vaultwarden/data
# only noise_private.key and rsa_key.pem belong there between failovers
sudo litestream restore -o /mnt/ssd/ha-standby/headscale/data/db.sqlite \
  file:///mnt/ssd/litestream-replicas/headscale
sudo litestream restore -o /mnt/ssd/ha-standby/vaultwarden/data/db.sqlite3 \
  file:///mnt/ssd/litestream-replicas/vaultwarden
sudo chown 1000:1000 /mnt/ssd/ha-standby/vaultwarden/data/db.sqlite3
```

Each restore takes well under a second (0.24 s and 0.30 s in the rehearsal). There is no
`sqlite3` on the Pi; check the result with Python:

```bash
sudo python3 -c "import sqlite3; c=sqlite3.connect('file:/mnt/ssd/ha-standby/headscale/data/db.sqlite?mode=ro', uri=True); print(c.execute('pragma integrity_check').fetchone(), c.execute('select count(*) from nodes').fetchone())"
```

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

**As soon as headscale-standby answers, the router sends new public connections for
`headscale.woitzik.dev` to the Pi** (netwatch `ha_headscale_standby`, ADR-088), within
about ten seconds. That also happens in a rehearsal: starting the standby is the switch.

## 5. Flip traffic to rpi-srv-02

| Clients | Normal path | During failover | How it switches |
|---|---|---|---|
| Internet (`headscale.woitzik.dev` only) | WAN 443 -> router dst-nat -> DMZ proxy `10.0.30.2` -> headscale LB | WAN 443 -> router dst-nat -> `10.0.20.3:8443` (Caddy, headscale only) | Automatic: netwatch on `10.0.20.3:8081` sees the standby answer and fills address list `ha_headscale_standby` |
| LAN and tailnet (both names) | AdGuard rewrite -> Traefik `10.0.20.200` | AdGuard rewrite -> `10.0.20.3:443` (Caddy) | `ansible/ha-standby-dns.yml`, below |
| Tailnet control URL | MagicDNS extra record -> public IP | same record (written by the standby's `headscale-public-ip-record`) -> router -> Pi | follows the internet row |

From a workstation with the repo and the Ansible Vault password (nothing on
`pve-mgmt-01` is involved):

```bash
ansible-playbook ansible/ha-standby-dns.yml -e adguard_ha_standby_failover=true
for s in 10.0.20.2 10.0.20.3; do dig +short @$s headscale.woitzik.dev; dig +short @$s vault.woitzik.dev; done
# all four answers: 10.0.20.3
```

Each Pi restarts AdGuard once (about 15 seconds); keepalived keeps the DNS VIP on the
other one. Do not run `site.yml` for `rpi_nodes` during a failover: it renders the
default rewrites and moves LAN clients back to Traefik.

Check the router followed (any of these, whichever works from where you are):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.20.3:8081/     # 200 = netwatch sees the standby
curl -s -o /dev/null -w '%{http_code}\n' --resolve headscale.woitzik.dev:443:<WAN IP> https://headscale.woitzik.dev/health
```

Existing control connections stay where they are until they break. A client whose
primary died reconnects by itself; in a rehearsal force it with
`sudo systemctl restart tailscaled`.

## 6. Verify from a real client, not just curl

- A tailnet device that was already registered: confirm it still shows
  connected in `headscale nodes list` (run inside the `headscale-standby`
  container: `docker exec headscale-standby headscale nodes list`), that
  `tailscale status --json` on it reports `BackendState: Running` (not
  `NeedsLogin`), and that `tailscale ping` reaches another peer on the standby.
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
   don't flip traffic back to something still crash-looping. k3s starts the primary
   by itself when the host boots; clients stay on the standby until steps 2 and 3,
   because DNS and the router still point there. If the standby took writes you need
   (step 5), scale the primary to 0 before anything else.
2. **Stop the standby containers first**: `sudo docker compose stop` in
   `/opt/ha-standby`. The standby stops accepting writes, and within about ten seconds
   netwatch sees the health URL fail and the router sends public headscale traffic back
   to the DMZ proxy.
3. Move LAN/tailnet DNS back: `ansible-playbook ansible/ha-standby-dns.yml` (no flag);
   both Pis answer `10.0.20.200` again. Restart `tailscaled` on clients you want back
   right away; the rest reconnect when their connection to the stopped standby drops.
4. Verify from a real client again (same checks as step 6), now against
   the primary.
5. **Data**: while it served, the standby was the only writer, and the primary
   resumes from its own database as of the outage. For headscale the standby's
   writes are mostly node `last_seen`/endpoint updates, which are safe to drop.
   If a device was registered, a route approved or a vaultwarden item changed on
   the standby, carry its database back before the primary starts: keep the
   primary scaled to 0, copy the standby's `db.sqlite`/`db.sqlite3` (after
   `docker compose stop`) into the primary's PVC with a helper pod, then scale
   up. Compare `headscale nodes list` and the vaultwarden item count on both
   sides before calling failback done.
6. Litestream on the primary resumes shipping WAL segments to
   `rpi-srv-02` automatically (it's a sidecar in the same pod spec,
   unaffected by any of this) — confirm with a fresh
   `ls -la /mnt/ssd/litestream-replicas/{headscale,vaultwarden}/` shortly
   after and check the newest generation's mtime is recent.
7. Reset the standby: `sudo docker compose down`, then delete the restored databases
   (`db.sqlite*` in the headscale data directory, `db.sqlite3*` in the vaultwarden one) so
   only `noise_private.key` and `rsa_key.pem` remain for the next restore.
8. Log the incident: what triggered it, how long the standby actually
   served traffic, whether anything in this runbook was wrong or
   out of date, in `phase8/LEDGER.md` and (if this runbook needs a
   correction) as a follow-up PR against this file.

## Known gaps, disclosed not hidden

- The certificate on the Pi lives 30 to 60 days without the cluster (cert-manager renews
  30 days before expiry, the push runs daily). An outage longer than that needs a
  certificate issued another way.
- Internet clients reach Caddy on `rpi-srv-02` (server VLAN) without CrowdSec while the
  standby runs; only headscale is served there and the router's per-source flood guard
  applies (ADR-088).
- Authelia is down with the cluster, so new device logins (OIDC) fail; registered devices
  keep working.
- The 3 static identity files are copies in Ansible Vault. If a key on the primary is
  rotated, re-encrypt it (step 0); nothing detects the mismatch automatically.
- `headscale-config.yaml.j2`/`headscale-policy.hujson.j2` in
  `ansible/roles/rpi_ha_standby/templates/` are hand-kept in sync with
  `kubernetes/apps/headscale/config.yml`. Images are checked in CI, the config is not.
- Writes the standby accepts are not carried back. For headscale these are node
  `last_seen`/endpoint updates (harmless); a device registered or a route approved on the
  standby is lost at failback.

## Rehearsal 1 (2026-11-27): through Traefik

The Traefik IngressRoute used here is retired: the standby now publishes on loopback
only, and the Caddy path of rehearsal 2 serves both cases.

Scope: real tailnet clients on the standby with the primary left running, vaultwarden
read-only. Stopping the primary was avoided because both Deployments are self-healed by
the ArgoCD ApplicationSet, and the standby had to be proven before a real cutover.

Vaultwarden, read-only (no client switched):

| Step | Time | Result |
|---|---|---|
| `litestream restore` from the replica files | 0.30 s | `integrity_check` ok |
| Compare with the primary (`sqlite3 -readonly` in the litestream sidecar) | | users 1, ciphers 286, folders 2, devices 5, newest cipher `2026-11-27 11:43:52 UTC`: identical |
| `docker compose up -d vaultwarden-standby` | 3.3 s to `/alive` | login page 200, `/api/config` 200, no key generated, `rsa_key.pem` hash unchanged |
| Stop, remove container and restored DB | | |

A stale `db.sqlite3` from 2026-08-27 sat in the vaultwarden data directory and would have
made `litestream restore` fail during a real failover; it is now in
`/var/backups/ha-standby-stale/` on the Pi.

Headscale, real clients:

| Step | Time (CET) | Result |
|---|---|---|
| Restore replica | 13:05:29.6 | integrity ok; 5 nodes, same names as the primary |
| Standby up | 13:05:29.8 to 13:05:31.9 | `/health` pass, Noise key not regenerated (hash `8c6dc16d...` as primary) |
| IngressRoute to standby (retired pattern) | 13:05:38.1 to 13:05:41.7 | Traefik serves the standby |
| Restart tailscaled on rpi-srv-02 | 13:05:48.8 to 13:05:51.5 | `Running`, online, no re-login |
| Restart tailscaled on rpi-srv-01 | 13:05:52.3 to 13:06:17.0 | `Running`, online, no re-login |
| `tailscale ping rpi-srv-01` from rpi-srv-02 | | pong, direct, 3 ms |
| Failback: stop standby, delete the three objects | 13:06:39.6 to 13:06:53.0 | Traefik back on the primary |
| Restart tailscaled on both Pis | to 13:07:00.0 | both online on the primary; pings to rpi-srv-01 and homelab-router-1 work |
| Litestream | 13:07:13 | newest headscale LTX file on the Pi written after failback |

Clients were on the standby for about a minute. During the window, peers still on the
primary (homelab-router-1, the phone) and peers on the standby could not reach each
other (`tailscale ping homelab-router-1` from rpi-srv-02: no reply): each control server
only knew the new disco keys of its own clients. A real failover moves every client, so
this split exists only in a rehearsal like this one. The primary served throughout; its
database never saw the standby's writes.

## Rehearsal 2 (2026-11-27): the off-host path

Scope: the whole path the outage uses, Caddy on the Pi and the router netwatch included,
with the primary left running. Clients moved: the tailscaled on both Pis; public
connections opened during the window went to the standby as well.

| Step | Time (CET) | Result |
|---|---|---|
| `litestream restore` of both databases | 14:01:26.4 to 14:01:26.7 | integrity ok, 5 nodes |
| `docker compose up -d` | 14:01:28.8 | `10.0.20.3:8081` answers 200 at 14:01:29.4; Noise key hash unchanged (`8c6dc16d`) |
| Router netwatch | 14:01:30 | address list `ha_headscale_standby` holds the WAN address |
| TLS through Caddy | | `headscale.woitzik.dev` on 443 and 8443, `vault.woitzik.dev` on 443: 200, certificate verifies; `vault.woitzik.dev` on 8443 aborted |
| TS2021 | | `Upgrade: tailscale-control-protocol` returns `101 Switching Protocols` on 443 and 8443; `tailscale debug ts2021` completes the Noise handshake through Caddy |
| Hairpin to the WAN address | | lands on the standby (router dst-nat to `10.0.20.3:8443`) |
| `ha-standby-dns.yml -e adguard_ha_standby_failover=true` | 14:02:03 to 14:03:12 | both Pis and the VIP answer `10.0.20.3` for both names |
| Restart tailscaled, rpi-srv-02 then rpi-srv-01 | 14:03:19.4 to 14:03:26.5 | both `Running`, online on the standby, control connections on `10.0.20.3:443`; `tailscale ping rpi-srv-01` direct, 2 ms |
| Failback: `docker compose stop` | 14:03:35 | netwatch down at 14:03:41, address list empty; hairpin answered by the primary again |
| `ha-standby-dns.yml` (no flag) | to 14:05:04 | both Pis answer `10.0.20.200` |
| Restart tailscaled on both Pis | to 14:05:11 | primary lists all four active nodes online; ping to rpi-srv-01 and homelab-router-1 work |
| Litestream | 14:05 | new LTX files on the Pi after failback |

The public path pointed at the standby for 2 min 11 s. Found and fixed during the
rehearsal: the playbook's wait for AdGuard stopped at the first `connection refused`
instead of retrying, so it ended with an error after the switch on each Pi (the switch
itself had applied); Caddy advertised HTTP/3 on UDP ports the host firewall drops.
