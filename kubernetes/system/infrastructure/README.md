# infrastructure

Miscellaneous cluster-wide, low-level fixes that don't belong to any single app.

## Contents

- `sysctl-fix.yml` — a `hostNetwork`/`hostPID` DaemonSet applying host-level sysctls
  cluster-wide (e.g. inotify/connection-tracking limits) that can't be set any other
  way in k3s.
- `transport.yml` — `insecure-transport` ServersTransport (two copies, `apps` and
  `kube-system` namespaces) letting Traefik route to self-signed-cert backends
  (Proxmox, PBS, Wazuh) without failing TLS verification.
- `external.yml` — now just a warning comment (the actual resources it used to hold
  were removed). Documents two real incidents this repo learned from, worth reading
  before adding anything new here: this Application runs with `selfHeal: true`, and
  duplicate IngressRoute definitions with the same name+namespace but *less*
  restrictive rules (missing a PathPrefix, missing the Authelia middleware) would
  periodically win Traefik's host-match resolution over the correct, more restrictive
  versions living in `apps-ingressroute.yml`/`other-ingressroute.yml` — silently
  widening exposure of Traefik's own dashboard and PVE/PBS. Both duplicates were found
  and removed; the lesson stands as a warning against re-adding IngressRoutes here.

## Dependencies

None to bootstrap.
