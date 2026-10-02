# ADR-049: Trivy severity scope, and what "code scanning is clean" actually means here

**Status:** Accepted and applied, 2026-10-02

## Context

`security-scan` in `.github/workflows/ci.yml` runs Trivy three times over
`kubernetes/` and `terraform/`: two `format: table` steps restricted to
`severity: CRITICAL,HIGH`, and one `format: sarif` step that uploads to the
GitHub Security tab.

The SARIF step set no severity filter, so it uploaded every severity Trivy
produces. Measured against `kubernetes/` with trivy 0.75.0 and the repo's own
`.trivyignore`, that produced **478 findings**:

| Level | Count | Meaning |
|---|---|---|
| error | 19 | HIGH/CRITICAL |
| warning | 167 | MEDIUM |
| note | 292 | LOW/UNKNOWN |

So the Security tab showed 478 alerts while the part CI actually enforces was
19. Two problems, one visible and one not.

The visible one: a 19-item signal buried under 459 advisory rows is a signal
nobody reads. The same findings appear on every PR and every push, forever, and
because `.trivyignore` never changed the count, the backlog was indistinguishable
from a regression.

The not-visible one, and the reason this ADR exists: **of the 19 enforced
findings, almost none were oversights.** They were conclusions the repo had
already reached and recorded — in manifest comments — but never conveyed to the
scanner.

## The evidence was already in the repo

Seven workloads carry an inline comment explaining why
`readOnlyRootFilesystem` is absent, and they are not conservative guesses:

- `authelia`: the flag was applied, survived ~2.5h and 35+ restarts, then
  crash-looped in production with a bare `Errors occurred performing startup
  checks`. Reverted 2026-06-25. The comment is explicit that the initial manual
  test was **a false positive, not a real fix**.
- `scanopy`: the daemon creates its log directory unconditionally, no env
  override exists. Crashes on startup otherwise.
- `scrutiny`: the entrypoint writes `/env.sh` at the filesystem root, rewrites
  `/etc/cron.d` via `sed`, and cron needs a writable `/var/run` pidfile.
- `firefly`: bundles nginx, which renders into its own rootfs.
- `homepage`, `open-webui`: entrypoint writes hit EROFS.

Five more are provable from the job's own script, which is committed in the same
file: `restore-test` and `r2-usage-guard` download `kubectl` and `velero` into
`/usr/local/bin`, and `dr-game-day`, `tailnet-route-drift-check` and
`weekly-report` run `apk add`, which writes `/var/cache/apk`, `/lib/apk/db` and
`/usr`. A read-only root forbids all of it.

That is 12 of 14 `KSV-0014` sites. The remaining four (`freshrss`, `crowdsec`,
`onlyoffice`, `myspeed`) had **no** justification on record, and are therefore
not in the same category — see below.

The other five enforced findings are equally deliberate: `subnet-router` and
`scanopy` are already `privileged: true`, where `NET_RAW` is redundant;
`kube-bench` exists to read the node's own kubelet config; `scrutiny-collector`
needs `hostPID` for S.M.A.R.T. data; the Trivy operator must read every Secret to
find image references in them.

## Decision

**1. Narrow the SARIF upload to `severity: CRITICAL,HIGH`,** matching the two
table steps. GitHub auto-closes an alert when a later upload no longer contains
it, so this converges the tab to zero without any dismissal API call.

**2. Move the 19 enforced findings into `.trivyignore`,** each with its evidence
inline. The rationale already existed; this is what makes the scanner read it.

**3. Do not silently paper over the four unjustified ones.** `.trivyignore`
separates its `KSV-0014` block into three evidence classes — confirmed live,
provable from the committed script, and **not yet proven incompatible** — so the
last group is visibly weaker and stays on the books.

## Why not just set `readOnlyRootFilesystem`

For the twelve documented workloads it would re-break failures that were already
paid for in production. `authelia` is the worst case: it is SSO for the entire
stack, so a crash-loop locks out every service behind it.

For the remaining four, the honest reason is `REL-021`'s lesson. Probe pods with
`readOnlyRootFilesystem` plus each workload's own mounts reported **every** data
path writable for `freshrss` and `crowdsec` — which is precisely the setup that
looked fine for `authelia` before it failed hours later under real traffic. Two
of 478 SARIF rows are not worth spending core-auth availability on to clear.

## Consequences

- The Security tab reaches zero, and every alert it can ever show is genuinely
  enforced rather than advisory.
- **459 findings are still present**, at MEDIUM and LOW. They are recorded below
  by rule so the backlog is countable, not a feeling. None of them gate a merge.

| Rule | Count | Note |
|---|---|---|
| KSV-0021 / KSV-0020 | 149 | Requires UID/GID > 10000; would break images that expect a specific UID. Not actionable as a blanket check. |
| KSV-0125 | 61 | "Trusted registry" — every image ref would need an explicit registry prefix. |
| KSV-0012 | 64 | Runs as root; needs per-image testing, same hazard as `KSV-0014`. |
| KSV-0106 / KSV-0003 / KSV-0004 | 99 | Drop `ALL` capabilities. Genuinely valuable, mechanical, and the best next candidate. |
| KSV-0030 / KSV-0104 | 24 | Seccomp profile unset. Cheap and safe; best next candidate. |
| KSV-0011/0015/0016/0018 | 32 | No CPU/memory requests or limits. Changes scheduling, so needs a capacity check first. |
| KSV-0048 / KSV-0117 / KSV-0023 / KSV-0037 | 24 | RBAC breadth, privileged ports, hostPath, kube-system resources. Structural. |
| KSV-0013 / KSV-0049 / KSV-0113 | 6 | `:latest` tags, configmap/secret management breadth. |

- `docs/AUDIT.md` was deleted in PR #355 as an internal operational tracker,
  but 13 references to it survive across manifests, docs and Ansible — including
  the `.trivyignore` header and the `authelia` evidence this ADR leans on. The
  REL-IDs it cited (019, 021, 022, 062, 068) exist nowhere in the repo now. Those
  pointers are dead and are **not** repaired here, because repointing them at
  `docs/HOMELAB-AUDIT.md` would substitute visible references to nonexistent IDs
  for visible references to a nonexistent file. The rationale survives inline in
  each manifest; only the citation is stale.

## Revisit this when

- The capability-drop and seccomp rules (123 findings combined) are taken on as
  their own PR — mechanical, and the largest honest reduction available.
- `.trivyignore` grows a class (c) entry that gets fixed rather than justified.
  Any manifest comment claiming an incompatibility should have been proven the
  way `authelia`'s was, in production.
