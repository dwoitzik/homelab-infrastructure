# URL Inventory

Every public hostname that should exist for this homelab, tested from outside the
network using real DNS resolution — not `curl --resolve`, not a port-forward, not the
MetalLB LoadBalancer IP directly (see Methodology below for why those don't prove
external reachability).

**Last tested:** 2026-08-23, from `ct-srv-claude-agent` (LXC 100), using
`dig @1.1.1.1` for DNS, then connecting to the literal public answer directly
(`curl --resolve` pinned to that answer, or a raw TCP connect for the non-HTTP
service).

## Summary

This table was last refreshed 2026-08-14, before `ADR-033` (public exposure allowlist)
was applied — it described a since-abandoned wildcard-tunnel plan (PR #436) and listed
44 hostnames as `PARKED` pending that PR. That PR was never the direction taken: the
operator reversed course the same day and `ADR-033` replaced it with an explicit
allowlist of exactly two hostnames. This is the first refresh since, and the table
below reflects what is actually live today, not what PR #436 would have produced.

- **3 hostnames resolve publicly and answer correctly**: `photos.woitzik.dev`,
  `headscale.woitzik.dev` (both via the Cloudflare Tunnel, `ADR-033`'s allowlist), and
  `mc.woitzik.dev` (Minecraft, via a playit.gg relay tunnel — a separate, non-Cloudflare
  path; TCP traffic can't go through Cloudflare's CDN, see the Non-application section
  below).
- **41 of the 44 Traefik-routed hostnames have no public DNS record at all**, by
  design (`ADR-033`) — reachable via LAN or the Headscale/Tailscale VPN only, through
  the same internal AdGuard rewrite → Traefik LoadBalancer path every local client
  already uses. This is the intended state, not a gap: previously this table called
  these rows `PARKED — awaiting PR #436`; that framing is stale and has been dropped.
- `claude.woitzik.dev` is a special case, not in the Traefik-routed set at all (see
  its own note below) — also has no public DNS record, also by design, for a different
  reason (`ADR-032`/`ADR-033`).

**Zero unintended public exposure found.** Exactly the 3 hostnames the operator's own
allowlist decisions intend to be public are public; nothing else is.

## Methodology — why `curl --resolve` and the LB IP don't prove anything

This LXC's own DNS resolver is Tailscale's MagicDNS (`100.100.100.100` in
`/etc/resolv.conf`), which resolves every `*.woitzik.dev` query to an internal LAN IP
via AdGuard's rewrite (confirmed live: the system resolver returns `10.0.20.200`, the
Traefik LoadBalancer IP, for hostnames that have zero public DNS record) — the same
false-positive risk the previous version of this document warned about, just from a
different internal resolver than the one that existed in 2026-08-14's network setup.
`dig @1.1.1.1 <host> A` (a public resolver, bypassing the local rewrite entirely) is
the only test in this document's Public DNS column, and every HTTP check pins the
connection with `curl --resolve host:443:<that literal public answer>` rather than
letting the system resolver pick the target.

## Non-application DNS records (not in scope for the table below)

`woitzik.dev`/`www` (Vercel-hosted personal site), MX/DKIM/DMARC/SPF (Brevo/SMTP2GO
email), and ACME challenge TXT records — verified present and unrelated to application
exposure.

`mc.woitzik.dev` — Minecraft, via a playit.gg relay tunnel, confirmed live 2026-08-23:
`dig @1.1.1.1 mc.woitzik.dev A` → `147.185.221.212`, and a raw TCP connect to
`147.185.221.212:25565` succeeds. This is a deliberate public surface (`docs/EXPOSURE.md`
tracks it as the one hostname with actual strangers on it) — not part of `ADR-033`'s
Cloudflare-Tunnel allowlist since Minecraft's TCP protocol can't route through
Cloudflare's CDN, but equally deliberate. Direct WAN port-forwards for it were removed
2026-07-01 (`terraform/stacks/network/nat_portforward.tf`) in favor of this tunnel.

`claude.woitzik.dev` — not a Traefik-routed hostname. `ADR-032` (2026-08-14) gave it its
own dedicated Cloudflare Tunnel; this note previously claimed that tunnel was destroyed
by the next day's apply (`ADR-033`/PR #440), but that PR never actually touched the
Terraform resource — the claim was wrong. Whatever was deleted on 2026-08-23 was deleted
live only, never in git, so it was pure declared-vs-live drift and the next `cloudflare`
apply silently recreated it. Actually removed from Terraform 2026-08-27 (`ADR-032` now
marked Superseded) so this can't happen again. Reachable via Tailscale/LAN only.

## Full table

All 44 hostnames below are Traefik-routed (`kubernetes/system/apps-ingressroute.yml` /
`other-ingressroute.yml`). Per `ADR-033`, only `photos` and `headscale` get a
Cloudflare Tunnel ingress rule and public DNS record; every other row's "no tunnel
rule, no public DNS" is the intended, designed-in state, not an outstanding defect —
each is still fully reachable via LAN/VPN through the same Traefik instance.

| Hostname | Public DNS (live, `dig @1.1.1.1`) | Tunnel ingress rule (`ADR-033`) | Status |
|---|---|---|---|
| `ai.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `argo.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `atlantis.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `auth.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design — checked in `ADR-033` that nothing publicly reachable depends on it) |
| `backup.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `bazarr.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `beszel.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `cars.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `dns.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `docs.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `draw.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `element.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `finance.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `git.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `gotify.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `ha.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `headscale.woitzik.dev` | 104.21.38.184 | Explicit (main.tf) | **PASS (200)** — public by design, structurally required (`ADR-033`) |
| `home.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `hydra.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `links.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `loki.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `matrix.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `mealie.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `media.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `monitoring.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `n8n.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `nextcloud.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `onlyoffice.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `photos.woitzik.dev` | 104.21.38.184 | Explicit (main.tf) | **PASS (200)** — public by design, family access (`ADR-033`) |
| `pve.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `radarr.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `requests.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design — was the one hostname with **no** protection of any kind under the old wildcard plan; moot now) |
| `router.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `rss.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `s3.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `sabnzbd.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `scrutiny.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `search.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `secrets.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `sonarr.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `speed.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `status.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `traefik.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `vault.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design) |
| `wazuh.woitzik.dev` | none | not allowlisted | LAN/VPN only (by design — had no plausible reason to be public per `ADR-033`'s own audit) |

## TLS

Every hostname above is covered by a single wildcard certificate
(`kubernetes/system/certificates/wildcard-woitzik-dev.yml`, `wildcard-woitzik-dev-tls`,
issued via `letsencrypt-production` ClusterIssuer, confirmed `Ready: True`) — no
per-hostname certificate management needed as new services are added. This is
unaffected by which hostnames are publicly resolvable; Traefik terminates TLS for the
LAN/VPN path the same way it would for a public one.
