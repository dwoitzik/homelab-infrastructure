# CLAUDE.md — homelab-infrastructure

## Purpose
This repository is the single source of truth for a GitOps-managed homelab. It also
serves as a **public portfolio artifact**: it is read by potential employers and
customers as evidence of Platform/SRE engineering practice. Every change must meet a
professional production bar — clean, reproducible, documented, and secure.

## Your role
You work as a Platform/SRE engineer on this repo. You may read, edit, commit, and push,
but **only** through the workflow and guardrails below. Optimize for reproducibility and
fast recovery, never clever one-offs. If a change cannot be expressed as code and
committed, it does not belong here.

## Hardware inventory — physical constraints (never design around hardware that doesn't exist)
**2026-08-17 correction**: this section previously described a single-host
`mini`/`rpi1`/`rpi2` topology that predates the current cluster entirely. The real
current topology (see `docs/compute-nodes.md` for the full authoritative breakdown):
one Proxmox host (`pve-mgmt-01`, SSH alias `pve`) runs both direct LXC workloads AND a
3-VM k3s cluster (`vm-srv-k3s-11/12/13`) on top of itself -- "primary workloads" mostly
means "k3s pods" now, not host-level Docker containers. Two Raspberry Pis run DNS
(AdGuard Home + Unbound, primary+replica).

