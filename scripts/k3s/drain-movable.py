#!/usr/bin/env python3
"""Cordon a node and evict only the pods that can run somewhere else.

usage: drain-movable.py <node>

`kubectl drain` also evicts pods that are pinned to the node (a local-path PV
on it, a hostname nodeSelector, or a required node affinity for it). Those
cannot reschedule, so evicting them only turns a kubelet restart that the
containers would survive into an outage until uncordon. They are left running
here; everything else goes through the Eviction API, so PodDisruptionBudgets
still hold. A pod whose PDB keeps refusing is reported and left running.
Runbook: docs/runbooks/k3s-upgrade.md
"""
import json
import subprocess
import sys
import time


def kubectl_json(*args):
    out = subprocess.run(["kubectl", *args, "-o", "json"], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)["items"]


def main():
    node = sys.argv[1]
    subprocess.run(["kubectl", "cordon", node], check=True)

    pinned_claims = set()
    for pv in kubectl_json("get", "pv"):
        affinity = pv["spec"].get("nodeAffinity")
        claim = pv["spec"].get("claimRef")
        if not affinity or not claim:
            continue
        values = [v for term in affinity["required"]["nodeSelectorTerms"]
                  for expr in term["matchExpressions"] for v in expr.get("values", [])]
        if values == [node]:
            pinned_claims.add((claim["namespace"], claim["name"]))

    todo = []
    for pod in kubectl_json("get", "pods", "-A", "--field-selector", f"spec.nodeName={node}"):
        ns, name = pod["metadata"]["namespace"], pod["metadata"]["name"]
        owners = [o["kind"] for o in pod["metadata"].get("ownerReferences", [])]
        if "DaemonSet" in owners or pod["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        spec = pod["spec"]
        claims = {(ns, v["persistentVolumeClaim"]["claimName"])
                  for v in spec.get("volumes", []) if "persistentVolumeClaim" in v}
        required = spec.get("affinity", {}).get("nodeAffinity", {}).get(
            "requiredDuringSchedulingIgnoredDuringExecution", {})
        affinity_nodes = [v for term in required.get("nodeSelectorTerms", [])
                          for expr in term.get("matchExpressions", [])
                          if expr.get("operator") == "In" for v in expr.get("values", [])]
        if (claims & pinned_claims or affinity_nodes == [node]
                or spec.get("nodeSelector", {}).get("kubernetes.io/hostname") == node):
            print(f"keep    {ns}/{name} (node-pinned)")
            continue
        todo.append((ns, name))

    deadline = time.time() + 300
    while todo and time.time() < deadline:
        remaining = []
        for ns, name in todo:
            body = json.dumps({"apiVersion": "policy/v1", "kind": "Eviction",
                               "metadata": {"name": name, "namespace": ns}})
            r = subprocess.run(["kubectl", "create", "--raw",
                                f"/api/v1/namespaces/{ns}/pods/{name}/eviction", "-f", "-"],
                               input=body, capture_output=True, text=True)
            if r.returncode == 0 or "not found" in r.stderr.lower():
                print(f"evicted {ns}/{name}")
            else:
                remaining.append((ns, name))
        todo = remaining
        if todo:
            time.sleep(10)
    for ns, name in todo:
        print(f"BLOCKED {ns}/{name} (PDB, left running)")


if __name__ == "__main__":
    main()
