# Disaster Recovery Runbook

Bare metal to running cluster, assuming nothing survives but: PBS backups, the Garage
S3 bucket contents (if the host running Garage is also gone, this assumes the archive
disk itself survives), and this git repo. Written from the actual 2026-08-13 recovery —
every step here was really executed, not theorized. See
`docs/RECOVERY-REPORT-2026-08-13.md` for the full narrative and `HARDWARE.md` for why
several steps are the way they are.

## 0. Before you start

Read `HARDWARE.md` first. The single most important constraint: **the boot NVMe is
DRAM-less** — don't restore/stage large data onto it if the HDD-backed `media`/`archive`
pool is available instead.

## 1. Host foundation

1. Confirm Proxmox boots and `pvesh` responds. Check `proxmox-boot-tool status` —
   missing UUID tracking is a real bug this recovery hit, not paranoia.
2. Confirm storage: `local-lvm` (LVM-thin) for boot/VM-image, `media`/`archive` (ZFS,
   HDD) for bulk/staging. If ZFS shows up on the boot path, that's drift — see
   `HARDWARE.md` for why it shouldn't be there.
3. Confirm SSH access works both to the host and from wherever this repo is checked out.
   A pmxcfs/`authorized_keys` symlink dependency caused a real lockout during the
   2026-08-13 recovery — `authorized_keys2` is the workaround if `authorized_keys` isn't
   being read correctly.

## 2. Preserve Tier-1 data before touching anything destructive

If VMs/LXCs need restoring from PBS to inspect their data, **restore to scratch VMIDs on
the HDD-backed `media` storage, not NVMe, and do not boot them.** Set `onboot=0`
explicitly and immediately — a real incident during this recovery had scratch VMs
auto-start after a host reboot and IP-conflict with the freshly-provisioned production
VMs, causing over an hour of misdiagnosed "flakiness."

Mount VM disks read-only (`qemu-nbd -r -c`, `mount -o ro,noload` to skip journal replay
without writing) to extract data. Copy extracted data to the `media`/`archive` pool, not
the NVMe.

## 3. Rebuild the k3s cluster

1. Fresh VMs (or LXCs, per whatever the current `terraform/stacks/proxmox/` declares),
   cloned from the template — verify `ciupgrade=0` on the template's cloud-init config
   (an unpinned upgrade caused a real version-drift bug during this recovery).
2. Install k3s via `ansible/k3s-cluster/` — **pin the version explicitly**
   (`INSTALL_K3S_VERSION`) for every node, server and agents alike. The install script
   defaults to latest, which caused a real version mismatch between server and an agent
   during this recovery.
3. Confirm the datastore is actually SQLite (single server, no `cluster-init`), not
   etcd — `kubectl` behaves the same either way, but `docs/decisions/ADR-015` explains
   why this matters for the hardware.
4. Apply CNI/MetalLB/Traefik/cert-manager, then bootstrap ArgoCD.
5. **Do not bulk-apply `kubernetes/system/argocd/apps-applicationset.yaml` or
   `system-app-bootstrap.yml` yet.** Apply core system components
   (`kubernetes/system/*/application.yml`) individually, in dependency order (Vault →
   ExternalSecrets → everything else), verifying each is healthy before the next. Bulk
   auto-apply comes later, once the foundation is proven — see step 6.

## 4. Vault — the circular dependency

A fresh Vault instance can't unseal itself. If the old cluster is truly gone, its
unseal keys are gone with it, *unless* something preserved the old cluster's own
datastore (a PBS restore of the old control-plane VM's disk counts). If so:

1. Spin up a disposable, network-isolated temporary k3s server instance pointed at the
   old cluster's preserved SQLite/kine datastore.
2. Extract the `vault-unseal-keys` Secret from it — **never display the values**, extract
   straight to files, use immediately, delete the files after.
3. Destroy the temporary instance.
4. Restore Vault's own PVC (same local-path swap-restore pattern as any other stateful
   service — see step 5) and unseal with the recovered keys.

If the old cluster's datastore is *also* gone, there is currently no tested recovery
path for Vault — see the honest gap noted in `kubernetes/system/vault/README.md`. Build
and test a `vault operator raft snapshot`-based backup before this becomes a real
problem, not after.

