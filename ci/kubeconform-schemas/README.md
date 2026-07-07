# Vendored Kubeconform Schemas

Kubeconform normally fetches JSON schemas for built-in Kubernetes kinds from
`raw.githubusercontent.com/yannh/kubernetes-json-schema` on every run. That CDN
intermittently rate-limits (HTTP 429), which previously failed CI/pre-commit on
PRs that touched zero Kubernetes manifests (see PR #306, then re-assessed and
made durable here).

This directory vendors the schemas for every built-in kind actually used under
`kubernetes/`, so validation runs fully offline — no network call, no flake.
CRD kinds (ArgoCD `Application`, Traefik `IngressRoute`, cert-manager
`Certificate`, etc.) have no upstream schema in that repo at all; they resolve
as "missing" and are skipped via `-ignore-missing-schemas`, same as before —
that behavior is unchanged and doesn't depend on network either way.

## Layout

`v1.31.0-standalone/<kind>-<group>-<version>.json`, matching kubeconform's own
default naming template so `-schema-location` can point straight at this
directory with no translation:

```text
-schema-location 'ci/kubeconform-schemas/{{ .NormalizedKubernetesVersion }}-standalone/{{ .ResourceKind }}{{ .KindSuffix }}.json'
```

## Refreshing (new kind added, or Kubernetes version bump)

If a PR introduces a **built-in** kind not yet vendored here (kubeconform will
report it as `missing schema` and skip it silently instead of validating it —
check the `-summary` skip count if that's unexpected), fetch it once:

```bash
find kubernetes/ -name "*.yaml" -o -name "*.yml" | grep -v users_database | xargs kubeconform \
  -kubernetes-version 1.31.0 -debug -ignore-missing-schemas -summary 2>&1 \
  | grep 'schema found at' | grep -oP 'https://\S+\.json' | sort -u

# for each new URL:
curl -sL --fail "<url>" -o "ci/kubeconform-schemas/v1.31.0-standalone/$(basename "<url>")"
```

Commit the new file(s) alongside the manifest change. On a Kubernetes version
bump, repeat the whole vendoring pass for the new version's subdirectory.
