# CrowdSec

Collaborative intrusion-detection agent — watches logs for attack patterns, feeds a
local API that Traefik's bouncer middleware queries to block bad actors. Runs as a
DaemonSet (`security` namespace) so every node gets local coverage.

## Storage

No PVC — detection state and its local scenario/parser hub are rebuilt on every start
from the CrowdSec Hub (upstream), not from local persistence.

## Known gotchas

- **On first boot it tries to register with CrowdSec's central Console
  (`api.crowdsec.net`)** for community threat-intel sharing — this is optional and not
  required for local bouncer functionality. Failing to reach it (e.g. during the DNS
  wildcard-hijack bug documented in `docs/RECOVERY.md` §7) causes a crash loop; fixing
  the underlying DNS issue resolves it without needing to explicitly disable console
  registration.
- **A plaintext bouncer API key was found committed in this repo's git history**
  (pre-existing, not introduced during the 2026-08-13 recovery). Flagged per the
  "flag leaked secrets, don't rewrite history" rule — rotation is the operator's call.
- Several Traefik IngressRoutes have the `crowdsec-bouncer` middleware reference removed
  temporarily wherever CrowdSec wasn't yet deployed when they were applied — re-add it
  once CrowdSec is confirmed healthy, since Traefik fails closed (blocks all traffic) on
  a missing middleware reference, not open.