**2026-08-23 correction**: an earlier session attempted (PR #463, referencing an
"ADR-022" that was never actually merged) to migrate Headscale off k3s onto
`rpi-srv-02` natively via Docker -- this line previously described that as done. It
wasn't: the attempt left a real, orphaned native Headscale container running on
`rpi-srv-02` with its own stale node registrations, decommissioned the same night
this correction was written (see `phase8/LEDGER.md`). Headscale runs on k3s
(`kubernetes/apps/headscale/`); `rpi-srv-02` is instead a genuine HA exit-node
failover PEER of the k3s-hosted server via Tailscale (PR #544, `ansible/roles/
tailscale`), not a replacement for it.

| Node | Spec | Role |
|---|---|---|
| `pve-mgmt-01` (`pve`) | Ryzen 7 5825U (8C/16T, VCN HW-transcode), 64 GB, 512 GB NVMe | Proxmox host -- LXCs + 3-VM k3s cluster |
| `rpi-srv-01` | RPi 4B, 8 GB RAM, SD card (10.0.20.2) | AdGuard Home + Unbound (primary DNS) |
| `rpi-srv-02` | RPi 4B, 8 GB RAM, SD card + 111.8GB USB SSD (10.0.20.3) | AdGuard Home + Unbound (replica) + Tailscale HA exit-node failover peer |
| network | MikroTik RB5009 | router / L3 |
| bulk | 2 TB HDD via USB (on `pve-mgmt-01`, ZFS pool `archive`) | backup (Garage/PBS) + Jellyfin media |

### Hard storage rules (this caused real host freezes — do not regress)
- The **only reliable disk is the 512 GB NVMe** (`local-lvm` thin pool) on
  `pve-mgmt-01`. All critical persistent state lives there or on the `nfs-client`
  StorageClass backed by it. This cluster does NOT run Longhorn -- the two
  StorageClasses actually in use are `local-path` (node-local, default) and
  `nfs-client` (via `ct-srv-nfs-01`); do not write playbooks/docs assuming Longhorn
  exists.
- **Never** place stateful PVs or databases on USB-attached storage or SD cards. USB IO
  contention previously froze the host -- do not reintroduce that failure mode. The
  `local-lvm` thin pool has also independently caused host crashes from `discard=off`
  block accumulation (see `phase8/LEDGER.md` Entries 6-8) -- a distinct, already-
  documented failure mode from the USB-contention one.
- The 2 TB USB HDD (ZFS `archive` pool) is for **backup (Garage/PBS) and Jellyfin
  media** (large sequential data, slow is fine).
- RPi SD cards are write-fragile. Keep databases and heavy logging off them; prefer
  attached-SSD storage where available (as done for Headscale on `rpi-srv-02`).

### Topology reality
- `pve-mgmt-01` is a **single point of failure** for everything, including all 3 k3s
  VMs (they're all guests on this one host). Zero-downtime HA is NOT achievable with
  this hardware -- do not pretend otherwise or build configs that imply it.
- Target **recovery, not HA**: define and document RTO/RPO and make every component
  restorable from Git + backups. A full rebuild from a bare host must be a documented,
  tested procedure.
- **One narrow, deliberate exception (2026-08-27, ADR-029)**: headscale and
  vaultwarden have a **warm standby** on `rpi-srv-02` -- Litestream WAL
  streaming (RPO: seconds) plus a manual, documented failover
  (`docs/runbooks/failover-headscale-vaultwarden.md`, RTO: minutes). Still
  not zero-downtime/automatic failover -- a human runs the runbook, on
  purpose, to avoid split-brain on hardware this small. Every other
  component is still "recovery, not HA" as stated above; this is not a
  precedent for auto-failing-over anything else without the same
  single-writer-by-construction reasoning ADR-029 lays out.
- HW transcoding (Jellyfin) and ML (Immich) run on `pve-mgmt-01` (the APU, via LXC/k3s
  GPU passthrough). Never schedule them on RPi nodes.

## Stack (confirmed — do NOT "correct" these)
K3s (SQLite/kine datastore, not etcd -- see ADR-015) · ArgoCD (app-of-apps GitOps) ·
`local-path`/`nfs-client` storage (NOT Longhorn) · Traefik (ingress) · MetalLB (LB) ·
cert-manager · Authelia (auth) · Vaultwarden. Terraform via **Atlantis** (PR-driven
plan/apply). Object storage via **Garage** (NOT MinIO). Secrets via **Ansible Vault** +
Kubernetes Secrets.

## Target useful workloads
Jellyfin, Immich, Minecraft server — each fully GitOps-managed, backed up, and documented.
Real daily usefulness is a first-class goal, not just demo cleanliness.

## Guardrails (non-negotiable)
1. **Snapshot before any change that can affect running state.** Proxmox VM/CT snapshot
   (or a manual PVC data copy for PV-level changes -- this cluster has no snapshot-
   capable CSI driver, see the Hardware inventory section above) *before* apply. If
   you can't snapshot, stop and ask.
2. **Never push secrets.** `gitleaks` must pass. Secrets only via the existing Ansible Vault
   mechanism. If you find a leaked secret in history, flag it — do not silently rewrite history.
3. **Branch + PR workflow.** Never commit directly to `main`. One concern per branch/PR.
   Let CI (and Atlantis for Terraform) run before merge.
4. **Validate before apply.** TF: `terraform validate` + `tflint` + `tfsec`/`checkov`.
   Manifests: `kubeconform` / `kubectl --dry-run`. Playbooks: `ansible-lint`.
   Plus `yamllint` + `markdownlint`. A change that fails linting is not done.
5. **ArgoCD safety.** Assume auto-sync may be on — a merged manifest deploys itself, so
   treat merge as deploy. For stateful apps (Vaultwarden, Immich Postgres, Garage) take a
   **data backup** before changing anything that touches their volumes or schema.
6. **Reversibility.** Never perform an action you cannot undo from snapshot/backup/Git.
   Destructive ops (PV delete, namespace delete, `terraform destroy`) require explicit human
   confirmation in the PR.
7. **Conventional Commits** + meaningful PR descriptions (what, why, blast radius, rollback steps).

## Comment style (2026-08-20: stop doing this)
Recent commits piled dated, narrated investigation-diary comments into code
("2026-08-20: root-caused X, confirmed via Y, checked Z, here's the whole
story") -- multiple per file, sometimes 20%+ of a file's lines. Reads as
agent narration dumped into code, not engineering context a human would
leave. For a portfolio repo this is a liability, not a flex.

- Inline comments: one to three lines, WHY only (a non-obvious constraint,
  a workaround, a real gotcha). No dates, no "confirmed via", no step-by-
  step investigation replay.
- The investigation itself (what was tried, what was ruled out, evidence)
  belongs in `phase8/LEDGER.md` (already the append-only record) or, for
  anything that's a real decision future readers need, a proper ADR in
  `docs/decisions/`.
- PR descriptions carry the blast radius / rationale / rollback -- per
  guardrail 7 below. Don't duplicate that into the diff as a comment block.
- Before adding a comment, ask: would a human engineer, mid-incident, have
  written this exact thing in the code? If it reads like a changelog entry,
  it goes in the PR/ADR/LEDGER instead.
- This got violated again after being written, so it's mechanically
  enforced now too: `comment-narration-guard` (pre-commit hook,
  `scripts/check-comment-narration.py`) blocks dated or "confirmed via/live"
  comments in the staged diff. If it fires, rewrite the comment -- don't
  bypass the hook.

## Quality bar (portfolio repo)
- Every component has a README/runbook: what it is, how to deploy, how to restore, dependencies.
- Architecture documented with a Mermaid diagram kept in sync with reality.
- Decisions recorded as lightweight ADRs in `/docs/adr`.
- Pre-commit hooks enforce gitleaks + all linters locally.
- CI (GitHub Actions) runs lint + validate + plan on every PR; status must be green to merge.
- A top-level `DISASTER-RECOVERY.md` describes full-rebuild + per-service restore, kept current.

## Definition of done (every change)
Snapshot taken · code only (no manual drift) · gitleaks + linters green · validated/dry-run ·
docs + runbook updated · ADR added if it's a decision · PR states blast radius + rollback ·
backup taken if stateful.
