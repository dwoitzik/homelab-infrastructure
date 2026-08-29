# Post-Mission Assessment

**Written:** 2026-08-26, at the close of the "Steady-state consolidation and portfolio
finish" goal — the last of a series of `/goal`s that began with a from-nothing rebuild
on 2026-08-13 and ran, with real gaps and real incidents along the way, for thirteen
days. This is the honest closing account: what broke, why, what the architecture looks
like now and what forced each choice, the status of every failure mode this mission
ever found, and what the next agent should know that took this one thirteen days to
learn.

This document does not replace the ground truth. `phase8/LEDGER.md` (97 entries) is the
real, append-only record of every hypothesis tried and every dead end hit; this is a
synthesis of it, written for a reader who wasn't there — including a future version of
this agent.

## 1. What broke, and why

The proximate trigger was a Proxmox host in a degraded state on 2026-08-12: boot
configuration drift, a root filesystem mid-migration from ZFS to LVM-thin, and a k3s
cluster that was fully dead. But the root cause, established with evidence rather than
assumed, was one specific hardware/software mismatch: **a DRAM-less boot NVMe running
ZFS underneath etcd's write pattern**. ZFS's copy-on-write overhead plus etcd's
fsync-heavy raft log produced sustained write amplification this specific SSD's
controller couldn't absorb without a DRAM cache — the result was months of intermittent
I/O saturation, repeated Proxmox crashes, GitOps drift, and OOM kills, culminating in
the 2026-08-12 collapse. Full detail and the complete data-recovery accounting:
`docs/RECOVERY-REPORT-2026-08-13.md`.

That report is the end of the *first* phase — a 14-hour rebuild that restored every
real dataset (nothing was actually lost except two services, Gitea and Nextcloud, that
were confirmed to have held no real data before the incident) and stood up a new
architecture. Everything from here is what happened in the thirteen days after that
report was written, across two more BRIEFING revisions and this final consolidation
goal — a second act this mission's own documentation hadn't fully accounted for until
now.

That second act was not a quiet cleanup pass. It included, in rough chronological
order: a full external-exposure audit that found real, unintended public attack
surface and closed it to an explicit two-hostname allowlist (`ADR-033`); Garage's
metadata store corrupting *twice* under real write pressure and eventually being wiped
and reprovisioned from scratch, taking Terraform's own remote state with it; a PBS
backup bug that silently produced 1-byte archives for weeks, caught by an agent that
insisted on testing a real restore rather than trusting a green backup job; a host
storage-exhaustion incident serious enough to be a declared hard-stop; the Vault root
token appearing in an agent's own tool output on **four separate occasions**, each one
caught, disclosed, and eventually closed by removing the root token from the working
path entirely (`ADR-025`); and, in this final pass, a sixth-and-counting class of the
same underlying problem — a config file that happened to hold a live credential, read
for an unrelated, legitimate reason — finally closed by mechanical enforcement rather
than another reminder (`ADR-028`). None of this is flattering, and none of it is
hidden here.

## 2. Architecture now, and what forced each choice

The system this mission converged on is not the one the original brief assumed. Every
major deviation was forced by something real, not preference:

- **k3s datastore: SQLite via kine, not etcd** (`ADR-015`). The prior documentation's
  claim that this cluster ran etcd was already false by the time this mission started
  — the live datastore was SQLite. This decision formalized what had already happened
  rather than reverting to the thing that caused the original disaster.
- **Boot/VM storage: LVM-thin, not ZFS.** Direct consequence of §1 — ZFS's overhead was
  incompatible with this specific disk under this specific write pattern.
- **k3s VM disks stay on the NVMe thin-pool, not the HDD-backed archive pool**
  (`ADR-019-k3s-vm-disk-placement`). Tested rather than assumed once the etcd
  write-amplification cause was actually fixed — HDD latency would have traded a
  solved wear problem for a new scheduling-latency one.
- **Storage classes: `local-path` and `nfs-client`, not Longhorn.** Longhorn's
  replication overhead was a poor fit for a topology that is, in practice, a single
  host — redundancy comes from disciplined Velero+kopia backup instead.
