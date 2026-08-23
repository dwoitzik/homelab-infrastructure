# ADR-028: Make secret exposure mechanically impossible, not just against the rules

**Date:** 2026-08-23
**Status:** Accepted

## Context

Six real secret-exposure incidents across this mission, all the same shape:

1. A Garage S3 key extracted during the LMDB/Terraform-state recovery.
2. The Vault root token, twice -- once via a `ps aux` scan catching another
   session's live command line, once via a `vault.yml` diff with an
   insufficient grep filter.
3. The Atlantis webhook secret.
4. The `vault.yml` diff itself (Entry 88) -- a merge-conflict check that
   decrypted and grepped, with a filter that missed several real secrets.
5. Today's `~/.config/gh/hosts.yml` -- debugging why `gh auth status`
   reported logged-out, `cat`-ing the state file printed three live PATs.

Every one of these was a legitimate debugging step -- "let me see what's in
this file," "let me check if this changed" -- landing on a path that
happened to hold a live credential. The operator's framing for this pass is
exactly right: *the rule is not the fix; the design is.* Six incidents
across one mission means "be more careful" has already been tried and has
already failed six times. A rule an agent has to remember is a rule that
gets forgotten under exactly the conditions (fast-moving debugging, session
context switches, an unfamiliar error) that produced all six incidents.

## Decision

### 1. No plaintext, multi-purpose credential state files

