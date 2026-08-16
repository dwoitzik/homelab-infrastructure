# ADR-021: Replace Atlantis's public webhook with a self-hosted GitHub Actions runner

**Date:** 2026-08-15
**Status:** Accepted

## Context

Atlantis (`ct-srv-atlantis-01`, 10.0.20.250, ADR-012) is the only reason
`atlantis.woitzik.dev` has ever needed a public Cloudflare Tunnel entry: GitHub's
webhook delivery is inbound-push, so GitHub has to be able to reach Atlantis to tell it
a PR was opened or an `atlantis plan`/`apply` comment was posted. Every other service
this Phase 1 pass has looked at is inbound because a human wants to reach it from
outside the LAN/VPN — Atlantis is inbound because of a *machine-to-machine* direction
problem, not a genuine "someone needs to reach this from their phone" need.

ADR-019 (this session) already dropped `atlantis.woitzik.dev`'s Cloudflare DNS record
and tunnel ingress rule as part of moving to an explicit public-exposure allowlist —
Atlantis is not on that allowlist and has no plausible case for being on it. That
apply is what actually happened live, confirmed via the Cloudflare API; see
`docs/EXPOSURE.md` and `phase8/LEDGER.md` Entry 2 for the full history, including the
self-inflicted chicken-and-egg it created (the same apply that removed the DNS record
also removed the one path GitHub's webhook needs to tell Atlantis to finish
reconciling its own Terraform state — parked, not blocking, since the dangerous state
is already closed live).

That parked issue is itself the argument for this ADR: as long as Atlantis depends on
an inbound GitHub webhook, closing its public exposure and keeping its GitOps function
working are in direct tension. Re-exposing it even briefly to unstick a webhook
recreates exactly the surface this whole phase exists to remove. The direction problem
needs solving structurally, not worked around each time it bites.

## Options considered

**Option A — self-hosted GitHub Actions runner (chosen).** A runner inside the
network polls GitHub outbound for work; GitHub never initiates a connection inward.
`atlantis.woitzik.dev`'s tunnel entry is deleted outright (already effectively true
post-ADR-019) rather than narrowed. Atlantis itself — or a GitHub Actions workflow
doing the equivalent `terraform plan`/`apply`-on-PR-comment flow directly — runs on
that runner.

**Option B — keep Atlantis public, narrow the door.** Cloudflare Access in front of
`atlantis.woitzik.dev`, a WAF rule restricting source IPs to GitHub's published
webhook ranges, and HMAC signature verification on the webhook payload (already
present via `atlantis_gh_webhook_secret` — `ansible/roles/atlantis/defaults/main.yml`).
Technically still public, but only GitHub's IP ranges can reach it, and only a
correctly-signed payload gets acted on.

## Decision

**Option A.** Deploy a self-hosted GitHub Actions runner inside the network (same
`atlantis_nodes` VLAN 20 placement Atlantis already uses, or folded onto the existing
`ct-srv-atlantis-01` LXC) and move the PR-driven `terraform plan`/`apply` workflow onto
it, either by having the runner execute Atlantis itself in a mode that doesn't need an
inbound webhook, or by replacing Atlantis with GitHub Actions workflows that call
`terraform plan`/`apply` directly and gate `apply` on manual workflow approval
(GitHub Environments' required-reviewers feature is a direct substitute for Atlantis's
own `atlantis apply` PR-comment gate).

`atlantis.woitzik.dev`'s Cloudflare Tunnel entry stays deleted — not narrowed, not
Access-gated, gone. GitHub Actions' own outbound-polling runner registration is the
only network path involved, and it originates from inside the network, so no MikroTik
port forward, Cloudflare Tunnel, or WAN-listening service is needed at all.

## Reasons