- **3 VMs on one physical host, kept, not collapsed** (`ADR-026`). Measured, not
  assumed: allocation is ~87.5% vCPU / ~52% RAM against host capacity, and splitting
  further or consolidating to fewer VMs was checked against real data before deciding
  against it.
- **A single shared NVMe backs everything, so bulk background I/O is now guarded**
  (`ADR-023`). Two separate host-wide incidents in one day forced this — there is no
  second disk to isolate noisy jobs onto, so the only lever is throttling and
  scheduling discipline, encoded as an actual guard rather than an operational habit
  to remember.
- **Public exposure is an explicit two-hostname allowlist, not opt-out** (`ADR-033`,
  the exposure one). An opt-out wildcard model accumulated three real, unnoticed
  exposure gaps (including one app with *no* protection at all) within a single day of
  existing. Default-deny at the DNS/tunnel layer, matching the firewall's own posture
  one layer down.
- **Vault credentials for this agent: a narrow AppRole, not the root token**
  (`ADR-025`). Forced by four real root-token exposures, not adopted proactively.
- **Declared-vs-live drift gets its own scheduled check, independent of ArgoCD**
  (`ADR-027`). Forced by the dead man's switch itself sitting merged-but-unapplied for
  days, undetected, because nothing was watching for that specific failure class.
- **Secret exposure is now mechanically blocked, not just a rule to remember**
  (`ADR-028`, this pass). Forced by the sixth incident of the same shape in as many
  weeks — a `PreToolUse` hook that denies the read outright, rather than another
  paragraph asking the next session to be careful.

The full decision record is 28 ADRs deep (`docs/decisions/`); the list above is the
spine, not the whole tree.

## 3. Every failure mode this mission found, and its current status

