# ADR-081: Nightly k3s upgrades from the Proxmox host, with snapshot rollback

## Status

Accepted, 2026-11-17.

## Context

The cluster sat on an end-of-life k3s minor for months because every upgrade was a
manual session: snapshot the VMs, swap the binary on the server, drain and upgrade each
agent, check everything, clean up. The first manual run (1.31 to 1.34, see ADR-080 and
`docs/runbooks/k3s-upgrade.md`) took most of a day and paged the owner several times.

The owner asked for upgrades to happen on their own at night and to undo themselves if
anything breaks.

Constraints found on the way:

- The Proxmox host cannot reach the k3s VMs over the network (VLAN firewall), but all
  three run the QEMU guest agent, so `qm guest exec` gives the host a command channel
  that does not depend on the cluster network or SSH.
- Proxmox snapshots are instant and roll back in under a minute; a PBS restore takes far
  longer. The PBS backup runs on odd days at 03:00 and Velero's daily backup at 05:00.
- A node must not be drained while its pinned local-path pods would become unavailable
  for longer than the kubelet restart, and two nodes must never be down together.

## Decision

An Ansible role, `k3s_auto_upgrade`, installs `/usr/local/sbin/k3s-auto-upgrade` and a
systemd timer (06:00) on the Proxmox host. Each run:

1. Reads the wanted version from `ansible/k3s-cluster/inventory.yml` on `main` and the
   running version through the guest agent. Nothing to do: exit.
2. Refuses anything but a single minor step forward, and runs only on nights with a
   successful PBS backup in the last six hours and no Velero backup in progress.
3. Checks the cluster is healthy first, then takes a disk snapshot of all three VMs and
   adds an Alertmanager silence for the expected maintenance alerts.
4. Upgrades the server, then each agent (drain of movable pods only, binary swap with
   checksum, uncordon), running the full health check after every node: all nodes
   Ready, no serving pod unready, ingress through Traefik answering repeatedly, every
   ExternalSecret synced.
5. On any failure, stops all three VMs, rolls them back to the snapshot, starts them
   server first and checks health again. One ntfy message reports the result.
6. On success, deletes the snapshots, expires the silence and reports once.

Renovate tracks the pin: patch releases merge themselves after a week, minor releases
come as one PR per minor and need a manual merge. A merge is the approval; the timer
does the rest.

`--dry-run`, `--check` and `--drill` (snapshot, roll straight back, verify) make the
script testable without upgrading anything.

## Consequences

- Upgrades happen at most every other night and never during a backup.
- A rollback restores the VMs to the moment before the upgrade, so writes made inside the
  VMs during the window (minutes, at 06:00) are lost. Application data on NFS and on the
  archive pool is outside these disks and unaffected.
- Proxmox host packages stay manual: if the host itself breaks, nothing can roll it back
  at night.
- The orchestrator depends on the guest agent; if it stops answering, the run fails
  before changing anything, or the rollback reports that it needs attention.
