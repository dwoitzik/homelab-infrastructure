# IaC Gaps — hand-created infrastructure with no Git trail

**Status:** audit only, 2026-07-07. No migrations executed. This is the full list, for
review before any of it is worked.

## Why this exists

Three separate incidents this session were traced back to critical config that lives
outside Terraform/Ansible/GitOps entirely, with no record of who created it, when, or
why:

- **Garage buckets** (REL-057b) — a bucket-sharing bug between Velero and CNPG's own
  backup traffic caused intermittent `BackupStorageLocation: Unavailable`. The fix
  (a new scoped bucket) was one `garage bucket create` command — same as how all 4
  buckets came to exist, with zero record in Git.
- **The Cloudflare API token Secret** (REL-061/REL-048) — a bare, hand-created
  Kubernetes `Secret` went dead with nothing to detect it; the same failure class as
  every other bare-Secret bug found this session (SEC-013, SEC-014, SEC-015).
- **The `vzdump exclude 9000` fix** (REL-063) — lives entirely in
  `/etc/pve/jobs.cfg` on the Proxmox host. It's confirmed correct and working, but if
  that host's `/etc/pve` config were lost tomorrow, there's no file in this repo that
  would tell a rebuild to re-add it.

This is exactly the "hand-created infra, no IaC trail" pattern a portfolio reviewer is
trained to look for. This document is the systematic sweep, not a fix — each item
below has risk + effort, and a proposed order at the end.

## Method

- `kubectl get secrets -A`, filtered out anything with an `ownerReference`, an
  `external-secrets.io`/Helm-managed label, or a cert-manager-issued TLS type — what's
  left is either a real hand-created Secret or dead cruft.
- `garage bucket list` cross-checked against `grep -r garage terraform/` (zero hits).
- SSH to the Proxmox host, read `/etc/pve/{jobs,storage,datacenter}.cfg` directly,
  cross-checked against `terraform/stacks/proxmox/*.tf` (VM/LXC resources only — no
  host-level config resources exist).
- Cloudflare zone's live DNS records pulled via the API, cross-checked against
  `terraform/stacks/cloudflare/main.tf`'s `resource` blocks.
- Vault: no `terraform/stacks/vault*` directory exists at all; every Vault write this
  session (and, per `AUDIT.md`'s history, every prior session) went through
  `kubectl exec vault-0 -- vault kv put/patch` directly against a live pod.
- ArgoCD `Application` objects: cross-checked every live `Application` name against
  `kind: Application` blocks in `kubernetes/system/**` — **this came back clean**, no
  orphans. REL-042/044/045/046's bootstrap-Application sweep (2026-07-05) fully closed
  that particular gap; noted here for completeness, not as a new finding.

## Findings

### 1. `gitea-secrets` / `nextcloud-secrets` — live placeholder passwords in production

**Status: RESOLVED, #332.** Rotated live (not just in Git) — real `SECRET_KEY`/
`INTERNAL_TOKEN` for Gitea, real Postgres + admin passwords for Nextcloud, all written
to Vault and wired via `ExternalSecret`. Full history checked (767 commits): no real
secret was ever committed, only the placeholder — no history rewrite needed. Left below
for context; not part of the remaining migration sequence.

**Risk: Critical.** `kubernetes/apps/gitea/secrets.yml` and
`kubernetes/apps/nextcloud/secrets.yml` are checked into Git as plain `Secret`
manifests with `stringData` values literally reading `REPLACE_WITH_ADMIN_PASSWORD` —
templates that were apparently never wired to a real secret source. Checked the live
cluster values directly: **both are still the literal string
`REPLACE_WITH_ADMIN_PASSWORD` right now**, not placeholders that got overwritten later
by a real value.

Both apps' `Deployment`s are live and running (`gitea`: 1/1 Running 5d6h;
`nextcloud`: 1/1 Running 2d16h). Both services are `ClusterIP`-only today — no
`Ingress`/`IngressRoute` for either was found, so this isn't currently reachable from
the LAN or internet, only from inside the cluster's pod network. That's a mitigating
factor, not a fix: any pod in the cluster (or anyone who adds an `Ingress` for either
app later, e.g. to actually use them) can log in as `admin` with a password sitting in
public GitHub history.

Every sibling app that *does* use `ExternalSecret` (Authelia, cloudflared) has a
working, git-tracked pipeline for this. Gitea and Nextcloud simply never got migrated
onto it.

**Effort: Small.** Identical pattern to REL-061/SEC-013/SEC-014 this session: generate
real credentials, write them into Vault (`secret/gitea`, `secret/nextcloud`), replace
`secrets.yml` with an `ExternalSecret`, `kubectl delete` the live placeholder Secret so
ExternalSecret recreates it with the real value, then actually re-authenticate to both
apps with the new credentials to confirm the rotation took.

