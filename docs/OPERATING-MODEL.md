# Operating Model

The target steady state for this homelab: it should run for weeks without anyone
touching it, and when something does need attention, it should say so in Discord
rather than being discovered by a user noticing a service is broken. This document is
the contract — what's supposed to auto-update, what's supposed to alert, what's
supposed to self-heal, and what's deliberately left manual because automating it would
be riskier than the manual step. `docs/AUTONOMY-STATUS.md` is the honest scorecard
against this contract (proven vs. configured-but-unproven vs. gap); this document is
the target, that one is the current reality.

## What auto-updates

Renovate (`renovate.json`), scheduled every 2 hours (`kubernetes/apps/renovate/`):

- **Auto-merges** (patch/minor/digest only, after CI-green + a 3-day soak): stateless
  kubernetes-managed images, CI GitHub Actions, dev tooling (pre-commit hooks,
  Terraform providers).
- **PR-only, always** (every update type including patch/minor, not just major): a
  named list of stateful/critical services — databases, Vault, Authelia, Garage,
  Vaultwarden, and apps whose upgrades need a manual data migration (Nextcloud,
  Paperless, Immich, Gitea) or whose breakage silently takes out backups (Velero's own
  plugin). See `docs/AUDIT.md` REL-056 for the full list and the judgment calls behind
  it.
- **PR-only, always**: every major-version bump, any package, regardless of tier.

Terraform is **not** auto-applied by Renovate or anything else — every Terraform
change, dependency bump or otherwise, goes through a PR and Atlantis's plan/apply gate
(`atlantis apply` comment required). This is deliberate: Terraform changes physical/VM
state on a single-point-of-failure host (`mini`), and that always gets a human in the
loop.

## What alerts, and where

Prometheus + Alertmanager → Discord (`kubernetes/system/monitoring/`), plus ArgoCD's
own notifications-controller → the same Discord channel via a separate path
(`kubernetes/system/argocd/argocd-notifications-cm.yml`) for app-state events that
Prometheus can't currently see (see REL-055 for why ArgoCD's own metrics port doesn't
work and this pivot was necessary).

Routed to Discord today:

- Everything `severity: critical` (Proxmox/RPi host temp, control-plane down, storage
  >93% full, Postgres-alert critical tier, `CertManagerCertNotReady`,
  `VeleroBackupFailed`).
- Explicitly named `severity: warning` alerts that matter at steady-state:
  `KubePodCrashLooping`, `KubeJobFailed` (covers Renovate's own CronJob failing),
  `KubeNodeNotReady`, `CertManagerCertExpirySoon`, `VeleroBackupPartialFailure`.
- ArgoCD `on-health-degraded`, `on-sync-failed`, `on-sync-status-unknown` — for every
  Application, via ArgoCD's own default-subscription mechanism, no per-app annotation
  needed.

Deliberately **not** routed: routine `severity: warning` noise
(`KubeMemoryQuotaOvercommit` and similar) that would make Discord noisy without being
actionable at steady state.

See `docs/STEADY-STATE-RUNBOOK.md` for what to actually do when each of these fires.

## What self-heals

- **ArgoCD**: `syncPolicy.automated.selfHeal: true` on all 41 live Applications — a
  merged manifest change deploys itself, and manual `kubectl` drift on anything ArgoCD
  tracks gets reverted automatically. Treat every merge to `main` as a deploy.
- **Docker containers** (media stack, Minecraft, AdGuard/unbound, etc.):
  `restart: unless-stopped` — crashes and host reboots self-recover the process, not
  the data.
- **Media acquisition** (`ansible/roles/media_acquisition/`): Docker healthchecks + an
  `autoheal` sidecar force-restart anything Docker marks unhealthy; a queue watchdog
  cron clears stuck Sonarr/Radarr queue items every 10 minutes.
- **Kyverno** runs in Audit mode only — it reports policy violations, it does not
  block or auto-remediate. This is deliberate, not a gap: enforcement mode on a
  single-operator homelab risks a bad policy silently blocking a legitimate deploy with
  no one around to notice quickly.

## What stays manual, on purpose

- **Terraform apply** — always through Atlantis, a human comments `atlantis apply`.
  Never auto-applied, regardless of what changed.
- **Stateful/critical service bumps** (Renovate PR-only tier above) — always reviewed
  before merge, because the failure mode for these is data loss or a full auth outage,
  not "reroll the pod."
- **Snapshots before any state-affecting change** — Proxmox VM/CT snapshot or Longhorn/
  PV snapshot, taken by a human before applying anything that touches running state.
  Not automated, because the judgment of "is this change state-affecting" doesn't
  belong to a script.
- **Velero restore** — running, but **never actually exercised** as of this writing
  (see `docs/AUDIT.md` REL-057). This is the single most important unproven item in
  the whole autonomy picture: a backup schedule that's never been restore-tested is a
  hope, not a guarantee. Fixing this is a manual, deliberate DR-drill task, not
  something to automate blindly.
- **Full cluster rebuild from bare metal** — documented in `DISASTER-RECOVERY.md`, not
  automated. `mini` is a single point of failure by hardware design (see
  `CLAUDE.local.md`); the target is fast, well-documented *recovery*, not zero-touch
  *failover*, because true HA isn't achievable on this hardware.

## Non-goals

- **Zero-downtime HA.** Not achievable with one physical host. Not attempted.
- **Fully unattended major-version upgrades** for stateful services. These have
  repeatedly needed a human judgment call mid-migration (REL-028's PG18 mount-point
  gotcha, REL-029's capability-drop regression) — automating past that would trade a
  10-minute manual step for a much longer unattended-failure cleanup.
- **Alerting on everything.** Deliberately tuned to steady-state-relevant signals, not
  every possible Prometheus rule — an alert nobody acts on trains people to ignore
  Discord.
