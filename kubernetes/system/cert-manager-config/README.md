# cert-manager-config

The actual issuer + credentials, split from `cert-manager/` (the controller) for
bootstrap ordering — see that directory's README.

## Contents

- `issuer.yml` — `letsencrypt-production` ClusterIssuer, DNS-01 challenge via
  Cloudflare (so certs can be issued for internal-only services too, not just ones
  reachable from Let's Encrypt's HTTP-01 validators).
- `external-secret.yml` — pulls the Cloudflare API token from Vault into a k8s Secret
  the issuer references. The same token is reused by `terraform/stacks/cloudflare` for
  DNS/tunnel management — one credential, two consumers.

## How to restore

Re-apply after Vault + ExternalSecrets are healthy and the Cloudflare token exists in
Vault at the expected path. The actual wildcard Certificate resource lives in
`kubernetes/system/certificates/`, not here.

## Dependencies

cert-manager (controller), Vault + ExternalSecrets (for the API token).
