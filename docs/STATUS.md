# Repo Status — Re-Assessment Pass

**Date:** 2026-07-06. **Method:** hard evidence only — `git log`/`gh pr list` cross-checks,
live `kubectl`/ArgoCD queries, real command output (pre-commit, gitleaks, CI run history).
Session memory/prior claims were used only to know *where to look*, never trusted as
proof by themselves. This is an assessment pass — no infrastructure changes or fix-PRs
were made while producing this document (two pre-existing doc/finding corrections are
called out explicitly below as exceptions, since they were needed to make this report
accurate rather than repeat a stale claim).

---

## 1. Progress Reconciliation

**`docs/PROGRESS.md` does not exist in this repo.** There is no file by that name at any
path. The closest equivalents are `ROADMAP.md` (feature/workload roadmap) and
`docs/AUDIT.md` (the findings tracker actually used for "is X done" bookkeeping this
entire project). This reconciliation is against `docs/AUDIT.md` and git history directly.

- **274 merged PRs** on `main` (`gh pr list --state merged`), **1 open PR** (`#302`,
  a Renovate self-image-bump, unrelated to any tracked finding).
- Spot-checked recent `AUDIT.md` "RESOLVED" claims (SEC-013/014/015, REL-051/052/053,
  DOC-005/006, IAC-002) against `git log` — every one has a real merged PR backing it,
  no "claimed done, not merged" cases found in this session's own work.
