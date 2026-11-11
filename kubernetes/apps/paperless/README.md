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

### The beat schedule database is not on NFS

`data/celerybeat-schedule.db` is a symlink into a node-local `emptyDir`
(`data/beat-local/`), created by an initContainer. Python's `dbm.sqlite3` switches
that database into SQLite WAL mode on every open, and over NFS the WAL commits
never reach the main database file — `celery beat` then crashes with
`database disk image is malformed` and restarts every few seconds, so no
scheduled task (index update, mail fetch, sanity check) ever runs.

The file holds only which task ran last, so losing it costs nothing. It has to
be a symlink rather than a single-file mount: SQLite puts its `-wal` and `-shm`
files next to the database, and those would land on the NFS path again.

See `docs/decisions/ADR-070-paperless-beat-schedule-off-nfs.md`.