| Failure mode | Status |
|---|---|
| ZFS + etcd + DRAM-less NVMe write amplification | **Fixed.** LVM-thin + SQLite datastore, `ADR-015`/original rebuild. Root-caused with evidence, not assumed. |
| Boot configuration drift / missing `proxmox-boot-uuids` tracking | **Fixed**, part of the original rebuild. |
| K3s pod DNS search-list hijack (`ndots:5` + wildcard rewrite silently breaking external and internal lookups) | **Fixed**, static `resolv.conf` with no search domain. Found only because Phase 5 insisted on proving alerting worked end-to-end rather than trusting the config. |
| Velero backups missing `defaultVolumesToFsBackup` (backups "succeeded" but captured no real PVC data) | **Fixed and proven** — a real restore was tested, not assumed from a green job. |
| PBS producing 1-byte archives silently for weeks | **Fixed**, two independent real causes found (not the first two hypotheses tried). |
| Garage metadata (LMDB) corrupting under write pressure — twice | **Mitigated, not eliminated.** Wiped and reprovisioned both times; the underlying shared-disk write-pressure risk is addressed by `ADR-023`'s I/O guard, but Garage's own corruption tolerance under this hardware's write pattern was never independently hardened beyond that. **Accepted with trigger**: if it corrupts a third time, the guard itself needs revisiting, not just another wipe. |
| Vault root token exposure (4 separate incidents) | **Fixed by design**, `ADR-025` — narrow AppRole is now the working credential; the root token is out of the path entirely rather than handled more carefully. |
| CNPG WAL archiving broken for 3 production databases since cluster creation | **Fixed and verified** — `ContinuousArchiving: Success` confirmed live on all three, including the one (Synapse) that took longest to confirm. |
| PostgreSQL/CNPG PodMonitor sync-loop (`Health: Unknown` since the manifest was added) | **Fixed this pass** — CNPG deletes any PodMonitor matching its Cluster's own *name* on every reconcile; renamed away from the collision. |
| Six secret-exposure near-misses across the mission (config files holding live credentials, read for legitimate reasons) | **Fixed by design this pass** (`ADR-028`) — mechanically blocked, not a rule to remember. Explicitly not a security boundary against a hostile actor; explicitly doesn't cover the k3s guest VMs (this agent's key doesn't reach them). |
| Unintended public exposure (opt-out wildcard model, 3 real gaps found in one day) | **Fixed**, `ADR-033` allowlist. Re-verified this pass via a full external DNS scan — exactly the 3 intended hostnames answer, nothing else. |
| Cloudflare Access (email OTP) for `photos.woitzik.dev` | **Not live.** Terraform written and merged (PR #473), `atlantis plan` clean three times, but the apply itself needs the operator's own PR comment plus a required-reviewer Environment approval — this agent hit a real, respected boundary (Claude Code's own classifier denied triggering the apply) and did not route around it. **Accepted with trigger**: operator comments `atlantis apply -d cloudflare`, approves the gate. |
| Minecraft egress restricted to playit.gg specifically | **Not done.** DMZ still has blanket internet egress (isolated from every other VLAN, which is the actual security boundary — this is a minimization gap, not a live one). No RouterOS FQDN-address-list pattern exists in this repo to build from safely; documented rather than rushed. **Accepted with trigger**: worth doing when someone has real MikroTik Terraform time, not urgent. |
| Drift between git and live state going undetected | **Mitigated, with a known gap just found.** `ADR-027`'s drift-check covers `kubernetes/system/` on a 30-minute schedule. It does **not** cover `kubernetes/apps/` (assumed covered by ArgoCD's own selfHeal) — but selfHeal only reverts drift *away* from git; it does nothing for a resource that's live but was never committed at all. That exact gap caused a real 4-day outage this pass (a `NetworkPolicy` egress rule applied live 2026-08-23, never committed, crash-looping `cloudflared` — see the note from the parallel session that found and fixed it, PR #572). The drift-checker's own scope is now a known, named blind spot, not a solved problem. |
| SSD wear (56% and climbing at the time `HARDWARE.md` was last updated) | **Accepted with trigger, now actively monitored.** 57% as of this pass's own manual check. Replacement trigger is explicit (warning ≥80%/spare<50, replace now ≥90%/spare<10/any media error) and now checked automatically every month (`ssd_wear_check`, this pass), not just documented. This is the most honest "still weak" item in this whole assessment — see §5. |
| Cadence work (restore tests, wear checks, dependency review, DR drills) documented but not actually running | **Fixed this pass** — four scheduled jobs, each proven with a real triggered run, not just deployed and assumed: `CadenceJobDidNotRun` silence-alerting, monthly SSD wear check, quarterly dependency/CVE review, quarterly DR game day (a real pod kill against `homepage`, timed recovery in 18s). |
| No closing assessment of the mission as a whole | **This document.** |

## 4. What I'd tell the next agent

- **Read the ledger before you touch anything, and believe it over any summary
  including this one.** Every genuinely bad moment in this mission — the Garage
  corruption, the storage exhaustion hard-stop, all four Vault token exposures —
  happened when an action was taken on an assumption instead of a check. The pattern
  that actually works, over and over: state a hypothesis, check it against live state,
  then act.
- **A credential-shaped file will eventually get read for an unrelated reason.** Six
  times, not once. The fix that stuck wasn't "be more careful," it was removing the
  possibility mechanically (`ADR-028`). If you find yourself writing a new debugging
  step that touches a file that might hold a secret, ask whether it belongs on the
  deny-list before you run it, not after.
- **This host has exactly one disk.** Every storage decision on this cluster traces
  back to that one fact. If a future you is tempted to add write-heavy anything —
  another database, a new backup target, a monitoring agent with its own local
  storage — check `ADR-023` and `HARDWARE.md` first. The two worst incidents of this
  entire mission were both this same failure mode wearing a different face.
- **"Deployed" is not "working."** The PBS 1-byte-archive bug, the Velero
  `defaultVolumesToFsBackup` gap, and CNPG's silently-broken WAL archiving were all
  green in their own status output. Every one of them was only found because someone
  insisted on testing a real restore instead of trusting a green backup job. Keep
  doing that.
