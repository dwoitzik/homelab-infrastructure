# Scrub Survey — working catalog, not yet acted on

Produced for the repository quality pass. This is a catalog to work from, not
polished prose — organized for scanning and triage, not reading start to
finish. Nothing in this document has been fixed yet; it's the input to that
work.

Methodology: grepped every `.tf`/`.yml`/`.yaml` file for comment lines
containing a date (`YYYY-MM-DD`), a PR reference (`#123`), or the phrases
"confirmed live", "this session", "this agent", "the operator" — 112 files
matched at least once, 2 files (`nextcloud.yml`, `vm.tf`) had 14+ matches
each. Below, the ~20 highest-density files get real line-level detail; the
rest are listed in a compact table. Classification key: **RELOCATE** (real
rationale, wrong location — move to an ADR/runbook), **SCRUB** (shouldn't be
public at all), **KEEP** (legitimate as-is, flagged only because it matched
the search pattern).

## Comment relocation candidates — high-density files (detailed)

### `kubernetes/apps/nextcloud/nextcloud.yml` (16 matches)

- L13, L19, L100, L295, L370-376: a running investigation diary for a
  Nextcloud entrypoint/permissions saga (rsync behavior, liveness grace
  period, postgres user failure, worker-process uid/gid, first-boot install
  sequence) told as "found live... confirmed live... 2026-08-13... 2026-08-14"
  narration. **RELOCATE** — real rationale (why the liveness grace period is
  long, why `drop: ["ALL"]` needed adjusting) belongs on the resource as a
  short WHY comment; the investigation narrative belongs in an ADR (none
  exists yet for Nextcloud's hardening — write one) or `phase8/LEDGER.md`-style
  history, not in-repo since that ledger is explicitly out-of-repo per commit
  `8b6638e` ("stop tracking internal operational trackers in this public
  repo").
- L54, L78, L179, L267: PVC/redis persistence toggle history ("removed
  2026-07-05", "re-enabled 2026-08-10"). **RELOCATE** — this is changelog
  content; if the *current* state needs justifying (why no PVC on redis),
  one line suffices, the toggle history doesn't.
- L292 (REL-029), L198 (REL-031-redis), L471 (REL-061): internal tracking-ID
  references with no explanation of what REL-029/031/061 *are* to an outside
  reader. **RELOCATE** — either the ADR/runbook these IDs point to should be
  linked, or the ID stripped and just the rationale kept.

### `terraform/stacks/proxmox/vm.tf` (14 matches)

- L11, L101-109, L216, L315: dated narration for the boot-stagger fix and the
  `home.lan` DNS root-cause (this one's rationale is genuinely good — Proxmox
  cloud-init's fallback to the node's own search domain — but told as a dated
  investigation rather than a WHY). **RELOCATE**, and note: a proper ADR for
  the DNS fix already may not exist — check `docs/decisions/` and write one if
  not, since this is exactly the kind of non-obvious cross-system interaction
  (Proxmox cloud-init -> VM netplan) worth a permanent record.
- L49, L241 reference ADR-014/ADR-015 by number with enough context to stand
  alone — these are **KEEP**, just flagged by the date pattern; they're doing
  it right (cite the ADR, state the current rationale briefly).
- L70-77, L190-196, L289-295: `discard=on`/`mbps_wr` tuning, each with a
  "2026-08-16 applied live" / "2026-08-19 codified... LEDGER Entry 40"
  pair. **RELOCATE** — the *why* (prevent thin-pool exhaustion / IO
  contention, presumably) should stay; "applied live on this date, codified
  three days later" is changelog.

### `terraform/stacks/proxmox/lxc.tf` (12 matches)

Same pattern as `vm.tf` — dated "confirmed live" narration for boot storage,
`start_on_boot` provider quirk, NFS mount timing, memory sizing. **RELOCATE**
throughout. One flag: L3 references "2026-08-13 disaster recovery" as context
for why boot/VM-image storage is laid out a certain way — this is a real
architectural decision (post-incident storage redesign) that deserves an ADR
if `docs/RECOVERY-REPORT-2026-08-13.md` doesn't already cover the *storage
layout decision* specifically (it may only cover the recovery narrative,
which is a different thing) — check before relocating, don't just delete the
pointer.

### `kubernetes/apps/homepage/homepage.yml` (12 matches)

L14-288: a multi-entry "2026-08-15: root-caused the API error" investigation
diary spread across several widget configs, plus explicit session-scoping
notes ("no Vault write access in this session", "this agent has no Vault
write access this session"). **RELOCATE + SCRUB overlap** — the
session/agent-capability notes are pure narrative (SCRUB — an outside reader
gains nothing from knowing an AI agent's tool access on a specific date), the
actual root-cause explanations (widget config bugs, service names) are real
and should move to a Homepage-specific README or an ADR if the bug class is
generalizable. L164, L240 ("removed per operator review") — rephrase to state
the current decision, not attribute it to a review event.

### `kubernetes/system/monitoring/application.yml` (11 matches)

L328-381: the blackbox-exporter scope-fix narrative (already partially
cleaned up per this repo's own history — see the "Correction, 2026-08-23"
follow-up inline). **RELOCATE** — this whole block reads as exactly the kind
of thing that belongs in an ADR (there may already be relevant content in
`docs/decisions/ADR-019-public-exposure-allowlist.md` — cross-check before
duplicating). L24, L51-57: alert-tuning history, same pattern.

### `kubernetes/system/apps-ingressroute.yml` (11 matches)

L67, L187-189, L235-240, L457-460: SEC-hardening dates, a wrong-IP
correction, an ADR-019/PR-437/PR-440 history recap embedded directly in
IngressRoute comments. **RELOCATE** — ADR-019 already exists and is the
right home for the PR-437/440 history (check it doesn't already have this,
since it may — this could be a duplicate telling of the same story in two
places, which is its own smell).

### `ansible/roles/pve_power/defaults/main.yml` (11) and `tasks/main.yml` (10)

Both files are almost entirely `phase8/LEDGER.md Entry NN`-referencing
narration (L42, L48, L60-66, L76, L81 in defaults; L43-45, L96-215 in tasks).
**RELOCATE**, and this is the clearest case in the whole repo for the "write
an ADR if none fits" instruction — CPU governor/P-state tuning, vzdump
throttling, thin-pool exhaustion mitigation, and the PBS backup health check
are four distinct real decisions currently only explained via `LEDGER.md`
entry numbers that don't resolve to anything for a reader of this public
repo (`phase8/` isn't in the tree — confirmed via `8b6638e`, it's deliberately
excluded). This is the file where "relocate" most urgently needs a real
destination, not just "somewhere else" — recommend a new
`docs/decisions/ADR-XXX-pve-power-management.md` consolidating the real
rationale from both files.

## Comment relocation candidates — remaining files (compact)

All still have 1-3 narrative-pattern matches; sampled but not individually
transcribed. General character: same shape as above (dated "confirmed live"
notes, PR-number cross-references, session-scoped capability notes) at lower
density. Recommend the same relocate-or-keep judgment call per line when
doing the actual edit pass; do not assume every match needs to move —
several are legitimate ADR citations (**KEEP**).

| File | Matches | Note |
|---|---|---|
| `kubernetes/apps/immich/immich.yml` | 9 | Backup-worthiness rationale mixed with dated fixes |
| `kubernetes/apps/trivy-operator/trivy-operator.yml` | 8 | Scan-scope decisions, dated |
| `kubernetes/apps/network-policies-egress.yml` | 8 | **Already largely fine** — most matches are legitimate "why this rule exists" (e.g. the cloudflared/homepage egress fixes), a few reference specific incident dates that could trim to just the mechanism |
| `kubernetes/apps/crowdsec/crowdsec.yml` | 8 | Sidecar config rationale, some dated |
| `ansible/roles/rpi_optimize/tasks/main.yml` | 7 | RPi tuning history |
| `terraform/stacks/network/firewall_extra.tf` | 6 | Import-audit dates (2026-06-21) — mostly **KEEP**, these explain *why* a rule was adopted via import, which is genuinely non-obvious |
| `terraform/stacks/cloudflare/main.tf` | 6 | Tunnel history, some now superseded by #599-602 — check for stale comments describing a config that no longer matches the code |
| `kubernetes/apps/renovate/renovate.yml` | 6 | Config tuning history |
| `kubernetes/apps/garage/garage.yml` | 6 | Bucket/storage decisions, dated |
| `ansible/site.yml` | 6 | Playbook-inclusion rationale, some dated |
| `terraform/stacks/proxmox/host-config.tf` | 5 | Host tuning, dated |
| `terraform/stacks/network/imports.tf` | 5 | Import-audit context — mostly **KEEP**, same reasoning as firewall_extra.tf |
| `terraform/stacks/cloudflare/imports.tf` | 5 | Same pattern |
| `kubernetes/system/monitoring/alertmanager-config.yml` | 5 | Routing-tuning history |
| `kubernetes/system/argocd/system-app-bootstrap.yml` | 5 | Bootstrap-order rationale, some dated |
| `ansible/roles/k3s_node_tuning/tasks/main.yml` | 5 | DNS/tuning history (may overlap with vm.tf's home.lan story — check for duplication) |

Files with 1-2 matches (not individually detailed, same triage rule
applies): `kubernetes/system/kyverno/policies.yml`,
`kubernetes/system/argocd/manifests-application.yml`,
`kubernetes/apps/paperless/paperless-gpt.yml`,
`kubernetes/apps/authelia/authelia.yml`,
`kubernetes/system/velero/schedule.yml`,
`kubernetes/system/traefik/application.yml`,
`kubernetes/system/postgres/postgres-monitoring.yml`,
`kubernetes/system/monitoring/manifests-application.yml`,
`kubernetes/system/cert-manager-config/external-secret.yml`,
`kubernetes/apps/scrutiny/scrutiny.yml`, `kubernetes/apps/paperless/stack.yml`,
`kubernetes/apps/paperless/paperless.yml`, `kubernetes/apps/mealie/mealie.yml`,
`ansible/k3s-cluster/inventory.yml`, `terraform/stacks/network/nat_portforward.tf`,
`terraform/stacks/network/main.tf`, and roughly 70 more files not listed
individually here — re-run the same grep pattern during the actual edit pass
to get the live list, this survey is a snapshot as of 2026-08-28.

Grep to reproduce the full file list:

```bash
grep -rlE '^\s*#.*(confirmed live|this session|this agent|the operator|20[0-9]{2}-[0-9]{2}-[0-9]{2}|#[0-9]{2,4}\b)' \
  --include='*.tf' --include='*.yml' --include='*.yaml' .
```

## Scrub candidates — should never have been public

### Real home WAN IP address, committed in plaintext

`docs/EXPOSURE.md:58` — `178.202.46.102`, stated explicitly as "the actual
home WAN IP" alongside an 18-port external scan methodology. **The
methodology is good portfolio content** (demonstrates real security
diligence); **the literal IP should not be there**. Publishing "here is my
real home IP and here is the exhaustive list of ports I confirmed are
closed" is handing a would-be attacker a validated target plus a
reconnaissance shortcut, even though every port scanned clean. Fix: replace
the literal address with "the home WAN IP" (already the DDNS-hostname phrase
used two words later in the same sentence — the specific-IP mention is
redundant with that phrasing anyway). Same fix applies if the IP appears
elsewhere — only found this one instance via targeted grep, worth a
`grep -rn '178\.202\.4[67]\.'` sweep during the actual edit pass since a
second, nearby address (`178.202.47.0`, the current DMZ path target per
`terraform/stacks/cloudflare/main.tf`) is now also live and public via DNS
itself (not this repo's doing, and the operator has separately confirmed
that one is intentional/correct — see `phase8/LEDGER.md` Entry 106 — but
it's the same class of value, worth being consistent about whether WAN-facing
IPs are treated as sensitive or not across the whole repo).

### `.gitleaks-baseline.json` contains a real (rotated) leaked password in plaintext, 3 times

Lines 777, 873, 2229 — the `Match` field on those entries holds the actual
literal value of the MikroTik `terraform-user` password that leaked and was
rotated per commit `1132ea2c` / `768b43a8` (SEC-015, "rotate leaked
MikroTik terraform-user password"). The commit message says it was rotated
live on the router — so this specific string is very likely dead — but a
gitleaks baseline file that exists specifically to document *and thereby
re-publish forever* a real credential value is a genuine tension worth the
operator's explicit sign-off, not a silent carry-forward. Two options,
neither obviously right without knowing gitleaks' exact baseline-matching
behavior (this session separately confirmed empirically, while adding an
unrelated baseline entry, that gitleaks compares more than just the
`Fingerprint` field — likely `Match` too, so redacting `Match` may break the
suppression and cause the finding to resurface in CI):

1. Verify whether `Fingerprint` alone is sufficient for baseline matching
   (check the gitleaks source/docs for the exact struct-equality behavior,
   rather than assuming); if so, replace `Match` with a redacted placeholder
   in these 3 entries.
2. If `Match` must stay exact for the baseline to work, that's a real
   argument for `.gitleaks-baseline.json` needing different handling
   entirely (e.g., confirm the password is actually rotated live one more
   time, then accept the historical value as inert-and-documented, same
   posture as `docs/AUDIT.md`'s own mentions of the same literal value,
   which already made the same call previously — this baseline file is just
   repeating a decision already made elsewhere in the repo, not a new
   leak by itself, but it's still a second copy of a real secret in a public
   file and deserves the same explicit sign-off the original got).

Not a new incident — flagging because it's a real credential value sitting
in the working tree right now, and "already decided once elsewhere" isn't
the same as "the operator has seen this specific occurrence."

### Third-party names in `ansible/k3s-cluster/galaxy.yml`

L20, L25 — `Julien DOCHE <julien.doche@gmail.com>`, `Vincent RABAH
<vincent.rabah@gmail.com>`. **Not flagged as a scrub candidate** — this is
standard Ansible Galaxy role metadata (`galaxy.yml`'s own `authors` field),
almost certainly listing the upstream/vendored role's real maintainers as
Galaxy itself requires, not private individuals connected to this operator.
Noted for completeness per the survey instructions, no action recommended.

### Nothing else concerning found in the working tree

Checked `.md` docs, `scripts/`, `README.md`, `CLAUDE.md`/`CLAUDE.local.md`
for personal info (home address, personal phone) beyond the WAN IP above —
found none. The password-shaped strings already in `.gitleaks-baseline.json`
were spot-checked against their current file content; all except the
MikroTik password above are genuine placeholders (`REPLACE_WITH_*`,
`***REMOVED-*-PASSWORD***`, obvious dummy values like
`"authelia-password-123"`, or non-secret argon2/bcrypt hash examples already
handled per this repo's own prior security passes).

## `Co-Authored-By: Claude` — factual correction to the stated premise

**There are zero commits with a `Co-Authored-By: Claude` trailer anywhere in
this repository's history.** Checked exhaustively, not sampled:

```bash
git log --all --grep="Co-Authored-By: Claude" --oneline   # 0 results
git log --all --format="%H%n%B%n---" | grep -c "Co-Authored-By: Claude"  # 0
```

There *is* a `Co-authored-by: dwoitzik <woitzikdavid18@gmail.com>` trailer on
110 commits — these are all Renovate's own dependency-update commits
crediting the repo owner per Renovate's standard convention, unrelated to AI
attribution. No `.gitmessage` file, no `commit.template` git config, no
CI/hook step that appends any AI-generated-by marker exists anywhere in the
repo (checked `.github/`, root dotfiles, pre-commit config). The only file
containing the literal string "Co-Authored" is
`docs/decisions/ADR-000-template.md`.

**Recommendation:** whoever acts on this quality pass should re-verify the
premise before doing any git-history rewrite for this specific reason — a
`filter-repo` pass to strip a trailer that was never actually committed would
be pure unforced risk (force-push, rewritten SHAs, broken PR links) for zero
actual benefit. If the concern is about *future* commits from an AI
assistant, that's already governed by this repo's standing instruction
(`/root/.claude/CLAUDE.md`: "Never add `Co-Authored-By: Claude`...") and
appears to have held for the entire visible history — nothing to fix in
templates/hooks/CI because nothing there is currently generating this.

## Git history — light check, not exhaustive

2,663 total commits across all refs — too large to search exhaustively in
this pass; used targeted `-S<string>` pickaxe searches instead of a full
history grep.

- **`mynetname`** (the DMZ dyndns hostname currently in live DNS, per
  `phase8/LEDGER.md` Entry 106): first appears in commit `4e9ebb7` ("route
  every woitzik.dev hostname through the Cloudflare tunnel" — an older,
  different architecture), then `739fac1`, then `98d3d47` (#601, the current
  DMZ path). This value is *also* live in public DNS right now by the
  operator's own recent confirmation, so its presence in history isn't a
  separate exposure — noting only for completeness.
- **The leaked MikroTik password** (same value as above): appears in exactly the 2
  commits already known and referenced above (`1132ea2c`, plus one earlier
  commit in the same SEC-015 sequence) — already documented, already
  rotated per that commit's own message, not a new finding.
- Did **not** run a full-history secret/IP sweep (e.g. `git log --all -p |
  grep`) — with 2,663 commits this is a multi-minute, high-output operation
  better suited to a dedicated tool (`gitleaks detect` already covers the
  password-pattern case and runs in CI/pre-commit per `.gitleaks-baseline.json`'s
  own existence and this repo's `SECURITY.md`-adjacent tooling). If the
  operator wants a genuinely exhaustive history sweep beyond gitleaks' own
  secret-shaped-string detection (e.g. for IP addresses, real names, or
  hostnames specifically, which gitleaks doesn't target), that's a
  larger, separate pass worth scoping deliberately — not something to
  half-do here.
- **No `filter-repo` command is proposed in this survey** — per the
  Co-Authored-By finding above, there's no actual reason found yet to
  rewrite history for that specific concern. If the WAN-IP or MikroTik-password
  findings above are judged to warrant a history rewrite (rather than just a
  working-tree fix plus accepting the values are already
  dead/rotated/superseded), that's a separate decision with its own
  consequences (force push, broken PR links, rewritten SHAs on a public repo
  with an existing commit history people may have referenced) — flagging
  that this is a real fork in the road, not deciding it here.
