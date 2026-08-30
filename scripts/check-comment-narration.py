#!/usr/bin/env python3
"""Blocks the dated/narrated investigation-diary comment style CLAUDE.local.md
already asks not to do (see "Comment style"). Scans added lines in the staged
diff for a comment containing a date, an investigation-narration phrase, or
a comment block longer than 3 lines.

This exists because asking for it in CLAUDE.local.md alone didn't hold --
it got violated again the same day it was written, and twice more after
that. A mechanical gate outlasts a session's memory of the rule.
"""
import re
import subprocess
import sys

DATE_RE = re.compile(r"\b20\d{2}-\d{2}-\d{2}\b")
BANNED_PHRASES = [
    "confirmed via",
    "confirmed live",
    "confirmed:",
    "confirmed against",
    "root-caused",
    "root caused",
    "found live",
    "verified live",
    "investigated",
]
COMMENT_MARKERS = ("#", "//", "--")
MAX_COMMENT_BLOCK = 3


def is_comment_line(text: str) -> bool:
    stripped = text.strip()
    return any(stripped.startswith(m) for m in COMMENT_MARKERS)


def phrase_hit(content: str) -> str | None:
    if DATE_RE.search(content):
        return "date"
    lowered = content.lower()
    for phrase in BANNED_PHRASES:
        if phrase in lowered:
            return f'phrase "{phrase}"'
    return None


def main() -> int:
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout

    violations = []
    current_file = None
    block: list[str] = []

    def flush_block():
        if len(block) > MAX_COMMENT_BLOCK:
            violations.append(
                (current_file, f"{len(block)}-line comment block (max {MAX_COMMENT_BLOCK})", block[0])
            )

    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            flush_block()
            block = []
            current_file = line[6:]
            continue

        is_added = line.startswith("+") and not line.startswith("+++")
        if not is_added:
            flush_block()
            block = []
            continue

        content = line[1:]
        if not is_comment_line(content):
            flush_block()
            block = []
            continue

        block.append(content.strip())
        hit = phrase_hit(content)
        if hit:
            violations.append((current_file, hit, content.strip()))

    flush_block()

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
