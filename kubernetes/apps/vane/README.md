# Vane

AI answering engine (the project formerly called Perplexica): answers a question
with cited sources, searching through the in-cluster SearXNG and answering with a
local model on Ollama (`ct-srv-ai-01`). No external API key is involved.

- Access: LAN/VPN only, behind CrowdSec and Authelia
  (IngressRoute in `vane.yml`)
- Search: `SEARXNG_API_URL` points at `searxng.apps.svc:8080` (JSON format enabled)
- Model: `OLLAMA_BASE_URL` points at the Ollama LXC; egress to it is allowed by
  `allow-egress-vane-ollama` in `kubernetes/apps/network-policies-egress.yml`
- Data: settings and chat history in SQLite on a `local-path` volume

## First start

Open the setup screen once and pick `qwen2.5:7b-instruct` from the Ollama provider as
the chat model. Answers take roughly 10 to 30 seconds on the CPU-only LXC.

## Restore

Nothing critical: the volume holds settings and chat history. Re-apply the manifests and
pick the model again.