- **Respect a classifier denial as a real boundary, not an obstacle to route around.**
  This came up twice this pass alone (an `atlantis apply` PR comment, a GitHub Actions
  secret write) and multiple times earlier in the mission. Both times the honest move
  was to document the boundary and hand the specific next step back to the operator,
  not find a clever way around it.
- **`kubernetes/apps/` is not fully watched.** ArgoCD's selfHeal only catches drift
  *away* from git — a resource applied live and never committed sits there invisibly
  until something else notices (in this case, four days of a crash-looping tunnel).
  If you extend the drift-checker, extending its scope to `apps/` — carefully, its
  current scope was deliberately narrowed once already for a real reason, check
  `ADR-027` before widening it blind — is a genuinely open, valuable piece of work.
- **The three flagged-for-review credentials in `/root/.secrets/flagged-for-review/`**
  (a Proxmox API token, a GitHub PAT, a Vault session token, found loose during the
  `ADR-028` sweep) were still awaiting operator disposal as of this writing. Check
  `phase8/QUESTIONS.md`'s 2026-08-23 entry before assuming they're handled.
- **This agent's own host (`ct-srv-claude-agent`) is deliberately out-of-IaC**
  (`ADR-032`). Two pieces of real automation now live there instead of in the repo
  (the credential-deny hook, the quarterly dependency/CVE review) — both for
  defensible reasons specific to what this host alone can access, both documented in
  `STEADY-STATE.md` even though neither is committed. Don't "fix" that inconsistency
  by moving them into the repo without re-deriving why they're there first.

## 5. What's still weak — said plainly

- **The SSD is the obvious one.** 57% used as of this pass's own check, climbing at
  somewhere between ~0.57%/day (lifetime average) and ~1.22%/day (recent-rate,
  recovery-work-inflated) depending on how much of the recent rate was this mission's
  own load. Either bound puts replacement inside three months of the date this was
  first measured. It is now watched automatically and will alert at the documented
  thresholds — but automated watching is not the same as a drive in hand. This is a
  real, physical, unresolved risk sitting under every stateful thing this cluster
  runs, on a host with no second disk to fail over to.
- **The drift-checker's blind spot in `kubernetes/apps/`**, named in §3, is real and
  just cost four days of a public hostname being down. It was fixed reactively this
  time, by a parallel session, not proactively by this mission's own tooling.
- **Two real credential-hygiene items are unresolved**, not because they're hard but
  because they're genuinely the operator's call: the three flagged-for-review
  credentials' disposal, and — separately, and explicitly *not* reprioritized by the
  operator as of 2026-08-26 — the GitHub PAT rotation from an earlier accidental
  exposure. Neither is urgent. Neither is done.
- **Two exposure-hardening items from the original brief are still open**: Cloudflare
  Access for Immich (code ready, blocked on an operator-only apply step) and Minecraft
  egress restriction (real design work, not yet built). Both are honestly documented
  as open rather than claimed done; neither is a regression from where this mission
  started.
- **The k3s guest VMs were never swept for loose credentials.** `ADR-028`'s hook and
  sweep cover this agent's own host only — this agent's SSH key doesn't reach the k3s
  VMs directly, so whatever equivalent risk exists there (a kubeconfig, a token, a
  stray file) was never actually checked.
- **kube-bench findings and a cluster-wide RBAC audit both remain a human review item**,
  not because anything found so far is alarming, but because distinguishing genuine
  need from copy-pasted-too-broad access needs judgment this mission never claimed to
  have finished applying.
- **This is a text-matching credential guard, not a real security boundary.**
  `ADR-028`'s own Limitations section says so directly: it stops the *shape* of
  mistake that caused six incidents, it does not stop a hostile actor with shell
  access, and a new credential file created tomorrow won't be covered until someone
  adds it to the path list. It closes a real gap. It is not a claim of completeness.

There will be others this document didn't anticipate. That's not a failure of this
assessment — it's the honest state of a system that's real, running, and still
changing.
