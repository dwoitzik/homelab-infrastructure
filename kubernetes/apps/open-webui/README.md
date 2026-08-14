# Open WebUI

Local LLM chat frontend for Ollama (`http://10.0.20.251:11434`, a separate LXC).

## Storage

Single `local-path` PVC (`/app/backend/data`) — chat history, uploaded files, and (as
of 2026-08-13) the downloaded embedding model cache, all under this one mount.

## How to restore

Standard `local-path` swap-restore: scale to 0, mount the PVC via a throwaway pod,
copy preserved data in, scale back up.

## Known gotchas

- **`HF_HOME`/`SENTENCE_TRANSFORMERS_HOME` must point inside the persisted `data`
  mount.** Without this, the embedding model (30 files from HuggingFace) re-downloads
  on *every* pod restart instead of once — under load this made first-boot startup
  slow enough to blow past the liveness probe's grace window every time, an
  unrecoverable crash loop where each restart re-triggered the same slow download that
  then got killed again before finishing. Fixed 2026-08-13 by pointing both env vars
  at `/app/backend/data/.cache/huggingface`.
- `WEBUI_SECRET_KEY` is pinned to a real Secret value rather than left to the
  entrypoint's own fallback (write a random key to a local file) — with
  `readOnlyRootFilesystem` that fallback fails outright, and even before that hardening
  it was silently generating a *new* random key on every restart, invalidating every
  session each time.
