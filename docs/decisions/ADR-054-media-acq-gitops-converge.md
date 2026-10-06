# ADR-054: Media-acquisition stack converges to git main with automatic broken-release rollback

**Status:** Accepted, 2026-10-06

## Context

The media-acquisition LXC (ct-srv-media-acq-01) ran its six-app Docker stack
with unpinned `:latest` images for months without ever being updated, and
nothing applied updates when they did land. Concrete consequence, 2026-08-20
to 2026-10-06: Treasure Maps indexer began rejecting NZB downloads whose
client did not report a current version, all six weeks of downloads failed,
and Radarr/Sonarr went into permanent indexer failure backoff. The image was
stale *not* because no new release existed — upstream NZBHydra2 shipped 9.1.1
on 2026-09-30 — but because nothing had any path to reach the LXC:

1. Renovate only matched `kubernetes/` manifests and `github-actions`
   (renovate.json `fileMatch`). Its `docker:pinDigests` preset wants a digest
   to update, and the compose file used bare `:latest`.
2. The Ansible deploy task (`docker_compose_v2`, `state: present`) never pulls
   images, so even a manual playbook run kept the stale local image.
3. A deliberate 2026-08-17 decision removed watchtower (site.yml comment) with
   the promise that "updates come through the repo or not at all" — but no
   repo-side mechanism for compose was ever stood up. The removal was correct;
   the replacement commitment was on paper only.

## Decision

Give the LXC the same "merge is deploy" property ArgoCD already gives the
Kubernetes side, without introducing a runner/secret dependency:

1. **Compose becomes a static, Renovate-pinned file.** `docker-compose.yml` is
   committed under `ansible/files/media-acquisition/`, all images pinned
   `tag@sha256`. Renovate manages it via its `docker-compose` manager: every
   version bump and digest update is a PR, auto-merged for patch/minor/digest
   after the existing 3-day soak + green CI, PR-only for majors. No Jinja —
   a template would not be parseable by Renovate.
2. **The host converges to git main on a 5-minute timer.**
   `media-acq-gitops-converge.sh` (cron, root, pattern consistent with the
   existing queue-watchdog) clones the public repo over HTTPS, fetches only
   on change, copies the committed compose file into place, and runs
   `docker compose up -d`. An idle run is a no-op.
3. **Health-gated automatic rollback.** autoheal already force-restarts an
   unhealthy container but keeps running the *broken image*. The converge
   script maintains a "last fully healthy compose" bookmark: when every stack
   container reports healthy, the current compose file is bookmarked; when any
   container stays unhealthy for three consecutive 5-minute runs, the previous
   good bookmark is restored and `up -d` re-creates from the older digest set.
   Convergence is triggered by a change in the *compose content* versus the
   deployed file (not by git HEAD alone), so the first clone deploys, a
   docs-only commit is a no-op, and a rolled-back HEAD is pinned in
   `$STATE_DIR/rolled_back` until a newer commit arrives — otherwise the next
   cron tick would re-apply the exact broken release the gate just rejected.
   Both deploy and rollback notify the existing Discord webhook.
4. **Ansible pulling option.** The role's compose task sets `pull: always`, so
   a manual/CI playbook run applies a merged digest bump immediately rather
   than silently keeping the stale local image — the exact drift class that
   caused the outage.

## Why not alternatives

- **GitHub Actions deploy job:** the workflows run on GitHub-hosted runners
  (`ci.yml`) which cannot reach 10.0.20.0/24, and wiring the self-hosted
  atlantis runner to SSH into the LXC means deploying new key material to two
  hosts for what is, at heart, a one-host copy-and-recreate operation. The
  in-host timer clones a public repo without any credential.
- **watchtower / auto-pull:** rejected before (2026-08-17) and still rejected —
  re-introduces the uncontrolled "two systems race to change running state"
  problem and defeats digest pinning.
- **Rollback via git revert in a workflow:** couples runtime health to CI
  execution and leaves a window where the LXC is down but no workflow runs.
  On-host detection with a local good-state bookmark always fires.

## Risks / acceptance criteria

- A bad image passes Docker's healthcheck but breaks at the application layer
  (e.g. the NZBHydra2 case, where `curl /` returns 200 while downloads 403).
  Layer-2 checks (arr `system/status`, SAB queue) are out of scope for the
  automatic gate; the watchdog + manual diagnosis remain the last line. The
  gate catches the common case — crash, CrashLoopBackOff, failed startup.
- The converge timer creates containers only when the compose content changes;
  a digest-equal re-run does not interrupt downloads.
- The autoheal container itself is not health-gated (single point of the gate);
  it is effectively stateless.

## Verification

- `ansible-lint` green on the role changes; compose validated with
  `docker compose config`.
- Manual `media-acq-gitops-converge.sh --help`-less dry state: converged a
  deliberately-typed local compose edit back to main, confirmed the health
  gate bookmarks good state, and confirmed an intentionally broken image
  (nonexistent digest) triggered the 3-run rollback to the previous good
  bookmark with Discord notification.
- Live after merge: the first converge run recreated the stack onto the pinned
  digest set; six app containers all report healthy; 5-minute cron installed.

## Follow-ups

- NZBIndexNL disabled in NZBHydra2 (site now serves a Next.js SPA, no Newznab
  XML — the live `capscheck` fails); Usenet-Crawler enabled (free account, key
  valid, search OK); NZBFinder re-disabled (key valid but API requires the
  premium plan, `error code="102"`). These are Hydra-side states, not in repo.
- Renovate will open per-image pin/upgrade PRs for the seven compose images on
  the next scheduled run; first merge exercises the full converge path.
