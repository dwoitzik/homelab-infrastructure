# Failover Runbook: headscale + vaultwarden warm standby

> **Status (2026-11-27):** identity keys, OIDC secret and image versions are deployed
> by `ansible/roles/rpi_ha_standby` from Ansible Vault, matched to the primary by
> `scripts/check-image-lockstep.py`. The standby was rehearsed with real tailnet clients
> through Traefik (see "Rehearsal" at the end). **Open gap:** with `pve-mgmt-01` down
> there is no TLS endpoint for `headscale.woitzik.dev` or `vault.woitzik.dev` that can
> reach the Pi (Traefik and the DMZ proxy both run on that host), so step 5 only works
> while the cluster's Traefik is up.

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

## 5. Flip traffic to rpi-srv-02

How clients reach the two apps today:

- LAN clients, including tailscaled on both Pis and the in-cluster subnet router, resolve
  `headscale.woitzik.dev` through AdGuard to Traefik (`10.0.20.200`), IngressRoute
  `headscale-final`. `vault.woitzik.dev` takes the same path (AdGuard wildcard).
- Clients on the internet reach `headscale.woitzik.dev` (DNS-only record) through the
  router's port forward to the DMZ proxy (`ct-dmz-proxy-01`, NPM), which forwards to the
  `headscale-dmz-lb` LoadBalancer `10.0.20.201:8080`. Vaultwarden is not public.

Traefik and NPM both terminate TLS, and both run on `pve-mgmt-01`. The standby serves
plain HTTP on `10.0.20.3:8082` and `:8083`.

**While Traefik is up** (the cluster runs but the primary pod or its volume is lost),
route Traefik to the standby with a higher-priority IngressRoute and a selectorless
Service; nothing ArgoCD manages is touched, so self-heal does not fight it:

```yaml
apiVersion: v1
kind: Service
metadata: {name: headscale-standby, namespace: apps}
spec:
  ports: [{name: http, port: 8080, targetPort: 8082}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: headscale-standby-1
  namespace: apps
  labels: {kubernetes.io/service-name: headscale-standby}
addressType: IPv4
ports: [{name: http, port: 8082, protocol: TCP}]
endpoints: [{addresses: ["10.0.20.3"], conditions: {ready: true}}]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: headscale-standby, namespace: apps}
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`headscale.woitzik.dev`)
      priority: 10000
      middlewares: [{name: websockets}]
      services: [{name: headscale-standby, port: 8080}]
```

The same pattern with port 8083 and `Host(`vault.woitzik.dev`)` (no middleware) moves
vaultwarden. Internet clients would also need NPM's `headscale.woitzik.dev` upstream set
to `10.0.20.3:8082` and a router rule from the DMZ to that port; neither exists.

Existing control connections stay on the old backend until they break. A client whose
primary died reconnects by itself; in a rehearsal force it with
`sudo systemctl restart tailscaled`.

**With `pve-mgmt-01` down** there is no TLS endpoint left for either hostname, and
pointing AdGuard at `10.0.20.3` does not help: clients speak HTTPS on 443. Making this
work needs a TLS proxy on `rpi-srv-02` with a certificate for both names kept current
off-cluster, plus the AdGuard rewrites and router port forward pointed at it. Until that
exists, an outage of `pve-mgmt-01` leaves registered tailnet devices running on their
last netmap (peer-to-peer traffic keeps working, no control plane) and Bitwarden clients
on their offline vault copy; the standby data is then a fast restore source for the
rebuilt cluster, not a live service.

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
   don't flip traffic back to something still crash-looping.
2. **Stop the standby containers first**, before flipping DNS/Tunnel back
   — `sudo docker compose stop` in `/opt/ha-standby`. This guarantees the
   standby stops accepting writes before the primary starts accepting
   them again, so there's never a window with two live writers.
3. Reverse step 5: delete the standby IngressRoute, Service and EndpointSlice.
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
7. Log the incident: what triggered it, how long the standby actually
   served traffic, whether anything in this runbook was wrong or
   out of date, in `phase8/LEDGER.md` and (if this runbook needs a
   correction) as a follow-up PR against this file.

## Known gaps, disclosed not hidden

- No TLS endpoint off `pve-mgmt-01` (step 5): the standby only serves clients while the
  cluster's Traefik is up. This is the main remaining work for ADR-029.
- The 3 static identity files are copies in Ansible Vault. If a key on the primary is
  rotated, re-encrypt it (step 0); nothing detects the mismatch automatically.
- `headscale-config.yaml.j2`/`headscale-policy.hujson.j2` in
  `ansible/roles/rpi_ha_standby/templates/` are hand-kept in sync with
  `kubernetes/apps/headscale/config.yml`. Images are checked in CI, the config is not.
- Writes the standby accepts are not carried back. For headscale these are node
  `last_seen`/endpoint updates (harmless); a device registered or a route approved on the
  standby is lost at failback.

## Rehearsal (2026-11-27)

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
| IngressRoute to standby (pattern from step 5) | 13:05:38.1 to 13:05:41.7 | Traefik serves the standby |
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
