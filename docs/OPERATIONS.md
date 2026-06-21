# Operations Quick Reference

Single jump-off point for "where do I look first." Detail lives in the linked docs —
this page is intentionally short.

## Architecture & topology

| Question | Doc |
|---|---|
| Physical cabling, port map | `docs/physical-topology.md` |
| VLANs, firewall zones, MikroTik port config | `docs/vlan-segmentation.md` |
| k3s cluster layout, HA, storage, NetworkPolicies | `docs/k3s-architecture.md` |
| Compute node specs (Proxmox host, VMs, LXCs) | `docs/compute-nodes.md` |
| Naming conventions for hosts/VMs/LXCs | `docs/naming-convention.md` |
| Why a given architecture decision was made | `docs/decisions/ADR-*.md` |

## Operations

| Question | Doc |
|---|---|
| Where is secret X stored, how does it flow | `docs/secrets-inventory.md` |
| Backup schedule, what's covered, how to restore | `docs/backup-strategy.md` |
| SSO/OIDC setup for a new app | `docs/SSO_SETUP.md` |
| What's deployed, what's planned, what's in progress | `ROADMAP.md` |
| Ansible host groups → roles mapping | `ansible/README.md` |
| k3s provisioning / HA migration steps | `ansible/k3s-cluster/README.md`, `docs/k3s-architecture.md` |

## Network topology — the short version

```
Internet → Fritzbox 6591 (WAN, ISP modem/router)
              → MikroTik RB5009 (core router, VLANs 10/20/30/40/100, default-drop firewall)
                  → VLAN 10 (MGMT): Proxmox host, PBS
                  → VLAN 20 (SRV): k3s nodes, RPi (AdGuard+Unbound), AI LXC, Docker LXC, NFS
                  → VLAN 30 (DMZ): external reverse proxy, game servers
                  → VLAN 40 (IOT), VLAN 100 (ADMIN)
```

**AdGuard PTR resolution gotcha (2026-06-19 incident):** AdGuard (on the RPis, VLAN 20)
forwards reverse-DNS (PTR) lookups for the Fritzbox's own LAN range
(`192.168.178.0/24`) to the Fritzbox itself (`192.168.178.1`, reachable because MikroTik
routes it). This is intentional and correct — but `private_networks` in
`AdGuardHome.yaml` **must stay scoped to exactly `192.168.178.0/24`**. If it's left empty,
AdGuard treats *all* RFC1918 ranges as "private" and forwards PTR queries for the k3s pod
network (`10.42.0.0/16`) to the Fritzbox too, which can't answer them — every such query
then burns a 2-second timeout, and at cluster scale this turns into a query flood that
looks like a DNS outage. If AdGuard query volume spikes again, check
`docker logs adguardhome | grep "i/o timeout"` first and verify `private_networks` in
`/opt/adguardhome/conf/AdGuardHome.yaml` on both RPis.

## Common failure modes (seen in production, not hypothetical)

