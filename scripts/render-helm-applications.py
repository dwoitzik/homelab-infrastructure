#!/usr/bin/env python3
"""Render every Helm chart referenced by an ArgoCD Application and validate it.

Renovate auto-merges chart patch releases, so CI has to prove that a bumped
chart still renders with this repo's values on this cluster's Kubernetes
version. `helm template --kube-version` fails on a chart whose kubeVersion
constraint excludes the cluster, and on values the chart's schema rejects.
The rendered output then goes through kubeconform with the vendored schemas.

Usage: render-helm-applications.py [--kube-version X.Y.Z] [FILE ...]
Without FILE arguments every Application under kubernetes/ is checked.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
SCHEMAS = REPO / "ci" / "kubeconform-schemas"


def chart_sources(path):
    for doc in yaml.safe_load_all(path.read_text()):
        if not isinstance(doc, dict) or doc.get("kind") != "Application":
            continue
        spec = doc.get("spec", {})
        sources = spec.get("sources") or [spec.get("source")]
        namespace = spec.get("destination", {}).get("namespace", "default")
        for src in sources:
            if src and src.get("chart"):
                yield doc["metadata"]["name"], namespace, src


def render(app, namespace, src, kube_version, workdir):
    values_file = workdir / f"{app}-values.yaml"
    helm = src.get("helm", {})
    values = helm.get("values") or ""
    if helm.get("valuesObject"):
        values = yaml.safe_dump(helm["valuesObject"])
    values_file.write_text(values)
    cmd = [
        "helm", "template", helm.get("releaseName", app), src["chart"],
        "--repo", src["repoURL"],
        "--version", str(src["targetRevision"]),
        "--namespace", namespace,
        "--kube-version", kube_version,
        "--include-crds",
        "-f", str(values_file),
    ]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        return None, out.stderr.strip()
    rendered = workdir / f"{app}.yaml"
    rendered.write_text(out.stdout)
    return rendered, None


def kubeconform(rendered, kube_version):
    location = str(SCHEMAS) + "/{{ .NormalizedKubernetesVersion }}-standalone/{{ .ResourceKind }}{{ .KindSuffix }}.json"
    out = subprocess.run(
        ["kubeconform", "-kubernetes-version", kube_version,
         "-schema-location", location, "-ignore-missing-schemas",
         "-summary", str(rendered)],
        capture_output=True, text=True,
    )
    return out.returncode == 0, (out.stdout + out.stderr).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kube-version", default="1.31.0")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()

    files = [pathlib.Path(f) for f in args.files] or sorted(
        p for p in (REPO / "kubernetes").rglob("*.y*ml")
    )
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        for path in files:
            try:
                sources = list(chart_sources(path))
            except yaml.YAMLError:
                continue
            for app, namespace, src in sources:
                checked += 1
                label = f"{app} ({src['chart']} {src['targetRevision']})"
                rendered, err = render(app, namespace, src, args.kube_version, workdir)
                if err:
                    failures += 1
                    print(f"FAIL {label}: helm template\n{err}\n")
                    continue
                ok, report = kubeconform(rendered, args.kube_version)
                if not ok:
                    failures += 1
                    print(f"FAIL {label}: kubeconform\n{report}\n")
                    continue
                print(f"ok   {label}")
    print(f"\n{checked} chart source(s) checked, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
