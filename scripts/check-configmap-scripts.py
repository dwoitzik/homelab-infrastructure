#!/usr/bin/env python3
"""Syntax-check shell scripts embedded in Kubernetes ConfigMaps.

A script inside a ConfigMap is only parsed when its CronJob next runs, so a
broken quote can silently disable a weekly job for weeks. Every `*.sh` data
key in the given manifests is run through `sh -n` (`bash -n` when the script
starts with a bash shebang).

Usage: check-configmap-scripts.py [FILE ...]  (default: every YAML under kubernetes/)
"""
import pathlib
import subprocess
import sys
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent


def scripts(path):
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError:
        return
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
            continue
        for key, value in (doc.get("data") or {}).items():
            if key.endswith(".sh") and isinstance(value, str):
                yield doc.get("metadata", {}).get("name", "?"), key, value


def main():
    files = [pathlib.Path(f) for f in sys.argv[1:] if f.endswith((".yml", ".yaml"))]
    if not sys.argv[1:]:
        files = sorted((REPO / "kubernetes").rglob("*.y*ml"))
    failures = 0
    for path in files:
        for name, key, body in scripts(path):
            shell = "bash" if body.startswith("#!/bin/bash") or body.startswith("#!/usr/bin/env bash") else "sh"
            with tempfile.NamedTemporaryFile("w", suffix=".sh") as tmp:
                tmp.write(body)
                tmp.flush()
                out = subprocess.run([shell, "-n", tmp.name], capture_output=True, text=True)
            if out.returncode != 0:
                failures += 1
                err = out.stderr.strip().replace(tmp.name, f"{path}:{name}/{key}")
                print(f"FAIL {err}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
