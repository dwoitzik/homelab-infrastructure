# Paperless-ngx

Document management, deployed as a few separate pieces rather than one big container.

## What's running

- **Paperless-ngx** — the main webserver
- **paperless-gpt** — AI-generated titles/tags via Ollama (model: `qwen2.5:7b`)
- **PostgreSQL 16** — document metadata
- **Redis 7** — task queue
- **Tika + Gotenberg** — OCR and document conversion

## Auth

Goes through Authelia via the `Remote-User` header, not its own login.

## Storage

PVCs use the `nfs-client` StorageClass (`ct-srv-nfs-01`). Data, media, and the database
each get their own volume so a DB write doesn't get blocked behind a large media write.
