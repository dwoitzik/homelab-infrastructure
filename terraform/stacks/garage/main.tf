# =============================================================================
# Garage S3 buckets -- docs/IAC-GAPS.md item 3.
#
# All 4 buckets on this Garage instance were created via `garage bucket
# create` directly, zero Git record of who/when/why. One (terraform-state)
# is deliberately exempt -- it's the backend this very stack's state lives
# in, kept out of Terraform to avoid a bootstrap chicken-and-egg problem
# (see docs/decisions/ADR-003-garage-terraform-backend.md). The other 3 are
# managed here.
#
# Scope, stated plainly: this covers bucket EXISTENCE only (create/list/
# delete via Garage's S3-compatible API). Per-key access grants (which
# service's Garage key can read/write which bucket -- e.g. velero's own
# "velero" key, cnpg's "cnpg-backup"/"cnpg-backups-key") are managed through
# Garage's own admin API, which is NOT S3-compatible and has no Terraform
# provider covering it. Those grants are untouched by this stack and remain
# a manual `garage bucket allow` step -- a known, documented gap, not
# silently half-solved. See the effort note in docs/IAC-GAPS.md item 3.
# =============================================================================

resource "aws_s3_bucket" "loki_data" {
  bucket = "loki-data"
}

resource "aws_s3_bucket" "velero" {
  bucket = "velero"
}

resource "aws_s3_bucket" "cnpg_backups" {
  bucket = "cnpg-backups"
}
