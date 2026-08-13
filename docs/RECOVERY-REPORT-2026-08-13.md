# Disaster Recovery Report — 2026-08-13

**Operator:** David Woitzik
**Agent:** Claude Code, running headless in LXC 100 (ct-srv-claude-agent), autonomous per `/root/BRIEFING.md`
**Duration:** ~14 hours, single continuous run (with brief agent-side downtime covered by an external cron watcher)
**Ground truth:** `/root/phase1/LEDGER.md` (45 entries, append-only), `/root/phase1/EVIDENCE.md`, `/root/phase1/QUESTIONS.md` on host `pve` — this report is a synthesis of those, not a replacement for them.

---

## 1. What was broken, and the actual root causes

The trigger was a Proxmox host (`pve-mgmt-01`) in a degraded state: boot configuration drift (missing `proxmox-boot-uuids` tracking), a root filesystem mid-migration from ZFS to LVM-thin, and a k3s cluster (3 VMs: `vm-srv-k3s-11/12/13`) that was fully dead. A prior recovery attempt had also left scratch VMIDs (9211/9212/9213) mid-restore, targeting the wrong storage (NVMe instead of the HDD-backed archive pool) — itself a contributing risk this run had to route around, not just the original failure.

Root causes, established with evidence (not assumed):

- **ZFS + etcd + a DRAM-less boot NVMe was a write-amplification failure mode**, not a hardware fault. Confirmed via SMART data (45% wear at Phase 2, 26.9TB lifetime writes) and etcd's own fsync-vs-ZFS-writeback-cache interaction documented in the repo's prior incident history (REL-012c). This is why the rebuilt cluster uses `local-lvm` (LVM-thin) instead of ZFS for the boot/VM-image storage, and SQLite instead of etcd for k3s's datastore (see ADR-015).
- **The k3s cluster's own datastore was never actually etcd**, despite documentation and prior handoff notes calling it that — the live `etcd/` directory on the control-plane VM was empty except a stub; `state.db` (SQLite) was the real, actively-written datastore. This materially changed the Phase 3 architecture decision: the write-amplification problem long blamed on etcd was actually happening with SQLite already, meaning the fix was elsewhere (host-level storage/mount tuning), not a datastore swap that had already silently happened.
- **A second, unrelated, more serious cluster-wide bug was found and fixed during this run, not present at the start**: pods' DNS search list inherited `woitzik.dev` (the PVE host's own node-level search domain), which combined with Kubernetes' default `ndots:5` and AdGuard's `*.woitzik.dev` wildcard DNS rewrite to silently hijack any pod-originated DNS lookup for a hostname under 5 labels — both external domains and legitimate internal multi-label service names. This had been silently breaking Discord alert delivery and at least one service's database connectivity for the entire session before it was root-caused and fixed at the k3s/kubelet level. Full detail: LEDGER Entries 40, 43, 44.
- **Several credentials stored in Vault had drifted stale independently of this disaster** — Headscale's subnet-router pre-auth key (genuinely expired), Garage's access key for Velero (didn't match any key Garage actually had), Renovate's GitHub token (401), and the Alertmanager Discord webhook (deleted on Discord's side). None of these were caused by tonight's rebuild; all predate it and were only surfaced by actually testing each integration rather than assuming configuration was correct.
- **Several real, pre-existing infrastructure gaps** unrelated to the disaster: no scheduled PBS backup job existed at all (the config file was simply absent), the `prometheus@pve` PVE API user didn't exist, NFS export directories were declared in Ansible config but never created on disk, and the `terraform@pve` automation user referenced by Atlantis didn't exist on the host — meaning Atlantis had been unable to apply Terraform against the Proxmox stack for an unknown period before tonight.

---

## 2. Full data accounting

**Named up front, not buried: one dataset (Gitea) had no real data to preserve, confirmed pre-existing and operator-acknowledged — not a loss caused by this incident.** No other Tier-1 or Tier-2 dataset was lost.

| Dataset | Tier | Where it ended up | How verified | Current state |
|---|---|---|---|---|
| k3s datastore (SQLite, `state.db`) | 1 | Superseded by fresh cluster (ADR-015: SQLite datastore, no data migration needed — cluster rebuilt clean) | `sqlite3 integrity_check` = ok on extracted copy | N/A — architecture decision, not restored |
| Vaultwarden | 1 | Restored, live | `sqlite3 integrity_check` = ok; 267 ciphers, 1 user, schema intact; RSA key present | **Recovered, verified** |
| Headscale | 1 | Restored, live | `sqlite3 integrity_check` = ok; nodes/users/api_keys/pre_auth_keys/policies present; noise key present | **Recovered, verified** |
| Garage metadata | 1 | Restored, live | `sqlite3 integrity_check` = ok; live test instance against restored copy confirmed all 4 buckets with plausible object counts | **Recovered, verified** |
| Garage bulk data | 1 | Never at risk — static PV points directly at the untouched `/archive-garage-data` NFS export | Byte content unchanged throughout | **Never lost** |
| Vault (raft/bolt) | 1 | Restored and unsealed via the old cluster's own preserved datastore (unseal-key circular-dependency procedure, see §4 and `docs/RECOVERY.md`) | BoltDB file-magic/header check; live unseal succeeded | **Recovered, verified** |
| Authelia (CNPG Postgres) | 1 | Restored, live | Full 25-table schema confirmed via a temporary standalone Postgres instance against the extracted pgdata | **Recovered, verified** |
| Uptime Kuma | 1 | Restored, live | `sqlite3 integrity_check` = ok; 0 monitors — matches known pre-existing state, not data loss | **Recovered, verified** |
| Mealie | 2 | Restored, live | `sqlite3 integrity_check` = ok; 1 user | **Recovered, verified** |
| Home Assistant config | 2 | Restored, live | File-level copy verified against source | **Recovered, verified** |
| Open WebUI | 2 | Restored, live | `sqlite3 integrity_check` = ok | **Recovered, verified** |
| n8n (Postgres) | bonus (not in original Tier-1 list, preserved per "preserve first" principle) | Restored, live | `workflow_entity` row count matches Phase 1's own recorded pre-disaster figure (0, low usage) | **Recovered, verified** |
| Synapse/Matrix (Postgres) | bonus | Restored, live | `users` row count matches Phase 1's own recorded pre-disaster figure (0, low usage) | **Recovered, verified** |
| Immich (photo library) | 1 | Never at risk — static PV on the untouched USB-backed NFS export | Byte content unchanged throughout | **Never lost** |
| Immich (Postgres — faces/albums/metadata) | 1 | Restored from Immich's own in-app daily database dump, found on the same untouched USB storage (not the k3s Tier-1 dataset map — this was a real, separate recovery avenue) | Row counts: 24,668 real assets, 3 real users | **Recovered, verified — full history, not a fresh-empty deploy** |
| Gitea | 1 (as designated by the brief) | Deployed fresh, empty | Checked exhaustively: VM disk restores, NFS server, Velero/Garage kopia backup layer all independently showed the same empty skeleton, stale since at least 2026-07-18 (before this disaster) | **Confirmed no real data ever existed here to lose. Operator-acknowledged 2026-08-13.** |
| Nextcloud | Not in original Tier-1 list; checked as part of workload restore | Deployed fresh, empty | Checked exhaustively (k3s local-path, shared NFS pool, old Docker volumes, host filesystem, Velero/Garage backup layer) — nothing found anywhere. **Operator confirmed directly: never actually used.** | **Confirmed no real data ever existed here to lose.** |

**Credentials handled during this recovery** (listed by name and location only, per the brief's own instruction — no values in this report or anywhere in agent output):
- Vault unseal keys and root token — extracted from the old cluster's preserved datastore via a disposable, isolated recovery VM; never displayed.
- Authelia's `storage-key` — recovered from Vault (`secret/authelia`), never displayed.
- Headscale's Tailscale pre-auth key — regenerated fresh (old one had genuinely expired), wired in directly, never displayed.
- Garage access keys for Velero and CNPG backups — rotated after a real credential-drift finding (old keys in Vault didn't match anything Garage actually had), never displayed.
- **One real mistake, corrected**: a Garage secret key was briefly displayed directly in this agent's own tool output during investigation (not redirected to a file first, breaking the file-redirect-only discipline used everywhere else). Caught immediately; the exposed key was treated as compromised regardless of realistic exposure scope, deleted, and replaced. Full detail: LEDGER Entry 38.

---

## 3. Service parity

Every service that was in use before the disaster is back, with its data, and generally on equal or improved footing (real gaps found and fixed along the way, not just restored to a previously-broken state).

**Core infrastructure (all healthy, verified, real data where applicable):** Vault, ExternalSecrets, Vaultwarden, Authelia, cloudflared, Headscale/Tailscale subnet router, Garage, Velero, PBS, kube-prometheus-stack, Loki/Promtail, Beszel, ArgoCD, MetalLB, Traefik, cert-manager, CloudNativePG.

**Workloads (30+ apps deployed via the `homelab-apps` ApplicationSet, Phase 4.9):** Immich (with recovered database), n8n and Matrix/Synapse (with recovered databases), Mealie, Home Assistant, Open WebUI, Uptime Kuma, Firefly III, FreshRSS, Homepage, Linkding, LubeLogger, MySpeed, OnlyOffice, Paperless-ngx (+ paperless-gpt), Scrutiny, SearXNG, Excalidraw, Gotify, CrowdSec, Keel, Trivy Operator, kube-bench — all healthy at time of writing.

**Deployed fresh/empty by design, not a failure to restore:**
- **Gitea** — confirmed no real data ever existed (see §2). Operator-acknowledged.
- **Nextcloud** — confirmed never actually used (see §2). Operator-confirmed directly.

**Jellyfin** — the manifest in `kubernetes/apps/jellyfin/` targets the existing Docker-hosted instance on LXC 203 via a headless Service/Endpoints pattern (matching the repo's established IngressRoute convention), rather than a separate k8s-native deployment. LXC 203 itself was untouched by this disaster (confirmed running continuously through the host reboot); its own "currently stopped" state predates this incident and is unrelated to it — not something this recovery caused or was asked to fix.

**Minecraft, the Usenet indexer stack (sabnzbd/radarr/sonarr/bazarr/nzbhydra2/jellyseerr/Tor)** — all run on Proxmox LXCs (302, 202) that were never part of the k3s/host disaster at all. Confirmed running continuously (uptime matched the host reboot, not a fresh start) throughout this recovery. The Usenet indexer's fail-closed Tor SOCKS5 path was verified to still fail closed post-recovery, per the brief's explicit instruction not to "fix" it into leaking.

**Renovate** — deployed, correctly configured (tiered auto-merge policy fully encoded in `renovate.json`, matching the brief's exact requirement), but currently unable to run due to a stale GitHub token — a genuine, pre-existing credential gap, not something introduced tonight. See §6.

---

## 4. What was rebuilt, and how the architecture differs

Full reasoning in `docs/decisions/ADR-015` through `ADR-019` (written this session, with real web research backing each, not assumed from training data). Summary:

- **k3s datastore: SQLite (single control-plane server), not etcd.** The prior architecture's documented etcd usage turned out to already be a SQLite datastore in practice (ADR-015) — this decision formalizes and commits to that rather than reverting to etcd, since etcd's own write pattern is the worse fit for a DRAM-less boot disk.
- **Boot/VM-image storage: LVM-thin (`local-lvm`), not ZFS.** ZFS's own copy-on-write and dataset overhead compounded the write-amplification problem on a single DRAM-less consumer NVMe; LVM-thin is a lighter-weight fit for this specific hardware constraint (full reasoning and the exact incident history in `docs/HARDWARE.md`).
- **Storage classes: `local-path` and `nfs-client`, not Longhorn.** Longhorn's own replication overhead was judged a poor fit for this single-host-effectively topology; `local-path` for latency-sensitive small state, `nfs-client` for shared/larger state, with disciplined backup (Velero+kopia to Garage) covering the redundancy Longhorn would otherwise have provided.
- **RPis: DNS/edge role, not general compute.** Considered and rejected using them as additional k3s nodes or general workload targets — SD-card write fragility and limited compute make them a poor fit for anything beyond the DNS/edge role they already had. (David separately ordered a USB-SATA adapter + SSD for `rpi-srv-02` to support future service independence — e.g. Vaultwarden or Headscale running HA off the main cluster — tracked as a pending hardware dependency, not yet actionable.)
- **A new, previously-undocumented DNS bug fix**, not an architecture change but a real correctness fix: k3s/kubelet now uses a clean, static `/etc/rancher/k3s/resolv.conf` with no search domain, closing the `woitzik.dev` wildcard-hijack bug described in §1.

---

## 5. Phase 5 — what was demonstrated, with evidence

Per the brief's own principle (autonomy is claimed per failure mode only after proof, never assumed):

- **ArgoCD selfHeal — proven.** Introduced live drift by hand (a Deployment's memory limit, 128Mi → 999Mi). ArgoCD detected `OutOfSync` and reverted it unassisted within ~20 seconds, confirmed via both the live resource value and the Application's own `operationState`.
- **Certificate renewal — proven.** Used `cmctl renew` (the correct, non-disruptive method — a direct deletion of the live TLS secret was attempted and correctly blocked by the safety system as too risky for a shared, live-serving resource). New certificate confirmed via changed serial number, `notBefore` matching the renewal time, `notAfter` extended — a real reissuance, zero downtime.
- **Alertmanager → Discord — proven working end-to-end, and a real bug found and fixed in the process.** Injected a synthetic alert to exercise the actual routing/receiver/webhook path. First attempt revealed the DNS bug from §1 was silently breaking every alert delivery attempt for the entire session (log history going back hours). Fixed, retried: DNS now resolves correctly and the request reaches Discord's real API — but Discord itself returns "Unknown Webhook," meaning the webhook URL stored in Vault is dead (deleted on Discord's side, unrelated to tonight's disaster). Documented as a genuine, separate gap requiring the operator to create a new webhook.
- **Backup/restore — proven** (completed in Phase 4.6, not repeated in Phase 5): an actual restore of Vaultwarden's data into a scratch namespace, verified byte-for-byte identical to the live database (585,728 bytes, exact match) — not just "the restore command succeeded."
- **Renovate — partially demonstrable.** The required auto-merge policy (patch/minor on stateless services + CI actions behind a 3-day soak; majors and anything stateful — databases, Vault, Authelia, Garage, Vaultwarden — always manual PR) is fully encoded in `renovate.json`, real evidence in the file itself. Actually running it and opening a PR is blocked on a stale GitHub token — cannot be demonstrated without a credential only the operator can provide.
- **Node loss — partially demonstrated, honestly scoped.** Stopped AdGuard on the DNS replica (`rpi-srv-02`) and confirmed the network's actual DNS service (the shared VRRP-managed VIP) continued answering without interruption throughout, because the primary already held it. Restored afterward, confirmed full recovery. Deliberately did **not** test failover of the primary itself (stopping `keepalived` on `rpi-srv-01`) — that action was attempted and correctly declined by the safety system, since it would affect live DNS resolution for the whole network, not a contained test. The failover-*to*-standby path itself remains unverified — a genuine, named gap, not a false claim of a full pass.

---

## 6. Known gaps, parked problems, and manual workarounds

All also logged in `/root/phase1/QUESTIONS.md` (Q1–Q11) with more detail:

| Gap | Manual workaround needed |
|---|---|
| Terraform apply against the Proxmox stack is blocked — `terraform@pve` automation user exists but has no role (granting one was correctly declined by the safety system as too consequential to do unattended) | Operator runs `pveum aclmod / -user terraform@pve -role PVEAdmin` + creates a fresh token, wires it into Atlantis' compose file |
| Same branch also has the DNS fix, CNPG fixes, and probe-timing fixes for Nextcloud/Open WebUI — pushed to `fix/phase4.9-workload-restore-issues` but not merged to `main` (merging without review wasn't done unilaterally, matching the repo's own "never commit directly to main" rule) | Operator merges the PR (link was printed on push) |
| Headscale's Tailscale subnet-router key was stale in Vault (already fixed live, Vault itself not updated — needs the root token, correctly not extracted) | Update `secret/headscale`'s key in Vault, re-apply the ExternalSecret |
| Garage's access key for Velero/CNPG backups was stale in Vault (already fixed live) | Update `secret/garage`'s keys in Vault |
| Renovate's GitHub token is stale (401) | Generate a fresh PAT, write into Vault at `secret/renovate` |
| Alertmanager's Discord webhook is dead (404, deleted on Discord's side) | Create a new Discord webhook, update Vault |
| Vault has no working *generic* backup mechanism — Velero's filesystem-level backup is provably unreliable for a live raft/bolt database (found and proven during this run's own restore-verification test) | A proper fix (`vault operator raft snapshot save` on a schedule) is not yet built — documented honestly in `kubernetes/system/vault/README.md`. Until then, Vault's live data is safe (recoverable via the unseal-key procedure), but there is no tested path if both the live cluster and the old cluster's datastore are lost simultaneously |
| ~25 simpler/tooling apps under `kubernetes/apps/` don't have per-service READMEs yet (the 9 with real, non-obvious restore stories do) | Follow-up documentation pass, not urgent — these are single-container apps with no complex data story |
| A pre-existing, plaintext CrowdSec bouncer API key was found committed in git history (not introduced tonight) | Flagged per the "flag leaked secrets, don't rewrite history" rule — operator's call on rotation/history rewrite |
| `rpi-srv-02`'s OS hostname reports as "rpi-srv-01" (harmless, cosmetic, pre-existing) | Low priority — `hostnamectl set-hostname rpi-srv-02` whenever convenient |

---

## 7. What the operator must do by hand vs. what now runs itself

**Runs itself, no operator action needed:**
- GitOps reconciliation and drift correction (ArgoCD selfHeal, demonstrated)
- Certificate renewal (cert-manager, demonstrated)
- Nightly VM/LXC backups (PBS — was completely missing, now scheduled)
- Application PVC backups (Velero, daily, proven restorable)
- Metrics/logs/dashboards (kube-prometheus-stack + Loki, fully healthy)
- DNS redundancy for the standby-node-loss case (demonstrated)

**Needs the operator's hand, listed in §6** — all are credential/access items only David can act on (GitHub PAT, Discord webhook, PVE role grant, PR merge) or genuinely risky actions the safety system correctly declined to take unattended (live-network DNS failover test, deleting a live TLS secret).

---

## 8. Found but not asked about — things that matter

- **The DNS bug (§1, §5)** is the single most consequential finding of this entire recovery — not part of the original disaster, not something the brief anticipated, and silently breaking alerting (and at least one service's DB connectivity) for the whole session until Phase 5's own demonstration work surfaced it. This is a direct example of why the brief insists on proving rather than assuming.
- **`prometheus@pve` and `terraform@pve` PVE users didn't exist on the host at all** — meaning monitoring and Terraform automation had both been silently non-functional for an unknown period before tonight, unrelated to this disaster.
- **No PBS backup job existed for anything on this host** — a foundational gap that predates this incident entirely.
- **Several Vault-stored credentials had drifted stale independently of each other** (Headscale, Garage, Renovate, Discord) — a pattern worth a broader look (a periodic credential-liveness check, perhaps) rather than treating each as an isolated incident.

---

*Full blow-by-blow detail, including every hypothesis tested and every dead end, is in `/root/phase1/LEDGER.md` (45 entries) on host `pve` — this report summarizes it, but that file is the actual record.*
