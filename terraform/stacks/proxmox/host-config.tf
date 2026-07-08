# =============================================================================
# Proxmox host-level config -- docs/IAC-GAPS.md item 6.
#
# Research spike result (2026-07-07): the bpg/proxmox provider's actual
# resource coverage for /etc/pve/*.cfg is much better than assumed when
# IAC-GAPS.md was first written -- checked via `terraform providers
# schema -json` against the version already pinned in this stack, not
# guessed from documentation.
#
# Covered here:
# - local-zfs (storage.cfg's zfspool stanza) -- no credentials involved,
#   safe, complete.
# - datacenter.cfg's keyboard layout -- single low-stakes cluster-wide
#   setting, no credentials involved.
#
# Deliberately NOT covered here, with reasons:
# - local-pbs (storage.cfg's pbs stanza): the provider's
#   proxmox_virtual_environment_storage_pbs resource exists and covers
#   every field storage.cfg shows (datastore/server/fingerprint/content/
#   username) -- but PBS storage auth is a password Proxmox keeps
#   separately in /etc/pve/priv/storage/local-pbs.pw, root-only, not in
#   the plaintext storage.cfg and not currently in this repo's Ansible
#   Vault at all. Wiring that in properly (extract, store in Vault,
#   thread through as a Terraform variable) is a real task of its own,
#   not something to rush through in the same pass as the safe wins
#   above -- flagged as a separate follow-up, not silently skipped.
# - jobs.cfg's vzdump backup job (REL-063's `exclude 9000` fix): the
#   provider's proxmox_backup_job resource exists, but its schema only
#   supports `all` (every guest) XOR an explicit `vmid` include-list --
#   there's no equivalent to jobs.cfg's actual live shape (`all 1` +
#   `exclude 9000`). Modeling this in Terraform today would mean
#   switching to an explicit vmid list of every guest except 9000 --
#   which silently stops backing up any FUTURE guest added without also
#   remembering to update this list. That trades a small "no IaC trail"
#   gap for a worse, silent backup-coverage regression -- exactly the
#   failure class this session already hit twice (REL-019, REL-057b).
#   Recommendation: leave this one as a documented manual runbook step
#   in DISASTER-RECOVERY.md, not a Terraform resource, until the
#   provider supports all+exclude directly.
#
# Merged 2026-07-07 (PR #337) with the import{} blocks below already clean
# (2 to import, 0 to change) -- but the actual `terraform apply` that
# performs the import hasn't run yet. Pending explicit per-project
# authorization before applying.
# =============================================================================

# Short-form resource names (not the proxmox_virtual_environment_* prefix
# used by the rest of this stack's VM/container resources) -- the provider
# flags the _virtual_environment_ variants of these two specific resources
# as deprecated, scheduled for removal in v1.0. Using the form the provider
# itself recommends going forward, even though it's inconsistent with the
# rest of this file.
resource "proxmox_storage_zfspool" "local_zfs" {
  id       = "local-zfs"
  zfs_pool = "rpool/data"
  content  = ["rootdir", "images"]
  nodes    = [local.target_node]
  # storage.cfg shows "sparse 1" -- thin_provision is this resource's
  # equivalent field.
  thin_provision = true
}

resource "proxmox_cluster_options" "datacenter" {
  keyboard = "de"
}
