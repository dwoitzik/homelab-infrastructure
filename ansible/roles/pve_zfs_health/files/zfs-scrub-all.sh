#!/bin/sh
set -eu

# Scrub every ONLINE pool not already scrubbing. Stands in for Debian's
# zfsutils-linux scrub, whose slot overlapped the PBS GC/backup/verify windows.

/usr/sbin/zpool list -H -o health,name | while read -r health pool; do
  [ "$health" = "ONLINE" ] || continue
  if ! /usr/sbin/zpool status "$pool" | grep -q "scrub in progress"; then
    /usr/sbin/zpool scrub "$pool" || echo "zpool scrub $pool failed" >&2
  fi
done
