# URL Inventory

Every public hostname that should exist for this homelab, tested from outside the
network using real DNS resolution — not `curl --resolve`, not a port-forward, not the
MetalLB LoadBalancer IP directly. Those methods were used in the original recovery and
they don't actually prove external reachability (see Methodology below for why this
matters and bit us this time too).

**Last tested:** 2026-08-14, from `ct-srv-claude-agent` (LXC 100), using `dig @1.1.1.1`
and `dig @8.8.8.8` for DNS, then connecting to the literal public answer over HTTPS.

## Summary

46 hostnames are declared across the cluster's IngressRoutes. At the time of this test:

- **1 PASS** (`photos.woitzik.dev`)
- **45 PARKED**, all with the same two root causes, both already fixed and sitting in
  open PRs awaiting a human merge/apply step (self-merge and live Atlantis applies are
  intentionally gated — see the repo's own `CLAUDE.md` workflow, and `phase6/LEDGER.md`
  Entry 2 for why this agent didn't force them through):
  - **PR #435** (CI green, awaiting merge): CrowdSec bouncer Middleware's
    `crowdsecLapiKeyFile` pointed at a file that never existed, so Traefik failed every
    CrowdSec-protected route closed (404) regardless of DNS/tunnel state. Also adds the
    `external-atlantis` Service that was referenced but never defined.
  - **PR #436** (plan clean — 4 to import, 4 to add, 1 to change, 0 to destroy — awaiting
    `atlantis apply -p cloudflare` then merge): the Cloudflare Tunnel's ingress config
    only listed 3 hostnames (atlantis/photos/media) + a 404 catch-all, and 42 of the 46
    hostnames had **zero public DNS record at all** — including `auth.woitzik.dev`
    itself, meaning the Authelia gate was unreachable externally, which cascades to
    every CrowdSec+Authelia-protected hostname behind it. Fixed with a single wildcard
    tunnel ingress rule + wildcard DNS CNAME through Traefik, which already does
    correct per-host routing and auth enforcement. Also adds `claude.woitzik.dev`
    (previously LAN-only via an AdGuard rewrite) per the operator's explicit request.

Re-test after both PRs land — every PARKED row below is expected to flip to PASS with no
further changes, since the underlying IngressRoutes, Services, and middleware were
already correct; only DNS/tunnel/middleware config was missing or wrong.

## Methodology — why `curl --resolve` and the LB IP don't prove anything

This LXC's own DNS resolver (AdGuard, via the network's normal resolv.conf) rewrites
every `*.woitzik.dev` query to an internal IP for LAN convenience — confirmed live:
`dig home.woitzik.dev` here returns `10.0.20.200` (the Traefik LoadBalancer IP), while
`dig @1.1.1.1 home.woitzik.dev` returns the real public answer. That means a plain
`curl https://home.woitzik.dev/` run from inside this network silently tests the
internal path even without `--resolve`, and proves nothing about what David's phone gets
over LTE or a friend gets from outside. The only valid test is: resolve via a public
resolver not subject to the local rewrite, then connect to that literal answer.

## Non-application DNS records (not in scope for this table)

`woitzik.dev`/`www` (Vercel-hosted personal site), MX/DKIM/DMARC/SPF (Brevo/SMTP2GO
email), `mc.woitzik.dev` (Minecraft via playit.gg tunnel, not Cloudflare Tunnel —
TCP traffic can't go through Cloudflare's CDN), and ACME challenge TXT records. All
verified present and correctly separate from the application hostnames above.