- **Solves the direction problem instead of managing the exposure.** Option B still
  leaves a public listener that has to be correctly configured forever (IP-range
  allowlist has to track GitHub's published ranges as they change; Access has to stay
  correctly wired; HMAC verification has to stay correctly implemented) — every one of
  those is a way to silently regress back to "actually open" the way the wildcard
  ingress rule did in one day (ADR-019's own context section). Option A has no ongoing
  configuration surface to regress: there's simply nothing listening on the public
  internet.
- **Removes the `terraform@pve` token-in-compose problem as a side effect.** Atlantis's
  current deployment holds the Proxmox API token (and Cloudflare API token, and
  RouterOS credentials) directly in its running container, reachable by anything that
  can reach Atlantis's own API — which, until this ADR, was "anyone on the public
  internet who can get past HMAC verification." A self-hosted runner with no inbound
  path removes an entire class of "what if Atlantis's own auth has a bug" risk for the
  most sensitive credentials in the whole stack. This directly feeds the credential
  rotation plan in `docs/EXPOSURE.md` (Tier 1) — Option A makes that Tier 1 risk
  permanently smaller, not just rotated once.
- **Better portfolio story.** GitHub Actions + self-hosted runner is a widely
  recognized, directly reusable pattern (matches how most real orgs run
  infra-as-code CI); a bespoke public Atlantis webhook is a homelab-specific
  workaround that a reviewer has to understand Atlantis's internals to evaluate. The
  brief's own framing agrees with this (`phase8/BRIEFING-V4.md` section 1.1).
- **Option B was seriously considered, not just noted.** It's a legitimate, standard
  pattern (this is exactly how GitHub itself recommends securing inbound webhooks) and
  would have been the pick if Atlantis's specific webhook-driven UX (PR-comment-driven
  plan/apply, live plan output posted back to the PR) were considered essential to
  keep. It isn't — GitHub Actions can reproduce the same PR-comment-driven experience
  natively (`workflow_dispatch`, PR comment triggers via `issue_comment` events, and
  posting plan output back via the same runner using `gh pr comment`), so there's no
  functionality actually lost by moving away from Atlantis's specific implementation.

## Trade-offs (accepted)

- Migration work: existing `atlantis.yaml`-driven multi-stack config
  (`terraform/stacks/network`, `terraform/stacks/proxmox`, `terraform/stacks/cloudflare`)
  needs an equivalent GitHub Actions workflow per stack (or one parameterized
  workflow), plus the runner itself needs registering and keeping patched — a new
  host-level maintenance responsibility, same class of work as any other LXC in this
  repo (PBS-backed, Ansible-managed). GitHub has to be trusted with runner
  registration once at setup — a one-time bootstrap, not an ongoing exposure.
- Losing Atlantis-specific ergonomics (its own web UI for viewing all locked
  PRs/plans across the repo) unless deliberately reproduced — GitHub's own PR-comment
  trail becomes the primary interface instead, which is a reasonable trade for a
  homelab-scale repo with a small number of concurrent PRs.
- This is a real implementation project, not a config toggle — sequenced as its own
  follow-up PR (or set of PRs), not done as part of writing this ADR. Until it lands,
  Atlantis continues running exactly as today (LAN/VPN-reachable only, per ADR-019 —
  already correctly the interim state), just without a public webhook path, which
  means `atlantis plan`/`apply` PR comments won't trigger anything until either this
  migration completes or the webhook path is manually unstuck once (see the parked
  issue in `phase8/LEDGER.md` Entry 2) as a stopgap.

## Consequences

- New follow-up work item: implement the GitHub Actions workflow(s) + self-hosted
  runner, migrate `terraform/stacks/*`'s Atlantis-driven plan/apply flow onto it,
  decommission Atlantis's webhook listener entirely (its Docker container can keep
  running for `plan`/`apply` execution if reused as the runner's execution
  environment, or be removed if fully replaced by native `terraform` calls in the
  workflow).
- `ansible/roles/atlantis/defaults/main.yml`'s `atlantis_gh_webhook_secret` becomes
  unused once the webhook path is removed — remove it and rotate it out of Vault as
  part of that follow-up (folds into the Tier 1 credential rotation work already
  tracked in `docs/EXPOSURE.md`).
- `terraform/stacks/cloudflare/`'s Atlantis tunnel entry stays removed permanently
  (already true post-ADR-019) — this ADR is what makes that removal a deliberate,
  permanent architectural decision rather than a still-open loose end.
- Until the migration lands, `atlantis plan`/`apply` PR comments have no working
  delivery path — noted in `phase8/STATE.md` as an open item, not silently assumed
  fixed.
