# metallb-config

The `IPAddressPool` (`10.0.20.200`–`10.0.20.240`, VLAN 20/Server) and `L2Advertisement`
for MetalLB — split from `metallb/` so the pool config applies after the CRDs it
depends on exist. Traefik's Service picks up `10.0.20.200` (the first address in the
pool) as its stable external IP; everything routing-wise in this repo assumes that
specific IP.

## Dependencies

MetalLB (controller/CRDs).
