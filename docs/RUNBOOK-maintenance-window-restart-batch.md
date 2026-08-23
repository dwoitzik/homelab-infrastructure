# Runbook: batched restart-gated changes (host reboot + k3s config)

**Status: written for operator review/approval. Not executed. This document plans the
work; nothing in it has been run against the live cluster.**

## Why these are batched together

Four pending changes each need a restart to take effect, and this host has zero HA
(single Proxmox box under all 3 k3s VMs, see `CLAUDE.local.md`'s Hardware inventory
section) — every restart here means real downtime for something. Rather than taking
that downtime four separate times, this window does the host reboot once (which
naturally restarts k3s on all three guests as a side effect) and applies the k3s
config changes so they take effect as part of that same restart, not as additional
separate ones.

| # | Change | What actually needs to restart | Why it's been waiting |
|---|---|---|---|
| 1 | `amd_pstate=active` | Proxmox host (kernel boot parameter) | No reboot since the grub fix landed |
| 2 | k3s `egress-selector-mode: disabled` | k3s server on `vm-srv-k3s-11` (control-plane) | Fixes the kubelet-proxy 502 bug on k3s-12/13 exec/logs, blocked since 2026-08-21 |
| 3 | CIS 4.2.4 / 4.2.9 (kubelet flags) | k3s server, all 3 nodes | Needs verification first — may already be a non-issue, see below |
| 4 | Kubelet container-log rotation tightening | k3s server, all 3 nodes | Optional — see below |

**Separately, and NOT part of this restart batch**: CIS 4.1.3–4.1.8 (kubeconfig/cert
file permissions on each node) are plain `chmod`/`chown` on files a running process
already has open — they don't need a restart at all and can be applied at any time,
independent of this window. They're blocked on something else entirely: this agent
has no SSH/Ansible access to any k3s VM (`ansible -m ping` against `vm-srv-k3s-11`
fails with `Permission denied (publickey)` — this agent's key was only ever deployed
to `pve`/`rpi-srv-01`/`rpi-srv-02`/GitHub, not the k3s VMs). Whoever runs this window
(or has real access sooner) should just fix these now, no need to wait — see the
dedicated section at the end.

## Pre-checks (do these first, before scheduling anything)

1. **No onboot=1 stale VMIDs.** Tonight's hard reboot auto-started two orphaned
   clones (9211, 9213) sharing IPs with the real k3s-11/13 nodes, causing real
   IP/MAC conflicts — already stopped and `onboot` disabled live by the operator, but
   confirm before the *next* reboot too, since this is now a known failure mode for
   any crash-recovery boot on this host, not a one-off:

```bash
   ssh pve "qm list --full 2>/dev/null | awk '\$2!=\"\" {print}'; for id in \$(qm list | awk 'NR>1{print \$1}'); do qm config \$id 2>/dev/null | grep -q '^onboot: 1' && echo \"VMID \$id has onboot=1: \$(qm config \$id | grep ^name)\"; done"
```

   Cross-check the result against the three real k3s VMIDs (211/212/213 per
   `CLAUDE.local.md`) and the known LXC IDs — anything else with `onboot=1` sharing a
   VLAN20 IP with a real host is the same failure mode and should be stopped +
   `onboot` disabled before proceeding, same as tonight.
2. **Confirm the grub fix is actually what will boot.** Already verified live tonight
   (2026-08-22/23): `/etc/default/grub.d/amd_pstate.cfg` sets `amd_pstate=active`
   exactly once, and the regenerated `/boot/grub/grub.cfg` shows a single
   `amd_pstate=active` on the `linux` line for `vmlinuz-7.0.14-11-pve` with no
   `amd_pstate=passive` duplicate. Re-check this hasn't drifted since:

```bash
   ssh pve "grep -m1 'linux.*vmlinuz' /boot/grub/grub.cfg"
```

   Should show `amd_pstate=active` exactly once. If it shows both `active` and
   `passive`, or neither, stop — the fix has regressed or been reverted, don't
   reboot into an unverified state.
3. **Confirm host load is normal**, not mid-incident:
   `ssh pve "cat /proc/loadavg"` — should be in the low single digits, consistent
   with this session's baseline (2–4 range), not a live spike.
4. **Confirm current cluster health** so any post-reboot problem is diagnosable
   against a known-good baseline, not guessed at:
   `kubectl get nodes -o wide`, `kubectl get pods -A | grep -v Running | grep -v Completed`
   — record the output. Anything already broken before the reboot isn't a new
   regression from this window.
