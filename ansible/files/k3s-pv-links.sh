#!/bin/bash
# Recreate k3s local-path PV symlinks after boot.
#
# The local-path PVs in /tmp/k3s-old/storage point into tmpfs, which is empty
# after a reboot. The real data lives under /var/lib/rancher/k3s/storage.
# The target directories are the PV UIDs (created by kubelet when the PV was
# claimed); the symlink names are the PV names referenced by the PV manifests.
set -e
S=/tmp/k3s-old/storage
D=/var/lib/rancher/k3s/storage
mkdir -p "$S"
link() { rm -rf "$S/$1"; ln -sfn "$D/$2" "$S/$1"; }
link pvc-038db6ec-25be-415f-899f-f5dd432f7007_apps_gitea-data pvc-2b052339-ad38-4ba9-a87d-a5f9bac4e64e_apps_gitea-data
link pvc-1af757fd-9cd5-42ce-8428-35259a851d2b_apps_tailscale-router-state pvc-1fb102a5-dcec-4046-b1c3-a34437a01bfc_apps_tailscale-router-state
link pvc-39deaca3-e1a4-4cee-973b-41b1241e8894_apps_garage-meta pvc-7adcd727-6495-4907-9720-d7be1e3e175f_apps_garage-meta
link pvc-433f4fba-7085-4dfe-aa5f-e77ecd1c110d_database_postgres-authelia-1 pvc-d18397a5-fb2b-4ded-8173-5e505e1c4f25_database_postgres-authelia-1
link pvc-479f52fb-c9a7-4793-9e55-4a142acdb676_monitoring_uptime-kuma-data pvc-71e357e5-a666-4bff-a993-efa24519203f_monitoring_uptime-kuma-data
link pvc-67dec9ec-d3de-4b9f-9394-01216d8ca291_vault_data-vault-0 pvc-a7dafd49-0ebe-4e07-8bd9-8a7620cfad7c_vault_data-vault-0
link pvc-7b3d1f22-f61e-485b-b001-3906f99e7e9a_database_postgres-n8n-1 pvc-f1e0d4df-3901-448c-900f-3475f4c67d93_database_postgres-n8n-1
link pvc-cab0025a-bc71-4d18-8dfe-674ef1b167b9_database_postgres-synapse-1 pvc-0243bdb8-63a5-41a9-9d98-f181d0b25ad0_database_postgres-synapse-1
link pvc-e58111fa-1b03-43f1-b684-b6b94b7eeb80_apps_headscale-data pvc-4d45b0a2-f097-401c-beb7-a0ed286feb09_apps_headscale-data
link pvc-4c0dca6b-aa2a-46d8-93b6-46f7cb217e8c_apps_vaultwarden-data pvc-4c0dca6b-aa2a-46d8-93b6-46f7cb217e8c_apps_vaultwarden-data
link pvc-598ecf9e-300d-4266-9192-77ad4fe0b9e0_apps_open-webui-data pvc-598ecf9e-300d-4266-9192-77ad4fe0b9e0_apps_open-webui-data
link pvc-bca1f45d-1195-4bd7-8fc1-b0138e9bfd8f_apps_home-assistant-config pvc-bca1f45d-1195-4bd7-8fc1-b0138e9bfd8f_apps_home-assistant-config
link pvc-ff4a914f-5413-47fc-9f2e-9a826b2cf12d_apps_mealie-data pvc-ff4a914f-5413-47fc-9f2e-9a826b2cf12d_apps_mealie-data
