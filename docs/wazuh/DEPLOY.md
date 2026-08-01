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

# Start services
docker compose up -d

# Verify (password set during generate-certs.sh, stored in .env)
# Use curl's --netrc with credentials in ~/.netrc instead of inline
curl -sk --netrc https://localhost:9200
# Should return cluster_name: wazuh-cluster
```

## Access

- Dashboard: [wazuh.woitzik.dev](https://wazuh.woitzik.dev) (via Authelia)
- Default creds: admin / admin (password set during `generate-certs.sh`)
- Change password on first login

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
WAZUH_MANAGER='10.0.30.13' WAZUH_AGENT_GROUP='default' dpkg -i wazuh-agent_4.12.0-1_amd64.deb

# Start
systemctl enable --now wazuh-agent
```
