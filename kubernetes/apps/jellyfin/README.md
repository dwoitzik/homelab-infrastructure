# Jellyfin (+ Usenet stack)

Jellyfin itself does **not** run in this cluster — it runs on a dedicated LXC
(`ct-srv-jellyfin-01`, `10.0.20.254`) with GPU passthrough to the host's APU for
hardware (VAAPI) transcoding, which a k3s pod can't get. This manifest is a plain
`Service` + `Endpoints` pair that lets Traefik's existing IngressRoute keep working
unchanged, pointing at the external LXC instead of a cluster pod.

The Usenet indexer stack (sabnzbd/sonarr/radarr/bazarr/nzbhydra2/jellyseerr) follows
the same pattern in `usenet.yml`, pointing at the media-acquisition LXC — also outside
this cluster entirely.

## Storage / restore

Nothing here to restore — no data lives in k8s for either. Jellyfin's library/config
and the Usenet stack's state live on their respective LXCs, backed up via PBS like any
other LXC, not via Velero/k8s PVC snapshots.

## Known gotchas

- **Use `Endpoints`, not `EndpointSlice`, for this pattern.** A bare `EndpointSlice`
  looks correct via `kubectl` but Traefik's Kubernetes CRD provider resolves Service
  backends through the legacy v1 `Endpoints` API ("subsets") regardless — confirmed
  live via a real `"subset not found"` 404 before switching to `Endpoints`.
- The Usenet indexer's outbound path is intentionally routed through Tor SOCKS5 and
  fails closed if Tor is unreachable — this is deliberate, not a bug. Don't "fix" it
  into leaking.
