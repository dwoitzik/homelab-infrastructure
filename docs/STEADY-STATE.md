# Steady state

This document marks the end of active recovery mode. The cluster was rebuilt from a
real disaster (`DISASTER-RECOVERY.md`, `phase8/LEDGER.md`) and has since been hardened,
audited, and given real self-checking mechanisms. This is what "done" looks like day to
day: what runs itself, what still needs a human, what the alerts mean, and the rhythm
that keeps it that way.

## What runs itself

### GitOps and deployment

- ArgoCD (`kubernetes/apps/*` via the `homelab-apps` ApplicationSet, plus standalone
  system Applications) reconciles every merge to `main` automatically, `selfHeal: true`
  reverts live drift back to git for anything it manages.
- Renovate opens dependency-update PRs on its own schedule. CI runs on every PR;
  merging is a human decision (see below), but the PR itself needs no manual creation.
- The GitHub Actions self-hosted runner (`ct-srv-atlantis-01`, ADR-021) handles
  Terraform plan on PR comment (`atlantis plan -d <stack>`) automatically.

### Backups

- Velero: daily backup to Garage (in-cluster S3) + daily offsite to Cloudflare R2, with
  `r2-usage-guard` automatically pausing the offsite leg before hitting R2's free-tier
  cap rather than failing loudly or running up a bill.
- PBS/`vzdump`: host-level VM/LXC backup, every 2 nights (throttled, `bwlimit`/`ionice`
  tuned to not compete with foreground I/O).
- CNPG `ScheduledBackup`s for every Postgres cluster (`authelia`, `n8n`, `synapse`,
  `firefly`) to Garage via WAL-G.
- A monthly `monthly-restore-test` CronJob actually exercises a Velero restore, not
  just confirms a backup file exists.

### Certificates and secrets

- cert-manager renews the wildcard cert automatically via Let's Encrypt DNS-01
  (Cloudflare). No manual renewal step exists or should ever be needed.
- External Secrets Operator syncs from Vault into Kubernetes Secrets on a refresh
  interval — editing a value in Vault propagates without a redeploy.

### Monitoring and self-checking

- Prometheus/Alertmanager/Grafana: metrics, alerting rules, dashboards.
- The dead man's switch (`kubernetes/system/monitoring/dead-mans-switch.yml`) pings
  healthchecks.io every 5 minutes — if the *entire monitoring stack* goes silent, this
  is the one thing that can still page from outside.
- The declared-vs-live drift guard (`.github/workflows/drift-check.yml`, ADR-027) runs
  every 30 minutes, comparing every standalone manifest under `kubernetes/system/`
  against the live cluster and alerting if something merged to git was never actually
  applied — built after this exact gap took down the dead man's switch itself for
  days undetected.
- Blackbox external probing checks the 2 hostnames on ADR-019's public allowlist
  (`photos.woitzik.dev`, `headscale.woitzik.dev`) for real external reachability and
  TLS expiry. `mc.woitzik.dev` (Minecraft, via the playit.gg tunnel — a separate,
  non-Cloudflare exposure path) is the third genuinely public hostname but isn't
  probed by this job today. `claude.woitzik.dev`'s ADR-018 tunnel was applied once
  and destroyed by the very next apply (ADR-019); it has no public DNS record and no
  running `cloudflared` connector as of 2026-08-23 — corrected here after that stale
  claim was found and verified against live state.
- Weekly Discord self-report summarizes cluster health every Monday morning.
- kube-bench runs a CIS benchmark scan daily.
- trivy-operator scans for container vulnerabilities on image/workload changes.
- CrowdSec ingests community threat intelligence and auto-bans malicious IPs at the
  Traefik edge.

### Security enforcement

- Kyverno enforces resource limits, no-privileged-containers, and no-`:latest`-tags
  across every namespace it's staged into (see `kubernetes/system/kyverno/policies.yml`
  for the current per-namespace enforcement map).
- Pod Security Standards labels enforce `baseline`/`restricted` per namespace.
- NetworkPolicy default-deny egress now covers every namespace with a meaningful
  traffic pattern, including `apps` (the last one, closed 2026-08-23) — a compromised
  pod can't freely reach arbitrary internal services or exfiltrate over an unexpected
  port.
- On this control host (not the cluster): a `PreToolUse` hook
  (`~/.claude/hooks/deny-credential-read.sh`, ADR-028) mechanically blocks any command
  that would print a credential file's raw content — SSH keys, the Ansible Vault
  password file, `~/.kube/config`, and more. Six real secret-exposure incidents this
  mission all followed the same shape (a legitimate debugging step landing on a file
  that happened to hold a live credential); this closes that shape by design rather
  than by an agent remembering a rule.

## What the operator must still do by hand

- **Merge PRs.** `gh auth` now works on this box (fixed 2026-08-23 — it was a broken
  `HOME` env var / gh CLI state issue, not a missing credential), so an agent session
  can merge routine PRs going forward. Major version bumps and anything touching a
  stateful service's data model (a Renovate major, a schema-affecting change) still
  deserve a human's read before merging, not a blind auto-merge.
- **`atlantis apply` comments** for any Terraform PR that's actually supposed to take
  effect — plan runs automatically, apply is a deliberate PR-comment trigger by design
  (never automatic, per `ADR-021`).
- **Rotate the 3 GitHub PATs** that appeared in an agent's tool output on 2026-08-23
  (a debugging mistake, not a network exposure, but per this mission's own standing
  rule any such appearance is treated as compromised). `~/.config/gh/hosts.yml` itself
  is gone now (ADR-028 — `GH_TOKEN` is sourced from a dedicated 0600 file instead), but
  the active `dwoitzik` token's *value* is unchanged, just relocated to
  `/root/.secrets/gh_token` — rotating it is still real, not done by the design fix
  alone. Not urgent-critical (no evidence of misuse), but real.
