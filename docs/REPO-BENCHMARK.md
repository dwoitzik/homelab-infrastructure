# Repo Benchmark: How This Compares to Well-Regarded Public IaC Repos

Written to answer one question before touching anything: what does a platform
engineer expect to see in the first ninety seconds of a public homelab/IaC
repo, and where does this one fall short of that — concretely, not by taste.

Six repos examined directly (READMEs fetched, directory trees pulled via the
GitHub API, sample manifests/tasks read for comment style), chosen because
they're the ones actually cited and starred in this space, not arbitrary
picks.

## The repos

### [onedr0p/home-ops](https://github.com/onedr0p/home-ops) — 2.7k★

The most-referenced home Kubernetes repo in the GitOps-homelab community;
spawned the `cluster-template` project other people fork to start their own.

- README opens with a centered title + tagline, three rows of badges
  (live health checks like Alertmanager/status-page, then stack versions),
  then Overview → Kubernetes → Cloud Dependencies → DNS → Hardware →
  Gratitude. Architecture is a collapsible network diagram and a Mermaid
  diagram of the Flux dependency graph, both inside the README — no
  separate diagram file to go stale.
- Directory layout is flat and namespace-shaped: `kubernetes/apps/<namespace>/<app>/app/{helmrelease,externalsecret,pvc,kustomization}.yaml`.
  No `docs/decisions/` at all.
- Sampled `kubernetes/apps/default/home-assistant/app/helmrelease.yaml`:
  **one comment in the entire file** (a `yaml-language-server` schema hint).
  Zero rationale, zero narrative. The manifest's own structure and naming
  carry all the meaning it needs.
- Cost/dependency transparency: an explicit "Cloud Dependencies" section
  listing exactly what external services are relied on and the real
  monthly cost (~$10). Nothing hidden, nothing narrated either.

### [khuedoan/homelab](https://github.com/khuedoan/homelab) — bare-metal-to-running-cluster in one command

- README: title, three anchor links (Features / Get Started / Documentation),
  badges (tag, doc-site link, license, stars), then a **quoted callout**
  answering "what is a homelab?" for readers who aren't already in the
  community, then Overview (explicit `Project status: ALPHA`), Hardware
  (real photo), a checklist Features section, then a Roadmap.
- Full [Diátaxis](https://diataxis.fr/)-shaped docs site (`docs/concepts/`,
  `docs/getting-started/`, `docs/how-to-guides/`, `docs/installation/`,
  `docs/reference/`), published separately via mkdocs — rationale and
  concepts live in `concepts/`, not in code comments.

### [techno-tim/k3s-ansible](https://github.com/techno-tim/k3s-ansible) — 2.9k★

- README: title, embedded video thumbnail, one-paragraph what-this-does,
  explicit attribution to the forks it's based on, then a "Project guides"
  link list (Getting started / Configuration variables / Upgrading /
  Molecule testing / Contributing / **`AGENTS.md` for coding agents**).
- Sampled `roles/k3s_server/tasks/main.yml`: comments exist and are dense
  in places, but every one explains **why a line is there**, not when or by
  whom — e.g. `# k3s-init won't work if the port is already in use` and a
  multi-line comment on a `when:` condition that references an **issue
  number** (`#644`) instead of a date or a person. Issue/PR numbers as a
  pointer to more detail are fine; narrated history isn't.

### [terraform-aws-modules/terraform-aws-vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) — 3.2k★

The de facto reference for what a professional Terraform module looks like.

- `main.tf`: comments are single lines, sparse, and exist only where a line
  would otherwise be genuinely confusing —
  `# Use local.vpc_id to give a hint to Terraform that subnets should be
  deleted before secondary CIDR blocks can be free!` is the kind of thing
  that survives; there is nothing resembling a changelog anywhere in the
  file. Section dividers (`### VPC ###`) organize the file instead of prose.

### [Cloud Posse Reference Architecture](https://docs.cloudposse.com/components/) (formerly `cloudposse/terraform-aws-components`, now split per-component)

- Each Terraform "component" is deliberately single-purpose and
  self-contained (`src/` for code, `test/` for tests) rather than one giant
  stack — the opposite of cramming unrelated concerns into one file.
  Architecture/rationale lives in a dedicated documentation site
  (docs.cloudposse.com), not inline.

### [vehagn/homelab](https://github.com/vehagn/homelab) — 401★

The other end of the spectrum from khuedoan's full docs site: **one rich
README with a `docs/assets/` image folder and nothing else** — numbered
sections, screenshots, no separate markdown pages at all. Proof that a
single well-organized README is a legitimate, well-regarded pattern too;
the doc-site approach isn't mandatory, consistency and honesty are.

## What the good repos have in common

