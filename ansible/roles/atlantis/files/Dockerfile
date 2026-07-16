ARG BASE_IMAGE=ghcr.io/runatlantis/atlantis:v0.46.0@sha256:e79363da6b55182d0cb13d7d9deb1cef51528f309a64254755c80df09cbfd698
FROM ${BASE_IMAGE}

# SEC-007: trust Proxmox's self-signed cluster CA so the bpg/proxmox Terraform
# provider can verify TLS (insecure = false) instead of skipping verification
# entirely. Public CA cert only, no secret material.
USER root
COPY pve-root-ca.crt /usr/local/share/ca-certificates/pve-root-ca.crt
RUN update-ca-certificates
USER atlantis
