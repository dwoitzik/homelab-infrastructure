# ADR-053: The pve watchdog was alerting on the nightly PBS backup's own load

- **Status**: Accepted and applied, 2026-10-03
- **Relates to**: ADR-034 (watchdog design, escalating backoff), REL-012 (host crash
  precursor), `ansible/roles/pve_power/templates/pve-watchdog.sh.j2`

## Context

`pve-mgmt-01` runs `/usr/local/bin/pve-watchdog.sh` from cron every 5 minutes. It
alerts via ntfy when pool usage ≥ 92%, CPU temp ≥ 90 °C, or **load1 ≥ 30**.

The threshold is not arbitrary. An earlier session raised it from 25 to 30 because a
legitimate `ansible`/`kubectl` bulk-apply session "routinely bursts load into the
high-20s/low-30s for a few minutes, which isn't the REL-012 crash precursor this
watchdog exists to catch". That calibration was based on **minutes-long, daytime**
sessions.

The nightly PBS backup is a different animal. `jobs.cfg` defines it as
`*-*-01/2 03:00`, `storage local-pbs`, `--all 1`, snapshot mode, zstd — it runs every
other day for roughly **76 minutes**, overnight, unattended. On this 16-core / 62 GiB
host it drives load1 well past the threshold it was tuned to accommodate.

## Evidence

The correlation is not inferred from the alert timestamps. `pvescheduler` logs the
job start on its own:

```text
Oct 03 03:00:04 pve-mgmt-01 pvescheduler: <root@pam> starting task U
PID:pve-mgmt-01:003C8E2F:14E92805:6AC05394:vzdump::root@pam:
Oct 03 03:00:06 pve-mgmt-01 pvescheduler: INFO: starting new backup job: vzdump
  --mailnotification failure --node pve-mgmt-01 --quiet 1 --storage local-pbs
  --compress zstd --exclude 9000 --all 1
  --prune-backups 'keep-daily=7,keep-weekly=4' --mode snapshot
```

The backup snapshots run 01:00–02:16 UTC = **03:00–04:16 local**. Observed load1:
**38.96** at 03:15 and **56.36** at 03:37. The watchdog's ntfy alerts for `Load (>=30)`
fired at 03:15 and 03:37 — inside that window. With a 5-minute cron cadence and a
76-minute job, alerting is not an occasional annoyance: it is structurally guaranteed
on every run of the job, i.e. every other day.

What the load actually costs was **not** established, and the honest answer is that
nobody currently can: host-level CPU/I/O metrics for this node are blocked by the
unapplied `fwd_04a_srv_monitoring` MikroTik/Terraform state gap (same blocker as
ADR-050). The zstd compression stage is the obvious suspect and is plausible, but
calling it the cause without a profile would be guessing. It does not change the
decision either way — the threshold is wrong for the situation regardless of why the
load exists.

## Why not raise the threshold outright

Going to 60+ would silence the false positive, but load 56 was reached *by a healthy,
successful backup*. A bar that high no longer distinguishes "PBS is working" from "the
host is in trouble". The check exists for REL-012; a threshold chosen to accommodate a
routine workload stops being a crash precursor detector.

## Decision

While `vzdump` is running on the host, the load bar is **70** instead of 30. Outside a
backup, unchanged.

- **Not disabled.** 70 is above the observed 56.36 peak, so a genuine runaway *during*
  a backup still alerts — verified below.
- **The window is one process, not a clock.** Detection is `pgrep -x vzdump`, not a
  time-of-day check. No configuration can drift out of sync with it, and it works for
  a manually triggered backup just as well as the scheduled one.
- **A sustained condition is never lost.** The cron runs every 5 minutes; once
  `vzdump` exits, the bar returns to 30 and still-elevated load alerts on the next
  tick. Only the known-cause window is skipped.
- **Pool and CPU-temp stay at their thresholds.** A backup under zstd makes the host
  hot; if that crosses 90 °C that is a thermal fact worth knowing, not noise. Nothing
  about a backup justifies suppressing those two.

### `pgrep -x`, not `pgrep -f`

`-x` matches the process **name** only. `-f` matches the full command line, and on this
host that was not a theoretical concern — the first attempt at this change used a naive
`pgrep -af vzdump` to look for a running backup, and it matched the SSH session running
the check itself, because that command line contained the string `vzdump`.

Reproduced on the host before choosing:

```text
pgrep -f  = MATCH (false positive -- the check's own shell)
pgrep -x  = kein Match (korrekt)
```

with a control case (`cp /bin/sleep /tmp/vzdump`, so `comm` really is `vzdump`) where
`pgrep -x` correctly matched.

## Verification

Deployed to `pve-mgmt-01` and exercised against the real binary, with `NTFY`
redirected to a sinkhole so nothing was actually sent. Load is injected via a
parameterised `TEST_LOAD1` in a test copy of the rendered script; the deployed file is
unmodified.

| load1 | without `vzdump` | with `vzdump` |
|---|---|---|
| 29 | quiet | quiet |
| 38.96 (observed) | ALERT | quiet |
| 56.36 (observed peak) | ALERT | quiet |
| 69 | ALERT | quiet |
| 71 | ALERT | **ALERT** |
| 99 | ALERT | **ALERT** |

Rows 38.96 and 56.36 are the two values this ADR exists to stop alerting on. Rows 71 and
99 confirm the check was not simply switched off during a backup.

## Also fixed here

`read -r LAST BACKOFF < "$STATE" 2>/dev/null` printed
`/tmp/pve-watchdog.state: No such file or directory` on every run where the state file
was absent — which is every run in which the condition had cleared, because that branch
ends in `rm -f "$STATE"`. Shell redirections are evaluated left to right, so the failing
`< "$STATE"` redirect is reported before the command's own `2>/dev/null` is in effect
and cannot be suppressed that way. A `[ -f "$STATE" ]` guard silences it.

Pre-existing, not introduced here: confirmed identical at line 48 of the pre-change
script, which is preserved on the host as
`pve-watchdog.sh.bak-20261003-140917`.

## Consequences

- The recurring overnight `Load (>=30)` ntfy alert stops. Load, pool, and temp are all
  still checked every 5 minutes; only the bar moves, and only while `vzdump` runs.
- `pve-watchdog.sh` was deployed by hand (rendered from the template, checksum-compared,
  old version backed up) because neither this workstation nor `pve-mgmt-01` has Ansible
  installed. Same deviation as ADR-052's `pbs-backup-healthcheck.sh`; the repo is the
  source of truth and a future `ansible-playbook` run converges them.
- The question of whether the *backup* should be doing less work — a `bwlimit` on the
  job, or a different schedule — is untouched and remains unanswerable without host
  metrics from `fwd_04a_srv_monitoring`.

## Follow-up

Installing Ansible on the workstation would remove the hand-deploy drift noted above.
The `fwd_04a_srv_monitoring` gap remains the single blocker for host-level CPU/I/O
visibility, which is what would let the backup's actual cost be measured instead of
inferred.
