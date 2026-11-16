# ADR-079: Traefik loads the CrowdSec plugin from a local image, never from plugins.traefik.io

**Date:** 2026-11-16
**Status:** Accepted, applied

## Context

Traefik (v2.11, Helm chart 27.0.2) loaded the CrowdSec bouncer plugin through
`experimental.plugins`, which downloads the plugin from plugins.traefik.io (backed by
GitHub) every time a pod starts. When that download is slow or fails, Traefik logs
`Plugins are disabled because an error has occurred`, keeps running, and still answers
`/ping`, so the pod turns Ready. Every middleware of type `plugin` then fails to build
(`invalid middleware type or middleware does not exist`), every router that uses
`apps-crowdsec-bouncer` is disabled, and those hostnames return 404 from that replica.
On this WAN that happened during a routine pod restart: about half of ingress returned
404 for 8 minutes until the replica was restarted.

Two separate faults made that an outage:

1. Pod start depended on a third-party download.
2. Readiness (`/ping`) said nothing about whether the configuration Traefik serves is
   the one it was given.

## Decision

1. **No download at start.** Traefik uses `experimental.localPlugins`, which loads the
   plugin source from `plugins-local/src/<moduleName>` relative to its working
   directory (`/`). The source comes from `ghcr.io/dwoitzik/traefik-crowdsec-plugin`,
   built by `.github/workflows/traefik-plugin-image.yml` on GitHub-hosted runners from
   `images/traefik-crowdsec-plugin/Dockerfile`. That Dockerfile clones the plugin at a
   pinned tag and fails unless HEAD is the pinned commit. An initContainer copies the
   tree into an emptyDir mounted read-only at `/plugins-local`. The image is referenced
   by tag and digest.
   Chart 27 has no `localPlugins` value, so the flag goes through `additionalArguments`
   and the volume through `deployment.initContainers` / `additionalVolumes` /
   `additionalVolumeMounts`.
2. **Startup gate on the middleware.** A `startupProbe` runs
   `wget .../api/http/middlewares/apps-crowdsec-bouncer@kubernetescrd` on the internal
   API (port 9000) and passes only when the body has `"status":"enabled"`. Kubernetes
   does not run readiness until startup has passed, so a pod whose plugin did not load
   never becomes Ready and never gets endpoints. After 60 failures (about two minutes)
   the kubelet restarts the container.
3. **Rollout keeps a replica serving.** `updateStrategy` is set explicitly to
   `maxUnavailable: 0`, `maxSurge: 1` (the chart default, now pinned in our values), and
   the PDB keeps `minAvailable: 1`.

## Alternatives considered

- **Keep the remote plugin, add retries.** Traefik has no retry for plugin download,
  and the fault is the dependency itself.
- **Persist `/plugins-storage` on a PVC.** Traefik still contacts plugins.traefik.io to
  check the archive on every start, and it adds state to a stateless Deployment.
- **Plugin source in a ConfigMap.** The source with `vendor/` is about 1 MB, close to
  the ConfigMap limit, and a nested directory tree in a ConfigMap means a generated
  manifest of Go source in the repo.
- **Custom Traefik image with the plugin baked in.** Works, but then every Traefik
  upgrade means rebuilding our image and Renovate can no longer bump Traefik through
  the chart alone. The source-only image is independent of the Traefik version.
- **Readiness instead of startup.** Chart 27 hard-codes `readinessProbe.httpGet` on
  `/ping` and only merges extra fields, so an exec readiness probe would render two
  handlers and be rejected. A startup check is also the safer scope: plugin loading
  happens once per process, so a pod that passed startup stays good for its lifetime,
  while a readiness check tied to one Middleware object would take every replica out
  of service at once if that object were ever deleted or broken, including routes that
  do not use CrowdSec.

## How it fails now

- GHCR or the WAN down during a rollout: the new pod stays in `Init:ErrImagePull`; the
  old replica keeps serving because `maxUnavailable` is 0. Image pulls are cached per
  node (`IfNotPresent`), so restarts on a node that already ran the image need no
  network at all.
- Plugin source missing or broken: Traefik logs `Plugins are disabled`, the startup
  probe never passes, the pod is restarted, and it never receives traffic.
- `apps-crowdsec-bouncer` Middleware deleted or renamed: running pods keep serving
  (they 404 the routes that use it, as before), but new pods cannot start. Rename the
  probe URL in the same change as the Middleware.

## Bumping the plugin

1. Change `PLUGIN_VERSION` and `PLUGIN_COMMIT` in
   `images/traefik-crowdsec-plugin/Dockerfile` (Renovate does this through the regex
   custom manager in `renovate.json`). Check the plugin's release notes for config
   changes to `kubernetes/apps/crowdsec/middleware.yml`.
2. Merge. The workflow pushes `ghcr.io/dwoitzik/traefik-crowdsec-plugin:<version>`; its
   run summary shows the digest.
3. Update the `plugin-source` initContainer image tag and digest in
   `kubernetes/system/traefik/application.yml` (Renovate's kubernetes manager opens
   this PR on its own once the tag exists). Merge, then check both Traefik pods are
   Ready and their logs have no `Plugins are disabled`.

## Rollback

Revert the Traefik values change. The previous `experimental.plugins` configuration
downloads the plugin again at start, with the old failure mode.

## Consequences

- Plugin updates take two merges instead of one version string.
- Traefik pod start depends on GHCR only when the node has not cached the image; it no
  longer depends on plugins.traefik.io or GitHub at all.
