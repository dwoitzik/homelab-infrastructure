# REL-077 — 2026-10-20: `daily-offsite` hing einen Volume-Upload 4 Stunden

> Stand: 2026-10-20, aus Live-Zustand (Velero-Backups, PodVolumeBackups,
> node-agent-Pods, R2-Repo-Status, Backup-Logfile aus dem Object Store), nicht
> nur aus Logs. Durch Lesen von `kubectl get backups` aufgefallen, nicht durch
> einen Alarm — es gibt keinen.

## Symptom

`daily-offsite` (Velero → Cloudflare R2) meldete `PartiallyFailed`, 1 Error,
9 Warnings. Der Lauf lief von 04:00:52 bis 08:00:58 — **4 Stunden**, wo die
beiden Nächte davor 8 bzw. 13 Minuten brauchten. Das Backup-Logfile (über einen
`DownloadRequest` aus dem Object Store geholt) zeigte die Fehlerzeile:

```text
timed out waiting for all PodVolumeBackups to complete
```

Ein einzelnes `PodVolumeBackup` — `daily-offsite-20261020040052-llktt`, Pod
`mealie-d8fc999cc-xdlwx`, Volume `tmp` (emptyDir), Node `vm-srv-k3s-13` — stand
ab 04:03:08 auf `InProgress` und blieb es 4 Stunden, bis das
`itemOperationTimeout: 4h0m0s` des Backups griff. Alle anderen 1507
`PodVolumeBackup`s waren `Completed`.

## Kein Fehler an dem, was hätte fehlschlagen können (live verifiziert)

- **Nicht das Pod oder die Daten.** `mealie`s `/tmp` war leer (4.0K) — es gab
  nichts hochzuladen.
- **Nicht der Node oder die tägliche Sicherung.** `daily-backup` (Lokal-Leg,
  Garage, derselbe Node, dasselbe Pod, eine Stunde später) lief um 08:06
  sauber durch, inklusive eines `mealie`-Volumes.
- **Nicht der Backend.** Beide `BackupStorageLocation`s meldeten `Available`.
- **Nicht das Pod initiierend.** Kein OOM, kein Timeout auf Pod-Ebene.

Der einzige Unterschied zwischen dem hängenden Item und dem gesunden: das
**Storage Location**. Der gestallte Upload ging nach `r2-offsite`, der
funktionierende nach `default` (Lokal). Der Uploader hielt den kopia-Datenpfad
gegen R2 vier Stunden offen, ohne dass noch ein Prozess dafür arbeitete.

## Ursache

Zwei Velero-Defaults von je 4 Stunden waren hier nicht gesetzt, also
geerbt:

- `--fs-backup-timeout` (Datei-System-Backup-Budget pro Volume) — 4h
- `--default-item-operation-timeout` (Wartezeit des Backups auf async-Items) — 4h

Ein hängender Uploader kostete damit das volle Fenster, und das verwaiste
`PodVolumeBackup`-Objekt blieb nach dem bereits als fehlgeschlagen markierten
Backup auf `InProgress` stehen — ein Zombie, den der nächste Lauf im Weg hat.

Beitragender Faktor: alle drei node-agent-Pods restarteten cluster-weit am
2026-10-19 17:11 UTC (Exit 255, `Unknown` — ein k3s/containerd-Ereignis) und
erneut ~17 Stunden später. Ein node-agent-Restart mitten im Upload verwaisen
lässt in-flight kopia-Arbeit; dieser Lauf erzeugte danach einen frischen
Uploader, der gegen das R2-Repo keinen Fortschritt mehr machte.

## Fix

1. **Fail-fast-Timeout** in `kubernetes/system/velero/application.yml`
   (ADR-067): `--fs-backup-timeout=45m` und
   `--default-item-operation-timeout=45m`.
2. **Zombie-PVB entfernt:** `daily-offsite-20261020040052-llktt` gelöscht
   (reine Status-Ressource, kein Owner, kein laufender Prozess, keine Daten
   berührt).

## Offen

- **kopia-Index-Blob-Degradation** der `r2-offsite`-Repos ("Found too many
  index blobs"). Plausibler Grund für ein langsames Repo-Öffnen, aber die
  Evidenz ist hier nur indirekt (Pod, Daten und Lokal-Leg waren gesund).
  Braucht Messung von Index-Blob-Anzahl und NVMe-Last, bevor die
  `--default-repo-maintain-frequency=24h` (REL-044-Trade) angefasst wird. →
  Folge-Fix, siehe ADR-067 "Open".
- **Kein Alerting auf `PartiallyFailed`/hängende Offsite-Läufe.** Gefunden
  durch Lesen von `kubectl get backups`, nicht durch einen Alarm. → Folge-Fix.
