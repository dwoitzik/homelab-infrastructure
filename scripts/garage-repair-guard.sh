#!/usr/bin/env bash
# ADR-023: load-aware wrapper for `garage repair` subcommands.
#
# 2026-08-19: a `garage repair blocks` run (part of investigating unrelated
# Garage metadata corruption, see phase8/LEDGER.md Entry 39) grew the block
# resync backlog to 107,156 items and drove the host's shared NVMe write
# latency to ~5 seconds, load average to 25+, and made home.woitzik.dev/
# photos.woitzik.dev fully unreachable until Garage was scaled to 0. This
# script exists so that mistake requires deliberately overriding a guard,
# not just forgetting to check `iostat` first.
#
# Usage: ./garage-repair-guard.sh <garage repair subcommand and args>
# Example: ./garage-repair-guard.sh clear-resync-queue
#          ./garage-repair-guard.sh blocks
#          ./garage-repair-guard.sh --force blocks   # skip the load check
#
# Requires: ssh access to the `pve` host alias (for iostat), kubectl access
# to the cluster (for the actual garage repair invocation).
#
# IMPORTANT if you need to fully STOP an in-progress repair (not just gate a
# new one): `kubectl scale deployment garage --replicas=0 -n apps` alone is
# NOT enough and will silently revert within seconds/minutes -- the `garage`
# ArgoCD Application has selfHeal enabled and will scale it right back up to
# match git. Disable that first:
#   kubectl patch application garage -n argocd --type merge \
#     -p '{"spec":{"syncPolicy":{"automated":null}}}'
#   kubectl scale deployment garage --replicas=0 -n apps
# Re-enable automated sync (restores selfHeal + auto-prune) once done:
#   kubectl patch application garage -n argocd --type merge \
#     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
# (Learned live, 2026-08-19: an agent testing this guard script assumed an
# earlier `kubectl scale --replicas=0` was still in effect: it had already
# been silently reverted by selfHeal, so the "test" ran a real repair
# command against a live Garage instance. Harmless that time (`tables`, not
# `blocks`), but avoid finding this out the hard way twice.)

set -euo pipefail

PVE_HOST="pve"
GARAGE_NAMESPACE="apps"
GARAGE_DEPLOYMENT="deploy/garage"
LOAD1_MAX=5
WRITE_AWAIT_MAX_MS=50

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
  shift
fi

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--force] <garage repair subcommand> [args...]" >&2
  echo "Example: $0 clear-resync-queue" >&2
  exit 2
fi

if [ "$FORCE" -eq 0 ]; then
  echo "[garage-repair-guard] checking host load and NVMe write latency before proceeding..."

  load1=$(ssh "$PVE_HOST" "awk '{print \$1}' /proc/loadavg" | cut -d. -f1)
  # iostat -x field 12 is w_await (Device r/s rkB/s rrqm/s %rrqm r_await
  # rareq-sz w/s wkB/s wrqm/s %wrqm w_await ...) -- confirmed against this
  # host's real iostat output before hardcoding, not guessed from memory.
  write_await=$(ssh "$PVE_HOST" "iostat -x 1 2 2>/dev/null | awk '/^nvme0n1/{print \$12}' | tail -1" | cut -d. -f1)

  echo "[garage-repair-guard] load1=${load1} (max ${LOAD1_MAX}), nvme0n1 w_await=${write_await}ms (max ${WRITE_AWAIT_MAX_MS}ms)"

  if [ "${load1:-0}" -ge "$LOAD1_MAX" ] || [ "${write_await:-0}" -ge "$WRITE_AWAIT_MAX_MS" ]; then
    echo "[garage-repair-guard] REFUSING: host is already under load. Re-run when load1 < ${LOAD1_MAX} and w_await < ${WRITE_AWAIT_MAX_MS}ms, or pass --force if you understand the risk (see ADR-023 / LEDGER Entry 40)." >&2
    exit 1
  fi
  echo "[garage-repair-guard] load looks safe, proceeding."
else
  echo "[garage-repair-guard] --force passed, skipping the load check. You are responsible for watching iostat/load yourself."
fi

echo "[garage-repair-guard] running: garage repair --yes $*"
kubectl exec -n "$GARAGE_NAMESPACE" "$GARAGE_DEPLOYMENT" -- /garage repair --yes "$@"

echo "[garage-repair-guard] launched. Background workers run async -- keep watching 'iostat -x' and 'garage worker list' yourself, this guard only gates the launch, not the ongoing work."
