# ADR-063: Renovate digest/pin updates bypass minimumReleaseAge at branch stage

## Status

Accepted and applied, 2026-10-18.

## Context

A cluster-wide sweep surfaced that the entire media-acquisition stack was running stale
images: Jellyseerr 2.7.3, plus stale Radarr, Sonarr, SABnzbd, NZBHydra2, Bazarr and
Autoheal. The expectation was that Renovate keeps them current — `renovate.json` has a
`docker-compose` package rule with `automerge: true` and a 3-day soak, and the media-acq
LXC converges to git `main` every 5 minutes (ADR-054).

Renovate *was* opening the PRs — but they never merged. Open digest-update PRs had piled
up over two weeks (#901 jellyseerr, #889 radarr, #868 sonarr, #859 sabnzbd, #858
nzbhydra2, #854 bazarr, #855 autoheal, #856 a pinned GitHub Action). Every one carried a
`renovate/stability-days` check stuck at **pending** — "Updates have not met minimum
release age requirement" — while the underlying images were weeks old.

The cause is the global `minimumReleaseAge: "3 days"`. Since Renovate 42,
`minimumReleaseAge` defaults to `minimumReleaseAgeBehaviour: timestamp-required`, and
Renovate evaluates the age in two places: the **lookup** stage (which, for digest updates,
does get a timestamp and lets the PR be created) and the **branch** stage (which reads
`upgrade.releaseTimestamp` — never populated for a digest or first-time-pin update). At
the branch stage a missing timestamp falls into the "no timestamp, therefore pending"
path, so `renovate/stability-days` is set yellow on every run, forever. With
`internalChecksAsSuccess` defaulting to false, **automerge can never complete** — silently
(renovatebot/renovate#45236). A five-day-old image cannot fail a three-day soak; the check
is reporting that the age is *unknown* to it, not that it is young.

This is not specific to this repo's config: any repo with a global `minimumReleaseAge` and
SHA/digest-pinned images hits it.

## Decision

Add a package rule that sets `minimumReleaseAgeBehaviour: "timestamp-optional"` for
`digest` and `pin` update types:

```json
{
  "matchUpdateTypes": ["digest", "pin"],
  "minimumReleaseAgeBehaviour": "timestamp-optional"
}
```

This is the workaround the Renovate issue itself recommends. The soak is not removed
outright: the lookup-stage age check still applies wherever the registry exposes a push
timestamp (Docker Hub reports `tag_last_pushed` for these images), and digest re-points of
a floating `latest` are exactly the updates whose timestamps Renovate can't see — so the
branch-stage block only ever suppressed updates Renovate could not age, never ones it
could.

## Consequences

- The ~10 stuck digest/pin PRs unblock and auto-merge once CI is green, which restores the
  "merge is deploy" auto-update path for the media-acq stack and the digest-pinned k8s
  images.
- Residual risk: a digest re-point that happens to have no registry timestamp merges
  without the branch-stage soak. This is bounded by the same controls that always applied —
  CI (kubeconform, Trivy, the disclosure/comment guards) and, for the media-acq stack,
  ADR-054's 5-minute converge with a health-gated rollback to the last good image set.
- `minimumReleaseAge` stays enforced for ordinary version (patch/minor/major) updates,
  where a real release timestamp exists — the soak's supply-chain intent is intact for the
  update class that actually carries version semantics.
- Renovate separately cannot PATCH its Dependency Dashboard issue (HTTP 403 on the issue
  edit), so the dashboard is stale and this class of silent-stuck failure was invisible.
  Fixing the dashboard token's Issues permission is tracked separately.
