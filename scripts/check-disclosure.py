#!/usr/bin/env python3
"""Blocks new disclosure in a repository that is published in public.

Scope: added lines in the staged diff, same model as check-comment-narration.py.
Two tiers:

  HARD  -- always fails, cannot be baselined. Losing one of these to a public
           repo is unrecoverable without rotating the credential.
  BASED -- fails only when the finding is not already in .disclosure-baseline.json.
           Used for the internal-topology identifiers that the deploy manifests
           genuinely require (an IngressRoute host has to be the real hostname or
           it does not deploy), which are therefore accepted for now and must not
           be allowed to spread any further.

The baselined tier is a ratchet, not an approval: it records the identifiers the
live manifests already depend on so the gate can be enabled without a 342-file
refactor, and fails on the first new one. Removing an entry from the baseline is
a deliberate act with a reviewable diff -- you cannot silence the gate by editing
the manifest alone.

Regenerate the baseline deliberately after an intentional redaction:
    python3 scripts/check-disclosure.py --write-baseline
"""
import hashlib
import json
import os
import re
import subprocess
import sys

BASELINE_PATH = ".disclosure-baseline.json"

# The two baseline files catalogue these strings, and this script contains the
# patterns themselves; without this exemption the gate flags its own detector
# and baseline every run, which is how a guard gets switched off out of frustration.
SELF_EXEMPT = {
    BASELINE_PATH,
    ".gitleaks-baseline.json",
    "scripts/check-disclosure.py",
}

# The one zone this repository manages. Override for a fork.
DOMAIN = os.environ.get("DISCLOSURE_DOMAIN", "woitzik.dev")

FREE_MAIL = (
    "gmail.com", "googlemail.com", "gmx.de", "gmx.net", "web.de", "yahoo.de",
    "yahoo.com", "outlook.com", "hotmail.com", "hotmail.de", "t-online.de",
    "protonmail.com", "proton.me", "icloud.com", "aol.com", "live.com",
)

HARD_RULES = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("gh-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("personal-email", re.compile(
        r"\b[\w.+-]+@(?:" + "|".join(re.escape(d) for d in FREE_MAIL) + r")\b",
        re.I)),
]

BASED_RULES = [
    ("public-hostname", re.compile(
        r"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\." + re.escape(DOMAIN) + r"\b", re.I)),
    ("cloudflare-account-id", re.compile(r"\b[0-9a-f]{32}\b")),
    ("internal-hostname", re.compile(
        r"\b(?:pve-mgmt-01|rpi-srv-0[12]|vm-srv-k3s-1[123]|ct-srv-nfs-01)\b", re.I)),
    ("private-ipv4", re.compile(
        r"\b(?:10\.\d{1,3}|192\.168)\.\d{1,3}\.\d{1,3}\b")),
]


def staged_added_lines(diff_file=None):
    """Yield (path, line_text) for every added line in a diff.

    Defaults to the staged index (what pre-commit sees). CI passes --diff-file
    with a pre-computed PR diff, since a checkout has nothing staged.
    """
    if diff_file:
        with open(diff_file) as fh:
            diff = fh.read()
    else:
        diff = subprocess.run(
            ["git", "diff", "--cached", "--unified=0", "--no-color"],
            capture_output=True, text=True, check=True).stdout
    path, new_lineno = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            new_lineno = int(m.group(1)) if m else 0
        elif line.startswith("+") and not line.startswith("+++"):
            yield path, new_lineno, line[1:]
            new_lineno += 1


def load_baseline():
    try:
        with open(BASELINE_PATH) as fh:
            return set(json.load(fh))
    except FileNotFoundError:
        return set()


def entry_key(category, value):
    """Stable digest of one baseline entry.

    Keyed on category+value only, deliberately not on path. These identifiers are
    already public in the tree they came from, so mentioning one again in a new
    document discloses nothing new -- path-scoping would only manufacture
    friction, and friction is how a gate gets bypassed. What must not happen is a
    genuinely new identifier appearing, and that is what this catches.

    The baseline is committed, so values are stored as digests: verbatim they
    would be a single-file index of everything this repo discloses, which is a
    more convenient target list than grepping the original 230 files.
    """
    raw = "\0".join((category, value)).encode()
    return hashlib.sha256(raw).hexdigest()


def tracked_files():
    """Yield (path, content) for every tracked text file."""
    names = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True,
        check=True).stdout.split("\0")
    for name in filter(None, names):
        if name in SELF_EXEMPT:
            continue
        try:
            with open(name, errors="replace") as fh:
                yield name, fh.read()
        except (IsADirectoryError, FileNotFoundError):
            continue


def collect_baseline_keys():
    """Digest of every BASED-rule hit in the current tree."""
    keys = set()
    for path, content in tracked_files():
        for category, pattern in BASED_RULES:
            for value in pattern.findall(content):
                keys.add(entry_key(category, value))
    return keys


def main() -> int:
    write = "--write-baseline" in sys.argv

    if write:
        keys = sorted(collect_baseline_keys())
        with open(BASELINE_PATH, "w") as fh:
            json.dump(keys, fh, indent=2)
            fh.write("\n")
        print(f"Wrote {len(keys)} baselined entries to {BASELINE_PATH}")
        return 0

    diff_file = None
    if "--diff-file" in sys.argv:
        diff_file = sys.argv[sys.argv.index("--diff-file") + 1]

    findings = []
    for path, lineno, text in staged_added_lines(diff_file):
        if not path or path in SELF_EXEMPT:
            continue
        for category, pattern in HARD_RULES:
            if pattern.search(text):
                findings.append(("hard", category, path, lineno, text.strip()))
        for category, pattern in BASED_RULES:
            for hit in pattern.findall(text):
                findings.append(("based", category, path, lineno, hit))

    baseline = load_baseline()
    hard = [f for f in findings if f[0] == "hard"]
    new = [f for f in findings
           if f[0] == "based" and entry_key(f[1], f[4]) not in baseline]

    if not hard and not new:
        return 0


    if hard:
        print("Disclosure guard: credential-shaped material in the staged diff.")
        print("These are never baselined. Use a Secret reference "
              "(ExternalSecret/Vault/Ansible Vault), not a literal value.\n")
        for _tier, category, path, lineno, text in hard:
            print(f"  [{category}] {path}:{lineno}\n    {text}")

    if new:
        print("\nDisclosure guard: new infrastructure identifiers in the staged diff.")
        print(f"This repo is public. Already-accepted identifiers live in "
              f"{BASELINE_PATH}; adding new ones widens what the repo discloses.")
        print("If the value is genuinely required, re-run with --write-baseline "
              "and explain it in the PR.\n")
        for _tier, category, path, lineno, value in new:
            print(f"  [{category}] {path}:{lineno} -> {value}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
