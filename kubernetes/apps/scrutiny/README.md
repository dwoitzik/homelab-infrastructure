# Scrutiny

Disk health (S.M.A.R.T.) monitoring — a `scrutiny-collector` DaemonSet reads SMART data
per node, `scrutiny-web` serves the dashboard, InfluxDB stores the time series.

## Storage

`nfs-client` PVCs for both the InfluxDB time-series data and the web UI's own config.

## How to restore

Standard PVC swap-restore for both PVCs: scale to 0, mount via a throwaway pod, copy
preserved data in, scale back up. Losing this data costs SMART history, not anything
operationally critical — not worth urgent recovery if it's ever actually lost, a fresh
start just means historical trend charts reset.
