#!/usr/bin/env python3
"""ADR-027 drift guard -- catches the "declared in git, never applied to the
live cluster" failure class. This has bitten four times across this
mission's history with four different resource kinds (an ExternalSecret, a
Kyverno ClusterPolicy, a database NetworkPolicy, and the dead man's switch
CronJob) -- a manifest sitting in git provides zero protection against
whatever it was written to prevent until it's actually live.

Scope: every standalone raw-manifest YAML file under kubernetes/system/.
ArgoCD-managed objects (kind: Application/AppProject, and everything an
Application's own Helm/Kustomize source renders) are out of scope on
purpose -- ArgoCD's own selfHeal already keeps those live-vs-declared in
sync, this guard exists specifically for the files nothing else reconciles.

Usage: check-declared-vs-live.py --kubeconfig <path> [--repo-root <path>]
Exit 0 if everything declared is live, 1 if anything is missing.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import yaml

# Application/AppProject/ApplicationSet are ArgoCD's own objects -- already
# self-healed by ArgoCD, out of scope for this guard by design. Secret is
# excluded deliberately, not for lack of trying: checking whether a Secret
# exists needs `get`/`list` RBAC on secrets, and that grants the same
# ServiceAccount the ability to read secret VALUES too (Kubernetes has no
# "existence check" verb narrower than get/list) -- not a trade worth
# making for a read-only credential that lives on a CI runner's disk.
# Secrets are also the least silent of the four incident classes this guard
# targets: a missing Secret crash-loops its consumer pod visibly (see the
# paperless-ngx v3 PAPERLESS_SECRET_KEY incident, phase8/LEDGER.md) rather
# than silently doing nothing.
SKIP_KINDS = {"Application", "AppProject", "ApplicationSet", "Secret"}
# Namespace is required to `kubectl get` a namespaced object; these kinds
# are cluster-scoped and must never be queried with -n.
CLUSTER_SCOPED_KINDS = {
    "ClusterRole",
    "ClusterRoleBinding",
    "ClusterPolicy",
    "PriorityClass",
    "Namespace",
    "CustomResourceDefinition",
    "ClusterIssuer",
}


def find_declared_objects(repo_root: Path) -> list[dict]:
    objects = []
    system_dir = repo_root / "kubernetes" / "system"
    for path in sorted(system_dir.rglob("*.yml")) + sorted(system_dir.rglob("*.yaml")):
        text = path.read_text()
        try:
            docs = list(yaml.safe_load_all(text))
        except yaml.YAMLError as e:
            print(f"WARN: could not parse {path}: {e}", file=sys.stderr)
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get("kind")
            metadata = doc.get("metadata", {})
            name = metadata.get("name") if isinstance(metadata, dict) else None
            if not kind or not name:
                continue
            if kind in SKIP_KINDS:
                continue
            namespace = metadata.get("namespace") if isinstance(metadata, dict) else None
            api_version = doc.get("apiVersion", "")
            group = api_version.split("/")[0] if "/" in api_version else ""
            objects.append(
                {
                    "kind": kind,
                    "group": group,
                    "name": name,
                    "namespace": namespace,
                    "file": str(path.relative_to(repo_root)),
                }
            )
    return objects


def check_live(obj: dict, kubeconfig: str) -> bool:
    # Several kinds collide across API groups in this cluster (IngressRoute
    # exists under both traefik.io and the deprecated traefik.containo.us;
    # Schedule exists under both velero.io and chaos-mesh.org) -- a bare
    # `kubectl get <kind>` resolves ambiguously and can silently check the
    # wrong CRD entirely. Always qualify with the group from the doc's own
    # apiVersion.
    resource = f"{obj['kind']}.{obj['group']}" if obj["group"] else obj["kind"]
    cmd = ["kubectl", "--kubeconfig", kubeconfig, "get", resource, obj["name"]]
    if obj["kind"] not in CLUSTER_SCOPED_KINDS and obj["namespace"]:
        cmd += ["-n", obj["namespace"]]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    declared = find_declared_objects(repo_root)
    print(f"Checking {len(declared)} declared objects across kubernetes/system/...")

    missing = []
    for obj in declared:
        if not check_live(obj, args.kubeconfig):
            missing.append(obj)
            print(f"  MISSING: {obj['kind']}/{obj['name']} (namespace={obj['namespace']}, declared in {obj['file']})")
        else:
            print(f"  ok: {obj['kind']}/{obj['name']}")

    if missing:
        print(f"\n{len(missing)}/{len(declared)} declared objects are NOT live.")
        sys.exit(1)

    print(f"\nAll {len(declared)} declared objects are live.")
    sys.exit(0)


if __name__ == "__main__":
    main()
