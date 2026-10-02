#!/usr/bin/env python3
"""Fail when a manifest in an ArgoCD-covered directory is not in its include glob.

A file added to kubernetes/system/monitoring/ but missing from the
monitoring-manifests include glob is silently never deployed: ArgoCD reports
Synced because it deployed exactly what it was told, CI passes, and the
manifest sits in git having no effect. That has happened four times in this
directory (REL-014, REL-042, network-policies-egress.yml, and the Prometheus
restart alert), so it is checked mechanically rather than remembered.

Exclusions are listed below with the reason, which keeps this a ratchet: a newly
added file fails until someone either adds it to the glob or records why it is
rendered by another Application instead.
"""

import fnmatch
import pathlib
import re
import sys

import yaml

APP = pathlib.Path("kubernetes/system/monitoring/manifests-application.yml")
WATCHED_DIR = APP.parent

# Rendered by system-app-bootstrap via its */application.yml glob, not by
# monitoring-manifests. Adding these here would make two Applications render
# Application objects that the other one owns.
OWNED_ELSEWHERE = {
    "application.yml",
    "loki.yml",
    "manifests-application.yml",
}


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
    unknown = [name for name in uncovered if name not in OWNED_ELSEWHERE]

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
