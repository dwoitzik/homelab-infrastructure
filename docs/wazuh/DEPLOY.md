# Wazuh SIEM Deployment

## Prerequisites

- ct-srv-docker-01 RAM ≥ 8GB (PR #395)
- Docker + Docker Compose v2

## Deploy

```bash
# Copy to LXC
scp -r docs/wazuh/ root@10.0.20.251:/opt/wazuh/

# SSH into LXC
ssh root@10.0.20.251
cd /opt/wazuh

# Generate TLS certificates
chmod +x generate-certs.sh
./generate-certs.sh

# Set real credentials - NOT committed, .env stays on the LXC only
cat > .env <<'ENVEOF'
WAZUH_INDEXER_PASSWORD=<generate a real random password>
WAZUH_DASHBOARD_PASSWORD=<generate a real random password>
ENVEOF
chmod 600 .env

# opensearch_dashboards.yml is a static mounted config file, not a
# container env var - docker compose can't substitute into it, so the
# placeholder needs a real sed pass before first start (and after any
# future rotation).
source .env
sed -i "s/__WAZUH_INDEXER_PASSWORD__/${WAZUH_INDEXER_PASSWORD}/" \
  wazuh_dashboard/opensearch_dashboards.yml

# Start services
docker compose up -d

# Verify (credentials from .env above)
# Use curl's --netrc with credentials in ~/.netrc instead of inline
curl -sk --netrc https://localhost:9200
# Should return cluster_name: wazuh-cluster
```

## Access

- Dashboard: [wazuh.woitzik.dev](https://wazuh.woitzik.dev) (via Authelia) - not yet wired up, see "Expose via k8s Traefik" below
- Creds: admin / whatever was set in `.env` above
- 2026-08-20: this file, docker-compose.yml, and generate-certs.sh previously
  hardcoded a well-known example password from Wazuh's own quickstart docs,
  both here and live - a real, public leaked-credential exposure. Fixed here
  (env-var injection, not committed); the live indexer/dashboard still need
  their actual credential rotated via `wazuh-passwords-tool.sh`, tracked
  separately.

## Expose via k8s Traefik

After deployment, create IngressRoute in k8s:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: wazuh-final
  namespace: apps
spec:
  entryPoints: [websecure]
  routes:
  - match: Host(`wazuh.woitzik.dev`)
    kind: Rule
    middlewares: [{name: crowdsec-bouncer}, {name: authelia}]
    services:
    - name: wazuh-dashboard
      namespace: apps
      kind: ExternalService
      port: 443
      serversTransport: skip-verify
  tls: {secretName: wildcard-woitzik-dev-tls}
```

Or use a simple TCP passthrough via MetalLB/LoadBalancer.

## Agent Install (on k3s nodes)

```bash
# Download agent
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.12.0-1_amd64.deb

# Install
# 2026-08-20: was 10.0.30.13 (wrong VLAN/host entirely) - the manager is
# ct-srv-docker-01, 10.0.20.251.
WAZUH_MANAGER='10.0.20.251' WAZUH_AGENT_GROUP='default' dpkg -i wazuh-agent_4.12.0-1_amd64.deb

# Start
systemctl enable --now wazuh-agent
```
