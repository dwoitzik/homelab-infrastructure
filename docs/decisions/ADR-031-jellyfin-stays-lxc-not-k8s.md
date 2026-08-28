# ADR-031: Jellyfin stays on a dedicated LXC, not migrated into k3s

**Date:** 2026-08-14
**Status:** Accepted (kept as-is, after genuine re-evaluation)

## Context

Phase 6 (`phase6/BRIEFING-V2.md` §4.2) explicitly revoked the previous session's
LXC-placement decisions as a given and asked for GPU passthrough in k8s to be tested
before deciding whether Jellyfin belongs in the cluster, rather than assumed.

Current state (confirmed live, not assumed from old docs): Jellyfin runs in a dedicated
LXC (`ct-srv-jellyfin-01`, 10.0.20.254) via Ansible/Docker Compose
(`ansible/roles/jellyfin`), reached from the cluster through a headless Service+Endpoints
(`kubernetes/apps/jellyfin/jellyfin.yml`) so Traefik's IngressRoute keeps working
unchanged. The repo's own inline note (`WRK-007`, cited in that manifest) already
recorded the reason: "the k3s Deployment had no GPU passthrough at all (pure software
transcode)". This ADR is that decision's first proper write-up, plus a genuine
re-check now that k8s GPU passthrough is back on the table by mandate.

## What was actually checked (not assumed)

- `mini` (`pve-mgmt-01`)'s iGPU: confirmed live via `lspci -k` — AMD Barcelo (Ryzen 7
  5825U's integrated Vega graphics + VCN video engine), kernel driver in use is
  `amdgpu`, **bound at the Proxmox host level**, not detached to `vfio-pci`.
  `docs/compute-nodes.md` independently confirms IOMMU is active
  (`amd_iommu=on iommu=pt`) specifically for "GPU passthrough to LXC".
- Current LXC passthrough mechanism: `/dev/dri/renderD128` is bind-mounted straight into
  the container (`ansible/roles/jellyfin/templates/docker-compose.yml.j2`). This works
  because an LXC shares the host's kernel — the host keeps the `amdgpu` driver and simply
  grants the container access to the resulting device node. Non-exclusive, low-risk,
  already proven working.
- k3s's own nodes (`vm-srv-k3s-11/12/13`) are **Proxmox VMs, not LXCs**
  (`docs/k3s-architecture.md`) — a fundamentally different kernel boundary. A VM does not
  share the host kernel, so there is no equivalent "just bind-mount the device node" path.
- Researched current (2026) Kubernetes GPU passthrough options for this hardware class:
  AMD's own device plugin / GPU Operator (`rocm/k8s-device-plugin`) target ROCm
  compute workloads (HIP/OpenCL) — a materially different, heavier stack than what VAAPI
  hardware transcoding actually needs. For VAAPI specifically, what a pod needs is just
  `/dev/dri` visibility, same as the LXC today — but that device only exists on a node
  if the node's kernel can see the GPU at all, which for a *VM* means genuine hypervisor
  passthrough (VFIO), not a Kubernetes-layer plugin.

## Decision

Keep Jellyfin on the dedicated LXC. Do not attempt to move GPU-accelerated transcoding
into the k3s cluster on this hardware.

## Reasons

- **The blocker is at the hypervisor layer, not the Kubernetes layer.** No Kubernetes
  device plugin changes the fact that `vm-srv-k3s-11/12/13` are VMs without GPU access.
  Getting a k3s pod real GPU access here would require classic VFIO passthrough of the
  iGPU to *one specific VM* — unbinding `amdgpu` from the Proxmox host and binding
  `vfio-pci` instead.
- **That would be exclusive, not shared.** This is a single consumer Ryzen APU, not a
  data-center part with SR-IOV/mediated-device support for splitting one GPU across
  multiple VMs. Passthrough would hand the entire GPU to exactly one of the three k3s
  VMs — the other two, and the Proxmox host itself, would permanently lose access to it.
  The host currently uses `amdgpu` itself (confirmed live); giving that up is a real,
  hard-to-reverse cost, not a free architectural upgrade.
- **No portability gain to offset that cost.** k3s's own scheduler can't move a pod that
  needs a passed-through GPU device to a *different* node than the one VFIO was bound
  to — the "GPU follows the pod" benefit people usually migrate into Kubernetes for
  doesn't materialize on a single-iGPU single-physical-host homelab. It would just be
  Jellyfin running with equivalent access, on a VM instead of an LXC, at the cost of the
  GPU being permanently unavailable to anything else.
- **Current setup already works and is genuinely lower-risk.** LXC device passthrough via
  a shared kernel doesn't require touching PCI device binding, doesn't risk losing the
  host's own display/telemetry access to the GPU, and is already proven live.

## Trade-offs (accepted)

- Jellyfin stays outside GitOps/ArgoCD, same pattern as Atlantis (ADR-012) and the media
  acquisition stack (ADR-010) — Ansible/Docker Compose-managed, not `kubectl`-managed.
  Consistent with this repo's existing precedent for workloads with a hardware or
  network-isolation requirement that doesn't fit cleanly into "everything is a pod."
- If this hardware is ever upgraded to something with proper GPU virtualization support
  (SR-IOV-capable card, or a platform where the iGPU can be split), this decision should
  be revisited — the constraint here is the specific hardware, not a principled objection
  to GPU workloads in Kubernetes generally.

## Consequences

- No change to the current deployment. This ADR formalizes and evidences a decision that
  was previously only an inline comment (`WRK-007`), and satisfies Phase 6's explicit
  requirement to actually test/research the GPU-in-k8s question rather than carry the old
  answer forward unexamined.
- The media acquisition stack (Sonarr/Radarr/Bazarr/SABnzbd/NZBHydra2, ADR-010) and
  Minecraft (`ct_dmz_games_01`) were also reviewed against Phase 6's "does this belong in
  the cluster" question. Both already have adequate, still-valid documented reasoning for
  staying outside k3s (network-isolation/VPN requirements for the media stack; DMZ-zone
  isolation precedent for game servers, cited directly in ADR-010's own "Reasons"
  section) — no new ADR needed for either, the existing rationale holds under
  re-examination.
