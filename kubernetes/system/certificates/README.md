# certificates

One Certificate resource: `wildcard-woitzik-dev.yml`, covering `*.woitzik.dev` +
`woitzik.dev` via `letsencrypt-production` (DNS-01 through Cloudflare). Every
IngressRoute in this cluster references the resulting `wildcard-woitzik-dev-tls`
Secret — no per-service certificates, no per-service renewal to track.

## How to restore

Re-apply once `cert-manager-config`'s issuer is healthy. Renewal is automatic
(cert-manager re-issues before expiry); this has been proven live during Phase 5 of
the 2026-08-13 recovery, not just assumed.

## Dependencies

cert-manager, cert-manager-config (the issuer).
