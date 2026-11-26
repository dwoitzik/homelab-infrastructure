#!/usr/bin/env python3
"""Write PBS garbage-collection and verify outcomes to the node_exporter textfile collector."""
import json
import os
import subprocess
import sys

# Usage: pbs-job-metrics.py <datastore> <verify job id> <textfile collector dir>
STORE, VERIFY_JOB, TEXTFILE_DIR = sys.argv[1:4]
PROM = os.path.join(TEXTFILE_DIR, "pbs_jobs.prom")


def api(path):
    # Absolute path: cron's PATH lacks /usr/sbin, so a bare name fails there.
    out = subprocess.run(
        ["/usr/sbin/proxmox-backup-debug", "api", "get", path, "--output-format", "json"],
        check=True, capture_output=True, text=True, timeout=120,
    ).stdout
    return json.loads(out)


lines = []

# While a GC or verify task runs, PBS drops last-run-state/-endtime from the job
# status; the values from the previous write stand in until it finishes.
previous = {}
try:
    with open(PROM) as f:
        for line in f:
            if line and not line.startswith("#"):
                key, _, value = line.rstrip("\n").rpartition(" ")
                previous[key] = value
except FileNotFoundError:
    pass


def metric(name, value, help_text, labels="", running=False):
    if running:
        value = previous.get(f"{name}{labels}")
        if value is None:
            return
    lines.append(f"# HELP {name} {help_text}")
    lines.append(f"# TYPE {name} gauge")
    lines.append(f"{name}{labels} {value}")


lbl = f'{{store="{STORE}"}}'
gc = next((g for g in api("/admin/gc") if g.get("store") == STORE), {})
gc_running = "last-run-state" not in gc
metric("pbs_gc_last_run_ok", int(gc.get("last-run-state") == "OK"),
       "1 if the last garbage collection finished OK.", lbl, gc_running)
metric("pbs_gc_last_run_end_timestamp_seconds", gc.get("last-run-endtime", 0),
       "When the last garbage collection ended.", lbl, gc_running)
metric("pbs_gc_pending_bytes", gc.get("pending-bytes", 0),
       "Bytes the last garbage collection could not yet remove.", lbl)

job = next((j for j in api("/admin/verify") if j.get("id") == VERIFY_JOB), {})
# A job that has never run has no last-run-upid either; that is a real 0.
verify_running = "last-run-upid" in job and "last-run-state" not in job
jlbl = f'{{job_id="{VERIFY_JOB}"}}'
metric("pbs_verify_job_last_run_ok", int(job.get("last-run-state") == "OK"),
       "1 if the last run of the verify job finished OK.", jlbl, verify_running)
metric("pbs_verify_job_last_run_end_timestamp_seconds", job.get("last-run-endtime", 0),
       "When the verify job last finished.", jlbl, verify_running)

snaps = api(f"/admin/datastore/{STORE}/snapshots")
states = [(s.get("verification") or {}).get("state", "none") for s in snaps]
for state in ("ok", "failed", "none"):
    metric("pbs_snapshots", states.count(state),
           "Snapshots in the datastore by verification state.",
           f'{{store="{STORE}",verify_state="{state}"}}')

# Help/type lines must appear once per metric name.
seen, out = set(), []
for line in lines:
    if line.startswith("#"):
        key = line.split()[1:3]
        if tuple(key) in seen:
            continue
        seen.add(tuple(key))
    out.append(line)

tmp = PROM + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, PROM)
