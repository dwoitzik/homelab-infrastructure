# ADR-012: Move Atlantis out of k3s onto its own LXC

**Date:** 2026-07-04
**Status:** Accepted

## Context

Atlantis ran as a k8s Deployment in the `apps` namespace, scheduled (via
`nodeAffinity`) onto either `vm-srv-k3s-11` or `vm-srv-k3s-12`. Both of these
VMs are themselves managed by the same Terraform stack Atlantis applies
(`terraform/stacks/proxmox`).

On 2026-07-04, two separate `atlantis apply` runs against that stack were
interrupted mid-flight (`Plugin did not respond`, `Error: execution halted`).
Investigation of the Proxmox task log showed `qmshutdown` issued by
`terraform@pve` against VM 211 (`vm-srv-k3s-11`) at the exact timestamp of
each interrupt, and k8s events showed the Atlantis pod's sandbox being killed
and recreated (`FailedMount: object "apps"/"atlantis-config" not registered`
→ `SandboxChanged`) in the same second.

Root cause: `bpg/proxmox` does not apply certain VM attribute changes
(`cpu.units`, `serial_device`, and apparently others) as a live update — it
issues a real graceful shutdown + restart of the VM. When the plan touched
the VM that happened to be running the Atlantis pod, Atlantis shut down its
own node mid-apply, killing the Terraform process before it could restart
the VM, leaving it powered off until manually started again.

This is a structural hazard, not a one-off bug: any future plan touching
k3s-11 or k3s-12's VM config carries the same risk as long as Atlantis runs
inside the cluster it manages.

## Decision

Move Atlantis out of k3s entirely, onto its own dedicated Proxmox LXC
(`ct-srv-atlantis-01`, vm_id 204, 10.0.20.250), deployed via Ansible +
docker-compose — the same pattern already used for `ct-srv-media-acq-01`,
`ct-srv-jellyfin-01`, etc.

## Reasons

- Fully decouples Atlantis's own availability from the infrastructure it
  modifies. It can now stop/restart/reboot any or all of the 3 k3s VMs
  without taking itself down.
- Matches the repo's existing pattern for single-purpose management
  services running as LXCs rather than k8s workloads (`ct-mgmt-pbs-01`,
  `ct-srv-nfs-01`).
- Removing Atlantis from the k3s NetworkPolicy surface (REL-034's
  `allow-atlantis-ingress` rule) simplifies that policy back to a plain
  intra-namespace allow — the whole class of "does an in-cluster pod have
  unauthenticated access to the Terraform-apply UI" risk goes away since
  Atlantis is no longer reachable from inside the cluster at all.

## Trade-offs

- Atlantis's BoltDB (repo locks, PR workspace clones) lived on a k8s PVC
  (`atlantis-data`, NFS-backed, 5Gi). This migration does not carry that
  data forward — any currently-locked PR plan is dropped; re-run
  `atlantis plan` on any open PR after cutover. Acceptable for a homelab
  GitOps runner with no long-running applies.
- Atlantis is no longer part of ArgoCD-managed GitOps for its own
  deployment — it's now Ansible-managed like the other LXC-based services.
  This is consistent with the repo's existing split (k8s workloads via
  ArgoCD, host-level/infra services via Ansible), not a new inconsistency.
- One more LXC to patch/back up (PBS covers this the same as every other
  LXC on `mini`).

## Consequences

- `kubernetes/apps/atlantis/atlantis.yml` (Deployment, Service, ConfigMap,
  PVC) removed.
- `kubernetes/apps/network-policies.yml`'s `allow-atlantis-ingress` /
  REL-034 exclusion on `allow-intra-namespace` removed — no longer
  applicable once Atlantis isn't a pod.
- `kubernetes/system/apps-ingressroute.yml`'s Atlantis IngressRoute removed
  (Cloudflare Tunnel routes directly to the LXC's IP now, never went
  through Traefik in the first place per REL-034's finding).
- `terraform/stacks/cloudflare/main.tf` tunnel ingress for
  `atlantis.woitzik.dev` repointed from
  `http://atlantis.apps.svc.cluster.local:4141` to
  `http://10.0.20.250:4141`.
- New `terraform/stacks/proxmox/lxc.tf` resource `ct_srv_atlantis_01` and
  new `ansible/roles/atlantis/` role (docker-compose, matching
  `media_acquisition`'s pattern) deploy and configure it.
- Secrets (`atlantis-secrets` k8s Secret) migrated to Ansible Vault
  (`vault_atlantis_*` in `ansible/group_vars/all/vault.yml`), the k8s
  Secret deleted once cutover is confirmed.
