# metallb-config

The `IPAddressPool` (`10.0.20.200`–`10.0.20.240` minus `10.0.20.205`, VLAN 20/Server)
and `L2Advertisement` for MetalLB — split from `metallb/` so the pool config applies after the CRDs it
depends on exist. Traefik's Service picks up `10.0.20.200` (the first address in the
pool) as its stable external IP; everything routing-wise in this repo assumes that
specific IP.

`10.0.20.205` is excluded because the rybbit LXC holds it as a static address; handing it
to a LoadBalancer Service would put two hosts on one IP. Keep the pool clear of every
static VLAN 20 address, and keep the router's VLAN 20 DHCP pool
(`terraform/stacks/network/dhcp.tf`) out of this range.

## Dependencies

MetalLB (controller/CRDs).
