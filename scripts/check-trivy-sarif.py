#!/usr/bin/env python3
"""Fail when the SARIF uploaded to GitHub code scanning is not empty.

The Security tab is only trustworthy as a gate if something fails when it
regresses. Trivy runs with `exit-code: 0`, so a new HIGH finding introduced by a
Trivy version bump would appear on the tab without failing any check -- and a
tab nobody watches is the same tab that hid 459 advisory findings under 19 real
ones in the first place (see ADR-049).

Findings are resolved by adding a documented entry to .trivyignore, which is the
same path used for the 19 that were already there.
"""

import json
import pathlib
import sys

SARIF = pathlib.Path("trivy-results.sarif")


def main() -> int:
    if not SARIF.exists():
        print(f"  {SARIF} missing -- the SARIF step did not run.")
        return 1

    document = json.loads(SARIF.read_text())
    runs = document.get("runs") or [{}]
    results = [r for run in runs for r in run.get("results", [])]

    if not results:
        print("  0 findings at CRITICAL,HIGH -- code scanning stays clean.")
        return 0

    print(f"  {len(results)} finding(s) at CRITICAL,HIGH reached code scanning:\n")
    for result in results:
        location = ((result.get("locations") or [{}])[0].get("physicalLocation") or {})
        uri = (location.get("artifactLocation") or {}).get("uri", "?")
        line = (location.get("region") or {}).get("startLine", "?")
        print(f"    {result.get('ruleId', '?'):<12} {uri}:{line}")
    print("\n  Fix the finding, or record why it cannot be fixed in .trivyignore.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
