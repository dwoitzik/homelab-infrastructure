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

## Transcoding / HDR tone-mapping

VAAPI hardware **encoding** works on the host APU (AMD Barcelo, RADV RENOIR):
`h264_vaapi` runs 1080p transcodes many times faster than real time, and an 8-bit
1080p library transcodes cleanly alongside Usenet load. Hardware **HDR tone-mapping
does not** — every accelerated path fails on this iGPU:

| Method | Result |
| --- | --- |
| VPP (`tonemap_vaapi`) | hardware lacks VPP tone-map (`-22 Invalid argument`) |
| OpenCL (`tonemap_opencl`) | no OpenCL runtime in the official image (`-1001`) |
| Vulkan/libplacebo | libplacebo stride-validation error against RADV RENOIR |
| Software (`tonemapx`) | 0.525x on 4K — below real time, buffers badly |

So `EnableTonemapping` stays **false**: a 4K HDR source that must be transcoded for a
non-HDR client gets tone-mapped by neither hardware nor a fast enough software path.
The intended way to watch HDR is **Direct Play** — a client that decodes HEVC 10-bit
and HDR itself (Apple TV 4K, Fire TV Stick 4K, most recent smart TVs) never asks the
server to tone-map. If correct colours on an SDR-only client become a real need, the
options are a custom image with a Mesa rusticl OpenCL runtime, or a GPU with working
hardware tone-mapping (Intel Arc, NVIDIA).

## Known gotchas

- **Use `Endpoints`, not `EndpointSlice`, for this pattern.** A bare `EndpointSlice`
  looks correct via `kubectl` but Traefik's Kubernetes CRD provider resolves Service
  backends through the legacy v1 `Endpoints` API ("subsets") regardless — confirmed
  live via a real `"subset not found"` 404 before switching to `Endpoints`.
- The Usenet indexer's outbound path is intentionally routed through Tor SOCKS5 and
  fails closed if Tor is unreachable — this is deliberate, not a bug. Don't "fix" it
  into leaking.
