#!/bin/bash
# Swap the k3s binary on one node to a pinned, sha256-checked release; unit and config stay untouched.
# usage: upgrade-node.sh <node-ip> <node-name> <k3s|k3s-agent> <version> [fetch-only]  (see docs/runbooks/k3s-upgrade.md)
set -euo pipefail
ip=$1 node=$2 svc=$3 ver=$4 mode=${5:-}
enc=${ver/+/%2B}
ssh dw@"$ip" "sudo bash -s" <<REMOTE
set -euo pipefail
d=/root/k3s-dl-$ver
mkdir -p -m 700 \$d && cd \$d
[ -s sums ] || curl -fsSL -o sums https://github.com/k3s-io/k3s/releases/download/$enc/sha256sum-amd64.txt
want=\$(awk '\$2=="k3s"{print \$1}' sums)
if [ ! -s k3s ] || [ "\$(sha256sum k3s | awk '{print \$1}')" != "\$want" ]; then
  curl -fsSL -o k3s.part https://github.com/k3s-io/k3s/releases/download/$enc/k3s && mv k3s.part k3s
fi
[ -n "\$want" ] && [ "\$want" = "\$(sha256sum k3s | awk '{print \$1}')" ] || { echo "checksum mismatch"; exit 1; }
[ "$mode" = fetch-only ] && { echo "fetched $ver"; exit 0; }
cur=\$(/usr/local/bin/k3s --version | head -1 | awk '{print \$3}')
cp -p /usr/local/bin/k3s /usr/local/bin/k3s.prev-\$cur
install -m 0755 -o root -g root k3s /usr/local/bin/k3s.new
mv -f /usr/local/bin/k3s.new /usr/local/bin/k3s
/usr/local/bin/k3s --version | head -1
systemctl restart $svc
cd / && rm -rf \$d
REMOTE
[ "$mode" = fetch-only ] && exit 0
for _ in $(seq 1 60); do
  v=$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$v" = "$ver True" ] && { echo "$node ready on $ver"; exit 0; }
  sleep 5
done
echo "$node not ready on $ver after 5m: $v"; exit 1
