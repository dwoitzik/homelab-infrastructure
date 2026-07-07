# All 3 buckets already exist live (created 2026-06-18/2026-07-07 via
# `garage bucket create` directly) -- import, don't create-fresh, so
# `terraform apply` doesn't attempt a destructive recreate or error on
# "BucketAlreadyExists". Same discipline as the cloudflare stack's
# imports.tf (see GIT-008/REL-047 in docs/AUDIT.md for what goes wrong when
# import{} blocks are left stale after a resource is already imported).

import {
  to = aws_s3_bucket.loki_data
  id = "loki-data"
}

import {
  to = aws_s3_bucket.velero
  id = "velero"
}

import {
  to = aws_s3_bucket.cnpg_backups
  id = "cnpg-backups"
}
