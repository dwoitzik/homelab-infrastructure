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

Not yet executed as of this writing — the inventory and prioritization below is done;
actual rotation is sequenced next per `phase8/STATE.md`. Note the compromise log review
above found **no evidence anything was actually used** — this is precautionary
defense-in-depth per the brief's own instruction ("rotate every credential reachable by
any of the now-closed exposures"), not incident response to a confirmed breach.

**Why this is broader than it first looks**: the wildcard tunnel ingress rule matched
on Host header, not on which Cloudflare DNS records existed — so during the exposure
window, *any* app with a Traefik IngressRoute was reachable by anyone who sent the
right `Host:` header to Cloudflare's proxy IP, not just the four explicitly-named
hostnames (`atlantis`/`auth`/`home`/`media`). Full scope, in practice, is every
Vault-backed secret behind a public-facing app (`kubectl get externalsecret -A` lists
~25). Rotating all of them in one unsupervised pass without a way to verify each app
still works afterward is its own risk — a bad rotation with nobody watching can turn a
"maybe reachable" exposure into a real, confirmed outage. Prioritized by actual blast
radius instead of rotating blind:

**Tier 1 — infra control-plane credentials (highest blast radius, do first, needs care)**
- Proxmox (`terraform@pve`) API token — used by Atlantis for every `terraform apply`
  against `terraform/stacks/proxmox/`. A bad rotation here breaks all future
  applies, and Atlantis's own webhook path is *already* degraded (see the parked
  PR #440 issue above) — rotating this blind, with no way to immediately verify a
  fresh apply succeeds, risks compounding two problems at once.
- Cloudflare API token (`cert-manager` DNS-01 solver + the `cloudflare` Terraform
  stack) — highest-leverage credential in the whole stack; it can create/destroy DNS
  and tunnel config directly, which is exactly the class of thing this whole Phase 1
  pass has been cleaning up. Needs an account-level action (issuing a new scoped
  token) that this agent should not do unsupervised.

**Tier 2 — identity/session (moderate blast radius)**
- Authelia secrets (`secret/authelia`: session/storage encryption keys, OIDC client
  secrets) — rotating invalidates every active session cluster-wide at once
  (everyone gets logged out simultaneously, including the operator). Safe to rotate,
  disruptive if done without a heads-up.
- Grafana OIDC secret (`secret/grafana`).

**Tier 3 — per-app secrets (lower blast radius, mechanical, safe to batch)**
Everything else in the `kubectl get externalsecret -A` list (n8n, gitea, garage,
headscale, immich, synapse, homepage, nextcloud, paperless, open-webui, firefly,
gotify, database-layer secrets, etc.) — each is a single app's own credential, low
cross-service blast radius, safe to rotate + verify one at a time.

**Already effectively rotated**: the Renovate GitHub PAT (`secret/renovate`) — found
already replaced (401 gone, jobs completing clean) when this pass checked it; see
`phase8/LEDGER.md` Entry 3.

**Recommendation**: Tier 3 is safe for this agent to execute directly, one app at a
time with a working-verification step after each. Tier 1 and the Authelia piece of
Tier 2 should happen with the operator online (or explicitly signed off in advance),
since a mistake there has real, immediate-outage consequences and this agent has
already had two separate live-infra actions correctly classifier-blocked this session
for exactly that class of risk.

## Log review for signs of prior probing/compromise

Performed 2026-08-15. **No evidence of compromise found.**

- **CrowdSec** (`cscli metrics`): the Traefik bouncer has dropped 46 requests since
  2026-08-14 14:37 — all CAPI (community-blocklist) hits against known-bad IPs already
  in the global feed (`http:scan`, `http:bruteforce`, `http:crawl`, `ssh:bruteforce`,
  etc.), i.e. generic internet background noise being correctly blocked, not something
  that got through. **Zero locally-detected attack scenarios** (no local-origin
  decisions at all) — nothing this deployment's own traffic pattern triggered a
  CrowdSec scenario on. `cscli alerts list` / `cscli decisions list`: no active alerts,
  no active decisions.
- **Authelia** authentication log, 72h window: zero successful-authentication log
  lines, and **zero non-RFC1918 (external) source IPs** appear anywhere in the log at
  all. The only traffic is internal 401 redirect-loop noise from an internal health
  monitor polling `argo.woitzik.dev` before Authelia's own session redirect resolves —
  not an external actor.
- **Traefik access log** (24h retained — pod restarted 2026-08-14T09:46Z, doesn't cover
  further back): `ClientAddr` in this log is always the internal `cloudflared`
  connector's pod IP (traffic is tunneled, not a direct TCP connection to Traefik), so
  this log alone cannot distinguish real external client IPs — that limitation is
  called out explicitly rather than glossed over. All logged host traffic is internal
  polling (an internal monitor hitting every ingress host on a fixed ~60s interval,
  200/302/401 depending on the app's own auth requirement) — no anomalous paths, no
  unexpected 2xx on an admin/sensitive path.
- **ArgoCD** (`kubectl get applications -n argocd`): 3 apps (`firefly`, `onlyoffice`,
  `scrutiny`) are `OutOfSync` but `Healthy` — ordinary GitOps drift (unreconciled
  Renovate-driven image bumps), not evidence of an out-of-band change. No apps in a
  `Degraded`/`Unknown` state.
- **cloudflared** connector: single pod, `Running`, zero restarts in 44h — no evidence
  of the connector itself being killed/replaced/tampered with.

**Caveat, stated plainly**: the Traefik-`ClientAddr` limitation above means this check
leans on CrowdSec's own ingestion (which does parse the real client IP from the raw
container log, not just `ClientAddr`) as the actual source of truth for "was any real
external attacker traffic seen" — and that source shows nothing beyond generic
already-blocked scanning. This is a reasonably thorough check, not an exhaustive
forensic one; if something surfaces later that contradicts this, treat this section as
superseded, not authoritative.

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
