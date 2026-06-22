# Operations Quick Reference

Where to look first. Everything else links out from here on purpose — this page stays short.

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

```text
Internet → Fritzbox 6591 (WAN, ISP modem/router)
              → MikroTik RB5009 (core router, VLANs 10/20/30/40/100, default-drop firewall)
                  → VLAN 10 (MGMT): Proxmox host, PBS
                  → VLAN 20 (SRV): k3s nodes, RPi (AdGuard+Unbound), AI LXC, Docker LXC, NFS
                  → VLAN 30 (DMZ): external reverse proxy, game servers
                  → VLAN 40 (IOT), VLAN 100 (ADMIN)
```

**AdGuard PTR gotcha (2026-06-19):** AdGuard forwards reverse-DNS lookups for the
Fritzbox's LAN (`192.168.178.0/24`) to the Fritzbox itself — that part's fine. But
`private_networks` in `AdGuardHome.yaml` has to stay scoped to exactly that subnet. Leave
it empty and AdGuard treats every RFC1918 range as "private," including the k3s pod
network, and starts forwarding PTR queries the Fritzbox can't answer. Each one eats a
2-second timeout. At cluster scale that looks like a DNS outage. If query volume spikes
again: `docker logs adguardhome | grep "i/o timeout"`, then check `private_networks` in
`/opt/adguardhome/conf/AdGuardHome.yaml` on both RPis.

## Common failure modes (seen in production, not hypothetical)

| Symptom | Root cause | Where it's documented |
|---|---|---|
| AdGuard query count spikes, DNS feels slow | `private_networks` too broad, PTR queries for 10.42.x.x routed to Fritzbox and timing out | See above |
| App in `apps` ns can't reach something in `monitoring` ns (or vice versa) | NetworkPolicy default-deny with no explicit allow rule for the calling namespace | `docs/k3s-architecture.md` §5, `kubernetes/apps/network-policies.yml`, `kubernetes/system/monitoring/network-policies.yml` |
| ExternalSecret stuck on stale "Vault is sealed" error after Vault was unsealed | ClusterSecretStore caches status; force a resync or recreate it | `docs/secrets-inventory.md` |
| Velero backup "Completed" but data is unrecoverable | `defaultVolumesToFsBackup` missing from the Schedule — only k8s manifests were captured, not PVC data | `docs/backup-strategy.md` |
| paperless-gpt fails every document with "model not found" | Ollama model pull never finished — check `ollama list` on the AI node (`ct-srv-ai-01`, 10.0.20.251) before assuming a config bug | — |
| `ollama pull` on the AI LXC keeps restarting/stalling mid-download | Plain `&` over SSH gets SIGHUP'd when the session ends. Use `setsid nohup ollama pull <model> > /tmp/ollama-pull.log 2>&1 < /dev/null & disown` instead. | — |
| k3s API unreachable on `10.0.20.11` after HA migration | kubeconfig should point at the VIP `10.0.20.10`, not a specific node | `docs/k3s-architecture.md` |
| Proxmox host becomes totally unresponsive (ping works, SSH/everything else doesn't; no kernel panic in the logs) | Long-running investigation across 2026-06-20 to 2026-06-22. Ruled out: thermal paste (repasted, temps fine), CPU C-states (`max_cstate=1` made things worse, reverted), boot-time resource storm alone (staggered `startup` order helped but freezes continued). Two real contributing factors found: (1) BMAX ships an undersized PSU for this chip's TDP — dropped BIOS TDP 54W→25W. (2) A known unfixed OpenZFS 2.4.1 deadlock under ARC memory pressure + concurrent I/O (`openzfs/zfs#18426`) matches every symptom exactly — upgraded to ZFS 2.4.2, capped ARC to 4GB and dirty-data to 1GB, dropped txg_timeout to 5s, forced PCIe ASPM to `performance` (power-saving link states are a plausible NVMe-stall trigger given the marginal PSU). Also found and fixed a real contributing trigger: `paperless-gpt` was configured for `gemma2:27b` (15GB, and not even vision-capable) instead of the documented `qwen2.5:7b` — loading it spiked host memory by ~13GB in 10 seconds, into real swap usage. `onboot` is now `0` for every VM/LXC — a host reboot starts nothing automatically; start things back up deliberately. Open question: whether running 3-node etcd HA on a single physical disk is worth the 3x fsync write amplification it causes versus reverting to single-node etcd. If it happens again: `dmesg -T`, `journalctl -k -b -1`, check for `dmu_tx_wait`/`txg_sync` in D-state (`ps aux \| grep D`), `zpool status -x`. | — |
| Proxmox host SSH key auth fails (`Permission denied (publickey,password)`) | The host itself, not its VMs/LXCs, may be missing the key in `authorized_keys` — VM/LXC SSH goes through cloud-init/Ansible separately. Check with `ssh -o PreferredAuthentications=publickey root@10.0.10.10`. | — |
| `kubectl apply` succeeds but the live resource reverts within seconds | ArgoCD repo-server cache staleness, hit 3x on 2026-06-20 (tempo, traefik, paperless-gpt). Force it: `kubectl patch application <name> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`. If that's not enough, `kubectl rollout restart deployment argocd-repo-server -n argocd`. StatefulSets need a delete+recreate — `volumeClaimTemplates` are immutable, so a cache refresh alone won't fix it. | — |
| Two ArgoCD Applications fight over the same resource (`SharedResourceWarning`, flickering or pruned) | Two owners claiming the same object — usually a Helm chart's own ingress toggle vs. a manually-defined IngressRoute. Pick one, disable the other's claim, recreate. | `kubernetes/system/traefik/application.yml` — `ingressRoute.dashboard.enabled: false`, the manual route in `other-ingressroute.yml` wins |

## Pending — needs the cluster back up

- **Secrets rotation**: full list in `docs/secrets-inventory.md`. Needs live Vault and
  service access to actually rotate, not just to identify.
- **MikroTik service hardening apply**: `terraform/stacks/network/imports.tf` is committed
  and validates clean, but the backend (Garage S3) is k3s-hosted, and this stack only ever
  applies via Atlantis. Comment `atlantis apply` once the cluster's back — check Atlantis
  itself is reachable first, since it's also k3s-hosted.
- **Velero R2 offsite backup**: configured, just waiting on Cloudflare R2 credentials.
- Firewall rules that existed live but weren't in Terraform are now imported
  (`firewall_extra.tf`) — same Atlantis-apply constraint as above.
- **No remote syslog from MikroTik**: security events only live in a 1000-line in-memory
  buffer. Wiring it to Loki needs a syslog receiver on the cluster side.
- **No native MikroTik config backup**: the Terraform API user doesn't have permission to
  run `/system backup`/`/export`. Recoverability depends entirely on Terraform state right
  now. Needs either a higher-privilege API user or an admin credential in Vault.
- **Check for a leftover Longhorn ArgoCD Application in-cluster**: `kubernetes/system/longhorn/`
  (an Application manifest with `selfHeal: true`/`prune: true`, plus an IngressRoute) was
  still in the repo despite Longhorn being fully migrated to NFS — removed from git
  2026-06-21, but if it was ever applied to the cluster, the Application object itself
  might still exist and keep reconciling Longhorn back in. Check with
  `kubectl get application longhorn -n argocd` once the cluster's up, delete it if present.

## Last known-good audit

2026-06-19: full pass across AdGuard, Velero, NetworkPolicies, Vault, k3s, CI. Findings
and fixes are in the git history (`git log --oneline` around that date) and reflected in
the docs above. If something here feels stale, `git log -1 -- <doc>` tells you how stale.