### 2. Vault's own configuration — policies, mounts, KV structure

**Risk: High.** There is no `terraform/stacks/vault*` directory. Every Vault
secrets-engine mount, every KV path structure (`secret/cloudflare`, `secret/garage`,
`secret/gitea`, etc.), and every policy has been created ad hoc via
`kubectl exec vault-0 -- vault kv put/patch` — including everything wired up *during
this very session* (REL-061's `secret/cloudflare`, REL-057b's new bucket credentials).
`vault-unseal-keys` (the Secret holding the unseal material itself) is also a bare,
hand-created `Secret` with no ExternalSecret/Vault-behind-Vault story, which is
expected (it can't depend on Vault being unsealed to bootstrap Vault) but is worth
stating plainly as a permanent, load-bearing manual step.

This is the highest-blast-radius item on this list: Vault is the trust root for every
other secret in the cluster. If the Vault pod's PV were lost, rebuilding from Git alone
recreates *nothing* of the KV structure — only `DISASTER-RECOVERY.md`'s prose and this
session's own `AUDIT.md` entries record what paths and policies are supposed to exist,
and even those are incomplete (this document itself is the first time anyone
enumerated the actual KV paths in use).

**Effort: Medium-to-Large.** Terraform has a `hashicorp/vault` provider that can manage
mounts, policies, and even KV metadata (not raw secret values, by design — those stay
out of state). Realistic scope: declare the mount(s) and policies in Terraform,
consider a checked-in *inventory* of expected KV paths (path + description, no values)
so a rebuild has a checklist even where the values themselves must come from backup or
be regenerated.

### 3. Garage buckets — 4 buckets, zero Terraform

**Risk: High.** `garage bucket list` shows 4 buckets (`loki-data`, `velero`,
`terraform-state`, `cnpg-backups`) — all created via the `/garage` CLI directly, none
in Terraform. One of these (`terraform-state`) is the backend Terraform itself uses
(`ADR-003-garage-terraform-backend.md` already documents this is deliberately kept out
of Terraform to avoid a chicken-and-egg bootstrap problem — that one's exempt by
design). The other 3 are not: `velero` and `cnpg-backups` in particular have already
caused a real incident this session (bucket-namespace collision, REL-057b) purely
because there was no record of who owned which bucket for what.

**Effort: Medium.** Garage exposes an S3-compatible admin API; there's no
Garage-specific Terraform provider, but bucket creation/key-grants could be modeled
with a generic `aws` provider pointed at Garage's S3 endpoint, or with a small
`null_resource`/API-call wrapper if the S3-compatible surface doesn't cover Garage's
admin operations (bucket aliasing, per-key permission grants) cleanly. Needs a short
research spike before committing to an approach.

### 4. Cloudflare DNS zone — 4 of ~30 records under Terraform

**Risk: Medium.** `terraform/stacks/cloudflare/main.tf` manages exactly 4
`cloudflare_dns_record` resources (`photos`, `atlantis`, `media` — all Cloudflare
Tunnel CNAMEs — plus `mc_playit`) and one tunnel config. The live zone has ~30 records
via the API — `auth.woitzik.dev` (Authelia — the one guarding almost everything else),
`headscale`, `home`, `jf`, `link`, `vw`, `www`, the bare `woitzik.dev` root, 3×MX,
DKIM/DMARC/SPF TXT records, and a Vercel verification TXT — all hand-created via the
dashboard, no Git record of what they should be. `_acme-challenge` TXT records are
expected to be ephemeral (cert-manager's DNS-01 solver creates/deletes them
automatically) and aren't a gap in the same sense — noted, not counted as a finding.

`auth.woitzik.dev` pointing at the wrong thing (or being silently deleted) would break
authentication for every other exposed service — it's the single highest-consequence
record on the list that isn't already covered.

**Effort: Medium.** Mechanical but tedious — `terraform import` each real record (not
the ephemeral ACME ones), verify no diff, done. Biggest risk during migration is
transient DNS breakage if an imported record's Terraform representation doesn't
exactly match live state on the first `plan`; do this one record at a time, not in
bulk.

### 5. `homepage-secrets` — 9 real API keys/passwords, no ExternalSecret

**Risk: Medium.** Bundles `HOMEPAGE_VAR_ADGUARD_PASSWORD`, `ARGOCD_TOKEN`,
`BAZARR_API_KEY`, `GRAFANA_PASSWORD`, `JELLYFIN_API_KEY`, `JELLYSEERR_API_KEY`,
`RADARR_API_KEY`, `SABNZBD_API_KEY`, `SONARR_API_KEY` — all real, live credentials
(unlike the gitea/nextcloud case, these are correct working values, just with no
IaC/Vault trail). A hand-created Secret consumed only by `homepage.yml`.

**Effort: Small.** Same ExternalSecret pattern used repeatedly this session — one Vault
path (`secret/homepage`) with 9 keys, one `ExternalSecret`, delete the hand-created
Secret. Mechanical, no live credential rotation needed (reuse the existing values).

### 6. Proxmox host-level config — `jobs.cfg`, `storage.cfg`, `datacenter.cfg`

**Risk: Low-Medium.** `terraform/stacks/proxmox/*.tf` only manages VM/LXC resources
(`vm.tf`, `lxc.tf`). The vzdump backup job definition (`REL-063`'s `exclude 9000` fix
lives here), the storage pool definitions (`local-zfs`, `local-pbs` — including the PBS
connection fingerprint), and datacenter-wide settings (currently just the keyboard
layout, low stakes on its own) are all hand-edited files on the host with no Git
record. Low day-to-day change frequency lowers the risk relative to the items above,
but it's exactly the kind of thing a from-scratch rebuild (per
`DISASTER-RECOVERY.md`'s stated goal) would silently miss.

**Effort: Unknown, needs a research spike.** The `bpg/proxmox` Terraform provider (used
elsewhere in this repo) has only partial coverage of host-level `/etc/pve/*.cfg` —
needs to be checked stanza-by-stanza before committing to how much of this can actually
move into Terraform versus staying as a documented manual runbook step in
`DISASTER-RECOVERY.md`.

### 7. `kasm-secrets`, `mullvad-wg-config`, `seafile-secrets` — dead cruft, not a migration target

**Risk: None (hygiene only).** No live `Deployment`/`Pod`/anything references any of
these 3 Secrets, and none of them appear anywhere in `kubernetes/` — leftovers from
apps that were retired or never actually deployed via GitOps (`kasm`, `seafile`) plus
one (`mullvad-wg-config`) with no corresponding app in this repo at all. Not a "bring
under IaC" case — there's nothing live to represent. Just delete them.

**Effort: Trivial.** `kubectl delete secret kasm-secrets mullvad-wg-config
seafile-secrets -n apps`, done in one PR-less housekeeping pass (or folded into
whichever of the above PRs touches Secrets anyway).

## Proposed priority order

Ordering principle, stated explicitly: **(1) live-exposed issues before latent ones,
(2) among latent issues, Vault-into-IaC ranks highest** — it's the trust root for every
other item here, and currently the least reproducible component in the stack (a lost
Vault PV recreates nothing from Git).

Applying that: item 1 was the only genuinely *live-exposed* case found in this sweep
(an actual known-guessable credential, actually accepted by a running service) — it's
done, via #332. Every remaining item is *latent* (a reproducibility/blast-radius gap,
not an active exposure), so principle 2 sets the rest of the order — Vault first among
them, then ranked by how much operational damage a repeat incident would do.

