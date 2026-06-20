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
| Proxmox host (10.0.10.10) becomes completely unresponsive (SSH/API/ping all fail) for several minutes right after a reboot, then recovers on its own | **Boot-time resource storm, not a hardware fault.** All 3 k3s VMs (4 vCPU each) + every LXC used to auto-start simultaneously with no stagger. Load average hit 147 within 4 minutes of boot — etcd resync across all 3 nodes, ArgoCD reconciling cluster-wide drift, and cold ZFS ARC cache all hit at once on a laptop-class Ryzen 7 5825U. Fixed 2026-06-20: staggered `qm/pct set --startup order=N,up=Xs` — NFS server first (order 1), then k3s-11/12/13 sequentially 30s apart (order 2-4), then everything else (order 5-6). If it still happens: `ssh root@10.0.10.10 uptime` and `ps aux --sort=-%cpu \| head` to confirm it's still load-storm and not something new — don't assume it's hardware again. |
| Proxmox host SSH key auth fails (`Permission denied (publickey,password)`) | The host itself (not its VMs/LXCs) may not have Claude's/admin's key in `authorized_keys` — distinct from VM/LXC SSH, which goes through cloud-init/Ansible. Verify with `ssh -o PreferredAuthentications=publickey root@10.0.10.10`. |

## Last known-good audit

2026-06-19: full pass across AdGuard, Velero, NetworkPolicies, Vault, k3s, CI. Findings
and fixes are in the git history (`git log --oneline` around that date) and reflected in
the docs above. If something here feels stale, `git log -1 -- <doc>` tells you how stale.
