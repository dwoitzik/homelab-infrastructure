# OnlyOffice

Document server — provides in-browser editing for Nextcloud's office-document
integration.

## Storage

Single `nfs-client` PVC — document cache/fonts/config, not a source of truth for actual
document content (that lives in whatever app is using it, e.g. Nextcloud).

## How to restore

Nothing critical to restore — the PVC is a cache, not a data store. Re-apply the
manifests; it rebuilds its own working state on start.