1. ~~`gitea-secrets`/`nextcloud-secrets` placeholder passwords~~ — **done, #332.**
2. **Vault's own configuration** — highest-priority latent item, per principle 2.
   Every other item below either stores secrets in Vault already or would if migrated
   (Garage keys, Cloudflare's own token, homepage's bundle) — doing this first means
   those migrations land on a Terraform-managed Vault instead of adding more ad hoc
   `vault kv put` calls on top of an already-undocumented base.
3. **Garage buckets** — already caused 2 real incidents this session (REL-019,
   REL-057b). Medium effort, well-scoped.
4. **Cloudflare DNS zone** — risk concentrated almost entirely in one record
   (`auth.woitzik.dev`); could be split into "import `auth` alone first" (small,
   high-value) then the rest (medium, lower urgency).
5. **`homepage-secrets`** — Small effort, mechanical — good candidate to bundle with
   item 2's PR since it's the same ExternalSecret pattern, once Vault's own mounts are
   Terraform-managed.
6. **Proxmox host-level config** — Low-Medium risk, low day-to-day change frequency.
   Start with the research spike (what can `bpg/proxmox` actually cover) before
   committing effort here; may end up partially "document in `DISASTER-RECOVERY.md`"
   rather than "Terraform resource" for whatever the provider can't reach.
7. **Dead Secret cleanup** (`kasm-secrets`, `mullvad-wg-config`, `seafile-secrets`) —
   No risk, trivial effort. Fold into whichever PR is already touching Secrets;
   doesn't need its own slot in the sequence.

**Not executed in this pass** — items 2-7 are still just the list, awaiting explicit
sequencing approval before any of them is worked.
