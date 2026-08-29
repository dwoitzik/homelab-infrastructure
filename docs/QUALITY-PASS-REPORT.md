# Repository Quality Pass — Final Report

Written at the end of the pass, not before it — this is what actually got
done, what's left, and an honest read of the repo as it stands, not a plan.
The two working documents this pass produced along the way
(`REPO-BENCHMARK.md`, `SCRUB-SURVEY.md`) are the evidence base; this is the
summary and the parts they don't cover (git-history/attribution guidance,
the cold read).

## What shipped, in six PRs

1. **#604** — `REPO-BENCHMARK.md` + `SCRUB-SURVEY.md`. Research and
   cataloging only.
2. **#605** — Fixed 4 duplicate ADR numbers (016-019, each used twice).
3. **#607** — Relocated `ansible/roles/pve_power/`'s incident narrative
   into new `ADR-034`; both role files trimmed to WHY-only comments.
4. **#608** — Removed the real home WAN IP from `docs/EXPOSURE.md`.
5. **#609** — ADR index, deduped `DISASTER-RECOVERY.md` vs
   `docs/RECOVERY.md`, `ADR-001`/`002` descriptive slugs, and a second
   ADR-number collision this pass caused (see below) — caught and fixed
   in the same pass.
6. This report.

Every PR is docs/comments-only. `terraform validate`, `terraform fmt`,
`ansible-lint` (production profile), `yamllint`, `markdownlint`, and
`kubeconform` all pass on every file touched. Nothing about how any
manifest, module, or policy behaves is different after this pass than
before.

## Coverage: honest, not complete

`SCRUB-SURVEY.md` found **~112 files** with narrative-style comments.
This pass fully relocated **one** of them (`pve_power`, the survey's own
"clearest case") plus fixed the two concrete scrub findings and the
structural issues. That is deliberate triage, not an oversight to hide:
`pve_power` was done as a real, complete example of the pattern — new ADR,
trimmed files, verified lint-clean, verified no behavior change — so the
same treatment is reproducible for the rest by whoever picks this up
next. The other ~111 files are cataloged with real line numbers and a
relocate/scrub/keep classification in `SCRUB-SURVEY.md`; the two other
high-density files with genuinely new destinations needed
(`kubernetes/apps/nextcloud/nextcloud.yml` — no existing ADR for its
hardening saga; `terraform/stacks/proxmox/vm.tf`'s `home.lan` DNS
root-cause — likely covered by `docs/RECOVERY.md`'s existing DNS-gotcha
section, worth confirming before writing a new ADR) are flagged with
enough detail to start from directly.

**Why stop here rather than push through all 112**: this pass also
produced the benchmark, the security scrub, three structural fixes, and
this report — all explicitly asked for in the same request. Grinding
through the long tail of 1-3-comment-match files at the expense of those
would have been the wrong trade, and claiming full completion on the
long tail without actually doing it would have been dishonest. The
survey document exists specifically so the remaining work doesn't need
re-discovering.

## Security scrub — final status

