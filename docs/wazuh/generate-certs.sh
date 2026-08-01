#!/bin/bash
# Generate Wazuh certificates for single-node deployment
# Run from /opt/wazuh/ on ct-srv-docker-01
set -euo pipefail

CERT_DIR="wazuh_indexer/certs"
DASH_CERT_DIR="wazuh_dashboard/certs"
PASSWORD="SecretPassword1!"

mkdir -p "$CERT_DIR" "$DASH_CERT_DIR"

echo "==> Generating root CA..."
openssl genrsa -out "$CERT_DIR/root-ca-key.pem" 2048
openssl req -x509 -new -nodes -key "$CERT_DIR/root-ca-key.pem" \
  -sha256 -days 3650 -out "$CERT_DIR/root-ca.pem" \
  -subj "/C=US/ST=California/L=California/O=Wazuh/OU=Wazuh/CN=Wazuh Root CA"

echo "==> Generating Wazuh Indexer certificate..."
openssl genrsa -out "$CERT_DIR/wazuh-indexer-key.pem" 2048
openssl req -new -key "$CERT_DIR/wazuh-indexer-key.pem" \
  -out "$CERT_DIR/wazuh-indexer.csr" \
  -subj "/C=US/ST=California/L=California/O=Wazuh/OU=Wazuh/CN=wazuh.indexer"
cat > "$CERT_DIR/indexer-ext.cnf" <<EOF
[v3_ca]
subjectAltName = DNS:wazuh.indexer,IP:127.0.0.1
EOF
openssl x509 -req -in "$CERT_DIR/wazuh-indexer.csr" \
  -CA "$CERT_DIR/root-ca.pem" -CAkey "$CERT_DIR/root-ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/wazuh-indexer.pem" -days 3650 -sha256 \
  -extfile "$CERT_DIR/indexer-ext.cnf" -extensions v3_ca

echo "==> Generating Wazuh Manager certificate..."
openssl genrsa -out "$CERT_DIR/wazuh-manager-key.pem" 2048
openssl req -new -key "$CERT_DIR/wazuh-manager-key.pem" \
  -out "$CERT_DIR/wazuh-manager.csr" \
  -subj "/C=US/ST=California/L=California/O=Wazuh/OU=Wazuh/CN=wazuh.manager"
cat > "$CERT_DIR/manager-ext.cnf" <<EOF
[v3_ca]
subjectAltName = DNS:wazuh.manager,IP:127.0.0.1
EOF
openssl x509 -req -in "$CERT_DIR/wazuh-manager.csr" \
  -CA "$CERT_DIR/root-ca.pem" -CAkey "$CERT_DIR/root-ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/wazuh-manager.pem" -days 3650 -sha256 \
  -extfile "$CERT_DIR/manager-ext.cnf" -extensions v3_ca

echo "==> Generating Wazuh Dashboard certificate..."
openssl genrsa -out "$DASH_CERT_DIR/wazuh-dashboard-key.pem" 2048
openssl req -new -key "$DASH_CERT_DIR/wazuh-dashboard-key.pem" \
  -out "$DASH_CERT_DIR/wazuh-dashboard.csr" \
  -subj "/C=US/ST=California/L=California/O=Wazuh/OU=Wazuh/CN=wazuh.dashboard"
cat > "$DASH_CERT_DIR/dash-ext.cnf" <<EOF
[v3_ca]
subjectAltName = DNS:wazuh.dashboard,IP:127.0.0.1
EOF
openssl x509 -req -in "$DASH_CERT_DIR/wazuh-dashboard.csr" \
  -CA "$CERT_DIR/root-ca.pem" -CAkey "$CERT_DIR/root-ca-key.pem" \
  -CAcreateserial -out "$DASH_CERT_DIR/wazuh-dashboard.pem" -days 3650 -sha256 \
  -extfile "$DASH_CERT_DIR/dash-ext.cnf" -extensions v3_ca

# Copy root CA to dashboard dir
cp "$CERT_DIR/root-ca.pem" "$DASH_CERT_DIR/root-ca.pem"

# Cleanup CSRs and ext files
rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.cnf "$CERT_DIR"/*.srl
rm -f "$DASH_CERT_DIR"/*.csr "$DASH_CERT_DIR"/*.cnf

echo "==> Done! Certificates generated:"
find "$CERT_DIR" "$DASH_CERT_DIR" -name "*.pem" | sort
