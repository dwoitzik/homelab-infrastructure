"""
Add Uptime Kuma monitors for all homelab services.

Usage:
    KUMA_URL=https://status.woitzik.dev python3 add_kuma_monitors.py <admin_password>

Requires: pip install uptime-kuma-api
"""

import os
import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType

KUMA_URL = os.getenv("KUMA_URL", "https://status.woitzik.dev")
USERNAME = os.getenv("KUMA_USER", "dw")
PASSWORD = sys.argv[1]

monitors = [
    # Infrastructure
    ("Proxmox VE", "https://pve.woitzik.dev"),
    ("Proxmox Backup Server", "https://backup.woitzik.dev"),
    ("MikroTik Router", "https://router.woitzik.dev"),
    # Platform
    ("ArgoCD", "https://argo.woitzik.dev"),
    ("Traefik", "https://traefik.woitzik.dev"),
    ("Longhorn", "https://longhorn.woitzik.dev"),
    ("Atlantis", "https://atlantis.woitzik.dev"),
    # Security & Auth
    ("Authelia", "https://auth.woitzik.dev"),
    ("Vaultwarden", "https://vault.woitzik.dev"),
    ("AdGuard Home", "https://dns.woitzik.dev"),
    # Apps
    ("Paperless-ngx", "https://docs.woitzik.dev"),
    ("Nextcloud", "https://nextcloud.woitzik.dev"),
    ("Mealie", "https://mealie.woitzik.dev"),
    ("Open WebUI", "https://ai.woitzik.dev"),
    ("Gitea", "https://git.woitzik.dev"),
    ("Home Assistant", "https://ha.woitzik.dev"),
    ("Headscale", "https://headscale.woitzik.dev"),
    # Monitoring
    ("Grafana", "https://monitoring.woitzik.dev"),
    ("Uptime Kuma", "https://status.woitzik.dev"),
    # Storage
    ("Garage S3", "https://s3.woitzik.dev"),
]

try:
    with UptimeKumaApi(KUMA_URL) as api:
        api.login(USERNAME, PASSWORD)
        for name, url in monitors:
            print(f"Adding: {name} ({url})")
            api.add_monitor(
                type=MonitorType.HTTP,
                name=name,
                url=url,
                interval=60,
                accepted_statuscodes=["200-299", "300-399", "401"],
            )
        print(f"\nAdded {len(monitors)} monitors.")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
