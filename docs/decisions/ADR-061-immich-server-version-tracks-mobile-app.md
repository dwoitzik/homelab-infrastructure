# ADR-061: immich's server version must track the mobile app version

- **Status**: Accepted and applied.
- **Date**: 2026-10-18
- **Relates to**: `kubernetes/apps/immich/immich.yml`, `kubernetes/apps/immich/README.md`,
  the earlier bump in #747 ("to match mobile app 3.2.1 sync requirement")

## Context

The operator reported that the immich mobile app no longer uploaded photos from the
home LAN — selecting photos and starting a backup did nothing. The initial suspicion was
infrastructure: storage, the database, or the LAN ingress path.

All of those checked out:

- `immich-server`, `immich-postgres-0`, `immich-redis`, and `immich-ml` were `Running`.
- The library NFS export (`10.0.20.100:/usb-immich-library`) was 20% used, and a 20 MiB
  write from inside `immich-server` completed at ~56 MB/s.
- The LAN path resolved `photos.woitzik.dev` to Traefik (`10.0.20.200`), which answered
  `200` on `/api/server/ping` with a valid `*.woitzik.dev` certificate.
- The server log contained no `ERROR`/`WARN`, and every `POST /api/assets` that arrived
  returned `201`/`200`.

The real signal was in the server's own request log: the mobile app was connecting and
polling (it called `/api/sync/stream`, `/api/sync/ack`, `/api/search/random`,
`/api/auth/validateToken`, `/api/server/version`), but it **never called
`POST /api/assets`** — it was not attempting an upload at all.

The `session` table (immich records the client build per session) showed why:

```text
 deviceType | deviceOS | appVersion |           updatedAt
------------+----------+------------+-------------------------------
            | android  | 3.3.3      | 2026-10-18 13:52:39+00
            | android  | 3.3.3      | 2026-10-18 14:10:42+00
            | android  | 3.2.1      | 2026-09-28 08:21:26+00
```

The app had auto-updated from `3.2.1` (what #747 pinned the server to match) to
`3.3.3`, while the server was still `v3.2.2`:

```text
GET /api/server/version -> {"major":3,"minor":2,"patch":2,"prerelease":null}
```

immich's mobile app refuses to sync or upload when the server is older than the app
build — the app-side guard is silent to the server, which is why every server-side
health signal was green while uploads simply stopped.

## Decision

Bump `immich-server` and `immich-machine-learning` to `v3.3.3` (the app's version),
pinned by digest. The Postgres image is left unchanged: `v3.3.3` is a patch release
with no database-image change.

## Consequences

- Uploads resume once the app and server versions align.
- This is a standing coupling, not a one-off: when the mobile app auto-updates ahead
  of the pinned server image, uploads stop again with no server-side error. The server
  image must be bumped to track the app. The README records this as a known gotcha, and
  `session.appVersion` is where to check which build a client is running.
- Rolling the server image back is not sufficient to undo this change — a downgrade
  also requires restoring the pre-upgrade database dump (immich does not support
  downgrades). A pre-upgrade `pg_dump` was taken and stored alongside immich's own
  daily dumps on the library volume before applying.