| Symptom | Root cause | Where it's documented |
|---|---|---|
| AdGuard query count spikes, DNS feels slow | `private_networks` too broad, PTR queries for 10.42.x.x routed to Fritzbox and timing out | See above |
| App in `apps` ns can't reach something in `monitoring` ns (or vice versa) | NetworkPolicy default-deny with no explicit allow rule for the calling namespace | `docs/k3s-architecture.md` §5, `kubernetes/apps/network-policies.yml`, `kubernetes/system/monitoring/network-policies.yml` |
| ExternalSecret stuck on stale "Vault is sealed" error after Vault was unsealed | ClusterSecretStore caches status; force a resync or recreate it | `docs/secrets-inventory.md` |
| Velero backup "Completed" but data is unrecoverable | `defaultVolumesToFsBackup` missing from the Schedule — only k8s manifests were captured, not PVC data | `docs/backup-strategy.md` |
| paperless-gpt fails every document with "model not found" | Ollama model pull never finished — check `ollama list` on the AI node (`ct-srv-ai-01`, 10.0.20.251) before assuming a config bug | — |
| `ollama pull` on the AI LXC keeps restarting/stalling mid-download | Backgrounding via plain `&` over SSH gets SIGHUP'd when the SSH session ends. Use `setsid nohup ollama pull <model> > /tmp/ollama-pull.log 2>&1 < /dev/null & disown` to fully detach it from the SSH session. | — |
| k3s API unreachable on `10.0.20.11` after HA migration | kubeconfig should point at the VIP `10.0.20.10`, not a specific node — any single node can be down without losing the API | `docs/k3s-architecture.md` |
| Proxmox host (10.0.10.10) becomes completely unresponsive (SSH/API/ping all fail) for several minutes right after a reboot, then recovers on its own — or doesn't, and needs a hard reset | **Two compounding causes, both fixed 2026-06-20:** (1) Boot-time resource storm — all 3 k3s VMs (4 vCPU each) + every LXC used to auto-start simultaneously with no stagger, load average hit 147 within 4 min of boot. Fixed with `qm/pct set --startup order=N,up=Xs` (NFS first, then k3s-11/12/13 30s apart, then the rest) — see `terraform/stacks/proxmox/vm.tf` and `lxc.tf`. (2) **Known AMD Ryzen Zen3 (Cezanne, incl. 5825U) C-state kernel hang bug**, often triggered in combination with ZFS — deep idle states (C3/C6) can hang the whole host, presenting as a true freeze rather than just high load. Mitigated by adding `processor.max_cstate=1 idle=nomwait` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` + `update-grub`. Also capped `zfs_arc_max=8589934592` (8GB) in `/etc/modprobe.d/zfs.conf` — it was unbounded (0 = up to ~50% of RAM = ~31GB), competing with VM memory (k3s VMs alone request 44GB) and forcing swap during the boot storm. **Both grub and ARC changes require a reboot to take effect** — they are not yet validated by an actual recurrence-free reboot as of 2026-06-20. If the host still hangs/crashes after a clean reboot with these in place, the C-state mitigation theory is wrong and this needs escalating to actual hardware diagnostics (memtest, PSU swap). If it still happens: `ssh root@10.0.10.10 uptime` and `ps aux --sort=-%cpu \| head` to check load-storm vs `dmesg -T` for hardware/MCE errors. |
| Proxmox host SSH key auth fails (`Permission denied (publickey,password)`) | The host itself (not its VMs/LXCs) may not have Claude's/admin's key in `authorized_keys` — distinct from VM/LXC SSH, which goes through cloud-init/Ansible. Verify with `ssh -o PreferredAuthentications=publickey root@10.0.10.10`. |
| `kubectl apply` on a manifest succeeds, but a live resource (Deployment volumeMounts, StatefulSet storageClassName, IngressRoute fields) reverts to old values within seconds | **ArgoCD repo-server Helm/manifest cache staleness** — hit 3x on 2026-06-20 (tempo PVC storageClassName, traefik tlsStore/dashboard, paperless-gpt volumeMounts). `selfHeal: true` re-applies from ArgoCD's cached render of the chart/manifests, which can lag behind a fresh git push or a fresh kubectl apply. Fix: `kubectl patch application <name> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`, wait ~15s, then re-check. If that alone doesn't work, restart the cache itself: `kubectl rollout restart deployment argocd-repo-server -n argocd`. For StatefulSets specifically, also delete+recreate the StatefulSet (volumeClaimTemplates are immutable — a stale-cached re-apply won't fix the field even after the cache clears, the object itself must be replaced). |
| Two ArgoCD Applications both create a resource with the same name/namespace (`SharedResourceWarning` in `.status.conditions`, resource flickers between two specs or gets pruned entirely) | Ownership conflict — e.g. a Helm chart's own `ingressRoute.dashboard.enabled` and a manually-defined `IngressRoute` with the same name fighting over the object. Pick one owner, disable/remove the other's claim to that resource name, then recreate. | `kubernetes/system/traefik/application.yml` (`ingressRoute.dashboard.enabled: false` — the manual Authelia-protected route in `other-ingressroute.yml` is the canonical one) |

## Pending — needs the cluster back up to finish

- **Secrets remediation (Phase 2)**: 12 plaintext secrets found in git history by gitleaks
  on 2026-06-21 — full list and rotation plan in `docs/secrets-inventory.md`. Blocked on
  live Vault + service access.
- **MikroTik service hardening apply**: `terraform/stacks/network/imports.tf` (telnet/ftp
  disabled, api/api-ssl scoped to 10.0.0.0/8) is committed and `terraform validate`-clean,
  but not yet applied — this stack's backend is Garage S3 (k3s-hosted), and per the
  network/proxmox-stacks rule, it only ever applies via Atlantis. Needs an `atlantis apply`
  comment on the next PR/plan once the cluster is back, or a manual one-time apply if
  Atlantis itself needs the change to even reach the cluster (chicken-and-egg — check
  Atlantis is actually reachable first).
- **Velero R2 offsite backup**: configured, waiting on Cloudflare R2 credentials from David
  (see `project_velero_r2_pending` memory note / `docs/backup-strategy.md` Stage 1b).
- **19 MikroTik firewall rules not yet in Terraform**: after the 2026-06-21 cleanup of 36
  orphaned/duplicate rules, 19 *legitimate, distinct* rules remain that were created
  manually at some point (VPN access tiers, Atlantis/MikroDash API access, WireGuard,
  Cobblemon port-forward, monitoring scrape, OIDC routes) and were never added to
  `firewall_deterministic.tf`. Not a security issue — they're intentional and working —
  but they're invisible to `terraform plan`, so a future cleanup pass could recreate the
  same drift. Worth importing into Terraform properly once there's time.
- **No remote syslog from MikroTik**: security events (failed logins, firewall drops) only
  go to a 1000-line in-memory ring buffer — nothing centralized. Wiring this to Loki needs
  a syslog receiver on the cluster side (Promtail syslog stage or similar), so it's blocked
  on the cluster being up — revisit once it's back.
- **No native MikroTik config backup job**: the `terraform` API user lacks permission to
  run `/system backup`/`/export` (tested 2026-06-21, got "not enough permissions"). Full
  recoverability currently depends entirely on Terraform state (which itself lives in
  Garage S3 — i.e. on the cluster). Would need either elevated API-user permissions or an
  admin-level credential added to Vault to fix properly.

## Last known-good audit

2026-06-19: full pass across AdGuard, Velero, NetworkPolicies, Vault, k3s, CI. Findings
and fixes are in the git history (`git log --oneline` around that date) and reflected in
the docs above. If something here feels stale, `git log -1 -- <doc>` tells you how stale.
