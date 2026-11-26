#!/usr/bin/env python3
"""Write per-pool ZFS health to the node_exporter textfile collector."""
import json
import os
import subprocess
import sys
import time

# Absolute path: cron and systemd PATHs differ, and /usr/sbin is not always on them.
ZPOOL = "/usr/sbin/zpool"
TEXTFILE_DIR = sys.argv[1]
PROM = os.path.join(TEXTFILE_DIR, "zfs_pools.prom")

status = json.loads(subprocess.run(
    [ZPOOL, "status", "-j", "--json-int", "-p"],
    check=True, capture_output=True, text=True, timeout=60,
).stdout)

metrics = {}


def metric(name, help_text, labels, value):
    entry = metrics.setdefault(name, (help_text, []))
    label_str = ",".join(f'{k}="{v}"' for k, v in labels.items())
    label_part = f"{{{label_str}}}" if label_str else ""
    entry[1].append(f"{name}{label_part} {value}")


def walk_vdevs(pool, vdevs):
    for vdev in vdevs.values():
        for kind, key in (("read", "read_errors"), ("write", "write_errors"),
                          ("checksum", "checksum_errors")):
            metric("zfs_pool_vdev_errors", "Error count ZFS holds for the vdev since the last zpool clear.",
                   {"pool": pool, "vdev": vdev["name"], "type": kind}, int(vdev.get(key, 0)))
        walk_vdevs(pool, vdev.get("vdevs", {}))


for name, pool in status.get("pools", {}).items():
    state = pool.get("state", "UNKNOWN")
    metric("zfs_pool_online", "1 if the pool state is ONLINE.", {"pool": name}, int(state == "ONLINE"))
    metric("zfs_pool_state", "Current pool state as a label, always 1.", {"pool": name, "state": state}, 1)
    metric("zfs_pool_data_errors", "Files or metadata with permanent (unrepaired) errors.",
           {"pool": name}, int(pool.get("error_count", 0)))
    walk_vdevs(name, pool.get("vdevs", {}))

    scan = pool.get("scan_stats") or {}
    is_scrub = scan.get("function") == "SCRUB"
    metric("zfs_pool_scrub_running", "1 while a scrub is in progress.", {"pool": name},
           int(is_scrub and scan.get("state") == "SCANNING"))
    if is_scrub and scan.get("state") == "FINISHED":
        metric("zfs_pool_scrub_end_timestamp_seconds", "When the last completed scrub ended.",
               {"pool": name}, int(scan.get("end_time", 0)))
        metric("zfs_pool_scrub_errors", "Errors the last completed scrub could not repair.",
               {"pool": name}, int(scan.get("errors", 0)))

metric("zfs_pool_metrics_last_run_timestamp_seconds", "When zfs-pool-metrics last ran.", {}, int(time.time()))

lines = []
for name, (help_text, samples) in metrics.items():
    lines += [f"# HELP {name} {help_text}", f"# TYPE {name} gauge", *samples]

tmp = PROM + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, PROM)
