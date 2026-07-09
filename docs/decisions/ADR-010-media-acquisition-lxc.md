# ADR-010: Dedicated LXC for the media acquisition stack, VPN-wrapped at the network level

**Date:** 2026-06-24
**Status:** Accepted

## Context

Sonarr/Radarr/Bazarr/SABnzbd/NZBHydra2 ran as Kubernetes Deployments in the `apps`
namespace. SABnzbd had a hand-rolled Mullvad WireGuard kill switch (init container +
manual iptables rules) bolted onto its pod spec — the only one of the five with any VPN
protection, and the WireGuard config was never actually populated with real credentials,
so the kill switch was failing closed (no leak, but no functioning tunnel either).

The user wants the whole acquisition pipeline (not just the download client) to be as
privacy-focused as practical: indexer search queries, metadata lookups, and the actual
download traffic should all avoid exposing the home IP, with no risk of silently falling
back to a direct connection if the VPN drops.

## Decision

Move the whole stack (Sonarr, Radarr, Bazarr, SABnzbd, NZBHydra2) into a new, dedicated
Proxmox LXC (`ct-srv-media-acq-01`, 10.0.20.253) running plain Docker Compose, with
network isolation enforced at the container-namespace level via **gluetun** (a
purpose-built VPN container with native Mullvad support and a real kill switch) rather
than per-pod sidecars. Jellyseerr (request-management UI, not itself privacy-sensitive)
and a standalone Tor SOCKS proxy (for NZBHydra2's indexer queries specifically) sit on a
separate bridge network within the same LXC.

This follows the existing precedent in this repo (`ct_dmz_proxy_01`, `ct_dmz_games_01`)
of running Docker-based workloads outside Kubernetes when dedicated network-level
configuration matters more than GitOps/Helm uniformity.

## Reasons

- **gluetun over hand-rolled WireGuard+iptables:** purpose-built for exactly this case,
  actively maintained, native Mullvad support, built-in kill switch and health checks —
  strictly better than re-implementing the same logic five times (once per app), which
  is what the current SABnzbd-only sidecar does.
- **Dedicated LXC over a k3s agent node:** wrapping a whole LXC's network namespace in
  a VPN tunnel is straightforward; doing the same for a k3s *agent* would also tunnel the
  node's own control-plane traffic (API server, etcd) through Mullvad, which must not
  happen. A separate LXC avoids that conflict entirely.
- **Tor for indexer queries only, never bulk downloads:** Tor's bandwidth is far too
  limited for media-sized transfers, and routing bulk downloads through it would be
  abusive to the shared Tor network (which exists for people who need anonymity for
  safety, not bulk transfers). Indexer search queries are small and a good fit.
- **Jellyseerr stays outside the VPN-wrapped namespace:** it's a request-management UI
  reachable via Traefik/Authelia, not itself making acquisition queries — putting it
  inside gluetun's namespace would complicate normal ingress for no privacy benefit.

## Trade-offs

- Leaves Kubernetes/GitOps/ArgoCD management for these six apps in favor of
  Ansible + Docker Compose — a real regression in "everything is GitOps-managed," but
  matches the already-accepted pattern for the DMZ LXCs, and the privacy requirement
  takes priority here.
- Adds a sixth host to the inventory and a new role to maintain.
- Modest additional load on `rpool` (currently ~66% used) — root disk only
  (~25GB), media itself stays on the existing NFS mount, not duplicated.

## Amendment — 2026-06-26: VPN approach revised

After analysis, the gluetun/Mullvad approach was dropped in favour of a simpler two-layer
model:

- **SABnzbd → Eweka over SSL (port 563) directly.** Transport is encrypted; the ISP sees
  only "connected to news.eweka.nl", not content. No VPN needed: Usenet copyright
  enforcement operates exclusively via BitTorrent peer-list monitoring — there is no
  mechanism by which an ISP or rights-holder can observe or report Usenet downloads. VPN
  on the download path would also halve throughput and risk Eweka flagging the account for
  apparent multi-subscriber IP sharing.
- **NZBHydra2 indexer queries → Tor SOCKS5 (172.28.1.10:9050, `tor` container).** Search
  queries are small and latency-tolerant; Tor is a better fit than a free commercial VPN
  (no single operator to trust, no throttling concern for metadata-only traffic). Configured
  in NZBHydra2 with "fail closed" — Tor outage blocks queries rather than leaking the home
  IP to indexers.

gluetun and Mullvad credentials have been removed from the role. `vault_eweka_username`
and `vault_eweka_password` in Ansible Vault replace the Mullvad placeholders.

## Consequences

- New Terraform resource `ct_srv_media_acq_01` (`terraform/stacks/proxmox/lxc.tf`),
  needs an `atlantis apply` to actually provision (per this repo's Atlantis-only-apply
  convention).
- New Ansible role `media_acquisition`, new inventory group `media_acq_nodes`.
- **Cutover is a separate, deliberately deferred step:** the existing Kubernetes
  Deployments/PVCs for these apps are left running until the new LXC is provisioned,
  Ansible has run successfully, and the stack is verified working — only then should
  Traefik's IngressRoutes be repointed and the old k8s resources removed. Doing both in
  one shot would risk an outage window with no acquisition stack running at all.
- Blocked on Eweka credentials (placeholders in Vault) — fill in after Eweka signup, then
  re-run `ansible-playbook ansible/site.yml --limit media_acq_nodes`.
