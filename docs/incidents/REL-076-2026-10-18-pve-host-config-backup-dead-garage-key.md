# REL-076 — 2026-10-18: pve-host-config-Garage-Backup lief nie erfolgreich

> Stand: 2026-10-18, aus Live-Zustand (Garage-Key-Liste, Bucket-Inhalt,
> `journalctl`, rclone exit code), nicht nur aus Logs. Beim Untersuchen des
> rclone-Konfig-Drift zwischen der `pbs`-Rolle und dem Host aufgefallen, nicht
> durch einen Alarm — es gibt keinen.

## Symptom

`pve-config-backup.service` schlug bei jedem Lauf fehl:

```text
pve-host-config backup FAILED (rclone exit 1)
status code: 403, ... No such key: GKa5404e9…
```

Der Ziel-Bucket `pve-host-config` in Garage war **leer** — der Proxmox-Host
wurde also seit Einführung des Jobs am 2026-08-21 zu keinem Zeitpunkt
tatsächlich gesichert (`/etc/pve`, Netzwerk-, fstab-Konfig).

## Ursache (live verifiziert)

`ansible/group_vars/all/vault.yml` (`vault_pve_host_backup_garage_key_id`) hielt
den Zugriffsschlüssel `GKa5404e9…`. Dieser Schlüssel existiert in
Garage nicht (mehr) — `garage key list` kennt ihn nicht:

```text
GK3d0b90dc9f95e1d693e35306  velero
GKad2eb021ebe38db4e52407eb  cnpg-backups-key
GKac8df491375eb4f51643c7cc  loki
GK102614d2a19457b6492e8ac3  pve-host-backup     ← der gültige Schlüssel
GKcf3752deb29c176a0461598b  atlantis
```

Der gültige Schlüssel `GK102614d2a19457b6492e8ac3` (Name `pve-host-backup`,
RW auf Bucket `pve-host-config`, angelegt 2026-08-21) war nie im Vault
hinterlegt. Die Rolle rendert `rclone.conf` aus dem Vault-Wert, deployte also
wiederholt den toten Schlüssel — die Fehlkonfiguration war reproduzierbar, nicht
einmalig.

## Fix

`vault_pve_host_backup_garage_key_id`/`_secret` auf den gültigen Schlüssel
korrigiert, `pve_host_backup`-Rolle erneut auf `pve-mgmt-01` ausgerollt
(`changed=1`, nur `rclone.conf`), Dienst manuell gestartet:

```text
pve-host-config backup OK: pve-host-config-20261018T151409Z.tar.gz
```

Objekt liegt im Bucket (`rclone lsf garage:pve-host-config/`).

## Offen

- Kein Alerting auf den Fehlschlag: `pve-config-backup.service` hat weder
  `OnFailure=` noch einen Healthchecks-Ping (der PBS→Drive-Script hatte einen).
  Ein monatelanger, stiller Ausfall war die Folge. → separater Fix.
