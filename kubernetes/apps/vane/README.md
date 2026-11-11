# Vane

AI answering engine (the project formerly called Perplexica): answers a question
with cited sources, searching through the in-cluster SearXNG and answering with
Claude via the Anthropic API.

- Access: LAN/VPN only, behind Authelia (IngressRoute in `vane.yml`)
- Search: `SEARXNG_API_URL` → `searxng.apps.svc:8080` (needs the JSON format and the
  Wolfram Alpha engine enabled in SearXNG)
- Secret: `ANTHROPIC_API_KEY` from Vault `secret/vane` → `anthropic-api-key`
- Data: settings and chat history in SQLite on a `local-path` volume

## First start

Pick the Anthropic provider and a Claude Haiku model in the setup screen; the API key is
read from the environment.

## Restore

Nothing critical: the volume holds settings and chat history. Re-apply the manifests and
pick the model again.
