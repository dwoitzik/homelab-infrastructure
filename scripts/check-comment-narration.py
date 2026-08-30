#!/usr/bin/env python3
"""Blocks the dated/narrated investigation-diary comment style CLAUDE.local.md
already asks not to do (see "Comment style"). Scans added lines in the staged
diff for a comment containing a date or an investigation-narration phrase.

This exists because asking for it in CLAUDE.local.md alone didn't hold --
it got violated again the same day it was written, and again ten days
later. A mechanical gate outlasts a session's memory of the rule.
"""
import re
import subprocess
import sys

DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
BANNED_PHRASES = [
    "confirmed via",
    "confirmed live",
    "confirmed:",
    "root-caused",
    "root caused",
    "found live",
    "verified live",
    "investigated",
]
COMMENT_MARKERS = ("#", "//", "--")


def is_comment_line(text: str) -> bool:
    stripped = text.strip()
    return any(stripped.startswith(m) for m in COMMENT_MARKERS)


def main() -> int:
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    violations = []
    current_file = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            continue
        if not line.startswith("+") or line.startswith("+++"):
            continue
        content = line[1:]
        if not is_comment_line(content):
            continue
        lowered = content.lower()
        hit = None
        if DATE_RE.search(content):
            hit = "date"
        else:
            for phrase in BANNED_PHRASES:
                if phrase in lowered:
                    hit = f'phrase "{phrase}"'
                    break
        if hit:
            violations.append((current_file, hit, content.strip()))

    if violations:
        print("Comment-narration guard: found dated/investigation-diary comments.")
        print("Per CLAUDE.local.md's Comment style section: WHY only, 1-3 lines,")
        print("no dates, no \"confirmed via/live\" narration. Put the investigation")
        print("in phase8/LEDGER.md or an ADR instead.\n")
        for f, hit, text in violations:
            print(f"  {f}: {hit}\n    {text}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
