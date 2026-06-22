# ADR-005: NFS storage instead of Longhorn

**Date:** 2026-06
**Status:** Accepted

## Context

Longhorn provided replicated block storage for all k3s PVCs. In practice it didn't handle
node instability well: when a node got OOM-killed, Longhorn would re-attach a volume to a
different node while the pod itself got rescheduled elsewhere, and the two would disagree —
RWO volumes ended up in a `Multi-Attach error` loop that needed manual intervention to clear.
This happened more than once as the cluster's app workloads grew.

Options considered:

- Keep Longhorn, tune replica counts and node affinity to reduce the chance of the race
- Switch to a single NFS server backing a `nfs-client` StorageClass
- Move to Ceph/Rook for a "real" distributed storage layer

## Decision

Migrate all PVCs to the `nfs-client` StorageClass, backed by a dedicated LXC
(`ct-srv-nfs-01`) exporting a ZFS-backed share.

## Reasons

Longhorn's failure mode was specifically about *volatile* node environments — exactly what
this cluster has (VMs on a single physical host, occasional reboots, memory pressure under
load). NFS sidesteps the multi-attach problem entirely: there's one server, one source of
truth for the data, and pods can move between nodes freely since the mount isn't tied to
a specific node's local disk. Ceph/Rook would solve the same problem with proper
replication, but for a 3-node homelab cluster the operational overhead wasn't worth it —
NFS plus the existing Velero backup pipeline covers the actual failure modes this lab runs
into.

## Trade-offs

- No in-cluster replication for PV data anymore — durability depends entirely on the NFS
  server's own ZFS redundancy and on Velero's daily backups
- The NFS server itself is a new single point of failure, just a different one than
  Longhorn's per-node attach problem
- One exception: the `media` PVC (Jellyfin) is a direct NFS mount rather than going through
  the `nfs-client` provisioner, since it's large and doesn't need per-pod dynamic provisioning

## Consequences

`nfs-client` is now the default StorageClass for everything. The provisioner lives in
`kubernetes/system/nfs-provisioner/`. Longhorn's ArgoCD Application and IngressRoute were
removed from the repo — an orphaned copy of both (with `selfHeal: true`) was found and
deleted on 2026-06-21, well after the migration itself, which is a reminder to actually
delete things when migrating off them rather than just stopping use of them.
