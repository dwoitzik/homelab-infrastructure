# REL-075 — 2026-10-16: /tmp-Modus 0755 legte apt ~2 Monate lahm

> Stand: 2026-10-16, aus Live-Zustand (`stat`, `apt-get update`, `mount`,
> `systemctl status tmp.mount`), nicht nur aus Logs. Beim Rollout des
> Watchdog-Guards (ADR-058) aufgefallen, nicht durch einen Alarm.

## Symptom

`ansible-playbook` gegen `pve-mgmt-01` brach bereits beim ersten Task ab:

```text
Failed to update apt cache: unknown reason
```

## Ursache (live verifiziert)

`/tmp` war `drwxr-xr-x root:root` (0755) statt `drwxrwxrwt` (1777). apt prüft
Repository-Signaturen als Sandbox-User `_apt` (`APT::Sandbox::User`), und der
kann in ein 0755-`/tmp` keine temporäre Datei anlegen:

```text
Unable to mkstemp /tmp/apt.sig.<XXX> - GetTempFile (13: Permission denied)
```

Root selbst schreibt weiterhin — deshalb fiel es nirgends auf. `apt-get update`
lief formal durch, verwarf aber **jede** Signaturprüfung ("The repository is
not updated and the previous index files will be used"), d. h. jede
Aktualisierung/Installation über apt scheiterte ohne anderen Fehler als die
`W:`-Zeilen.

Der Mount ist tmpfs aus dem Stock-Unit `tmp.mount`
(`Options=mode=1777,strictatime,nosuid,nodev,size=50%,nr_inodes=1m`); `size`
und `nr_inodes` der laufenden Instanz stimmen mit dem Unit überein, `mode` und
`strictatime` fehlen in den effektiven Options jedoch. Der Mount ist seit
`2026-08-23 12:29:28 CEST` aktiv, der 0755-Zustand bestand also rund zwei
Monate. Auslöser nicht rekonstruierbar: weder im Repo noch auf dem Host findet
sich ein Skript/Cron/History-Eintrag, der `/tmp` chmod't; ein einmaliges
manuelles `chmod 0755` (oder ein `remount` ohne `mode=`) bleibt die
plausibelste Erklärung.

## Fix / Verifikation

- `chmod 1777 /tmp` live → `stat -c %A` zeigt `drwxrwxrwt`.
- `apt-get update`: Fetched 898 kB, **keine** Signaturfehler mehr.
- Persistenz: `tmp.mount` setzt `mode=1777` bei jedem Boot → ein Reboot stellt
  den korrekten Modus her; der Drift war Laufzeit, nicht Boot-Konfiguration.
- Erkennung: `pve-watchdog.sh` prüft jetzt `/tmp`-Modus != 1777 und meldet das
  über ntfy (gleiche Eskalation/Backoff wie die übrigen Host-Alarme).

## Restpunkte

- `apt` warnt weiterhin über doppelt konfigurierte PBS-Quellen
  (`/etc/apt/sources.list.d/pbs.list` und `pbs.sources` definieren beide
  `pbs-no-subscription`) — kosmetisch, separat zu bereinigen.
- Die Ursache des ursprünglichen chmod ist unbekannt: der Watchdog **erkennt**
  einen Wiederauftritt, **verhindert** ihn nicht.
