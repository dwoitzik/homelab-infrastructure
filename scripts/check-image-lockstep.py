#!/usr/bin/env python3
"""Fail when images that must share a version are pinned to different tags.

Immich server and machine-learning are released together and must run the
same version. Renovate looks them up separately, and the ML lookup (a GHCR
repository with 200+ pages of tags) sometimes fails, which leaves an update
branch that bumps only the server. This check keeps such a branch red, so
Renovate does not auto-merge it until both images move together.

The headscale and vaultwarden warm standbys on rpi-srv-02 (ADR-029) must run
the primary's version too: a standby older than the primary's database schema
fails on its first start during a failover.

Usage: check-image-lockstep.py
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# (files, image-name regex); every match across the files must carry the same tag.
GROUPS = [
    (["kubernetes/apps/immich/immich.yml"],
     r"ghcr\.io/immich-app/immich-(?:server|machine-learning)"),
    (["kubernetes/apps/headscale/headscale.yml",
      "ansible/roles/rpi_ha_standby/defaults/main.yml"],
     r"ghcr\.io/juanfont/headscale"),
    (["kubernetes/apps/vaultwarden/vaultwarden.yaml",
      "ansible/roles/rpi_ha_standby/defaults/main.yml"],
     r"vaultwarden/server"),
]


def main():
    failed = False
    for files, pattern in GROUPS:
        found = []
        for rel in files:
            text = (REPO / rel).read_text()
            hits = re.findall(r"(" + pattern + r"):([^@\s\"']+)", text)
            if not hits:
                print(f"{rel}: no image matches {pattern}")
                failed = True
            found += [(rel, image, tag) for image, tag in hits]
        if len({tag for _, _, tag in found}) > 1:
            print(f"{', '.join(files)}: images must share one tag, found:")
            for rel, image, tag in sorted(set(found)):
                print(f"  {rel}: {image}:{tag}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
