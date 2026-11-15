# k3s_secrets_encryption

Keeps the k3s Secrets encryption key (`/var/lib/rancher/k3s/server/cred/encryption-config.json`
on the server, `vm-srv-k3s-11`) and its offline copy in Ansible Vault
(`vault_k3s_encryption_config`) in step. Background: ADR-077.

## What it does

- Writes the key file from Ansible Vault **only when it is missing** (server rebuild
  against a restored `state.db`). It never overwrites a live key.
- Fails when the live file and the vault copy differ, so a key rotation that was not
  copied back shows up on the next `--check` run.

## Run

```bash
cd ansible
ansible-playbook site.yml --limit vm-srv-k3s-11 --tags k3s_secrets_encryption --check
```

## After `k3s secrets-encrypt rotate-keys`

Replace the vault copy with the new file, without the plaintext touching disk:

```bash
cd ansible
# delete the old vault_k3s_encryption_config block from group_vars/all/vault.yml first
ssh dw@10.0.20.11 'sudo cat /var/lib/rancher/k3s/server/cred/encryption-config.json' \
  | ansible-vault encrypt_string --stdin-name vault_k3s_encryption_config \
  >> group_vars/all/vault.yml
```

## Restore (server rebuild)

1. Install k3s with `secrets-encryption: true` but do not start it yet, or stop it.
2. Put the restored `state.db` in place.
3. Run this role (writes the key file, mode 0600).
4. Start k3s and check `k3s secrets-encrypt status` and that `kubectl get secret` works.
