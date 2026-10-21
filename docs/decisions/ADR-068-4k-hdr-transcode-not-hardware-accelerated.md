# ADR-068: Jellyfin HDR tone-mapping is not hardware-accelerated on the host APU

**Date:** 2026-10-20
**Status:** Accepted, applied

## Context

Jellyfin runs in `ct-srv-jellyfin-01` on the Proxmox host's AMD Barcelo APU (RADV
RENOIR, `1002:15e7`) with `/dev/dri/renderD128` passed through. VAAPI hardware
encoding is enabled (`HardwareAccelerationType=vaapi`) and works well: 1080p
`h264_vaapi` transcodes run many times faster than real time, and hold that rate
while the Usenet stack saturates the host.

The question was whether 4K HDR sources can be tone-mapped to SDR in real time when
a client cannot decode HDR directly. Jellyfin offers four tone-mapping backends;
each was tested directly against a real HDR10 source (HEVC Main10, `smpte2084`) on
this exact hardware:

| Path | Result |
| --- | --- |
| VPP `tonemap_vaapi` | `Failed to configure output pad` / `-22 Invalid argument` — the Barcelo VPP has no tone-mapping unit |
| OpenCL `tonemap_opencl` | `Failed to get number of OpenCL platforms: -1001` — no OpenCL runtime in the official `jellyfin/jellyfin` image |
| Vulkan/libplacebo | `libplacebo Validation failed: params->shared_mem.stride_w >= params->w` — RADV RENOIR image-import stride mismatch |
| Software `tonemapx` | `0.525x` (and `0.336x` for the older `zscale`+`tonemap` chain) at 4K→1080p — below real time |

Jellyfin's own log confirms the hardware negotiation reached the right place — the
device reports `supports Vulkan DRM modifier` and `supports Vulkan DRM interop`, and
Vulkan enumerates `AMD Radeon Graphics (RADV RENOIR)` — so this is not a missing
driver or a passthrough fault. It is a hardware/runtime limitation at the
tone-mapping stage specifically.

## Decision

Leave `EnableTonemapping` **false**. Do not attempt server-side 4K HDR → SDR
tone-mapping on this host; watch HDR via Direct Play instead.

## Reasons

Every accelerated tone-mapping path fails on this iGPU, and the only working one
(software) is roughly half real time at 4K, so a transcoded HDR film would buffer
indefinitely. Enabling tone-mapping would therefore turn a working "plays immediately
with slightly-wrong colours" case into a non-playing one, for no benefit. Direct Play
is the correct architecture for HDR regardless: a client that decodes HEVC 10-bit and
HDR itself (Apple TV 4K, Fire TV Stick 4K, recent smart TVs) never asks the server to
tone-map, so the server CPU/GPU cost is zero and the picture is the source's real HDR.

## Trade-offs

- An SDR-only client playing a 4K HDR file gets a flat, un-tone-mapped image (the
  server passes the stream through without HDR conversion) rather than a correctly
  mapped SDR image. Fluent playback was chosen over correct colours.
- Adding a Mesa rusticl OpenCL runtime (custom image) might enable `tonemap_opencl`,
  but the same class of GPU is not known to tone-map 4K in real time via software
  OpenCL; that route is not pursued without evidence it clears real time.

## Consequences

- `EncodingOptions` keeps `EnableTonemapping=false`; the value lives in
  `/opt/jellyfin/config/config/encoding.xml` on the LXC, not in Git, and is set via
  the Jellyfin dashboard.
- If correct HDR→SDR tone-mapping becomes a requirement, it needs different hardware —
  an Intel Arc / iGPU with VPP tone-mapping, or an NVIDIA GPU — not a config change
  here. Recorded so this is not re-litigated per incident.
- Direct Play support on the client is the documented expectation; the Jellyfin
  README states it explicitly.
