# Public Exposure

**This file is the whitelist.** Anything internet-reachable that isn't documented here,
with a reason, is a bug — not a design choice. Last audited: 2026-08-15 (Phase 8,
incident response).

## What's public, and why

| Hostname | What it fronts | Protection | Why it's public |
|---|---|---|---|
| `photos.woitzik.dev` | Immich (photo library) | Rate-limited, Immich's own mobile-app token auth. Cloudflare Access (email OTP) still to be added — see Open Items. | Family uses it for photo backup/access away from home. |
| `headscale.woitzik.dev` | Headscale (Tailscale control plane) | Its own device-registration/preauth-key flow. No Authelia — cannot be, by definition (see below). | A device re-authenticating or joining the mesh has to reach the coordination server *before* any VPN path to it exists. Confirmed by the operator directly (2026-08-15) as a deliberate, structural requirement, not an oversight — see `docs/decisions/ADR-019-public-exposure-allowlist.md`. |
| `mc.woitzik.dev` (Minecraft) | Minecraft server, `ct-dmz-games-01` (VLAN 30) | Not a Cloudflare Tunnel host at all — routed via playit.gg's own relay infrastructure (`doing-sigma.gl.joinmc.link`, playit-owned IP `147.185.221.212`). The home WAN IP never appears in this path. VLAN 30 (DMZ) firewall-isolated from every other zone (verified below). | Friends play on it. The only surface with actual strangers on it. |

**Everything else is not public at all.** Reachable only via LAN or the Headscale/Tailscale
VPN, through the internal AdGuard-rewrite-to-Traefik-LB path, which never touches
Cloudflare or the public internet.

## What was found live and closed this pass

An `atlantis apply` on the prior session's PR #440 had never actually run before this
audit. Live state (confirmed directly via the Cloudflare API, not assumed from any
config file) showed:

- A wildcard Cloudflare Tunnel DNS record (`*.woitzik.dev`) and matching wildcard
  ingress rule, meaning **every possible subdomain of woitzik.dev was internet-reachable
  by default** — even ones never declared in any IngressRoute. Confirmed live: a
  deliberately-made-up nonexistent subdomain (`randomnonexistent12345.woitzik.dev`)
  resolved through Cloudflare's proxy and reached Traefik.
- `atlantis.woitzik.dev` was live and fully functional externally (`HTTP 302` to
  Authelia, confirmed from outside) — GitOps/Terraform control panel reachable from the
  internet, gated by Authelia/CrowdSec but still a real, unintended exposure per this
  phase's own target state.
- `auth.woitzik.dev`, `home.woitzik.dev`, `media.woitzik.dev` — all live via the
  wildcard or their own explicit tunnel rules.

