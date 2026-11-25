#!/usr/bin/env python3
"""Fail when images that must share a version are pinned to different tags.

Immich server and machine-learning are released together and must run the
same version. Renovate looks them up separately, and the ML lookup (a GHCR
repository with 200+ pages of tags) sometimes fails, which leaves an update
branch that bumps only the server. This check keeps such a branch red, so
Renovate does not auto-merge it until both images move together.

Usage: check-image-lockstep.py
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# (file, image-name regex); every match in the file must carry the same tag.
GROUPS = [
    ("kubernetes/apps/immich/immich.yml",
     r"ghcr\.io/immich-app/immich-(?:server|machine-learning)"),
]


def main():
    failed = False
    for rel, pattern in GROUPS:
        text = (REPO / rel).read_text()
        found = re.findall(r"(" + pattern + r"):([^@\s\"']+)", text)
        tags = {tag for _, tag in found}
        if not found:
            print(f"{rel}: no image matches {pattern}")
            failed = True
        elif len(tags) > 1:
            print(f"{rel}: images must share one tag, found:")
            for image, tag in sorted(set(found)):
                print(f"  {image}:{tag}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
