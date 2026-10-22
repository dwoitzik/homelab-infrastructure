# ADR-070: The paperless beat schedule database moves off NFS

## Status

Accepted and applied, 2026-10-21.

## Context

Paperless-ngx runs on K3s with its `paperless-data` PVC on the `nfs-client`
StorageClass, which is the convention for every stateful app in this repo: the
NFS server is a separate VM, so a PVC is not pinned to one k3s node and the
workload stays reschedulable.

`celery beat` was crash-looping in that setup. The container log showed the
same traceback roughly every nine seconds:

```text
dbm.sqlite3.error: database disk image is malformed
  File "/usr/local/lib/python3.14/dbm/sqlite3.py", line 515, in __init__
    self.setup_schedule()
  File ".../celery/beat.py", line 543, in setup_schedule
    self._create_schedule()
```

120 occurrences in one day and 27 `celery beat` starts in the same window. The
consequences were not cosmetic: no scheduled task ran at all — index updates,
mail account polling, sanity checks — and the repeated scheduler start/stop was
visible in the pod's CPU usage.

The interesting part is that the file was not obviously broken. Read directly
from the container it opened fine and returned its four keys
(`__version__`, `entries`, `tz`, `utc_enabled`). It only failed when the
scheduler tried to *write* to it.

The cause is in CPython's `dbm/sqlite3.py`, in the Python 3.14 image this
container runs:

```python
# This is an optimization only; it's ok if it fails.
with suppress(sqlite3.OperationalError):
    self._cx.execute("PRAGMA journal_mode = wal")
```

Every write-mode open switches the database into SQLite WAL mode. WAL keeps
committed pages in a `-wal` file and only folds them into the main database
file at a checkpoint, which relies on shared memory (`-shm`) that is mapped
between processes. Over NFS that mapping is not reliable, so the commits stayed
in the `-wal` file and the main database stayed empty. The resulting state was
a 12 KB file with a valid SQLite header, no `Dict` table, and a matching
`-wal`/`-shm` pair — a database that reads as valid and fails on every write.

Running `PRAGMA wal_checkpoint(TRUNCATE)` by hand on the NFS file made the
`Dict` table appear immediately, which confirmed the diagnosis: the data was
there all along, just parked in a WAL that could not be checkpointed.

The usual escape hatch does not apply. `PRAGMA journal_mode = delete` is
persistent in the database header, but `dbm.sqlite3` re-issues
`PRAGMA journal_mode = wal` on every open, and a test on the live NFS mount
confirmed the mode flips back to `wal` on the next open. There is no
environment variable and no Celery option to change the schedule database's
backend.

## Decision

**Redirect the beat schedule database to node-local storage with a symlink.**

`data/celerybeat-schedule.db` becomes a symlink into `data/beat-local/`, which
is a node-local `emptyDir` mounted into the container. An initContainer
creates the symlink before the main container starts.

Three alternatives were considered and rejected:

- **Move the whole `paperless-data` PVC to `local-path`.** This would fix the
  problem, but `local-path` pins the PV to the node that created it via
  `nodeAffinity`. Every existing `local-path` PVC in this cluster is bound to
  exactly one of `vm-srv-k3s-11/12/13`, so a node failure would leave the
  volume unreachable and the pod unschedulable. That is why every other
  stateful app in this repo stays on `nfs-client` — see the note in
  `kubernetes/apps/myspeed/myspeed.yml`.
- **Set `PAPERLESS_DATA_DIR` to a local path.** `celery/beat.py` derives the
  schedule filename from `DATA_DIR` (`CELERY_BEAT_SCHEDULE_FILENAME = str(DATA_DIR /
  "celerybeat-schedule.db")` in paperless' settings, with no environment
  override). Redirecting `DATA_DIR` would also move the Tantivy search index
  and the log directory off the PVC, trading one lock-sensitive directory for
  another and losing index persistence.
- **Mount the file directly with `subPath`.** This was tried first and it does
  move the database file onto local storage, but SQLite's `-wal` and `-shm`
  files are created next to the database by path, and with a single-file mount
  they land on the NFS path again. The failure then shows up as
  `OSError: [Errno 16] Device or resource busy` when the scheduler opens the
  file, because a bind-mounted file cannot be opened the way SQLite needs.

A symlink resolves that: SQLite resolves the link and puts the database, the
`-wal` and the `-shm` file all inside the local directory.

## Consequences

- The schedule database is empty after every pod restart. It only records when
  a task last ran, so the first beat cycle after a restart re-runs the periodic
  tasks once. That is harmless for the tasks in use (index update, mail
  polling, sanity check) and is the intended behaviour of a fresh scheduler.
- The initContainer needs write access to the `paperless-data` volume to
  create the symlink. That volume is world-writable already, and the symlink
  is created with `rm -f` first so a re-run replaces a stale link.
- The `paperless-data` PVC stays on `nfs-client`, so nothing about node
  affinity or reschedulability changes. The search index, the logs and the
  migration lock stay persistent exactly as before.
- `fsGroup: 1000` was added to the pod spec so the `emptyDir` is
  group-writable for the paperless user (uid 1000). The initContainer itself
  runs unprivileged under the PodSecurity `restricted` profile, so it creates
  the link rather than chowning anything.
- Diagnosing this in future means looking at where the database file actually
  lives, not just at the path paperless prints. `ls -la data/` shows the
  symlink, and `ls -la data/beat-local/` shows the real file plus its
  `-wal`/`-shm` companions.
