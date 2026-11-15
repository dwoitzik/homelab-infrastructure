# cloudflared

Cloudflare Tunnel daemon — provides external access to selected internal services
without opening any inbound port on the MikroTik firewall. See ADR-011 for the full
reasoning behind choosing a tunnel over a port-forward.

## Storage

None — stateless. The tunnel credentials (`external-secret.yml`, sourced from Vault)
are the only thing that matters here; losing the pod costs nothing but a brief
reconnect.

## How to restore

Nothing to restore. Re-apply the manifests; as long as the tunnel credential in Vault is
still valid, it reconnects immediately.

## Known gotchas

- The tunnel ID and which internal hostnames it exposes are configured in Cloudflare's
  own dashboard, not in this repo — this manifest only runs the daemon that connects
  *to* an already-configured tunnel.

## Availability and monitoring

- Two replicas with required pod anti-affinity, one per node, both connecting with the
  same tunnel token. Cloudflare load-balances across connectors, so a node loss or a
  rollout keeps the tunnel up. `cloudflared-pdb` (`kubernetes/system/pod-disruption-budgets.yml`)
  keeps one replica during drains.
- `metrics.yml`: Service + ServiceMonitor on `:20241/metrics` and the
  `CloudflareTunnelDown` alert, which fires only when the summed
  `cloudflared_tunnel_ha_connections` across replicas has been zero for 5 minutes.