`cobblemon.woitzik.dev` — previously tracked as a stale record pending deletion,
confirmed already removed live (see PR #436 / `terraform/stacks/cloudflare/main.tf`).

## Full table

| Hostname | Backing service | IngressRoute | Tunnel ingress rule | Public DNS (live) | Auth path | Status |
|---|---|---|---|---|---|---|
| `ai.woitzik.dev` | `open-webui` | `ai-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `argo.woitzik.dev` | `argocd-server` | `argo-main` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `atlantis.woitzik.dev` | `external-atlantis` | `atlantis-final` | Explicit (main.tf) | 104.21.38.184 | CrowdSec + Authelia SSO | PARKED — CrowdSec middleware bug (404), fix in PR #435 (CI green, awaiting merge) |
| `auth.woitzik.dev` | `authelia` | `auth-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `backup.woitzik.dev` | `external-pbs` | `pbs-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `bazarr.woitzik.dev` | `bazarr` | `bazarr-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `beszel.woitzik.dev` | `beszel` | `beszel-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `cars.woitzik.dev` | `lubelogger` | `lubelogger` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `claude.woitzik.dev` | `external-claude-agent` | `claude-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `dns.woitzik.dev` | `external-dns` | `dns-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `docs.woitzik.dev` | `paperless` | `docs-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `draw.woitzik.dev` | `excalidraw` | `excalidraw` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `element.woitzik.dev` | `element-web` | `matrix-element-web` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `finance.woitzik.dev` | `firefly-iii` | `firefly-iii-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `git.woitzik.dev` | `gitea` | `gitea-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `gotify.woitzik.dev` | `gotify` | `gotify` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `ha.woitzik.dev` | `home-assistant` | `ha-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `headscale.woitzik.dev` | `headscale` | `headscale-final` | Wildcard (`*.woitzik.dev`, PR #436) | 172.67.137.91 | None at Traefik (own login) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `home.woitzik.dev` | `homepage` | `home-final` | Wildcard (`*.woitzik.dev`, PR #436) | 178.202.46.102 | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `hydra.woitzik.dev` | `nzbhydra2` | `nzbhydra2-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `links.woitzik.dev` | `linkding` | `linkding` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `loki.woitzik.dev` | `loki` | `loki-main` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `matrix.woitzik.dev` | `synapse` | `matrix-synapse` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `mealie.woitzik.dev` | `mealie` | `mealie-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `media.woitzik.dev` | `jellyfin` | `media-final` | Explicit (main.tf) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `monitoring.woitzik.dev` | `kube-prometheus-stack-grafana` | `grafana-main` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `n8n.woitzik.dev` | `n8n` | `n8n` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `nextcloud.woitzik.dev` | `nextcloud` | `nextcloud-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `onlyoffice.woitzik.dev` | `onlyoffice` | `onlyoffice-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `photos.woitzik.dev` | `immich-server` | `immich-final` | Explicit (main.tf) | 172.67.137.91 | Rate-limit only (own login/API token) | PASS (200) |
| `pve.woitzik.dev` | `external-pve` | `pve-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `radarr.woitzik.dev` | `radarr` | `radarr-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `requests.woitzik.dev` | `jellyseerr` | `jellyseerr-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `router.woitzik.dev` | `router-external` | `router-main` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `rss.woitzik.dev` | `freshrss` | `freshrss` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `s3.woitzik.dev` | `garage` | `garage-s3-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | None at Traefik (own login / intentionally public) | PARKED — no public DNS/tunnel rule, fix in PR #436 (open, plan clean) |
| `sabnzbd.woitzik.dev` | `sabnzbd` | `sabnzbd-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `scrutiny.woitzik.dev` | `scrutiny-web` | `scrutiny-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `search.woitzik.dev` | `searxng` | `searxng-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `secrets.woitzik.dev` | `vault` | `vault-main` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `sonarr.woitzik.dev` | `sonarr` | `sonarr-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `speed.woitzik.dev` | `myspeed` | `myspeed-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `status.woitzik.dev` | `uptime-kuma` | `status-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `traefik.woitzik.dev` | `api@internal` | `traefik-dashboard` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec + Authelia SSO | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `vault.woitzik.dev` | `vaultwarden` | `vaultwarden-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec only (own login) | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |
| `wazuh.woitzik.dev` | `external-wazuh` | `wazuh-final` | Wildcard (`*.woitzik.dev`, PR #436) | none (fixed by PR #436) | CrowdSec only (own login) | PARKED — no public DNS + CrowdSec bug, fix in PR #436 + #435 (both open) |

## TLS

Every hostname above is covered by a single wildcard certificate
(`kubernetes/system/certificates/wildcard-woitzik-dev.yml`, `wildcard-woitzik-dev-tls`,
issued via `letsencrypt-production` ClusterIssuer, confirmed `Ready: True`) — no
per-hostname certificate management needed as new services are added.
