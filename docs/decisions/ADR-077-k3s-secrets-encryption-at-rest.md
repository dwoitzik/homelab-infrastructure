# ADR-077: Encrypt Kubernetes Secrets at rest in the k3s datastore

**Date:** 2026-11-15
**Status:** Accepted

## Context

The cluster runs a single k3s server (`vm-srv-k3s-11`, VM 211) on the embedded SQLite
datastore (ADR-015). Until now every Secret, including `vault/vault-unseal-keys`, sat
in `state.db` as plaintext protobuf. Anyone with a copy of the VM disk or a PBS backup
of VM 211 could read every credential in the cluster without any key.

k3s supports apiserver-level encryption (`--secrets-encryption`, aescbc by default).
The documented `k3s secrets-encrypt enable` flow for existing clusters needs v1.33.10+;
this cluster is on v1.31.12. On v1.31 the server generates
`/var/lib/rancher/k3s/server/cred/encryption-config.json` (an aescbc key plus the
`identity` fallback) on the first start with the flag set, when the file does not exist
yet (`genEncryptionConfigAndState` in `pkg/daemons/control/deps/deps.go`). New writes
are encrypted from then on; existing Secrets stay readable through `identity` until
they are rewritten. `k3s secrets-encrypt rotate-keys` (v1.28+) then adds a fresh key and
rewrites every Secret with it in one step on a single server.

Encryption sits in the apiserver, so it is independent of the datastore (SQLite via
kine works the same as etcd).

## Decision

1. `secrets-encryption: true` in `server_config_yaml`
   (`ansible/k3s-cluster/inventory.yml`).
2. Enable on the live server: Proxmox snapshot of VM 211 and an SQLite online backup of
   `state.db` first, then set the flag, restart k3s, run
   `k3s secrets-encrypt rotate-keys`, restart again, and confirm with
   `k3s secrets-encrypt status` and by reading a Secret's raw row in `state.db`
   (must start with `k8s:enc:aescbc:v1:`).
3. Key handling: the key file sits next to the data on VM 211, so every PBS backup of
   VM 211 holds both, and a disk image alone stays as readable as before (accepted: the
   threat closed here is a leaked `state.db` copy or datastore dump, not a full VM image).
   An independent copy of `encryption-config.json` is kept in Ansible Vault as
   `vault_k3s_encryption_config`, encrypted with the vault password that lives outside
   the cluster and outside PBS. Without that copy, a `state.db` restored on its own (the
   Vault recovery path in `DISASTER-RECOVERY.md` section 4) would come back with
   unreadable Secrets.
4. Any later `rotate-keys` must be followed by updating `vault_k3s_encryption_config`;
   the `k3s_secrets_encryption` Ansible role fails in check mode when the live file and
   the vault copy differ.

## Consequences

- Secrets in the datastore are unreadable without the key; a stolen `state.db` alone
  leaks nothing from Secrets.
- Velero backups are unaffected: Velero reads Secrets through the API, so they are
  stored decrypted in Garage/R2 as before (SEC-H8 is a separate finding).
- Rebuilding the server from scratch means putting the key file back before the first
  k3s start against a restored `state.db` (see `DISASTER-RECOVERY.md`).
- Rollback: restore the VM 211 snapshot taken before the change. While the key file is
  in place, removing the flag alone does not work: Secrets written while encryption was
  on cannot be decrypted without the provider config. A clean rollback without the
  snapshot is `k3s secrets-encrypt disable`, restart, `k3s secrets-encrypt reencrypt`,
  then remove the flag.

## Outcome

Applied 2026-11-15 after snapshot `pre-secrets-encryption` of VM 211 and an SQLite
online backup (deleted again afterwards, since it held plaintext Secrets). The first
restart generated the aescbc config (stage `start`); `rotate-keys` rewrote all 114
Secrets and a second restart completed it. `k3s secrets-encrypt status`: Enabled,
`reencrypt_finished`, all hashes match. Every current Secret row in `kine` starts with
`k8s:enc:aescbc:v1:`. Older plaintext revisions stay in `kine` until its compaction
(roughly the last 1000 revisions are kept), and SQLite pages are only scrubbed by a
`VACUUM`; both were checked/run before the snapshot was removed. PBS backups of VM 211
taken before this date still hold plaintext Secrets until they expire.

The vault copy `vault_k3s_encryption_config` has the same SHA-256 as the live file;
`roles/k3s_secrets_encryption` checks that on every run.