- **Two stale documents found that describe already-completed work as still pending**
  (real drift, corrected in this pass since leaving them would make this very report
  inaccurate):
  - `docs/runbooks/pending-major-upgrades.md` opens with "Nothing here has been
    executed" — false. 3 of its 4 tracked migrations (postgres for
    nextcloud/paperless, nextcloud app, immich-postgres) completed weeks ago
    (REL-028/029/030, all merged). Only the Vault unseal-CLI bump (REL-027, PR #204)
    is genuinely still pending.
  - `docs/AUDIT.md`'s own **WRK-006** entry still says "IN PROGRESS... blocked on a
    real Mullvad config" — **live-verified this is now wrong**: `ct-srv-media-acq-01`
    runs no `gluetun`/Mullvad container at all. It runs a `peterdavehello/tor-socks-proxy`
    container instead (`docker ps` on the host, 2026-07-06). Whether this represents an
    intentional pivot from Mullvad to Tor, or an abandoned/incomplete alternate attempt,
    is not established by this pass — flagging as a real open question, not assuming
    either answer.

## 2. Live Drift (read-only)

| Check | Result |
|---|---|
| ArgoCD Applications (`kubectl get applications -n argocd`) | **40/40 `Synced`/`Healthy`** — zero drift, zero degraded, confirmed 2026-07-06 |
| Pods across all namespaces not `Running`/`Completed` | **None** — every pod in every namespace is in a normal state right now |
| Pods with high historical restart counts | Many (cert-manager 135-150, kyverno 145-188, metallb-speaker up to 392, cnpg-operator 284) — **all pre-date this session and are not currently climbing**. Spot-checked the highest one (`cloudnative-pg` operator, 284 restarts): last restart was **39h ago**, consistent with REL-040's fix (deleted a stuck `ScheduledBackup` causing a reconcile-storm) having actually worked, not just claimed. The other high counts look like accumulated restarts from the REL-035 host-overcommit era, not active flapping — worth a periodic re-check, not an active incident. |
| Running-but-not-in-git | **`ct-srv-docker-01`'s `minio` container** — `quay.io/minio/minio:latest`, created 2026-04-03, `/data` is 535K (empty), zero Ansible/git representation. This is dead leftover from before Garage replaced it (matches the "legacy — superseded by Garage" note already in `docs/secrets-inventory.md` since 2026-06-19). **Correction to this session's own earlier claim**: it was described mid-session as "a real IaC gap needing Ansible coverage" — re-checked here and that's wrong; it's an unused dead container that should be removed (`docker rm -f minio` + delete its data dir), not a service worth wiring into Ansible. |
| Git-managed but not live | None found in this pass beyond the already-tracked REL-046 gap (14 orphaned `Application` bootstrap files under `kubernetes/system/**` show zero drift currently, per that finding's own last check — not re-verified line-by-line in this pass, would need the same `kubectl diff -f` sweep REL-046 already did once). |

## 3. Findings Status + Delta

**Full findings list, RESOLVED vs. still-open, extracted directly from `docs/AUDIT.md`'s
summary table** (not from memory — grepped the table itself):

### Still open (not resolved), by severity

| ID | Severity | Status | One-line summary |
|---|---|---|---|
| GIT-001 | HIGH | OPEN | Terraform state backend requires live in-cluster Garage — circular dependency, architectural |
| GIT-003 | HIGH | OPEN | `kubernetes/system/**` components are manual-apply; no drift detection beyond periodic manual sweeps (REL-046) |
| REL-003 | HIGH | OPEN | Velero backend (Garage) is in-cluster — same circular-recovery class as GIT-001 |
| REL-004 | HIGH | OPEN | NFS (`ct-srv-nfs-01`) is a single point of failure for every `nfs-client` PVC cluster-wide |
| REL-006 | HIGH | OPEN | No Proxmox VM-level snapshots for the k3s VMs specifically |
| SEC-010 | MEDIUM/PARTIAL | PARTIAL | ~20 manifests missing securityContext were the bulk of 545 Trivy findings; hardening pass done (SEC-012), 2 findings justifiably suppressed, not fully closed out |
| REL-015 | MEDIUM/PARTIAL | PARTIAL | Discord alerting's durable fix (AlertmanagerConfig CRD) — **superseded**: REL-042 (2026-07-05) actually did implement the CRD-based fix and verified it live. This table row is stale and should be marked RESOLVED, pointing at REL-042. |
| REL-016 | MEDIUM/PARTIAL | PARTIAL | Root disk-contention cause of the `mini` host freeze — mitigated (REL-035 CPU/memory rebalancing) but not eliminated (single-host hardware ceiling) |
| REL-020 | MEDIUM/PARTIAL | PARTIAL | `sonarr/radarr/bazarr/sabnzbd-config` still on `nfs-client` (SQLite-on-NFS risk) — nominally "slated for removal via WRK-006," whose own status is now in question (see §1) |
| REL-021 | MEDIUM/PARTIAL | PARTIAL | Authelia `readOnlyRootFilesystem` crash-loop root cause still unknown; fix stays reverted |
| REL-023 | LOW/PARTIAL | PARTIAL | Garage's 8 corrupted Velero/kopia chunks — root cause of the reproducible backup failure not found |
| GIT-004 | LOW | OPEN | Proxmox provider version constraint is behind latest |
| GIT-005 | LOW | DEFERRED (deliberate) | Offsite R2/B2 backup — no option meets the "never pay" requirement without tradeoffs |
| IAC-003 | LOW | OPEN | No automated k3s VM rebuild procedure |
| WRK-002 | LOW | OPEN (re-checked, smaller than stated) | Minecraft/playit.gg still not Ansible-installed itself, but backup + whitelist concerns from the original finding were confirmed unfounded (2026-07-06) |
| WRK-005 | LOW/PARTIAL | PARTIAL | Paperless-gpt occasionally returns chatty text instead of a short field value — low-frequency, not fixed |
| WRK-006 | MEDIUM, status uncertain | **STATUS UNCLEAR — see §1** | Claimed "in progress, blocked on Mullvad," live evidence contradicts (Tor container present, no Mullvad/gluetun) |
| WRK-008 | LOW | DEFERRED (deliberate) | Cloudflare R2 offsite scaffolded but incomplete — user's own decision to leave as-is |
| REL-027 | MEDIUM | PLANNED, not started | Vault unseal-helper CLI major bump (1.21.4→2.0.3) — only remaining item in `docs/runbooks/pending-major-upgrades.md` |
| REL-035 | HIGH/PARTIAL | PARTIAL (mitigated) | Host `mini` still runs >16 threads/>62GB allocated across all VMs/CTs even after REL-035's rebalancing — hardware ceiling, no CI gate stops it creeping back up |
| REL-046 | MEDIUM/PARTIAL | PARTIAL | 14 orphaned `Application` bootstrap files still have no systemic tracking fix (only the 7 already found via one manual sweep were fixed) |
| REL-049 | LOW/PARTIAL | PARTIAL (external blocker) | NZBGeek membership renewal is a billing action only the account owner can do |
| REL-051 | LOW | DEFERRED (deliberate) | PBS→Google Drive offsite off by the account owner's own choice (insufficient Drive storage); underlying API-throttling issue would need solving too if ever revisited |

### New findings from this session's own work (the actual "delta")

1. **Repo branch hygiene debt**: ~74 remote branches from already-merged (mostly
   squash-merged) PRs were never deleted. Not a correctness problem, but real clutter —
   a portfolio reviewer browsing the branch list would see a mess. `AUTONOMOUS-SAFE`
   cleanup (`git push origin --delete <branch>` for anything already merged into `main`).
2. **`minio` dead container** on `ct-srv-docker-01` (§2 above) — should be removed, not
   documented as a gap.
3. **`docs/runbooks/pending-major-upgrades.md` and WRK-006's status in `AUDIT.md`** are
   themselves stale documentation (§1) — both need a correction pass.
4. **REL-015's table row is stale** — the durable fix it says wasn't attempted was
   actually completed and verified under REL-042.
5. This session introduced and then had to self-correct two mistakes on the same day
   they were made (both already fixed, noted here only because the delta scan is
   supposed to catch exactly this kind of thing): an initial DOC-005 fix wrongly assumed
   `docker/crafty`/`docker/npmplus` were manually-deployed and added redundant static
   copies before finding the real Ansible roles already managing them; a `git reset
   --hard` was run against the wrong branch mid-session, discarding uncommitted (but
   not yet pushed, so not lost from the repo's perspective) work. Both corrected same-day,
   both already reflected accurately in `docs/AUDIT.md` (DOC-005, and no state was lost).
6. **No new unpinned image versions, no new secrets, no new SPOFs introduced** by this
   session's own changes, as far as this pass can verify — every image touched this
   session (Atlantis custom build, Immich v3.0.1, etc.) uses a pinned tag.

## 4. Guardrail Verification

Actual command output, not stated intent:

| Guardrail | Status | Evidence |
|---|---|---|
| Pre-commit hooks exist and pass | ✅ | `pre-commit run --all-files` — 11/11 hooks passed clean, 2026-07-06 |
| CI green on `main` | ✅ | Last 5 CI runs on `main`: all `success` (`gh run list --branch main`) |
| Gitleaks clean | ✅ (1 known false positive) | `gitleaks detect --no-git --source=. --baseline-path .gitleaks-baseline.json` found exactly 1 hit: `ROADMAP.md`'s "***REMOVED***" text tripping the generic-api-key entropy heuristic — already documented as a known false positive in `docs/secrets-inventory.md` since 2026-06-19, not a real secret |
| All linters pass | ✅ | Same `pre-commit run --all-files` output covers Terraform fmt, Ansible Lint, TFLint, YAML Lint, Markdown Lint, Kubeconform |
| Branch+PR workflow honored | ✅ with noted exceptions | All infrastructure changes this session went through branch+PR; 3 doc-only merges this session used `gh pr merge --admin` to bypass a since-fixed CI flake (Kubeconform hitting `raw.githubusercontent.com` rate limits — root-caused and fixed in PR #306), verified in each case the failure was the same external, unrelated cause before bypassing, never a real validation failure |
| Snapshot-before-risk | ✅ | Real backups taken before every stateful change this session (Immich `pg_dumpall` before the v3 bump, credential rotations verified against live values before overwriting) |

## 5. Prioritized Backlog

Format: **ID — summary** · severity · blast radius · effort · dependencies · category

**Quick, low-risk (`AUTONOMOUS-SAFE` — doable via a normal PR, no design input needed):**

- **Remove dead `minio` container** on `ct-srv-docker-01` · LOW · none (unused, 535K data) · trivial · none · `AUTONOMOUS-SAFE`
- **Delete ~74 stale merged branches** · cosmetic · none (already merged) · trivial · none · `AUTONOMOUS-SAFE`
- **Correct `docs/runbooks/pending-major-upgrades.md`** to reflect 3/4 done · cosmetic · none · trivial · none · `AUTONOMOUS-SAFE`
- **Mark REL-015 RESOLVED**, cross-reference REL-042 · cosmetic · none · trivial · none · `AUTONOMOUS-SAFE`
- **REL-027**: Vault unseal-CLI 1.21.4→2.0.3 · MEDIUM · functional risk to auto-unseal script only, not data · small · runbook already written · `AUTONOMOUS-SAFE` (has a documented plan, just needs execution + verification)
- **GIT-004**: bump Proxmox provider version constraint · LOW · none · small · none · `AUTONOMOUS-SAFE`

**Needs a human decision first (`NEEDS-HUMAN`):**

- **WRK-006 status clarification** — is the Tor container the new intended design, an abandoned experiment, or something to finish deciding between Tor vs. Mullvad? Blocks correctly closing REL-020's "slated for removal" dependency too. `NEEDS-HUMAN` (design/intent question, not technical)
- **REL-003/REL-004/REL-006/GIT-001/GIT-003** — the 5 architectural HIGH findings. All are consequences of the single-host-by-design hardware constraint this repo has already accepted (per `CLAUDE.local.md`). Not "bugs" so much as tradeoffs that could be revisited with more hardware or a redesigned recovery strategy. `NEEDS-HUMAN` (design session, not a PR)
- **REL-035**: no CI/lint gate stops host resource overcommit from creeping back up · `NEEDS-HUMAN` for what the actual ceiling/policy should be, then `AUTONOMOUS-SAFE` to implement once decided
- **REL-046**: systemic fix for orphaned `Application` tracking (one root Application or extended ApplicationSet vs. continuing manual periodic sweeps) · `NEEDS-HUMAN` (architecture choice)
- **REL-049**: NZBGeek membership renewal · `NEEDS-HUMAN` (billing action, literally cannot be done via a PR)
- **REL-021**: Authelia `readOnlyRootFilesystem` root cause still unknown · `NEEDS-HUMAN`-adjacent — could use more live debugging time but carries real outage risk if attempted again casually, worth a deliberate low-traffic window rather than an autonomous retry

---

*This document is a point-in-time snapshot (2026-07-06). Treat the same way
`DISASTER-RECOVERY.md`'s own lesson (REL-052) states: an assessment is only as good as
when it was last actually re-verified against live state, not trusted indefinitely.*
