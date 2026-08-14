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
