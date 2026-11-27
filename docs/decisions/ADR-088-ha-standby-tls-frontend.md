# ADR-088: A TLS front end on rpi-srv-02 lets the headscale/vaultwarden standby serve without pve-mgmt-01

**Date:** 2026-11-27
**Status:** Accepted
**Relates to:** ADR-029 (warm standby), ADR-033 (public exposure allowlist), ADR-059
(headscale public DNS), ADR-086 (WAN 443 flood guard)

## Context

The headscale and vaultwarden standbys on `rpi-srv-02` (ADR-029) serve plain HTTP on
loopback ports. Both TLS terminators for `headscale.woitzik.dev` and `vault.woitzik.dev`
run on `pve-mgmt-01`: Traefik in k3s (MetalLB `10.0.20.200`, the AdGuard rewrite target)
and the DMZ proxy `10.0.30.2` (the router's WAN 443 dst-nat target). In the outage
ADR-029 exists for, `pve-mgmt-01` down with the router, the FritzBox and both Pis still
up, no client could reach the standby. The 2026-11-27 rehearsal only worked because
Traefik was up.

Three things were missing: a TLS endpoint on the Pi with a certificate that does not
depend on the cluster at failover time, a way to send LAN/tailnet clients to it, and a
way to send internet clients to it while Terraform (whose runner is on the same host)
cannot run.

## Decision

### 1. TLS front end: Caddy on rpi-srv-02, always running

`ansible/roles/rpi_ha_standby` runs `ha-standby-proxy` (Caddy, host network, read-only,
all capabilities dropped except `NET_BIND_SERVICE`) in its own compose project
`/opt/ha-standby-proxy`, separate from the stopped-by-default standby containers, so it
is ready and monitored before it is needed. Listeners, all bound to `10.0.20.3`:

| Port | Serves | Reached by |
|---|---|---|
| 443 | `headscale.woitzik.dev`, `vault.woitzik.dev` | LAN and tailnet clients after the AdGuard failover rewrite |
| 8443 | `headscale.woitzik.dev` only; any other SNI/Host is aborted | internet clients through the router's failover dst-nat |
| 8081 | plain HTTP, every path proxied to headscale-standby `/health` | router netwatch and the blackbox probe |

The standby containers now publish on `127.0.0.1` only. The host firewall (`inet hostfw`)
already allowed 443; 8443 is open to any source (it is the internet-facing listener) and
8081 to the router and the k3s nodes. Caddy proxies any `Upgrade` request, which
headscale's TS2021 Noise protocol needs, the same way the headscale docs' own Caddy
example does.

### 2. Certificate: issued in the cluster, pushed to the Pi over the Litestream account

A dedicated cert-manager `Certificate` (`apps/ha-standby-tls`, ECDSA P-256, its own key,
only the two names) is issued by the existing `letsencrypt-production` ClusterIssuer. The
CronJob `ha-standby-tls-push` copies it daily with rclone over SFTP to
`/mnt/ssd/litestream-replicas/ha-standby-tls/` on the Pi, as the existing `litestream`
user (chrooted, `internal-sftp` only, key auth), with the Pi's ed25519 host key pinned.
An hourly systemd timer on the Pi (`ha-standby-tls-install`) installs it only if the chain
verifies against the system CA bundle, both names match, the key matches the certificate
and it does not expire before the installed one, then restarts Caddy.

cert-manager renews 30 days before expiry, so the copy on the Pi stays valid for 30 to
60 days after the cluster dies.

Options considered:

- **ACME DNS-01 on the Pi with a Cloudflare token.** Cloudflare API tokens scope to a
  zone, not a record: a `Zone:DNS:Edit` token on the Pi could rewrite every record in
  `woitzik.dev` and issue certificates for any name. It also adds a new credential to
  Ansible Vault and a second ACME client to maintain. Rejected: larger blast radius and a
  new secret.
- **Push the existing wildcard certificate.** No new issuance, but the Pi would hold the
  key for `*.woitzik.dev`. Rejected in favour of a certificate for the two names the
  standby serves.
- **A new SSH key for the push.** Least privilege in theory, but a new secret in the
  cluster and on the Pi for a channel that already exists. The Litestream key can already
  overwrite the standby's database replicas, which is more damaging than writing a
  certificate the Pi refuses unless it is publicly trusted for exactly these names.
  Reused, deliberately; the NetworkPolicy `allow-egress-litestream-sftp` covers the
  CronJob as well.

No new secret exists anywhere. The only new trust is that the Pi holds the key of a
certificate valid for `headscale.woitzik.dev` and `vault.woitzik.dev`, the services it
already runs a copy of.

### 3. LAN and tailnet clients: AdGuard rewrite, switched by an Ansible run

`ansible/ha-standby-dns.yml` renders the AdGuard rewrites for both names to `10.0.20.3`
when run with `-e adguard_ha_standby_failover=true`, and back to Traefik with `false`
(the default). It runs from a workstation over SSH to the Pis, one Pi at a time, and needs
nothing on `pve-mgmt-01`. Tailnet clients use the Pis' AdGuard VIP as their nameserver
and reach `10.0.20.3` through `rpi-srv-02`'s own advertised subnet route.

Not automated: a health-checked DNS switch flips clients into the standby on a false
negative, the standby's writes are discarded at failback, and the switch is needed only
together with the manual decision to start the standby (ADR-029 keeps that manual).

### 4. Internet clients: router netwatch keyed on the standby itself

Terraform declares, on the MikroTik:

- a netwatch (`http-get` on `10.0.20.3:8081`) whose up/down scripts add or remove
  `192.168.178.10` in the address list `ha_headscale_standby`;
- a dst-nat rule placed before `dstnat_headscale_dmz`: WAN TCP 443 to `192.168.178.10`
  **and** `dst-address-list=ha_headscale_standby` goes to `10.0.20.3:8443`;
- a forward accept for WAN to `10.0.20.3:8443` (dst-nat'ed connections only), with the
  same flood guard as the DMZ path (ADR-086).

The trigger is "headscale-standby answers", not "the DMZ proxy is down". The standby only
runs after an operator started it, so the router follows that one manual decision: public
traffic moves when the standby starts and returns when it is stopped at failback. A flaky
probe of the primary can never move traffic, because the primary is not probed. Nothing in
Terraform is toggled at runtime (the address list entry is the only runtime state, written
by the netwatch scripts), so a later plan shows no drift. `vault.woitzik.dev` never gets a
public path: port 8443 serves headscale only and aborts anything else.

Options considered: toggling `disabled` on two NAT rules from netwatch (Terraform would
need `ignore_changes` on a security-relevant attribute, and a plan could re-enable the
wrong rule); netwatch on `10.0.30.2:443` (moves public traffic to a standby that may not be
running, and flaps with the DMZ proxy); a documented manual RouterOS step (violates the
rule that RouterOS changes go through Terraform, and Terraform cannot run in this outage).

### 5. Tailnet MagicDNS

Tailnet clients resolve `headscale.woitzik.dev` to the public IP through headscale's
extra record. The standby compose already runs the same `public-ip-record` writer. The
public IP leads to the router, which sends the connection to the Pi while the standby
runs, so the extra record stays correct unchanged.

## Monitoring

`kubernetes/system/monitoring/ha-standby-alerts.yml`, fed by the blackbox jobs
`ha-standby-proxy` (verified TLS handshake on 443 and 8443) and `ha-standby-active`
(the 8081 health URL):

- `HAStandbyProxyDown` (warning, 30 min): no verified TLS on a listener.
- `HAStandbyCertExpiringSoon` (warning): served certificate under 21 days, which means the
  push or install stopped at least nine days ago.
- `HAStandbyActive` (warning, 15 min): the standby runs and the router sends public
  headscale traffic to it; meant to catch a standby left running after a rehearsal.
- `HAStandbyProxyDownDuringFailover` (critical): standby running, front end failing.
- A failing push surfaces through the existing `KubeCronJobLastRunFailed`.

The job names avoid the `blackbox-*` prefix on purpose: `ExternalProbeFailed` pages on
those. All of this runs in the cluster, so it watches the standby's readiness while the
cluster is up; during the outage itself nothing alerts, as before.

## Consequences

- A `pve-mgmt-01` outage becomes a failover of minutes: restore, start the standby, run
  one playbook. The router follows by itself.
- Starting the standby at all, rehearsal or not, moves new public headscale connections to
  it. The runbook says so; `HAStandbyActive` reports a forgotten one.
- `rpi-srv-02` is in the server VLAN, not the DMZ. While the standby runs, an internet
  client reaches Caddy on the Pi directly, without CrowdSec. Mitigations: only headscale is
  served there, the router's per-source connection flood guard applies, Caddy runs with no
  capabilities beyond binding low ports and a read-only filesystem. Accepted for the
  duration of an outage; in normal operation the dst-nat never matches.
- The Pi holds a private key for the two hostnames. A compromised Pi could impersonate
  them on the LAN, which it can already do by serving the standby itself.
- The certificate names appear in Certificate Transparency logs. Both names are already
  public in this repository.