## 5. Restore stateful data — the general pattern

For any `local-path`-backed service (Vaultwarden, Headscale, Garage metadata, Authelia's
Postgres via CNPG, etc.):

1. Scale the workload to 0 (plain Deployment/StatefulSet) or, for CNPG clusters,
   annotate `cnpg.io/hibernation: "on"` — **never `spec.instances: 0`, CNPG rejects it.**
2. If the target ArgoCD Application has `selfHeal: true`, either wait for the scale-down
   to actually take (it may fight you briefly) or temporarily null out
   `spec.syncPolicy.automated` on the Application — but be aware this is only a
   *temporary* suppression for `ApplicationSet`-generated Applications, since the
   ApplicationSet's own reconcile loop will re-assert its template (including
   `automated`) periodically. For anything beyond a quick fix, the real answer is
   getting the correct manifest merged to `main`, not fighting selfHeal indefinitely.
3. Mount the target PVC via a throwaway pod, copy the preserved data in.
4. **Wait for the copy to genuinely finish before touching the pod again.** A real
   mistake during this recovery: deleting a pod with `--wait=false` while a background
   `tar` extraction was still running left a half-extracted, corrupt data directory.
   Check for completion (e.g. the expected files/`postgresql.conf` actually present)
   before proceeding.
5. Un-hibernate / scale back up.
6. Verify against actual content (row counts, `sqlite3 ... "PRAGMA integrity_check;"`,
   file sizes) — not just "pod is Running."

For `nfs-client`-backed or static-PV services (Immich's library, Garage's bulk data):
these usually point at storage that's physically independent of the k3s cluster's own
lifecycle and may not need restoring at all — check what the PV actually points at
before assuming a restore is needed.

## 6. Backup layer, then bulk workload rollout

1. Confirm a PBS backup job actually exists (`pvesh get /cluster/backup`) — this
   recovery found it completely missing, not something to assume is configured.
2. Deploy Velero + Garage, prove a real restore into a scratch namespace before trusting
   the schedule (brief §8's own explicit requirement — "a scheduled backup is not a
   restorable backup").
3. **Now** apply `kubernetes/system/argocd/apps-applicationset.yaml` to bring up the
   remaining workload catalog. Before doing this, check for any Tier-1 data (from step 2)
   that belongs to an app under `kubernetes/apps/*` and hasn't been restored yet — do
   that first, or immediately after first sync via the pattern in step 5, so a fresh
   empty PVC doesn't get mistaken for "done."
4. **Expect transient chaos from simultaneous deployment.** Bulk-deploying 20-30 apps
   at once causes real, self-resolving contention: fresh Postgres instances' `initdb`
   getting interrupted (recovery: `createdb` + a broad `pg_hba.conf` rule via local
   socket, no data lost since these were legitimately fresh), and probe-timeout crash
   loops on apps with a genuinely slow first boot (recovery: loosen `failureThreshold`
   generously for first-boot-only scenarios, not permanently).

## 7. The DNS gotcha — check this on every rebuild

If the PVE host's own DNS search domain matches a wildcard rewrite rule in your DNS
server (e.g. `*.woitzik.dev`), it can silently propagate into every pod's resolv.conf
and hijack short-hostname lookups — external and internal alike. Confirmed live via
`resolvectl status` on a node and `cat /etc/resolv.conf` inside a pod; the fix
(`ansible/roles/k3s_node_tuning`'s `/etc/rancher/k3s/resolv.conf` +
`k3s-cluster/inventory.yml`'s `resolv-conf` config) should already be in place if you're
running the current Ansible role — but if pods are behaving oddly on DNS for hostnames
that look otherwise correct, check this first.

## 8. Prove it, don't assume it

Before declaring the recovery done, actually demonstrate (not just configure):
Alertmanager delivering a real alert, a certificate actually renewing, ArgoCD actually
reverting hand-introduced drift, and a real backup actually restoring. See
`RECOVERY-REPORT-2026-08-13.md` §5 for exactly how each was proven during this run.
