# Kubernetes Applications

Manifests for everything ArgoCD deploys via the ApplicationSet — it watches this directory
and picks up any new subfolder automatically.

## Shared patterns

**Identity:** Authelia handles SSO. Apps with OIDC support use it directly; older apps go
through Traefik's `ForwardAuth` middleware instead.

**Secrets:** Real values never get committed — manifests carry `REPLACE_WITH_*`
placeholders, and the actual Secret gets applied straight to the cluster (or sourced from
Vault via ExternalSecrets where that's set up). See `docs/secrets-inventory.md`.

**Storage:** PVCs use the `nfs-client` StorageClass, backed by `ct-srv-nfs-01`. Used to be
Longhorn — migrated off it, see ROADMAP.md for why.

## What's here

- `authelia` — SSO/OIDC identity provider
- `atlantis` — Terraform GitOps runner
- `cloudflared` — Cloudflare Tunnel daemon (connects `photos.woitzik.dev` externally via tunnel `1f2e0f78-…`)
- `garage` — S3-compatible object storage (Velero backend, Terraform state)
- `gitea` — private git
- `headscale` — self-hosted Tailscale control plane
- `home-assistant` — smart home hub
- `homepage` — dashboard
- `immich` — photo/video backup (v2.7.5) at `https://photos.woitzik.dev` via Cloudflare Tunnel. Stack: VectorChord postgres PG14, Valkey in-memory cache, immich-server port 2283, immich-ml. Uses own auth (no Authelia ForwardAuth). See ADR-011.
- `jellyfin` — media server (k8s Service + Endpoints pointing to `ct-srv-jellyfin-01` LXC)
- `keel` — image auto-update (installed but not actively used; Renovate PRs handle updates)
- `mealie` — recipe manager
- `nextcloud` — files, CalDAV, CardDAV
- `open-webui` — local LLM frontend for Ollama
- `paperless` — document management (with paperless-gpt for AI titling)
- `renovate` — dependency update bot (Kubernetes manager active; all 93+ images in `kubernetes/` tracked)
- `uptime-kuma` — uptime monitoring
- `vaultwarden` — password manager