5. **Confirm recent PBS backups exist** for all 3 k3s VMs and the host's own config
   (this is a host reboot on the only physical box everything runs on — standard
   "snapshot before any change that can affect running state" guardrail from
   `CLAUDE.local.md` #1, at host granularity since PVE itself is what's changing).

## Downtime estimate

- Host reboot itself: ~3–5 minutes (BIOS/UEFI POST + GRUB timeout of 5s + kernel
  boot), based on this host's specs and no unusual boot-time services observed.
- All 3 k3s VMs cold-boot in parallel once the host is back — k3s server/agent
  startup + ArgoCD reconciling everything back to Synced: historically 5–10 minutes
  based on tonight's actual hard-reboot recovery (host up at 22:59, cluster
  substantially settled well within the following hour, though a NVMe I/O
  timeout/abort burst did occur ~6 minutes post-boot, see docs/HARDWARE.md's
  "Re-measurement, same night" section — resolved on its own within ~5 minutes with
  zero errors both times this host has hard-rebooted recently).
- **Total realistic window: 20–30 minutes**, most of it waiting for GitOps
  reconciliation and pod readiness rather than the reboot itself. Budget for longer
  if kube-bench/CIS verification (step 3 below) turns into an actual fix rather than
  a no-op.
- User-facing impact: everything is down for the reboot portion (single point of
  failure, no HA — `CLAUDE.local.md`'s own framing: "Target recovery, not HA"). Pick
  a low-usage window.

## Fallback boot entry

`proxmox-boot-tool status` confirms **two kernel versions are configured**:
`7.0.14-11-pve` (current/primary) and `7.0.2-6-pve` (previous). If `amd_pstate=active`
causes instability (crashes, hangs, CPU throttling misbehavior) that isn't obvious
until real load hits it:

1. Reboot again, and at the GRUB menu (5s timeout, interrupt it) select
   **"Advanced options for Proxmox VE GNU/Linux"** → the `7.0.2-6-pve` entry. This
   boots the previous kernel without needing to touch any config first — a genuine
   fallback, not a config edit under pressure.
2. Once stable on the fallback kernel, revert the actual fix: remove the
   `GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX amd_pstate=active"` line from
   `/etc/default/grub.d/amd_pstate.cfg` (or delete the file), run `update-grub`,
   and reboot once more to confirm a clean boot back on the primary kernel without
   the flag.
3. This is a real, tested-to-exist fallback path (`proxmox-boot-tool status`
   confirms both kernels are enrolled on the ESP), not a theoretical one.

## Per-item plan

### 1. `amd_pstate=active`

- **Pre-check**: done above (grub.cfg verification).
- **Apply**: reboot the host. Nothing else to do — the config is already committed
  and `update-grub` already ran; this step is purely "actually reboot."
- **Verify**:

```bash
  cat /proc/cmdline   # should show amd_pstate=active, no amd_pstate=passive
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # expect amd-pstate-epp (active+EPP), not plain amd-pstate (passive)
  cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # should now exist and be readable -- this path doesn't exist under passive mode at all
```

  Tonight's baseline for comparison (still on the OLD duplicate-cmdline boot):
  `scaling_driver` read `amd-pstate` (passive won the duplicate), and the EPP sysfs
  path wasn't tested but is expected absent under passive.

- **Also verify** (this is the actual point of the change, not just "did the driver
  name change"): RAPL power draw before/after via
  `rate(node_rapl_package_joules_total[5m])` in Prometheus/Grafana, and CPU temps
  stay reasonable under normal load for at least a few hours post-reboot. Compare
  against the 10.15W baseline recorded in `docs/HARDWARE.md`'s power section.
- **Rollback**: see Fallback boot entry above.

### 2. k3s `egress-selector-mode: disabled`

- **Pre-check**: confirm `fix/k3s-egress-selector-mode-disabled` (commit `c4f6351`)
  is merged to main and its `ansible/k3s-cluster/inventory.yml` change is what will
  actually get applied — `git log --oneline -- ansible/k3s-cluster/inventory.yml`.
- **Apply**: this is a k3s SERVER config change on `vm-srv-k3s-11` specifically
  (control-plane only — the setting controls how the apiserver reaches kubelets, not
  agent-side behavior). Whoever has real access to that VM (this agent doesn't, see
  the access note above) applies the updated `server_config_yaml` via the
  `k3s-ansible` role's normal playbook run, which restarts the k3s server service.
  Since the host is rebooting for item 1 anyway, the cleanest sequencing is: apply
  this config change to the VM *before* the host reboot, so k3s starts fresh with
  the new config as part of the natural post-reboot startup, rather than as a
  second separate restart.
- **Verify**: the actual bug this fixes — `kubectl exec`/`kubectl logs` against pods
  on `vm-srv-k3s-12`/`13` should stop 502ing. Test directly:

```bash
  kubectl exec -n <any-namespace> <a-pod-on-k3s-12-or-13> -- true
```

  Should succeed cleanly, no `error: Internal error occurred: unable to upgrade connection`.
  This has been a known, worked-around-via-`crictl` bug all session — a real,
  checkable fix, not just "config looks right."

- **Rollback**: revert `egress-selector-mode` to `agent` (the k3s default) in
  `server_config_yaml`, re-run the playbook, restart k3s server on k3s-11 again.
  Low risk either way — this setting only changes HOW the apiserver reaches
  kubelets, not whether it can; worst case reverts to the pre-existing (already
  known, already worked-around) 502 behavior, not a new failure mode.

### 3. CIS 4.2.4 / 4.2.9 — verify before assuming a fix is even needed

kube-bench's own remediation text for both of these starts with **"By default, K3s
[already does the compliant thing]"** — `--read-only-port` defaults to 0, and k3s
"automatically provides the TLS certificate and private key for the Kubelet." This
is a known category of k3s-vs-generic-Kubernetes CIS benchmark mismatch (same class
already documented in this repo for other REL-022-style findings) — kube-bench's
generic detection logic may simply not recognize k3s's embedded defaults as
compliant, rather than these being real gaps.

- **Pre-check (do this FIRST, before planning any actual config change)**: from a
  node with real access, check the live kubelet args k3s actually launched with:

```bash
  ps aux | grep -o -- '--read-only-port=[^ ]*'
  ps aux | grep -o -- '--tls-cert-file=[^ ]*\|--tls-private-key-file=[^ ]*'
```

  (Safe to run and share — these are flag names/paths, not secret values.) If
  `--read-only-port=0` and both TLS file flags are already present and pointing at
  k3s's own generated cert/key (`/var/lib/rancher/k3s/agent/serving-kubelet.crt`
  etc.), **these findings are very likely false positives and need no config change
  at all** — just document that in kube-bench's own findings doc and move on.

- **If a real gap is found**: both are single-line additions to
  `server_config_yaml`/`kubelet-arg` in the k3s-ansible role, same restart mechanism
  and same sequencing as item 2 (apply before the reboot, let it take effect
  naturally).
- **Verify**: re-run kube-bench's existing CronJob manually
  (`kubectl create job --from=cronjob/kube-bench kube-bench-manual -n apps`) and
  confirm 4.2.4/4.2.9 move from FAIL to PASS (or confirm they were never real gaps).
- **Rollback**: remove the added flag, re-run the playbook. No functional risk —
  these are either already-true defaults or narrow, well-documented kubelet flags.

### 4. Kubelet container-log rotation tightening — optional, lowest priority

Previously reviewed and explicitly deferred (`docs/HARDWARE.md`'s write-rate-
reduction section) as "not worth [a kubelet restart] for a marginal gain" when it
would have been the ONLY reason for that restart. That calculus changes now that a
restart is happening anyway for items 1–3 — worth reconsidering as a free rider, not
worth its own separate window.

- **Proposed change**: `--container-log-max-size=5Mi --container-log-max-files=3`
  (down from k3s's defaults of 10Mi/5 files) via the same `kubelet-arg` mechanism as
  item 3, all 3 nodes.
- **Real effect size**: modest. This caps *retained* rotated log volume per
  container, it doesn't reduce how much gets *written* before rotation — the wear
  benefit is real but small compared to the swappiness/trivy-concurrency changes
  already made (`fix/nvme-write-rate-reduction`). Skip this step entirely if the
  operator wants to keep the window's blast radius to just items 1–3.
- **Verify**: `du -sh` on a container's log dir on each node before/after a few
  days of normal operation, or watch `smart_nvme_data_units_written_total`'s rate
  before/after over a longer window (single-digit-percent effect at most, don't
  expect a dramatic before/after).
- **Rollback**: remove the two flags, re-run the playbook.

## CIS 4.1.3–4.1.8: do this now, separately, doesn't need this window at all

Pure file permission/ownership fixes on kubeconfig/cert files that already exist on
each node — no process restart needed, no functional risk, standard `chmod`/`chown`:

```bash
# On each of vm-srv-k3s-11/12/13:
chmod 600 /var/lib/rancher/k3s/agent/kubeproxy.kubeconfig
chown root:root /var/lib/rancher/k3s/agent/kubeproxy.kubeconfig
chmod 600 /var/lib/rancher/k3s/agent/kubelet.kubeconfig
chown root:root /var/lib/rancher/k3s/agent/kubelet.kubeconfig
chmod 600 /var/lib/rancher/k3s/agent/client-ca.crt
chown root:root /var/lib/rancher/k3s/agent/client-ca.crt
```

This agent can't run this (no SSH/Ansible access to any k3s VM — confirmed live
tonight, `ansible -m ping vm-srv-k3s-11` fails with `Permission denied (publickey)`,
consistent with `CLAUDE.local.md`'s access list which only names `pve`/
`rpi-srv-01`/`rpi-srv-02`/GitHub for this agent's key). Whoever has real access —
the operator directly, or a future session with a properly-scoped key added to the
k3s VMs — should just run this whenever convenient. It's genuinely independent of
the reboot-gated batch above.
