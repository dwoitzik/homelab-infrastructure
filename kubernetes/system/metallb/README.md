# MetalLB

Bare-metal LoadBalancer implementation — gives Traefik's Service a real, stable IP on
the LAN (`10.0.20.200`) since there's no cloud provider to hand out a LoadBalancer IP
on a homelab. Deployed via the official Helm chart (`application.yml`); the actual IP
pool is configured separately in `metallb-config/` for bootstrap-ordering reasons (the
CRDs need to exist before a pool can reference them).

## Dependencies

None to bootstrap. Traefik depends on this for its external IP.
