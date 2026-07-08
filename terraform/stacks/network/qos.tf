###############################################################################
# WAN QoS / bufferbloat mitigation
#
# Discord voice was choppy/robotic for people hearing the user, confirmed
# clean over mobile data -- home network path, not Discord/ISP. Investigation
# found: zero QoS or AQM existed on ether1 (WAN) -- `/queue simple` and
# `/queue tree` were both empty, so the interface falls back to RouterOS's
# default `pfifo` (plain FIFO, no active queue management). ISP profile is
# asymmetric cable: 1000 Mbit down / 50 Mbit up (real measured value,
# confirmed by the user via repeated live speedtests -- NOT taken from
# MySpeed's configured target, which happened to match but wasn't the
# authoritative source). A 50 Mbit upload ceiling is easy to saturate, and
# with no AQM, nothing stops the router's own send buffer from filling and
# inflating latency for everything sharing the link -- textbook bufferbloat,
# and exactly what robotic/choppy voice looks like.
#
# fasttrack is enabled globally (see firewall_deterministic.tf) and bypasses
# mangle marking for established connections -- a mangle-mark + queue-tree
# design would silently stop working for most real traffic. An address-based
# Simple Queue sidesteps this entirely: it enforces at the interface's
# queuing layer, independent of fasttrack/marks (confirmed: `target` is a
# plain IP-range match, no mangle dependency).
#
# max_limit is intentionally ~90% of the real measured ceiling, not the full
# 1000/50 -- capping below the ISP's own ceiling keeps THIS router's queue as
# the bottleneck instead of the ISP modem's, which is what lets PCQ's
# per-flow fairness actually do its job. Without that margin, the real
# bottleneck (and its buffer) would sit inside the ISP's modem, outside this
# queue's control, and bufferbloat would still happen there instead.
#
# pcq-upload-default/pcq-download-default round-robins per-flow, so one bulk
# transfer (e.g. Cloudflare-tunneled remote Jellyfin/Immich streaming, which
# is the realistic WAN-upload consumer here -- traced and ruled out Garage/
# PBS backups (LAN-local, don't cross WAN) and image pulls (download, not
# upload) as the culprits before proposing this) gets its own sub-queue
# instead of monopolizing the link against Discord's UDP voice flow. This is
# the standard RouterOS-native SQM approach when CAKE/fq_codel isn't
# available -- checked this RouterOS build's queue types
# (`/queue type print`): only pfifo/bfifo/red/sfq/pcq/mq-pfifo, no CAKE.
#
# target = 10.0.0.0/16 covers all 5 VLANs (10.0.10-100.0/24, see
# docs/vlan-segmentation.md) in one queue -- deliberately not split per-VLAN
# yet, since the goal right now is fixing the shared WAN bottleneck, not
# per-VLAN prioritization.
resource "routeros_queue_simple" "wan_egress_sqm" {
  name      = "wan-egress-sqm"
  target    = ["10.0.0.0/16"]
  max_limit = "45M/900M"
  queue     = "pcq-upload-default/pcq-download-default"
  comment   = "SQM: cap WAN link under real measured ISP ceiling (1000/50 Mbit) + PCQ per-flow fairness so one bulk transfer can't fill the buffer and starve latency-sensitive traffic (Discord voice bufferbloat fix)"
}
