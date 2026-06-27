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
| Node      | Spec                                                   | Role                                  |
|-----------|--------------------------------------------------------|---------------------------------------|
| `mini`    | Ryzen 7 5825U (8C/16T, VCN HW-transcode), 64 GB, 512 GB SSD | Proxmox host / primary workloads + storage |
| `rpi1`    | RPi 4B, 8 GB RAM, 128 GB SD                             | lightweight node                      |
| `rpi2`    | RPi 4B, 8 GB RAM, 128 GB SD                             | lightweight node                      |
| network   | MikroTik RB5009                                         | router / L3                           |
| bulk      | 2 TB HDD via USB (on `mini`)                            | backup (Garage) + Jellyfin media      |
| usb-immich | SanDisk 3.2Gen1, 460 GB USB stick                     | Immich photo library (NFS via LXC 220) |

### Hard storage rules (this caused real host freezes — do not regress)
- The **only reliable disk is the 512 GB SSD** on `mini`. All critical persistent state
  (Longhorn replicas, Immich Postgres, Vaultwarden DB) lives there.
- **Never** place stateful PVs, etcd, or databases on USB-attached storage or SD cards.
  USB IO contention previously froze the host — do not reintroduce that failure mode.
- The 2 TB USB HDD is for **backup (Garage) and Jellyfin media** (large sequential data, slow is fine).
- The SanDisk 3.2Gen1 USB stick (460 GB) is for **Immich photo library** — write-once/read-many workload suits USB flash; benchmarked at ~149 MB/s read / ~73 MB/s write, no errors detected. Databases must NOT go here.
- RPi SD cards are write-fragile. Keep etcd/SQLite and heavy logging off them; prefer
  USB-SSD boot where possible. Treat RPi nodes as disposable.

### Topology reality
- `mini` is a **single point of failure**. Zero-downtime HA is NOT achievable with this
  hardware — do not pretend otherwise or build configs that imply it.
- Target **recovery, not HA**: define and document RTO/RPO and make every component
  restorable from Git + backups. A full rebuild from a bare host must be a documented,
  tested procedure.
- HW transcoding (Jellyfin) and ML (Immich) run on `mini` (the APU). Never schedule them
  on RPi nodes.

## Stack (confirmed — do NOT "correct" these)
K3s · ArgoCD (app-of-apps GitOps) · Longhorn (storage) · Traefik (ingress) · MetalLB (LB) ·
cert-manager · Authelia (auth) · Vaultwarden. Terraform via **Atlantis** (PR-driven
plan/apply). Object storage via **Garage** (NOT MinIO). Secrets via **Ansible Vault** +
Kubernetes Secrets.

## Target useful workloads
Jellyfin, Immich, Minecraft server — each fully GitOps-managed, backed up, and documented.
Real daily usefulness is a first-class goal, not just demo cleanliness.

## Guardrails (non-negotiable)
1. **Snapshot before any change that can affect running state.** Proxmox VM/CT snapshot
   (or Longhorn snapshot for PV-level changes) *before* apply. If you can't snapshot, stop and ask.
2. **Never push secrets.** `gitleaks` must pass. Secrets only via the existing Ansible Vault
   mechanism. If you find a leaked secret in history, flag it — do not silently rewrite history.
3. **Branch + PR workflow.** Never commit directly to `main`. One concern per branch/PR.
   Let CI (and Atlantis for Terraform) run before merge.
4. **Validate before apply.** TF: `terraform validate` + `tflint` + `tfsec`/`checkov`.
   Manifests: `kubeconform` / `kubectl --dry-run`. Playbooks: `ansible-lint`.
   Plus `yamllint` + `markdownlint`. A change that fails linting is not done.
5. **ArgoCD safety.** Assume auto-sync may be on — a merged manifest deploys itself, so
   treat merge as deploy. For stateful apps (Vaultwarden, Immich Postgres, Longhorn) take a
   **data backup** before changing anything that touches their volumes or schema.
6. **Reversibility.** Never perform an action you cannot undo from snapshot/backup/Git.
   Destructive ops (PV delete, namespace delete, `terraform destroy`) require explicit human
   confirmation in the PR.
7. **Conventional Commits** + meaningful PR descriptions (what, why, blast radius, rollback steps).

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
