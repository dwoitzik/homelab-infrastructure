#!/usr/bin/env python3
"""Fail when a manifest in an ArgoCD-covered directory is not in its include glob.

A file added to kubernetes/system/monitoring/ but missing from the
monitoring-manifests include glob is silently never deployed: ArgoCD reports
Synced because it deployed exactly what it was told to, CI passes, and the
manifest sits in git having no effect. That has happened four times in this
directory (REL-014, REL-042, network-policies-egress.yml, and the Prometheus
restart alert), so it is checked mechanically rather than remembered.

Known-uncovered files are listed below with the reason, which keeps this a
ratchet: a newly added file fails until someone either adds it to the glob or
records why it belongs elsewhere.
"""

import fnmatch
import pathlib
import re
import sys

import yaml

APP = pathlib.Path("kubernetes/system/monitoring/manifests-application.yml")
WATCHED_DIR = APP.parent

# Not deployed by monitoring-manifests, and why. application.yml and loki.yml
# are rendered by system-app-bootstrap's */application.yml glob; adding them
# here would make two apps render Application objects owned by the other.
OWNED_ELSEWHERE = {"application.yml", "loki.yml", "manifests-application.yml"}

# Live in the cluster but not managed by ArgoCD. Adopted separately rather than
# silently here, because taking over 14 untracked objects is a change that needs
# its own diff review.
ADOPTION_BACKLOG = {
    "blackbox-alerts.yml",
    "cadence-alerts.yml",
    "dead-mans-switch.yml",
    "dr-game-day.yml",
    "loki-external-secret.yml",
    "weekly-report.yml",
}

KNOWN_UNCOVERED = OWNED_ELSEWHERE | ADOPTION_BACKLOG


def covered_globs():
    include = yaml.safe_load(APP.read_text())["spec"]["source"]["directory"]["include"]
    match = re.fullmatch(r"\{(.+)\}(\.yml)", include)
    return [name + ".yml" for name in match.group(1).split(",")] if match else [include]


def main() -> int:
    patterns = covered_globs()
    uncovered = [
        path.name
        for path in sorted(WATCHED_DIR.glob("*.yml"))
        if not any(fnmatch.fnmatch(path.name, pat) for pat in patterns)
    ]
    unknown = [name for name in uncovered if name not in KNOWN_UNCOVERED]

    for name in sorted(set(uncovered) & ADOPTION_BACKLOG):
        print(f"  backlog (live but not ArgoCD-managed): {name}")

    if not unknown:
        return 0

    print(
        "\nArgoCD include coverage: manifest not in the monitoring-manifests\n"
        "include glob, so ArgoCD will never deploy it:\n"
    )
    for name in unknown:
        print(f"  {name}")
    print(
        f"\nAdd it to the include glob in {APP}, or record it in\n"
        "scripts/check-argocd-include-coverage.py if it is rendered by another app.\n"
        "A green CI run and a Synced ArgoCD app do NOT mean this file deployed."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
