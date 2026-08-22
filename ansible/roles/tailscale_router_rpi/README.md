# tailscale_router_rpi

Second Tailscale subnet-router/exit-node, on `rpi-srv-02`, advertising the
same route (`10.0.20.0/24`) and exit-node capability as the existing
k3s-hosted one (`kubernetes/apps/headscale/subnet-router.yml`).

Tailscale natively supports multiple nodes advertising an identical route
and fails over between them automatically -- no client-side reconfiguration.
This removes the single Proxmox host as a point of failure for remote
LAN access and exit-node routing while away, without touching or migrating
the existing k3s router.

## Restore

Stateless -- re-running the role re-registers via the auth key in Vault. No
data to restore.