- **Real home WAN IP** in `docs/EXPOSURE.md` — **fixed** (#608).
- **Rotated MikroTik password in `.gitleaks-baseline.json`** (3 plaintext
  occurrences) — **operator confirmed dead** (compared byte-for-byte
  against the live Vault-stored credential, no match, different length)
  and explicitly said to leave it baselined as documented historical
  evidence. No change made, by direct instruction, not default judgment.
- **A live ntfy.sh topic identifier**
  (`dw-homelab-a12a7b540943`), hardcoded in 4 places across the repo
  (`ansible/roles/pve_power/defaults/main.yml` ×2,
  `kubernetes/system/velero/r2-usage-guard.yml`,
  `kubernetes/system/velero/restore-test.yml`) — **found this pass, not
  in the original survey, not fixed.** An ntfy.sh topic without
  additional access control is effectively a bearer credential for that
  notification channel — anyone who has the string can push to it, and
  on a public topic, potentially read from it too. Genuinely fixing this
  means moving it behind Vault/a Kubernetes Secret in all four spots,
  which is real infrastructure/secret-wiring work, not a comment edit —
  out of scope for a "no infrastructure changes" pass. Flagged here for
  a deliberate follow-up.
- **Git history**: no exhaustive sweep was run (2,600+ commits, `gitleaks`
  already covers the secret-pattern case in CI/pre-commit on an ongoing
  basis). Targeted checks found nothing beyond what's already
  known/rotated/confirmed-dead. If a genuinely exhaustive history sweep
  for IPs/hostnames/names specifically (which gitleaks doesn't target)
  is wanted, that's a separate, deliberately-scoped pass — not something
  to half-do inside this one.

## `Co-Authored-By: Claude` / AI attribution — the premise was wrong

This pass started from the request's own claim that "every commit
carries a `Co-Authored-By: Claude` trailer." **Checked exhaustively
before acting on it, not assumed**: zero such commits exist anywhere in
this repository's history (`git log --all`, both `--grep` and a full
raw-body scan, 2,663 commits). No `.gitmessage` file, no
`commit.template` git config, no CI/hook step anywhere in the repo adds
one. An early draft of `REPO-BENCHMARK.md` asserted a specific count (57
of 1,223 commits) before this was verified — that number was wrong and
has been removed, not corrected to a "right" number, because there
isn't one.

**No `git filter-repo` pass is warranted for this specific reason.**
Running one would mean a force push, rewritten commit SHAs across the
entire repository, and every existing PR/issue link and any external
reference to a specific commit breaking — real, permanent costs for a
problem that doesn't exist here. If the actual concern is *future*
commits from an AI assistant, that's already governed by this
environment's own standing instruction and appears to have held for the
whole visible history.

**If a history rewrite is wanted anyway** — for the WAN IP or the
MikroTik password specifically, independent of the Co-Authored-By
question, and independent of the operator's "leave it baselined" call
above — the mechanics would be:

```bash
# Install (not in this repo's toolchain by default)
pip install git-filter-repo

# Example: scrub a specific literal string from all of history
git filter-repo --replace-text <(echo 'literal-secret-value==>REDACTED')

# Or strip a specific file from all history entirely
git filter-repo --path path/to/file --invert-paths
```

Real consequences, all of them: every commit after the earliest touched
one gets a new SHA; a force push is required (`git push --force
--all --tags`, or per-branch); every existing PR based on pre-rewrite
history either closes with conflicts or needs re-basing; any external
link, citation, or clone referencing an old SHA breaks permanently; and
GitHub's own PR/commit-comment history tied to the old SHAs becomes
orphaned. This is the operator's call to make and run, not something to
execute as part of a documentation pass.

## Structural fixes made

- ADR numbering: 4 pre-existing duplicate pairs fixed (#605), plus **one
  new collision this pass itself caused and then caught** — an unrelated
  commit (Scanopy) claimed `ADR-031` while #605 was mid-review, also
  claiming `ADR-031` for a different topic. Found while building the ADR
  index (#609), fixed in the same PR (Scanopy → `ADR-035`). Noted
  explicitly because it's a real instance of exactly the failure class
  this pass exists to prevent, caught by the process rather than avoided
  by it.
- `docs/decisions/README.md`: an actual ADR index. Didn't exist before.
- `DISASTER-RECOVERY.md` (root) vs `docs/RECOVERY.md`: two independently
  diverged documents describing the same thing, one of them stale
  (pre-dated the current architecture by name). Consolidated to one, at
  the location `CLAUDE.local.md` itself already said should exist.
- `ADR-001`/`ADR-002` given descriptive slugs, matching every ADR from
  003 onward.

**Not done, real gaps still open:**

- No architecture diagram in the README — it has a stack table and a
  directory tree, but every top-tier repo benchmarked
  (`REPO-BENCHMARK.md`) has an actual diagram (network topology, GitOps
  flow, or both). This is the single highest-value thing left undone.
- `CHANGELOG.md` stops at `[0.8.0] — 2026-06-28`; the repo has had
  hundreds of commits since. Either bring it current or remove it —
  a visibly stale changelog reads worse than no changelog.
- The long tail of `SCRUB-SURVEY.md`'s ~111 remaining files.
- The ntfy-topic secret-wiring fix above.

## Reading it cold, as the hiring engineer would

The instruction was to say what's still wrong, not fix it in the same
pass. In order of what a reader would hit first:

1. **The README's first ninety seconds are genuinely good.** Opens with
   what/why, a real "what this demonstrates" section, an honest stack
   table, live CI badge. This is not a repo that fails the opening test.
2. **The first click into `docs/` breaks the spell.** It's flat — 24
   files, no separation between "reference doc" (`HARDWARE.md`,
   `OPERATIONS.md`) and "dated incident writeup"
   (`garage-velero-design-2026-07-17.md`, `cleanup-2026-07-17.md`,
   `vault-terraform-plan-2026-07-17.md`). A reader can't tell which docs
   are current-state reference and which are historical snapshots
   without opening each one. None of the benchmarked repos mix these as
   peers.
3. **`docs/POST-MISSION.md` is the biggest open question, and this pass
   deliberately didn't touch it.** It's a genuinely well-written
   retrospective — but it's explicitly framed as "thirteen days" of
   agent-session narrative (`phase8/LEDGER.md`, "97 entries", "a future
   version of this agent"), which is exactly the tone the rest of this
   pass spent its effort removing from code comments. Whether this
   document belongs in a portfolio repo at all, or needs a substantial
   rewrite into third-person "here's what this system is and why" rather
   than first-person mission narrative, is a real editorial call — not
   one this pass made unilaterally, but flagging it plainly: as written,
   it's the single largest concentration of exactly the smell items 2-4
   of this pass were about, and it's currently untouched.
4. **The long tail of narrative comments is still there.** A reader who
   opens `kubernetes/apps/nextcloud/nextcloud.yml` or
   `kubernetes/system/apps-ingressroute.yml` today still finds dated
   investigation diaries. `SCRUB-SURVEY.md` catalogs exactly where; the
   pattern demonstrated on `pve_power` is the template for closing the
   rest.
5. **No architecture diagram.** Said above, worth repeating here: this
   is the one thing every single benchmarked repo had that this one
   doesn't, and it's the thing a skimming reader would most want in the
   first ninety seconds, right after the README's opening paragraph.
6. **The ntfy topic and the still-open items in `phase8/QUESTIONS.md`-style
   docs.** A careful reader who greps for anything that looks like a
   credential will find the ntfy topic quickly. It's minor on its own,
   but a repo that presents itself as security-conscious
   (`ADR-028`'s "mechanical secret exposure prevention", the gitleaks
   baseline discipline) having one real live loose end undercuts that
   framing slightly.
7. **What actually reads well, unprompted**: the ADR discipline itself
   (once the numbering is fixed), the honesty of `POST-MISSION.md`'s
   content even if its framing needs work, the fact that trade-offs are
   stated rather than hidden throughout (`ADR-026`'s topology-overhead
   math, `ADR-029`'s explicit "still open" sections). This repo's
   instinct to disclose rather than polish over gaps is real and is
   the thing worth preserving through any further editing pass — the
   fix for the *tone* problem is moving the narrative out of the code,
   not sanding the honesty out of the docs.
