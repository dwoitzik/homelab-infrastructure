#!/usr/bin/env python3
"""Fail when kubernetes/system declares a kind the drift checker cannot read.

The declared-vs-live check (drift-check.yml) runs as the drift-checker
ServiceAccount. A manifest of a kind that account may not read makes every
scheduled run fail after the merge. This check catches it in the PR instead:
every declared group/kind must be listed in ci/drift-checker-readable-kinds.txt,
which is kept true by extending drift-checker-extra-read alongside it.
"""
import importlib.util
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("declared", REPO / "scripts" / "check-declared-vs-live.py")
declared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(declared)

listed = {
    line.strip()
    for line in (REPO / "ci" / "drift-checker-readable-kinds.txt").read_text().splitlines()
    if line.strip() and not line.startswith("#")
}
missing = {}
for obj in declared.find_declared_objects(REPO):
    key = f"{obj['group'] or 'core'}/{obj['kind']}"
    if key not in listed:
        missing.setdefault(key, obj["file"])

for key, path in sorted(missing.items()):
    print(f"drift checker cannot read {key} (first declared in {path}): grant get/list in "
          "kubernetes/system/infrastructure/drift-checker-rbac.yml and add it to "
          "ci/drift-checker-readable-kinds.txt")
sys.exit(1 if missing else 0)
