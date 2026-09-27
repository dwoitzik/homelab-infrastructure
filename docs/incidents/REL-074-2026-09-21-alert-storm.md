# REL-074 — 2026-09-21 overnight alert storm

> Stand: 2026-09-21, Reporting aus Live-Zustand (kubectl), nicht aus Alert-Texten.
> Post-hoc konsolidiert 2026-09-27 (Original-Notizen lagen in `sops/incident-log.md`, untracked).

## 1) Die 8 Alerts der Nacht — gruppiert

| Alarm | Quelle | Einordnung |
|---|---|---|
| KubeAPIServerHighLatency p99=8.5s | Prometheus/Rule | Kern-Symptom (Memory-Druck, s. u.) |
| SLO fast burn: photos.woitzik.dev (0.19%) | SLO-Rule | Folge (Monitoring-API selbst betroffen) |
| SLO fast burn: headscale.woitzik.dev (0.21%) | SLO-Rule | Folge |
| SLO fast burn: headscale.woitzik.dev (0.17%) | SLO-Rule | Folge, gleiche Kette |
| KubePersistentVolumeFillingUp gotify 0.06% frei | Rule | Eigenständig (PV-Knappheit, unabhängig) |
| KubePersistentVolumeFillingUp linkding 1% frei | Rule | Eigenständig |
| KubePersistentVolumeFillingUp onlyoffice 2.5% | Rule | Eigenständig |
| KubePersistentVolumeFillingUp myspeed 2.5% | Rule | Eigenständig |

Diagnose-Korrektur ggü. dem Original-Log: der dortige "etcd-apply-Mem-Krampf" stimmt
nicht — dieser Cluster führt nie etcd (ADR-015, kine/SQLite). Der p99-Spike-Mechanismus
ist inzwischen endgültig als **Prometheus-Restart-Artefakt** verstanden (bukkit-Counter
reset in der `rate([5m])`-Fenster → Junk-p99, siehe #771, 2026-09-27).

## 2) Wurzel-Hard-Werte (Live, 21.09. ~10:00)

- `vm-srv-k3s-13`: **99% Memory alloc**, bei nur 3% CPU → Memory-Druck, kein CPU-Problem.
- Zwei Stunden früher: 53% → 99%. Es wächst, Reserve unter Grenze.
- Top-Memory-Esser auf dem Node: immich-server (1.3Gi), Prometheus (1.1Gi), mealie, firefly.
- p99 API-Latenz 8.5s vs. 5s-Schwelle — das REL-012-Fenster, bevor der API-Server hängt.

## 3) Was NICHT die Ursache war (damit nicht wieder aufgespielt wird)

- **headscale-CP** läuft nicht im K3s-Cluster (Namespace existiert, CP ist 10.0.20.200 —
  lebt, HTTP 301, 35ms). „Server Not Found" im Browser = MagicDNS/Resolver-Pfad, nicht VM-down.
- Nur 1/2 CoreDNS-Repliken initial erreichbar (Netz-Wackeln auf dem Monitoring-Weg, kein
  CoreDNS-Crash).

## 4) Behandlung

1. RAM für `vm-srv-k3s-13` von 4Gi auf 8Gi (via Atlantis-Terraform-Apply).
2. Entlastung: Prometheus/immich mit Limits — falls sie auf k3s-13 mit greifbaren Limits
   liegen, Requests senken / Node-Affinity.
3. Verifikation nach Apply: `kubectl top nodes` → k3s-13 unter 80%; p99 API < 3s für 30min.

## 5) Status (2026-09-27)

- `kubectl top`: vm-srv-k3s-13 (7Gi allocatable) bei **36% Memory** — RAM-Bump war
  erfolgreich, Druck weg.
- Die vier PV-Füllungen (gotify/linkding/onlyoffice/myspeed) GALten eigenständig weiter,
  Stand im Repo als offen geführt (siehe `docs/HOMELAB-AUDIT.md` Known Gaps.
- Der p99-Artefakt-Mechanismus wurde am 27.09. nochmals bestätigt → #771 (Alert-`for`
  2m→10m) als harter Fix gemerged.
