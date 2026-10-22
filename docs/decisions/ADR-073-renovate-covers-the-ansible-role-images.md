# ADR-073: Renovate covers the Ansible role images

## Status

Accepted and applied, 2026-10-22.

## Context

The Kubernetes manifests and the media-acquisition compose file are covered by
Renovate, so their images get version and digest updates automatically. The
Ansible roles were not: `renovate.json` configured the `kubernetes` and
`docker-compose` managers, and the `ansible` manager was never given a file
pattern. The result was that thirteen images across nine roles carried either
a floating tag or no tag at all, and none of them were ever proposed for an
update — including `adguard/adguardhome` on the LAN DNS filter and
`jc21/nginx-proxy-manager` on the internet-facing reverse proxy.

Renovate's own `ansible` manager does reach the role directories, but only
their `tasks/` and `files/` parts. It parses `community.docker.docker_image`
tasks and Dockerfile `FROM` lines. The compose templates under
`ansible/roles/*/templates/` are Jinja files, and neither the `ansible` nor the
`docker-compose` manager can read them: the compose manager parses YAML, and a
Jinja template is not valid YAML — a line like `- {{ jellyfin_base_dir }}/config:/config`
is a mapping, not a string, so the extractor rejects the file.

## Decision

**Let the `ansible` manager use its default file patterns and give the
`docker-compose` manager the two compose files it should also see.**

The `ansible` manager needs no configuration. Its defaults already cover
`tasks/` and `files/` under a role directory, which is where the images in the
`adguard`, `minecraft`, `unbound` and `atlantis` roles live.

Two files are added to the `docker-compose` manager's `fileMatch`: the
media-acquisition compose file (already there) and `docs/wazuh/docker-compose.yml`.
The Kubernetes `fileMatch` is widened from `.yml` to `.ya?ml`, because
`kubernetes/apps/vaultwarden/vaultwarden.yaml` was invisible to Renovate and
its `vaultwarden/server` image carried no digest.

A package rule covers the role images: patch, minor and digest auto-merge
after CI green and the existing three-day soak, major stays PR-only because a
role image can carry a config migration. The rule is listed before the
media-acquisition rule so the latter keeps its own policy for the
linuxserver images.

## Consequences

- The images in the roles' `tasks/` and `files/` directories are now updated
  automatically: `adguard/adguardhome`, `ghcr.io/bakito/adguardhome-sync`,
  `itzg/minecraft-server`, `klutchell/unbound`, `willfarrell/autoheal` and
  `ghcr.io/runatlantis/atlantis`. Verified in a dry run against the real
  repository: all six are extracted with their current version and digest.
- **The compose templates under `ansible/roles/*/templates/` are still not
  covered.** They hold the images of the rybbit, nginx-proxy-manager,
  jellyfin, monitoring_agent, mikrodash and scanopy_daemon roles, plus the
  adguard role's own compose file. The custom regex manager
  (`customManagers` with `customType: regex`) is the tool for that, but it did
  not load in the Renovate version running here (43.253.2): the manager never
  appeared in the run log, with either `fileMatch` or `managerFilePatterns`,
  with or without `enabledManagers`. The images in those templates are pinned
  to a digest by hand, so they are deterministic, but they need a manual
  update.
- A merged Renovate PR for a role image only reaches the hosts on the next
  `ansible-playbook` run. The role stacks are not deployed by a GitOps converge
  the way the Kubernetes manifests are, so an image update is a two-step
  operation: merge, then run the role. The auto-merge policy is still right,
  because the alternative is a runtime that stays a year behind.
- `fileMatch` is deprecated in favour of `managerFilePatterns` in current
  Renovate. The deprecated form is kept because it is the one that works in
  the pinned version: `managerFilePatterns` is additive, and a pattern that
  matches the role task files made the `ansible` manager find nothing at all.