Closed during this audit: ran the pending Terraform apply, which destroyed the wildcard
DNS record and ingress rule, and the `atlantis`/`auth`/`home`/`media` DNS records.
Confirmed via direct Cloudflare API queries (not just the apply's own log) that these no
longer resolve. The apply also removed the dedicated `claude.woitzik.dev` tunnel
(ADR-018) entirely — correct, since that hostname was never on the public allowlist
either; this agent remains reachable via Tailscale/LAN, its original primary path.

The apply hit one real snag (a pre-existing, out-of-band `headscale.woitzik.dev` DNS
record collided with Terraform trying to create it fresh) — fixed with an import block,
documented in `phase8/LEDGER.md` Entry 2. Getting the fix's own completion re-applied
through Atlantis is currently blocked by a self-inflicted chicken-and-egg (Atlantis's
GitHub webhook needs the very DNS record this fix just removed to be reachable) —
parked, not urgent, since the actual dangerous state is already confirmed closed live;
what remains is Terraform's own state bookkeeping catching up.

## Inbound path inventory (Phase 1.2)

- **MikroTik NAT / port forwards:** none declared in Terraform
  (`terraform/stacks/network/nat_portforward.tf`) — the Minecraft/Cobblemon port
  forwards were explicitly removed 2026-07-01 when Minecraft moved to playit.gg. Only
  outbound masquerade rules exist.
- **External port scan of the actual home WAN IP** (`178.202.46.102`, resolved via the
  DDNS hostname the network uses, independent of any woitzik.dev record): 18 common
  ports checked (22, 23, 80, 443, 8006, 8007, 3389, 5900, 25565, 25566, 8080, 8443, 21,
  2049, 445, 139, 6379, 5432) from this LXC, over the real internet path (not a LAN
  shortcut) — every single one timed out (silently dropped, not actively refused),
  consistent with a genuine default-deny firewall rather than an active reject. No open
  ports found.
- **IPv6:** `terraform/stacks/network/firewall_ipv6.tf` declares a correctly
  default-deny INPUT chain (drop all except established/related and ICMPv6) and a
  default-deny FORWARD chain (drop all except established/related, ICMPv6, and internal
  ULA-to-WAN egress). No AAAA record exists for the home WAN/DDNS hostname at all. This
  is the *declared* state; this agent does not currently hold MikroTik router
  credentials to independently confirm it's the *live* state — flagged honestly as
  unverified rather than assumed, same distinction that mattered throughout the original
  recovery. Recommend the operator (or a session with router access) confirm directly.
- **UPnP:** not checked directly (no router access) — no evidence of it in Terraform
  config either way. Flagged as unverified.
- **Cloudflare DNS, full zone:** enumerated via the API directly (not guessed) — 10 A/
  AAAA/CNAME records remain after cleanup: `photos`, `headscale` (both proxied, tunnel),
  `mc` (playit.gg, not proxied — Minecraft's TCP traffic can't go through Cloudflare's
  CDN), `woitzik.dev`/`www` (Vercel-hosted personal site, unrelated to the homelab),
  and DKIM/bounce records for Brevo/SMTP2GO (email sending, not a service exposure).
  Nothing else.

## Minecraft DMZ isolation — verified, not trusted

The operator's claim ("it's in the DMZ behind a proxy") was checked directly rather than
assumed:

- `ct-dmz-games-01` (VMID 302) is on VLAN 30 (`10.0.30.3/24`), a distinct zone from
  Server (VLAN 20), Management (VLAN 10), and Admin (VLAN 100).
- `terraform/stacks/network/firewall_deterministic.tf`: DMZ's forward-chain rules are
  narrow and explicit — rule 09 allows DMZ → a `Reverse_Proxy_Targets` address list on
  ports 80/443/8006/8007 only; rule 11 allows DMZ → internet (`ether1`) only. No rule
  grants DMZ access to any other VLAN, and the chain's own default (rule 99, implied) is
  drop-all.
- **Real gap found, not previously documented:** the `Reverse_Proxy_Targets`
  address-list is *referenced* by the firewall rule but never *declared* anywhere in
  Terraform — it exists only as live, out-of-band router state. Nobody can review its
  actual membership via a PR, and it could silently drift to include something it
  shouldn't without any git history recording the change. This agent doesn't hold
  router credentials to enumerate its current members directly. **Recommendation:**
  bring this address-list under Terraform (`routeros_ip_firewall_addr_list` resources)
  as a priority follow-up — this is exactly the kind of untracked config this whole
  recovery effort has repeatedly found causing real incidents.

## Credential rotation

Not yet performed as of this writing — sequenced after finishing the inbound-path
inventory above, per Phase 1.3's own ordering (find and close first, then rotate).
Tracked in `phase8/STATE.md`; every credential reachable by any of the now-closed
exposures (Atlantis's `terraform@pve` PVE token, anything Authelia/CrowdSec/Traefik
held in front of the wildcard-exposed hosts) is in scope.

## Log review for signs of prior probing/compromise

Not yet performed as of this writing — next action after this document's initial cut.
Will check CrowdSec decisions, Authelia's authentication log, Traefik access logs, and
container logs for the period this exposure was live, specifically for successful
authentications that can't be accounted for, unexpected user/API-key creation, and
unusual outbound connections.

## Open items (not yet done)

- Cloudflare Access (email OTP) in front of `photos.woitzik.dev` — not yet configured.
- Atlantis itself coming off the public internet permanently (it's currently closed at
  the DNS layer, but the underlying direction problem — GitHub needs inbound webhook
  delivery — isn't solved yet; a self-hosted GitHub Actions runner or Cloudflare Access
  + IP allowlisting is still to be built, per Phase 1.1).
- Headscale ACLs (least-privilege within the tailnet, not just "on the tailnet or not").
- Live MikroTik firewall/IPv6/UPnP state confirmation (declared-vs-applied, this
  recovery's recurring gap class) — needs router credentials this agent doesn't
  currently hold.
- `Reverse_Proxy_Targets` address-list brought under Terraform.
- Credential rotation and log review (both above).
