# ADR-013: Tor SOCKS5 proxy for NZBHydra2 indexer queries, fail-closed

**Date:** 2026-07-06 (decision itself dates to ADR-010's 2026-06-26 amendment; this ADR
exists to make it independently discoverable rather than buried inside a broader
LXC-provisioning ADR)
**Status:** Accepted

## Context

The media-acquisition stack (`ct-srv-media-acq-01`) has two distinct outbound traffic
flows with different privacy properties:

1. **SABnzbd → Eweka**, the Usenet provider, over SSL/NNTPS (port 563). Already
   encrypted end-to-end; the ISP sees only "connected to news.eweka.nl," not content.
2. **NZBHydra2 → indexer sites** (NZBGeek, DrunkenSlug, etc.), plain HTTP/HTTPS search
   queries to look up releases. These requests are not inherently IP-hidden the way an
   NNTPS connection is transport-encrypted — every search exposes the home IP to
   whichever indexer receives it, same as browsing any website directly.

During the 2026-07-06 audit re-assessment pass, this was flagged for possible removal
under the assumption that "Usenet is already SSL end-to-end, so no proxy/VPN layer is
needed" — true for flow (1), but that reasoning does not extend to flow (2), a
completely different traffic type Tor was never meant to protect the download path
from in the first place.

## Decision

Keep the Tor SOCKS5 proxy (`tor` container, `172.28.1.10:9050`) in front of NZBHydra2's
indexer queries only. Never route SABnzbd's download traffic through it (Tor's
bandwidth can't handle bulk transfers, and doing so would be abusive to the shared Tor
network). Configure NZBHydra2 with **no direct-connection fallback** — if Tor is down,
indexer queries fail rather than silently leaking the home IP to indexer sites.

## Verification (2026-07-06)

Live-confirmed rather than assumed from the original design intent:

- `sabnzbd.ini`: `socks5_proxy_url = ""` (empty) — SABnzbd was never routed through Tor,
  consistent with the design; its `ssl = 1`, `ssl_verify = 2` settings confirm the
  direct-to-Eweka SSL path is real and active.
- `nzbhydra.yml`: `proxyType: SOCKS`, `proxyHost`/`proxyPort` pointing at the Tor
  container, no direct-fallback option enabled — fail-closed behavior confirmed as
  configured, not just documented as intent.
- One live exception: `proxyIgnoreDomains: [nzbfinder.ws]` — this specific indexer
  bypasses Tor and connects directly. Not investigated further as part of this pass;
  worth understanding why if revisited (site-specific Tor blocking? A deliberate
  earlier exception?).

## Consequences

- No infrastructure change from this ADR — it documents and preserves an existing,
  correct, already-live design that a routine audit pass nearly removed based on an
  incomplete read of what the Tor proxy actually protects.
- See `docs/AUDIT.md` WRK-006 (closed as "verified correct as designed," not "removed")
  and REL-020 (the SQLite-on-NFS risk this was entangled with is independently
  resolved — the whole stack no longer runs on Kubernetes/NFS at all).
- See ADR-010's 2026-06-26 amendment for the original, fuller reasoning behind
  dropping gluetun/Mullvad in favor of this two-layer model — this ADR exists
  alongside it for discoverability, not as a replacement.
