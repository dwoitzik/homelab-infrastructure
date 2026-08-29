# Beszel

Lightweight server-monitoring dashboard (`beszel.woitzik.dev`) — agent + hub pattern,
`beszel-agent` runs alongside the hub and reports resource usage.

## Storage

`nfs-client` PVC holding the hub's SQLite DB and its own SSH keypair (used to talk to
agents). Small, not latency-sensitive.

## Known gotchas

- Pod-level `dnsConfig.options: ndots: "1"` is already set — needed to avoid the
  cluster's `*.woitzik.dev`-wildcard DNS hijack bug (see `DISASTER-RECOVERY.md` §7) affecting
  its own outbound calls. If this gets removed during a manifest edit, short-hostname
  lookups from this pod will silently break again.
