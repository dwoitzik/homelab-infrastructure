# ADR-071: Every container image in the Ansible roles is pinned to a digest

## Status

Accepted and applied, 2026-10-21.

## Context

The Kubernetes manifests were mostly digest-pinned already, and Renovate keeps
them pinned. The Ansible-managed Docker Compose stacks were not: thirteen
images across nine roles carried either a floating tag or no tag at all.

The exposed ones were the reason this was not just tidying:

- `ansible/roles/nginx_proxy_manager` — the reverse proxy that fronts the
  internet-exposed services — ran `jc21/nginx-proxy-manager:latest` and
  `crowdsecurity/crowdsec:latest`.
- `ansible/roles/adguard` — the LAN DNS filter — ran `adguard/adguardhome`
  with **no tag at all** and `ghcr.io/bakito/adguardhome-sync` likewise.
- `ansible/roles/unbound` — the upstream resolver — ran
  `klutchell/unbound:latest` and `willfarrell/autoheal:latest`.

A tag is a mutable pointer. `adguard/adguardhome` with no tag resolves to
`latest`, so a registry-side tag move changes the DNS filter of the whole LAN
without a single line changing in this repository, and a rollback has nothing
to roll back to.

The drift was not only in the manifests. The same image was running at
different versions on different hosts from the same repository state: the
crowdsec container in the DMZ proxy was on **v1.7.8** while the crowdsec
DaemonSet in the cluster was on **v1.8.1**, and `nginx-proxy-manager` ran
`52b2c599…` on the DMZ proxy but `2aa69b38…` on the Pi nodes.

Renovate did not cover this either. Its `kubernetes` and `docker-compose`
managers are configured with `fileMatch` patterns that point at
`kubernetes/**` and `ansible/files/media-acquisition/docker-compose.yml`; the
role templates under `ansible/roles/**` are invisible to it. That is why
`willfarrell/autoheal:latest` in the unbound role was never pinned while the
same image in the media-acquisition compose file was.

## Decision

**Pin every image in the Ansible roles to the digest it currently runs.**

- Each pin uses the digest of the image already running on the host, so
  applying the roles changes no bytes. The tag is set to the version that
  matches that digest where the upstream publishes one (`klutchell/unbound`
  becomes `1.26.1`, `adguard/adguardhome` becomes `v0.107.79`,
  `crowdsecurity/crowdsec` becomes `v1.8.1`), and stays `latest` where no
  matching version tag exists.
- `itzg/minecraft-server` keeps `latest` because upstream publishes a new
  image per release day; the digest is the only stable handle.
- The **crowdsec version on the DMZ proxy is raised from v1.7.8 to v1.8.1**.
  This is the one deliberate version change in the set: v1.7.8 predates the
  v1.8.0 fixes for two unbounded request-body reads in the acquisition
  datasources (GHSA-rh69-4vqj-9gj8, GHSA-g2x2-jgfg-pg7g), and it aligns the
  proxy with the cluster DaemonSet, which already runs v1.8.1.
- `atlantis` builds a custom image locally (Proxmox CA baked in), so it has
  no registry digest. Its upstream base image is pinned, and the local image
  tag comes from a separate `atlantis_image_tag` variable — the digest in the
  image reference contains colons and would break the `split(':')` that
  derived the tag before.
- `ansible/roles/minecraft` moves to the `mc-server-4` / `data-4` layout
  that is already running. The role in `main` still named `mc-server-2` /
  `data-3`, and running it as-is stopped the live server and tried to start a
  container whose name was taken by a leftover.

## Consequences

- The image reference in each role is long. That is the cost of a digest, and
  it buys a rollback target that actually exists.
- A digest pin does not get security updates on its own. Something has to
  move the digest forward, and for the Kubernetes side that is Renovate. For
  the Ansible side this is still manual — the follow-up is to widen
  Renovate's `fileMatch` so the role templates are covered too.
- The pins are tied to the digests that were running on 2026-10-21. A host
  that was further behind gets the digest from the registry when the role
  runs, because the pull resolves the reference as written.
- The version split between the DMZ proxy and the Pi nodes for
  `nginx-proxy-manager` is resolved by the pin, not by a rollout: the role
  deploys the digest the role names on every host it manages, so the next
  role run on a Pi node would replace the older image with the pinned one.
  The Pi-node NPM stack is stopped by the `site.yml` pre-task and only
  exists for a standby path, so this was not worth an explicit rollout.
- Two containers on `ct-srv-rybbit-01` (`promtail`, `node_exporter`) and
  several on the Pi nodes are **not** managed by any role — they were
  deployed by hand. They are outside this change and remain untracked drift.
- `ct-mgmt-scanopy-01` was unreachable during the change, so the scanopy
  role's pinned image could not be verified live.
