# ADR-043: k3s Tailscale Exit Node Falsely Advertises IPv6 It Cannot Serve

**Date:** 2026-09-09
**Status:** Proposed -- finding confirmed live, fix not yet applied (affects David's live VPN exit path, his call on timing).

## Context

David reported push notifications and app data taking too long to arrive
on his Pixel when connected via headscale/tailscale, and asked for a real
investigation rather than assumed "normal tailnet overhead."

`kubernetes/apps/headscale/subnet-router.yml` already documents a known,
partial fix in its own comments: "containerboot only auto-enables IPv4
forwarding... IPv6 stays off despite `--advertise-exit-node` needing it,
breaking clients on IPv6-primary mobile carriers" -- with a `postStart`
hook (`sysctl -w net.ipv6.conf.all.forwarding=1`) attempting to address it.

Checked live whether that fix actually resolves the problem. It doesn't.
`kubectl exec` into the pod: `net.ipv6.conf.all.forwarding` is genuinely
`1`. But `ip -6 addr` shows only a link-local address on `eth0` -- no real
global IPv6 on the pod's own network interface at all. The k3s CNI's pod
network is IPv4-only; there is no IPv6 uplink for this pod to forward
traffic onto, sysctl or not. Tailscale's own runtime agrees: its `NetInfo`
log line reports `ipv6=false` on every restart, including a fresh one
performed today. The `postStart` sysctl fixes the kernel's willingness to
forward IPv6 -- it does not, and cannot, fix the absence of a real IPv6
path out of the pod.

Despite this, headscale's route table (`headscale nodes list-routes
--output json`) shows this node (`homelab-router-1`) as an approved,
available *and currently serving* candidate for `::/0` -- advertising
IPv6 exit capability it cannot actually deliver.

Separately, `rpi-srv-02` -- documented elsewhere in this repo (per
`CLAUDE.local.md`) as a deliberate manual-failover peer, not a
concurrently-active standby, matching the same "human runs the runbook on
purpose" philosophy ADR-029 established for headscale/vaultwarden -- is
*also* currently approved and serving as primary for all three routes
(`0.0.0.0/0`, `::/0`, and the `10.0.20.0/24` LAN route), simultaneously
with the k3s router, not only as an emergency fallback. Restarting the
k3s-hosted subnet-router pod (a real, safe, reversible action taken during
this investigation) did not change this split state -- it's stable, not a
stuck failover from a past blip.

`rpi-srv-02` is meaningfully weaker hardware (Raspberry Pi 4B vs. the
k3s router's Ryzen-hosted VM). If tailscale's client-side exit-node
selection on David's Pixel (which this agent cannot inspect or control
directly -- that's a client-side app setting) is choosing `rpi-srv-02`
for some or all of its traffic, whether because it's the only fully
dual-stack-capable candidate or for another reason, that would plausibly
explain meaningfully worse performance for exactly the kind of traffic
reported: general internet traffic (push notifications, app data) routed
through a full-tunnel exit node.

## What was NOT done, and why

This agent did not revoke `rpi-srv-02`'s exit-node route approval, even
though that's the most direct lever available (`headscale nodes
approve-routes`, a live action, not a git change) and would force all
exit-node traffic through the faster k3s path. Two reasons:

1. It would remove real redundancy on the same day a live cluster
   incident (see the day's other LEDGER entries) already demonstrated the
   k3s-hosted node's host can come under real pressure. Cutting David's
   only fallback path the same day, without him aware in the moment, is
   the wrong risk to take unilaterally.
2. This looks like exactly the class of decision ADR-029 already
   established a philosophy for: HA on this hardware works through
   *deliberate, human-triggered* failover, not standing dual-availability,
   specifically to avoid this kind of ambiguous split-brain-adjacent
   state. Applying that same philosophy here (matching an existing,
   accepted pattern) rather than inventing a new one is the right call --
   but it's still a real change to David's live exit-node path, and his
   call on timing.

## Proposed fix (not applied)

Narrow `rpi-srv-02`'s standing route approval to the LAN subnet only
(`10.0.20.0/24`), removing its standing exit-node (`0.0.0.0/0`/`::/0`)
approval so it can't be selected day-to-day. Document a manual
re-approval step (`headscale nodes approve-routes --routes
0.0.0.0/0,::/0,10.0.20.0/24 <id>`) for the same kind of deliberate,
human-triggered failover ADR-029 already uses elsewhere, rather than
leaving both nodes concurrently available.

Separately, and independently: either accept the k3s router's IPv6
exit-node advertisement is currently a broken promise (real if the CNI
can't be made dual-stack without larger networking changes -- out of
scope for this ADR to decide), or invest in giving the k3s pod network
real IPv6 connectivity so the advertisement stops being false. Whichever
is chosen, the current state -- advertising a capability the node cannot
deliver -- is worth correcting regardless of the route-approval decision
above.

## Consequences

Left for David's decision, tracked in `QUESTIONS.md`. Added to this
agent's standing regular-check list (per his explicit request) so this
gets re-verified on a schedule rather than needing to be manually
re-reported if it recurs or if a decision is made and needs confirming.
