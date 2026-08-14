# Homepage

Dashboard/landing page linking out to everything else in this homelab.

## Storage

None — config is baked into the Deployment/ConfigMap, not a PVC. Losing the pod costs
nothing; re-apply and it's back exactly as configured in git.

## Known gotchas

- Its own health checks against other services need a real `Host` header — hitting a
  backend by pod IP directly (bypassing the configured hostname) gets a 400 from that
  backend's own `TRUSTED_DOMAINS`-style checks, which looks like Homepage is broken
  when the target service is actually fine.
