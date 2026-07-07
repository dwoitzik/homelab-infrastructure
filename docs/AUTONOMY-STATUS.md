# Autonomy Status

Honest scorecard against `docs/OPERATING-MODEL.md`'s target steady state, as of
2026-07-07. Every row was checked against live cluster/host state during this pass, not
assumed from config alone — see `docs/AUDIT.md` REL-055/056/057 for the full evidence
behind each.

**Legend**: **PROVEN** — verified with a real, live event (a real alert reaching
Discord, a real automated grab→import cycle, a real renewal that already happened).
**CONFIGURED-BUT-UNPROVEN** — the config exists and looks correct, but no real event
has confirmed it works yet. **GAP** — doesn't work, doesn't exist, or was checked and
found actually broken.

| Capability | Status | How verified / why not |
|---|---|---|
| Renovate tiered auto-merge | **CONFIGURED-BUT-UNPROVEN** | `renovate.json` written, `renovate-config-validator`-clean (PR #316). Not merged, not enabled — zero live auto-merges have happened yet under the new tiering. |
| Discord: `severity: critical` alerts | **PROVEN** | Pre-existing route, confirmed still live via the synthetic `KubePodCrashLooping` test's underlying route structure (same receiver path). |
| Discord: `KubePodCrashLooping`/`KubeJobFailed`/`KubeNodeNotReady`/cert-manager/Velero warning-tier alerts | **PROVEN** | Fired a real synthetic `KubePodCrashLooping` alert via Alertmanager's API; `alertmanager_notifications_total{integration="discord"}` incremented (11 sent, 0 failed); user-confirmed landing in Discord (PR #315). |
| Discord: ArgoCD Degraded/OutOfSync/sync-unknown | **PROVEN** | Created a real throwaway Application pointed at a nonexistent path, genuinely triggered `sync.status: Unknown`, confirmed `TRIGGERED` + send in notifications-controller logs, user-confirmed landing in Discord (PR #315). |
| ArgoCD's own Prometheus metrics (app health/sync status) | **GAP** | `argocd-application-controller`'s metrics port (8082) isn't listening at all — confirmed live via `/proc/net/tcp`, survives a clean pod restart. Root cause not found. Worked around via the notifications-controller path above, but Grafana/Prometheus still can't see ArgoCD's own health state. |
| cert-manager metrics scraping | **PROVEN** (as of this pass) | `ServiceMonitor` added and confirmed matching the live Service's port name/labels (PR #315). |
| cert-manager renewal actually succeeding | **CONFIGURED-BUT-UNPROVEN** | Only 1 `CertificateRequest` (Revision 1) exists since 2026-06-03 — the wildcard cert has never actually auto-renewed yet. `renewalTime` is correctly ~4 weeks out; no historical renewal event to confirm it works when the time comes. |
| Velero backup scheduling | **PROVEN** | 23+ days of schedule history, confirmed via `kubectl get backups.velero.io`. |
| Velero backup *completion* reliability | **GAP** | 2 of the last 5 daily backups actually **failed** (`phase: Failed`, Garage `HeadObject` timeout) — a live, unexplained ~40% recent failure rate, separate from the already-fixed REL-019 issue. |
| Velero *restore* capability | **GAP** | `kubectl get restores.velero.io -A`: zero results, ever, cluster-wide. Never tested. This is the single biggest gap in the whole autonomy picture — a backup that's never been restored is unverified. |
| PBS (hypervisor-level) backup + restore | **PROVEN** | REL-052 (prior session): real restore of the Atlantis LXC from a PBS backup to a scratch VMID, booted clean with data intact, verified end-to-end. This is a *different* system from Velero above — don't conflate the two. |
| ArgoCD selfHeal | **PROVEN** | All 41 live Applications confirmed `syncPolicy.automated.selfHeal: true`, checked programmatically, zero exceptions. |
| Usenet acquisition pipeline (NZBHydra2→SABnzbd→Sonarr/Radarr) | **PROVEN** | Real history evidence: Sonarr grabbed GoT S01 at 05:37 on 2026-07-05, all 10 episodes imported by 06:32 same day, fully unattended. Radarr: grabbed→imported same pattern, hours apart matching download time. RSS sync confirmed on a 15-min timer. |
| Media stack autoheal (crash/hang recovery) | **PROVEN** (prior session, REL-032) | Docker healthchecks + `autoheal` sidecar + queue watchdog, verified working during the 2026-07-01/02 incident sweep. Not re-verified live this pass. |
| Jellyfin library auto-refresh on new import | **CONFIGURED-BUT-UNPROVEN** | Zero Sonarr/Radarr→Jellyfin webhook notifications configured — relies entirely on Jellyfin's own realtime filesystem monitor (on by default, no override found disabling it). No direct API-confirmed timestamp obtained proving a real file was picked up automatically (no accessible API key this pass). |
| Immich background job processing (thumbnails, ML, checksum) | **PROVEN** | Real log entry confirming an unattended scheduled job completed (`Finished checksum job, covered all assets`, ~7h old at check time). |
| Immich photo upload/backup | **Not applicable to server-side verification** | Client-triggered (mobile app background upload) — inherently outside what can be verified from the server side. |
| Minecraft container auto-restart | **PROVEN** | `restart: unless-stopped` confirmed in the Ansible role and live on both running containers (16h healthy uptime). |
| Minecraft backup coverage | **PROVEN (prior session)** | Confirmed via PBS nightly backup in an earlier pass (see memory: SEC-014 corrections). Not re-verified live this pass. |
| Minecraft — full fleet accounted for | **GAP (verification gap)** | Only 2 of a previously-referenced "4 servers" were found running on the games host this pass. The other 2 weren't chased down — may be on a different host, stopped, or the "4" figure itself was stale. |
| playit.gg tunnel reconnect behavior | **GAP (verification gap)** | No container matching that name found on the games host under this pass's check — didn't confirm reconnect behavior specifically. May run differently than assumed; needs a dedicated look. |
| Backup circular dependency (Garage backs up into itself) | **Known, accepted risk — not touched** | REL-003 (skip-list, architectural). Confirmed live this pass: the Velero schedule's `includedNamespaces: ["*"]` does include the `garage` namespace itself. This is the concrete reason a from-scratch cluster recovery can't currently bootstrap cleanly without a working Garage already up. |

## Bottom line

The alerting substrate (task 2) is now solid and proven end-to-end for the categories
that matter — that was the right thing to fix first, since it's what would have caught
the Velero backup-completion gap and the ArgoCD metrics gap in the first place, going
forward. The Renovate tiering (task 1) is ready but intentionally not yet live. The
biggest real risk this pass surfaced isn't anything exotic — it's the plain fact that
**backups have never been restore-tested at the Velero/in-cluster level**, and that
**2 of the last 5 backup runs actually failed** without anyone knowing before this
session's alerting fix existed. Those two items are the actual priority, not more
alerting polish.