1. **Comments explain why a non-obvious line exists, never when it changed,
   who changed it, or what session/incident it came from.** The closest any
   of them get to "history" in code is an issue/PR number as a pointer —
   never a prose narrative, never a date, never a name.
2. **Rationale that's more than one line lives in docs, not in the
   manifest.** ADRs, a concepts/ directory, or a single well-structured
   README section — but never a multi-paragraph comment block sitting above
   a `resource` or `kind:` line.
3. **The README is the ninety-second pitch**: what this is, what it
   demonstrates or proves, hardware/architecture (often a diagram, always
   at least a table), then how to actually use/rebuild it. Status badges
   are real and live (CI, uptime, versions), not decorative.
4. **Directory layout is uniform and predictable** — one shape per app/
   component, repeated everywhere, so a reader who's seen one app directory
   has effectively seen them all.
5. **Hardware/cost/dependency honesty.** The best repos state plainly what
   this actually costs to run and what it depends on externally — it reads
   as more credible, not less.
6. **No AI-attribution or generated-by artifacts anywhere** — not in
   commits, not in comments, not in READMEs. These are portfolios of the
   author's own engineering judgment; anything suggesting otherwise
   undercuts the entire premise.

## Where this repo stands, concretely

**Real strengths, not a blank slate.** The README already does several
things right: it opens with what/why (`README.md:5-10`), has a real "What
this demonstrates" section, a live CI badge, and a stack-overview table.
Every one of the 34 `kubernetes/apps/*` directories already has its own
README — that's ahead of onedr0p's own layout, which has none. ADRs exist
(28 of them) and are mostly numbered consistently.

**The actual gaps, with file/line evidence, not general complaints:**

- **Incident narrative embedded directly in manifests**, the single biggest
  gap versus every repo above. Example,
  `kubernetes/apps/network-policies-egress.yml:1-7`:

  > "These policies were applied live on 2026-08-23 (goal-1 apps
  > NetworkPolicy work) but never committed to git ... caught 2026-08-26
  > while diagnosing a real outage"

  This is changelog prose sitting above a `NetworkPolicy` resource. None of
  the six benchmarked repos would put this here — it belongs in an ADR or
  a runbook, with the manifest carrying at most a one-line "why this
  exists" pointer.
- Same pattern repeats across Ansible: `ansible/roles/atlantis/tasks/main.yml:4`
  ("confirmed live 2026-07-04 (container crash-looped on..."),
  `ansible/roles/k3s_node_tuning/tasks/main.yml:2,39,77` (three separate
  dated narrative blocks in one file), `ansible/roles/media_acquisition/tasks/main.yml:2`
  ("NOTE on architecture, found live (2026-06-24)..."). A stranger reading
  any of these gets a diary entry where they expected a reason.
- One instance names the operator directly by role rather than by name
  (`ansible/roles/github_actions_runner/tasks/main.yml:129`, "this
  operator's real, in-use notification...") — still a tell that this is
  session narrative, not documentation, even without a literal name.
- `terraform/stacks/network/*.tf` alone carries 321 comment lines across
  1,747 total (~18%) — not damning by volume, every benchmarked repo has
  *some* comments — but a meaningful fraction of those lines are dated
  narrative rather than the sparse, why-only style `terraform-aws-vpc`
  demonstrates.
- **`docs/` is flat and mixes topic docs with dated incident reports** as
  peers: `docs/garage-velero-design-2026-07-17.md`,
  `docs/cleanup-2026-07-17.md`, and `docs/vault-terraform-plan-2026-07-17.md`
  sit alongside `docs/OPERATIONS.md` and `docs/HARDWARE.md` with no
  distinction between "reference doc" and "dated incident writeup" — none
  of the benchmarked repos mix these; khuedoan separates by Diátaxis
  category, vehagn keeps a single README precisely to avoid this kind of
  sprawl.
- **ADR numbering is inconsistent at the start**: `docs/decisions/ADR-001.md`
  and `ADR-002.md` have no descriptive slug, every ADR from `ADR-003`
  onward does (`ADR-003-garage-terraform-backend.md`). Small, but it's the
  first thing a reader clicking into the ADR index sees.
- **Checked and ruled out, stated here so it isn't re-flagged later**: this
  pass looked for `Co-Authored-By: Claude`/`Generated with` trailers across
  all 2,663 commits in `git log --all`, both via `--grep` and a full raw
  commit-body scan. Zero matches, either exact or case-insensitive, and no
  commit template, hook, or CI step in this repo adds one. An earlier draft
  of this document asserted a specific count here (57 of 1,223 commits) —
  that number was wrong, not independently verified before being written
  down, and has been removed rather than corrected to a "right" number,
  because there isn't one: there's nothing to attribute-strip here at all.
  No `filter-repo` pass is warranted for this reason.

Everything in the rest of this quality pass works from the six gap
categories above, not from a fresh read of taste.
