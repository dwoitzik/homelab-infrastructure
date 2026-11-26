#!/bin/bash
# Checks to run after every node of a k3s upgrade; prints each result, no single pass/fail.
# Runbook: docs/runbooks/k3s-upgrade.md
set -u
SERVER=${SERVER:-10.0.20.11}
LB=${LB:-10.0.20.200}

echo "== nodes (name ready version unschedulable)"
kubectl get nodes --no-headers -o custom-columns='N:.metadata.name,R:.status.conditions[?(@.type=="Ready")].status,V:.status.nodeInfo.kubeletVersion,U:.spec.unschedulable'

echo "== secrets encryption"
ssh "dw@$SERVER" 'sudo k3s secrets-encrypt status' | head -3

echo "== pods not Running/Completed, or Running but not ready"
kubectl get pods -A --no-headers | awk '($4!="Running" && $4!="Completed") || ($4=="Running" && substr($3,1,index($3,"/")-1)!=substr($3,index($3,"/")+1))'

echo "== ExternalSecrets by reason"
kubectl get externalsecret -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].reason}{"\n"}{end}' | sort | uniq -c

echo "== ArgoCD apps not Synced/Healthy"
kubectl -n argocd get applications --no-headers | awk '$2!="Synced" || $3!="Healthy"'

# Each connection can land on another Traefik replica: TRIES requests per host
# make one broken replica show up as a minority of non-200 answers.
TRIES=${TRIES:-8}
echo "== ingress through Traefik ($LB), $TRIES requests per host"
for u in photos.woitzik.dev/ auth.woitzik.dev/ vault.woitzik.dev/ headscale.woitzik.dev/ nextcloud.woitzik.dev/status.php; do
  h=${u%%/*}
  codes=$(for _ in $(seq "$TRIES"); do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 --resolve "$h:443:$LB" "https://$u"
  done | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}')
  printf '%s %s\n' "$u" "$codes"
done
# Backends normally sit on different nodes; this shows where each answer came from.
kubectl get pods -A -o wide --no-headers \
  | grep -E '^(apps|kube-system|vault) +(traefik|immich-server|authelia|headscale|nextcloud-[0-9a-f]|vault-0)' \
  | awk '{print "  " $2, $(NF-2)}'

echo "== Prometheus targets down"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19091:9090 >/dev/null 2>&1 &
pf=$!
sleep 3
curl -s http://127.0.0.1:19091/api/v1/targets?state=active | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"]["activeTargets"]
down = [x for x in t if x["health"] != "up"]
print(len(t), "targets,", len(down), "down")
for x in down: print("  ", x["labels"].get("job"), x["scrapeUrl"], x["lastError"][:120])'
kill "$pf"

echo "== Velero backup storage locations"
kubectl get bsl -A --no-headers | awk '{print $2, $3}'

# apps has default-deny ingress; a pod in default must be refused there while
# DNS and a namespace without that policy stay reachable.
echo "== NetworkPolicy enforcement"
kubectl -n default delete pod np-probe --ignore-not-found --wait >/dev/null 2>&1
kubectl -n default run np-probe --image=busybox:1.37.0 --restart=Never --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np-probe","image":"busybox:1.37.0","command":["sh","-c","if wget -q -T 5 -O /dev/null http://homepage.apps.svc.cluster.local/; then echo DENY_BROKEN; else echo denied_ok; fi; if wget -q -T 5 -O /dev/null http://traefik-api.kube-system.svc.cluster.local:9000/ping 2>&1 | grep -q timed; then echo control_timeout; else echo control_reached; fi; nslookup kubernetes.default.svc.cluster.local >/dev/null && echo dns_ok"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"limits":{"cpu":"50m","memory":"32Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}}]}}' >/dev/null
kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-probe --timeout=120s >/dev/null
kubectl -n default logs np-probe
kubectl -n default delete pod np-probe --wait=false >/dev/null
