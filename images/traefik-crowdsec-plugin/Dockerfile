# syntax=docker/dockerfile:1

# CrowdSec bouncer plugin source for Traefik's experimental.localPlugins (ADR-079).
# An initContainer copies /plugins-local into an emptyDir, so Traefik never
# downloads the plugin at start.
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS source

# Renovate bumps both lines together (customManagers in renovate.json).
# renovate: datasource=github-tags depName=maxlerebourg/crowdsec-bouncer-traefik-plugin
ARG PLUGIN_VERSION=v1.6.0
ARG PLUGIN_COMMIT=1f6a8991c8f9273cf21a5da3a6e6875a5c0034cc

RUN apk add --no-cache git \
    && git clone --depth 1 --branch "${PLUGIN_VERSION}" \
       https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin.git /src \
    && test "$(git -C /src rev-parse HEAD)" = "${PLUGIN_COMMIT}" \
    && test -f /src/.traefik.yml \
    && rm -rf /src/.git

# busybox rather than scratch: the initContainer needs cp.
FROM busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec

COPY --from=source /src /plugins-local/src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin

USER 65534:65534