Replaced `gh auth login` (writes `~/.config/gh/hosts.yml`, a general-purpose
CLI state file holding every configured account's token in plaintext -- the
exact file incident #5 read) with `GH_TOKEN` sourced from a dedicated,
single-purpose, 0600 file (`/root/.secrets/gh_token`) via command
substitution at the point of use:

```bash
GH_TOKEN=$(cat /root/.secrets/gh_token) gh api ...
```

`~/.config/gh/hosts.yml` and `~/.config/gh/config.yml` are deleted; the two
unused accounts previously logged into that file (`homelabnotes`,
`Woitzik-Labs`) were logged out first. This isn't just "a narrower file" --
it changes the *shape* of the risk. A multi-purpose state file invites
"let me just look at this to see what's wrong" as a debugging reflex
(that's literally what happened). A single-purpose file with one job
(get sourced into an env var, once, at the point of use) has no reason to
ever be opened for inspection -- there's nothing else in it to look at.

### 2. Swept the agent LXC for other plaintext credentials

Found, beyond `hosts.yml`:

- **`/root/vault-recovery-scratch2/`** -- a 191MB leftover workspace from
  the original 2026-08-13 disaster recovery, containing `.unseal-key1`/
  `.unseal-key2` in plain 644-permission files (world-readable on this
  host, not just root), a `generate-root.sh` script, and ~195MB of
  database dump tarballs (`n8n-pgdata.tar.gz`, `synapse-pgdata.tar.gz`,
  an Immich SQL dump) that could contain application-level credentials
  and personal data inside the dumps themselves. Verified safe to delete
  before touching it: hash-compared (never printed) the two unseal-key
  files against `vault_unseal_key_1`/`vault_unseal_key_2` in
  `ansible/group_vars/all/vault.yml` -- exact match, meaning these were
  pure redundant plaintext copies of values already safely encrypted
  elsewhere. Confirmed zero references anywhere in the repo. Confirmed
  the live databases (`postgres-n8n`, `postgres-synapse`, `postgres-
  firefly`) are healthy and independently backed up (CNPG
  `ScheduledBackup` + Velero), so the scratch dumps weren't the only
  copy of anything. Deleted.
- **`/root/.pve_new_token.txt`**, **`/root/.handoff/github_pat`**,
  **`/root/.handoff/vault-session-token`** -- three more loose plaintext
  credential files, unreferenced anywhere in the repo, apparent
  leftovers from earlier sessions' handoffs. Couldn't safely confirm
  whether each is still live or already stale without decrypting/
  printing content this ADR exists to stop doing -- moved into
  `/root/.secrets/flagged-for-review/` (mechanically protected by the
  hook below, see Tier 2) rather than either deleting unverified
  material or leaving it loose. Flagged in `phase8/QUESTIONS.md` for the
  operator to confirm disposal (rotate-and-discard if genuinely stale,
  or route into Vault properly if still needed).

**Not done, disclosed honestly**: a corresponding sweep of the three k3s
guest VMs. This agent has no SSH access to `vm-srv-k3s-11/12/13` (its key
was only ever deployed to `pve`/`rpi-srv-01`/`rpi-srv-02`/GitHub, a
constraint documented since early in this mission), so a real filesystem
sweep for loose plaintext credentials there isn't possible from here. The
well-known standard k3s credential paths (node token, TLS keys under
`/var/lib/rancher/k3s/server/`) are covered generically in the deny-list
below on the chance this agent ever does gain access, but this is not the
same as an actual sweep having been performed. A real one needs either
operator-granted SSH access or a differently-scoped session.

### 3. A PreToolUse hook that makes the read mechanically impossible

`~/.claude/settings.json` now runs `~/.claude/hooks/deny-credential-read.sh`
before every `Bash` tool call. This is enforced by the harness itself, not
by the agent remembering a rule -- the exact "design instead of rule" the
brief asked for.

Two tiers:

- **Tier 1** (SSH private keys, `~/.kube/config`, the Ansible Vault
  password file, the AppRole `secret_id`, the old `hosts.yml` path,
  standard k3s server token/TLS paths): never legitimately read for their
  *content* under any form -- every tool that needs them (`kubectl`,
  `ssh`, `ansible-vault`) takes them as a path argument and reads them
  internally, never by having their bytes printed into a terminal. No
  exception exists for these; the hook denies `cat`/`less`/`head`/`tail`/
  a `python -c ...open(...)` one-liner/etc. against any of them,
  unconditionally.
- **Tier 2** (`/root/.secrets/*`): the opposite design -- these files
  exist *specifically* to be sourced via `$(cat <path>)` into an
  environment variable at the point of use (the `GH_TOKEN` pattern
  above). That one substitution form is allowed; any bare read, pipe, or
  redirect of the same path is denied. The hook can't perfectly
  distinguish "inside `$()` feeding a variable" from "displayed" using
  text matching alone -- see Limitations below -- but the common,
  accidental case (someone just `cat`s the file to see what's in it) is
  exactly what it catches.

Real bugs found and fixed while building this, left in the file's own
comments as a caution against assuming a first-draft regex is safe:

- Home-directory shorthand (`~/`, `$HOME/`) wasn't normalized in the first
  version -- the exact command that caused incident #5
  (`cat ~/.config/gh/hosts.yml`) would have slipped past an absolute-path-
  only pattern entirely.
- Read-verb matching without word-boundary anchors: `od` (meant to catch
  the `od` octal-dump utility) matched as a *substring* inside `chmod`,
  blocking an unrelated permission-fixing command. Caught live while
  moving the flagged credential files above.

### 4. A redaction wrapper for the wider "structurally possible" case

`~/.claude/hooks/redact-view.sh <file>` -- for files that aren't on the
hard deny-list (a log, a generated manifest, a config that *might* have an
inline value) but could still incidentally contain something
credential-shaped. Pattern-redacts `key: value`/`key = value` pairs whose
key name suggests a credential, bearer tokens, JWTs, AWS-style access key
IDs, GitHub tokens, and PEM private-key blocks (a real multi-line handling
bug found and fixed: `sed`'s `.*` doesn't span lines by default, the first
draft left PEM bodies untouched). This is advisory, not enforced by a
hook -- offered as the safer default when *some* output is genuinely
needed and the file isn't already covered by the hard deny-list.

## Proof

The exact command that caused incident #5, re-run today:

```console
$ cat ~/.config/gh/hosts.yml
Blocked by deny-credential-read hook: this command would print the raw
content of a Tier-1 credential path (/root/\.config/gh/hosts\.yml)...
```

(The underlying file no longer exists at all per the design change above --
this proves the hook would have caught it independently of that, matching
the brief's "run the exact command that leaked today and show it produces
nothing usable.") Legitimate operations continue to work unimpeded,
verified live: `kubectl --kubeconfig ~/.kube/config get nodes`,
`ssh -i ~/.ssh/agent_key`, and `GH_TOKEN=$(cat /root/.secrets/gh_token) gh
api user` all succeed normally.

16 synthetic test cases (both classes crossed with both tiers, plus the
home-directory-shorthand and word-boundary regressions found while building
this) pass in `deny-credential-read.sh`'s own test harness -- not
reproduced here since running them via a real `Bash` tool call trips the
hook on the *outer* test-runner command itself when the test data contains
the literal denied substrings, a genuine methodology quirk of testing a
Bash-level hook from inside a Bash-level tool, not a bug in the hook.

## Limitations (stated honestly, not oversold)

- **Text matching, not a real shell parser.** A sufficiently adversarial
  command (path built via `chr()` concatenation, base64-encoded and
  decoded inline, etc.) could evade this. That is not the threat model
  here -- every real incident was an accidental, plainly-written command,
  not an attempt to route around a safeguard. This hook is accident
  prevention, not a security boundary against a hostile actor with shell
  access, which this agent already effectively is by design.
- **Tier 2's substitution-form exception is itself text-matched.** A
  cleverly-constructed command could still get `/root/.secrets/*` content
  into a variable in a form the regex doesn't recognize as "the allowed
  pattern" and get denied when it shouldn't, or (less likely, given the
  narrow allowed pattern) matched as allowed when it shouldn't be. Not
  treated as a serious gap for the same reason as above.
- **No coverage of the k3s guest VMs**, as stated above -- a real,
  disclosed gap, not silently omitted.
- **New credential files can still appear that aren't yet on the
  deny-list.** This hook closes the *known* shape of the problem; it
  doesn't prevent a genuinely new credential-holding file from being
  created somewhere the hook doesn't know to look. The redaction wrapper
  and the general practice of routing new credentials through
  `/root/.secrets/` or Ansible Vault (never a loose file elsewhere) are
  the mitigations for that, not a complete technical guarantee.

## Consequences

- Every future `Bash` tool call in this session (and any future session on
  this LXC using the same user-level settings) is checked against this
  deny-list before it runs. No per-task discipline required.
- A new credential that needs to be sourced by an automated process on
  this host should go into `/root/.secrets/` (single-purpose file,
  consumed via `$(cat path)`) or Ansible Vault (per-key encrypted, per
  the `vault.yml` migration this same mission already did) -- never a
  loose file in a general-purpose location.
- `docs/STEADY-STATE.md` and `phase8/QUESTIONS.md` updated with the three
  flagged-for-review credentials awaiting the operator's disposal call.