- **Decide the disposal of 3 flagged-for-review credentials** in
  `/root/.secrets/flagged-for-review/` (a Proxmox API token, a GitHub PAT, a Vault
  session token — found loose on disk during ADR-028's sweep, moved somewhere
  mechanically protected rather than deleted unverified). See
  `phase8/QUESTIONS.md`'s 2026-08-23 entry for what each needs.
- **Fix the `fwd_04a_srv_monitoring` MikroTik/Terraform-state gap** — blocks
  `node-exporter-pve` from reaching Prometheus, which means NVMe wear alerts and host
  power/thermal metrics exist as code but don't actually fire yet. Needs real
  MikroTik/Terraform state-import time, not urgent but real (`docs/ROADMAP.md` has the
  full trigger condition).
- **CIS kubelet file-permission findings (4.1.3-4.1.8)** — plain `chmod`/`chown` on
  each k3s VM, no restart needed, just needs someone with real SSH access to those VMs
  (this agent's key was only ever deployed to `pve`/`rpi-srv-01`/`rpi-srv-02`/GitHub).
  Exact commands in `docs/RUNBOOK-maintenance-window-restart-batch.md`'s final section.
- **A cluster-admin/wildcard RBAC audit** (CIS 5.1.1/5.1.3) — needs dedicated review
  time to distinguish genuine need from copy-pasted-too-broad, not something to rush.
- **Watch SSD wear monthly** — real trigger conditions in `docs/HARDWARE.md`
  (warning at 80% used, replace-now at 90% or any media error). Currently 56%,
  projected to reach 90% somewhere between late September and mid-November 2026
  depending on how much of the recent rate was recovery-mission-specific load.
- ~~The `postgres-cluster` ArgoCD Application sync-loop bug~~ — **fixed 2026-08-23**:
  root-caused via CNPG's own operator logs — it deletes any PodMonitor matching its
  Cluster's own *name* on every reconcile when `monitoring.enablePodMonitor: false`,
  regardless of who created it or what labels it carries. Renamed the git-managed
  PodMonitor to `postgres-authelia-metrics` (Prometheus selects by label, unaffected
  by the object's own name) and confirmed it survives multiple CNPG reconcile cycles
  with zero further deletions.

## What the alerts mean

| Alert / signal | What it means | Urgency |
|---|---|---|
| healthchecks.io silence (dead man's switch) | The *entire* monitoring stack, or the cluster itself, is down — nothing else could page | Immediate — this is the last line of defense |
| `drift-check` workflow failure (GitHub Actions, every 30 min) | Something declared in `kubernetes/system/` isn't actually live | Same day — re-run `kubectl apply` on the named file, or investigate why it won't apply |
| `ExternalProbeFailed` (blackbox) | One of the 2 allowlisted public hostnames is unreachable from outside | Same day — check Cloudflare Tunnel + the backing service |
| `TLSCertExpiringImminent` | A cert is under 3 days from expiry and cert-manager hasn't renewed it | Immediate — renewal should be automatic; if this fires, automatic renewal already failed |
| `NVMeWearWarning`/`Critical` | SSD wear crossed 80%/90% (not live yet — see the firewall gap above) | Warning: plan a replacement. Critical: replace now |
| `ProxmoxHostHighTemp` | Host CPU/NVMe temp crossed 85°C | Same day — check for a stuck process, thermal paste isn't the first suspect on a cool-running host like this |
| CrowdSec ban spike (Homepage widget / Discord) | Real attack traffic being blocked at the edge | Informational unless the volume itself is unusual for this network |
| Weekly Discord report | Routine health summary | Not an alert — read it, don't panic about it |
| `r2-usage-guard` pause | Offsite backup approaching R2's free-tier cap, paused itself rather than risk a bill | Informational — offsite backup resumes automatically once usage drops (rolling window) |
| Renovate PR opened | A dependency has a new version | Not urgent — review on the normal cadence below, not same-day |

## Rhythm

### Monthly

- Review the `monthly-restore-test` CronJob's actual result, not just that it ran —
  confirm the restored data was real and complete, not just "exit 0."
- Check SSD wear (`smartctl -a /dev/nvme0n1` on `pve-mgmt-01`, or the Grafana dashboard
  once the firewall gap above is fixed) against the replacement trigger.
- Clear the Renovate PR backlog — merge what's safe, investigate anything held back
  (a major version, a stateful-service bump) rather than letting it silently age.

### Quarterly

- **A real DR game day.** Not a read-through of `DISASTER-RECOVERY.md` — actually
  restore something (a PVC, a VM from PBS, a CNPG cluster from WAL-G) to a scratch
  target and confirm the procedure still matches reality. The 2026-08-13 rebuild
  proved the full procedure once under real pressure; a quarterly partial exercise is
  what keeps it trustworthy between real incidents.
- **Dependency review** beyond Renovate's own PRs — anything Renovate doesn't track
  (base OS packages, Ansible collections, Terraform providers) and a look at whether
  any pinned version has a known CVE with no update path yet.
- **Re-read this document and `docs/ROADMAP.md`'s open items** — confirm the "what
  still needs a human" list above hasn't quietly grown stale in either direction (an
  item fixed and not removed, or a new gap that opened and was never added).

## What ends here

This document is what "recovery mode" was building toward: a cluster that
self-heals its declared state, backs itself up on a real tested rhythm, alerts on its
own silence, and has a documented, previously-executed path back from nothing. The
work from here is steady-state operation — the monthly/quarterly rhythm above, plus
whatever real feature or hardening work comes up — not disaster recovery.
