# Autonomy Status

Honest scorecard against `docs/OPERATING-MODEL.md`'s target steady state. Updated
2026-07-07 after the autonomy-readiness PRs (#314–319) merged and, where applicable,
were applied/verified live. Every row reflects an actual check, not a config read —
see `docs/AUDIT.md` REL-055 through REL-059 for the full evidence behind each.

**Legend**: **PROVEN** — a real event has already happened and been observed (an
actual alert reaching Discord, an actual automated grab→import cycle, an actual
renewal, an actual auto-merge nobody clicked). **CONFIGURED-BUT-UNPROVEN** — the
config is live and looks correct, but the real-world event that would demonstrate it
hasn't happened yet. **GAP** — doesn't work, doesn't exist, or was checked and found
actually broken.

| Capability | Status | How verified / why not | What would move it to PROVEN |
|---|---|---|---|
| Renovate tiered auto-merge (stateless/CI/dev-tooling, patch/minor/digest) | **CONFIGURED-BUT-UNPROVEN** | `renovate.json` merged (#316) and live. But checked: the 2 Renovate PRs merged today (#314 paperless-gpt, #302 Renovate's own image) were merged **by me via `gh pr merge`**, not auto-merged by Renovate — confirmed via `mergedAt`/author on both. Zero real auto-merge events have happened under the new tiering yet. | A future Renovate PR for a stateless/patch-minor package actually merging itself with no human click, after CI-green + the 3-day `minimumReleaseAge` soak. |
| Renovate PR-only tier (stateful/critical, all update types + all majors) | **CONFIGURED-BUT-UNPROVEN** | Config correct (`automerge: false`, grouped, labeled) — but by construction this tier never self-proves; it's proven by *not* auto-merging, which can't be positively observed yet since no such PR has landed since #316. | A real PR for a stateful/critical package (Vault, Authelia, a DB, etc.) landing and confirmed to sit unmerged with the `stateful-critical` label, not silently auto-merged. |
| Discord: `KubePodCrashLooping` | **PROVEN** | Fired a real synthetic alert via Alertmanager's API; `alertmanager_notifications_total{integration="discord"}` incremented (11 sent, 0 failed); user-confirmed landing in Discord. | — already proven |
| Discord: ArgoCD `on-sync-status-unknown` | **PROVEN** | Created a real throwaway Application pointed at a nonexistent path, genuinely triggered `sync.status: Unknown`, confirmed `TRIGGERED` + send in notifications-controller logs, user-confirmed landing in Discord. | — already proven |
| Discord: ArgoCD `on-health-degraded` / `on-sync-failed` | **CONFIGURED-BUT-UNPROVEN** | Same subscription mechanism and webhook as `on-sync-status-unknown` above (proven), but this specific trigger condition has never actually fired — different `when` expression, never exercised. | A real Application actually going Degraded, or a sync actually failing, with the Discord message observed. |
| Discord: `KubeJobFailed` (covers Renovate's own CronJob) | **CONFIGURED-BUT-UNPROVEN** | Same Alertmanager route/matcher/receiver as the proven `KubePodCrashLooping` alert (literally the same regex, same receiver), but this specific alertname was never individually fired. | A real Job failure (or another synthetic alert with this exact alertname) reaching Discord. |
| Discord: `KubeNodeNotReady` | **CONFIGURED-BUT-UNPROVEN** | Same route as above, never individually fired. | A real node going NotReady (or a synthetic alert), confirmed in Discord. |
| Discord: `CertManagerCertExpirySoon` (warning tier) | **CONFIGURED-BUT-UNPROVEN** | Same route as above, never individually fired — and no cert is currently within the 7-day window to fire it naturally. | A real cert entering the 7-day expiry window, or a synthetic alert, confirmed in Discord. |
| Discord: `VeleroBackupPartialFailure` (warning tier) | **CONFIGURED-BUT-UNPROVEN** | Same route as above, never individually fired. | A real partial-failure backup, or a synthetic alert, confirmed in Discord. |
| Discord: `severity: critical` route (pre-existing) | **CONFIGURED-BUT-UNPROVEN, this session** | This is the *old* route, not new work — but it was never actually re-verified live this session. The synthetic test used `severity: warning` specifically to exercise the *new* route; the critical route's current behavior was only inferred from reading the Alertmanager config, not observed firing. | An actual `severity: critical` alert (or a synthetic one) reaching Discord, checked the same way the warning-tier one was. |
| Discord: `CertManagerCertNotReady` / `VeleroBackupFailed` (new, severity critical) | **CONFIGURED-BUT-UNPROVEN** | Rides the critical route above (also unproven this session) and was never individually fired either. | Both: a real event or synthetic alert, confirmed in Discord. |
| ArgoCD's own Prometheus metrics (app health/sync status) | **GAP** | `argocd-application-controller`'s metrics port (8082) isn't listening at all — confirmed live via `/proc/net/tcp`, survives a clean pod restart. Root cause not found. | Metrics port actually listening and scraped; not attempted further this session. |
| cert-manager metrics scraping | **PROVEN** | `ServiceMonitor` live, confirmed matching the live Service's port name/labels, endpoint responding. | — already proven |
| cert-manager renewal actually succeeding | **CONFIGURED-BUT-UNPROVEN** | Only 1 `CertificateRequest` (Revision 1) since 2026-06-03 — never actually auto-renewed. `renewalTime` is ~4 weeks out. | The wildcard cert's `CertificateRequest` count going to 2, i.e. an actual renewal happening, checked around 2026-08-02. |
| DNS: `home.lan` answered locally by unbound | **PROVEN** | Before: `dig` showed real root-server recursion (`AUTHORITY SECTION: SOA a.root-servers.net`), 14ms. After the playbook ran against both RPi nodes: `aa` flag (authoritative), zero recursion, **0ms**, on both `rpi-srv-01` and `rpi-srv-02`. | — already proven |
| DNS: `ptbtime{1,2,3}.ptb.de` answered from local cache | **PROVEN** | Before: real upstream-sourced answer, TTL 14400, 40ms. After: answer from `local-data` (TTL 3600, `aa` flag set), **0ms**. | — already proven |
| DNS: DHCP `home.lan` domain actually cleared at the source | **GAP / inconclusive** | Merged `domain = ""` (#318) and triggered a real Atlantis plan against live router state (PR #321): **zero diff** for the DHCP resources — only an unrelated SNMP password drift showed up. This contradicts the original live evidence (`networkctl status` showing `home.lan` delivered via DHCP) and hasn't been reconciled. Either the fix doesn't target the real source, or the provider normalizes `""`/unset and can't actually detect-and-clear a real value. **Not applied — unresolved, needs more investigation before trusting this layer.** | Root-causing the plan/live discrepancy, then a real Atlantis apply followed by a fresh DHCP lease on a test host actually dropping `home.lan` from its search domains. |
| DNS: overall query volume actually drops | **UNPROVEN, explicitly not to be called resolved yet** | Both unbound-side fixes are live and individually proven (above). But the stated success criteria (7d query volume down substantially, NXDOMAIN rate for `*.home.lan` near zero, unbound avg response well under 341ms, NTP hostname queries near zero) require real AdGuard query-log data over the next several days, not an immediate check. | AdGuard's own 7d query-volume and avg-response-time stats actually dropping, checked in a few days — not before. |
| Velero backup scheduling | **PROVEN** | 23+ days of schedule history, confirmed via `kubectl get backups.velero.io`. | — already proven |
| Velero backup *completion* reliability | **GAP** | 2 of the last 5 daily backups actually **failed** (`phase: Failed`, Garage `HeadObject` timeout) — unexplained ~40% recent failure rate, separate from the already-fixed REL-019 issue. | Root-causing the Garage timeout; a subsequent clean run of 5/5 successful backups. |
| Velero *restore* capability | **GAP** | `kubectl get restores.velero.io -A`: zero results, ever, cluster-wide. Never tested. Still the single biggest gap in the whole autonomy picture. | An actual test restore performed and verified. |
| PBS (hypervisor-level) backup + restore | **PROVEN** | REL-052 (prior session): real restore of the Atlantis LXC from a PBS backup to a scratch VMID, booted clean, data intact, verified end-to-end. Different system from Velero — don't conflate. | — already proven |
| ArgoCD selfHeal | **PROVEN** | All 41 live Applications confirmed `syncPolicy.automated.selfHeal: true`, checked programmatically, zero exceptions. | — already proven |
| Usenet acquisition pipeline (NZBHydra2→SABnzbd→Sonarr/Radarr) | **PROVEN** | Real history evidence: Sonarr grabbed GoT S01 05:37 on 2026-07-05, all 10 episodes imported by 06:32 same day, unattended. Radarr same pattern. RSS sync confirmed on a 15-min timer. | — already proven |
| Media stack autoheal (crash/hang recovery) | **PROVEN (prior session, REL-032)** | Docker healthchecks + `autoheal` sidecar + queue watchdog, verified working during the 2026-07-01/02 incident sweep. Not re-verified live this pass. | — already proven, aging evidence |
| Jellyfin library auto-refresh on new import | **CONFIGURED-BUT-UNPROVEN** | Zero Sonarr/Radarr→Jellyfin webhook notifications configured — relies entirely on Jellyfin's own realtime filesystem monitor (on by default, no override found disabling it). No API-confirmed timestamp obtained. | A real import's timestamp cross-checked against Jellyfin picking up the file, or an accessible API key to query it directly. |
| Immich background job processing (thumbnails, ML, checksum) | **PROVEN** | Real log entry confirming an unattended scheduled job completed (`Finished checksum job, covered all assets`, ~7h old at check time). | — already proven |
| Immich photo upload/backup | **Not applicable to server-side verification** | Client-triggered (mobile app background upload) — inherently outside what can be verified from the server side. | n/a |
| Minecraft container auto-restart | **PROVEN** | `restart: unless-stopped` confirmed in the Ansible role and live on both running containers. | — already proven |
| Minecraft backup coverage | **PROVEN (prior session)** | Confirmed via PBS nightly backup in an earlier pass. Not re-verified live this pass. | — already proven, aging evidence |
| Minecraft — full fleet accounted for | **GAP (verification gap)** | Only 2 of a previously-referenced "4 servers" were found running on the games host. Other 2 not chased down. | Locating and checking the other 2, or confirming "4" was stale. |
| playit.gg tunnel reconnect behavior | **GAP (verification gap)** | No container matching that name found on the games host this pass — reconnect behavior unconfirmed. | Finding the actual tunnel process and observing a reconnect. |
| Backup circular dependency (Garage backs up into itself) | **Known, accepted risk — not touched** | REL-003 (skip-list, architectural). Confirmed live: Velero's `includedNamespaces: ["*"]` includes `garage` itself — the reason a from-scratch cluster recovery can't currently bootstrap cleanly. | Not in scope for PROVEN/GAP — architectural decision pending a design session. |

## Bottom line

Fewer green rows than the previous version of this table, on purpose — that version
conflated "the route exists and one alertname in it was tested" with "this alertname
is proven," and conflated "merged" with "demonstrated." Real state: **2 of ~9 Discord
alert paths have an actual observed event** (`KubePodCrashLooping`, ArgoCD
`sync-status-unknown`); the rest share proven plumbing but haven't individually fired.
Renovate's new tiering has never auto-merged anything — the 2 PRs that merged today
were merged by hand. Both unbound DNS fixes are genuinely proven at the unbound layer
(0ms local answers, confirmed before/after) — but the DHCP-side companion fix (#318)
turned up a real, unresolved discrepancy between the merged code and what the live
router's plan shows, and the actual query-volume-drop success criteria can't be
confirmed for days regardless. Velero restore is still the single biggest untested
assumption in the whole stack.
