# ADR-048: Public-repo disclosure policy and its mechanical guard

**Status:** Accepted and applied, 2026-10-02

## Context

This repository is a public portfolio artifact under a GitHub account whose
handle matches the managed domain, so anything committed here is permanently
readable and trivially harvested by automated scrapers. A disclosure review on
2026-10-02 found the repository had accumulated a complete internal map:

| Category | Count | Files |
|---|---|---|
| `*.woitzik.dev` hostnames | 673 | 342 |
| RFC1918 private IPv4 addresses | 474 | — |
| Internal hostnames (`<vm>`, `<rpi>`, `<hypervisor>` patterns) | 397 | — |
| Cloudflare account/zone IDs | 12 | 12 |
| Personal email addresses | 11 | 9 |
| Compiled third-party binaries | 1 (57 MB) | 1 |

Two specific problems prompted the change. First, `CLAUDE.local.md` — a file
whose entire purpose was to hold local-only hardware and topology context — was
tracked and had been public since it was first committed in `17e4a4b`. Second,
the GitHub Security tab showed 483 open Trivy alerts, which is a number no one
reads and therefore a number that carries no signal.

A secrets-only view would have missed the actual exposure. `gitleaks` over the
full history without a baseline returns 33 findings, all
`hardcoded-password-assignment`, and every one is either a placeholder or an
already-rotated value: `jwt_secret` resolves from Vault, Wazuh uses a
`${VAR:?}` fail-safe, and the files that once held literals are gone. **No live
credential is present in HEAD.** The exposure was reconnaissance, not credentials.

## The constraint that shapes everything else

`kubernetes/` is the ArgoCD source of truth and auto-sync is on, so a merged
manifest deploys itself. An `IngressRoute` host must therefore be the real
hostname or the route does not load, and Authelia's user list must contain the
real identity or SSO breaks. **A public GitOps repository cannot hide the values
it deploys.** Removing them requires a private overlay (kustomize base plus a
private overlay supplying hostnames), which is a real architecture change and is
deliberately not bundled into a hygiene change.

## Decision

1. **Credential-shaped material is never acceptable**, in any file, at any
   time: private keys, AWS keys, JWTs, Slack/GitHub tokens, and personal
   free-mail addresses. These are never baselined and always fail.
2. **Infrastructure identifiers are a ratchet, not a ban.** The ~899
   identifiers the live manifests already depend on are recorded in
   `.disclosure-baseline.json` and accepted for now. The gate fails on the first
   *new* one. Removing a baseline entry is a reviewable diff; the gate cannot be
   silenced by editing a manifest.
3. **Prose and comments get no such exemption.** Documentation is where the map
   is most useful to an attacker and least useful to ArgoCD, so it is redacted
   rather than baselined.
4. **Nothing executable is tracked.** The 57 MB vendored `kubectl` is removed
   and ignored; a repo is not a binary distribution channel.
5. **History is not rewritten.** HEAD holds no live credential, the exposed
   values are already rotated, and rewriting is disruptive to every clone and
   open PR for little security gain. This matches the repo's existing norm of
   not rewriting history without a specific reason.

## Consequences

- `docs/decisions/ADR-048-public-repo-disclosure-policy.md` and this file are the
  permanent record; the gate is `scripts/check-disclosure.py`, wired into
  `pre-commit` (staged index) and CI (full PR diff, so a local-hook bypass still
  fails).
- The baseline is expected to shrink. A PR that redacts identifiers removes
  entries; a PR that adds them grows the file and is visible in review as such.
- Hiding the deployable hostnames remains open and is the natural follow-up: a
  kustomize base plus a private overlay, tracked separately, because it changes
  how every manifest is rendered.

### Known limits, stated plainly

- **The baselined identifiers are still public.** The gate prevents growth, not
  presence. Anyone reading this repo today already has the internal map.
- **Public hostnames cannot be un-published by redacting them.** With a public
  certificate, an allowlisted host appears in Certificate Transparency logs
  (crt.sh) within minutes of issuance, regardless of what this repository says.
  Removing them from the repo closes the cheapest harvesting path — automated
  GitHub scraping — and does nothing about the others.
- **DDoS exposure is not a repository problem.** It is solved at the edge
  (Cloudflare, rate limiting, no origin exposure). This ADR reduces a targeting
  signal; it is not a DDoS mitigation.
- The GitHub handle and the domain brand are trivially correlatable by design,
  since the portfolio is meant to be attributable.
