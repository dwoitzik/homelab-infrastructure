import os
from uptime_kuma_api import UptimeKumaApi, MonitorType
import sys

KUMA_URL = os.getenv("KUMA_URL", "http://localhost:3001")
USERNAME = os.getenv("KUMA_USER", "david")
PASSWORD = sys.argv[1]

monitors = [
    ("Atlantis", "https://atlantis.woitzik.dev"),
    ("Authelia", "https://auth.woitzik.dev"),
    ("Proxmox VE", "https://pve.woitzik.dev"),
    ("Backup Server", "https://backup.woitzik.dev"),
    ("Minio Console", "https://minio.woitzik.dev"),
    ("ArgoCD", "https://argo.woitzik.dev"),
    ("Grafana", "https://monitoring.woitzik.dev"),
    ("Uptime Kuma", "https://status.woitzik.dev")
]

try:
    with UptimeKumaApi(KUMA_URL) as api:
        api.login(USERNAME, PASSWORD)
        for name, url in monitors:
            print(f"Adding monitor: {name} ({url})")
            api.add_monitor(
                type=MonitorType.HTTP,
                name=name,
                url=url,
                interval=60,
                upsideDown=False,
                accepted_statuscodes=["200-299", "300-399", "401"] # Allow 401 for OIDC redirect checks
            )
        print("All monitors added successfully.")
except Exception as e:
    print(f"Error: {e}")
