# cert-manager

Issues and renews the wildcard TLS certificate every service in this cluster shares.
Deployed via the official Helm chart (`application.yml`) — CRDs included.

## Configuration

Split from `cert-manager-config/` deliberately: this directory is just the controller
itself, so it can be applied and become healthy before the Cloudflare API token
(needed for DNS-01 challenges) exists — avoids a chicken-and-egg bootstrap ordering
issue during a full cluster rebuild.

## Dependencies

None to bootstrap. `cert-manager-config/` depends on this being healthy first.
