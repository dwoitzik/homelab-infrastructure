# ADR-059: headscale's public name resolves via a Cloudflare A record, not the MikroTik DDNS CNAME

- **Status**: Accepted, 2026-10-18. Apply pending the `terraform-apply` Environment
  gate; the CronJob auto-syncs once the PR merges.
- **Relates to**: ADR-033 (public-exposure allowlist), ADR-022 (headscale runs off-cluster),
  `kubernetes/system/monitoring/application.yml` (the `blackbox-http` probe),
  `kubernetes/system/monitoring/slo-rules.yml`, `terraform/stacks/cloudflare/main.tf`,
  `terraform/stacks/network/wan.tf` (`routeros_ip_cloud.ddns`)

## Context

On 2026-10-16 and 2026-10-17 the `SLOAvailabilityFastBurn` alert (critical) fired
repeatedly for `https://headscale.woitzik.dev`. The probe (`blackbox-http`, module
`http_auth_ok`, every 60s) recorded 48 failures in a ~17-hour window; `photos.woitzik.dev`,
probed by the same job, recorded none.

Every failure had `probe_http_status_code = 0` (no HTTP response — never connected) and
`probe_dns_lookup_time_seconds ≈ 9.50s`, a hard ceiling: DNS resolution itself timed out.
headscale answered `200` on every probe that *did* resolve, so headscale was never down.

The reason lives in the DNS chain:

```text
headscale.woitzik.dev  CNAME  ec190fe6b6ab.sn.mynetname.net   (ttl 300)
ec190fe6b6ab.sn.mynetname.net  A  178.202.47.0                (ttl 60)
```

`ec190fe6b6ab.sn.mynetname.net` is the MikroTik IP-Cloud DDNS name
(`routeros_ip_cloud.ddns`), and its **A record carries a 60s TTL**. Recursive resolvers
therefore re-chase the DDNS target roughly every minute, and MikroTik's authoritative
side intermittently takes ~8–9s to answer. Even on *successful* probes the lookup was
bimodal — p50 0.07s but p95 8.1s — and whenever it crossed the probe's ~9.5s tolerance
the probe failed outright, burning the 99.9% budget fast enough to page.

This is not a pure monitoring artifact: any client resolving `headscale.woitzik.dev`
goes through the same DDNS target and sees the same slowness.

## Decision

- **Publish `headscale.woitzik.dev` as a DNS-only Cloudflare A record** (not a CNAME to
  the MikroTik DDNS), so resolution is served by Cloudflare's authoritative DNS.
- **Keep its content current with a GitOps CronJob**
  (`kubernetes/system/infrastructure/cloudflare-ddns.yml`): every 5 minutes it reads the
  public IP from `api.ipify.org` and updates the record through the Cloudflare API,
  reusing `cloudflare-api-token-secret` (Zone:DNS:Edit), matching the pattern the removed
  cobblemon DDNS job used.
- **Terraform keeps the record but not its content**: the resource owns `type`/`name`/
  `ttl`/`proxied`, with `lifecycle { ignore_changes = [content] }` so the CronJob can
  update `content` without every `plan` trying to revert it to a stale IP.
- **Placement**: the CronJob runs in the `cert-manager` namespace. Its token secret and
  its already-broad `0.0.0.0/0:443` egress allow (for ACME + Cloudflare) both cover this
  job, so no new secret or NetworkPolicy is introduced.

## Consequences

- Probe DNS lookups return to tens of milliseconds; the fast-burn alert stops firing on
  what was a resolver-timing artifact.
- Real clients resolving the name get the same reliability improvement.
- Changing the record `type` (`CNAME -> A`) **forces replacement** in the Cloudflare
  provider, so the first apply destroys and recreates the record — a brief DNS gap,
  confined to the PR-gated manual apply.
- The home WAN IP (`178.202.47.0`) now appears literally in `main.tf`. It was already
  derivable from the DDNS hostname, and the disclosure guard has no rule for public IPv4.
- On a real WAN-IP change, convergence takes up to 5 min (CronJob interval) plus record
  TTL, versus the previous ~60s DDNS update — an acceptable trade for resolver reliability.
- Known layering smell: an infrastructure DDNS job living in the `cert-manager` namespace
  because that is where the token and the egress allow already are.

## Alternatives considered

- **Keep the CNAME and loosen the probe's resolver tolerance** (more retries / longer
  timeout). Rejected: it only hides the alert while clients keep suffering the same slow
  DDNS resolution.
- **Raise the TTLs instead.** Not possible: the 60s TTL belongs to MikroTik's DDNS A
  record, outside this repo's control.
- **Route headscale back through the Cloudflare tunnel.** Rejected in ADR-033 — headscale's
  TS2021 registration is incompatible with Cloudflare's proxy, which is why the record is
  DNS-only in the first place.

## Follow-up

- The `SLOAvailabilityFastBurn`/`SLOAvailabilitySlowBurn` annotations print the fractional
  error rate with a literal `%` (100x understatement); fixed in a separate PR to keep this
  change to one concern.
