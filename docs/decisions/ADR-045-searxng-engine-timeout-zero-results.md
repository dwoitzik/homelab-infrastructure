# ADR-045: SearXNG rendered zero results because the engine timeout discarded them

- **Status:** Accepted and applied
- **Datum:** 2026-09-30
- **Bezieht sich auf:** ADR-041 (SearXNG-Egress-Fingerprint-Blocking), REL-033 (request_timeout-Cap)

## Problem

SearXNG lieferte eine gerenderte Ergebnisseite mit null Treffern. Kein Fehler, kein
Timeout-Fehlbild, nur eine leere Ergebnisliste. Der Dienst selbst war gesund: Ready,
`/stats/errors` zeigte keine fehlerhaften Engines, und direkte Backend-Abfragen lieferten
20 Treffer in 200-1000 ms.

Zwei getrennte Ausfälle lagen zeitlich nahe beieinander und wurden zuerst als einer
behandelt:

1. Ein Traefik-Replik hatte sein CrowdSec-Plugin nicht geladen (GitHub-Download beim
   Start fehlgeschlagen, `/plugins-storage/archives` leer). Traefik deaktivierte 38 von
   53 Routern, darunter `search.woitzik.dev`, und der Service verteilte 50/50 auf den intakten
   und den defekten Pod. Das erzeugte die 404er.
2. Nach dem Neustart des defekten Pods blieben leere Ergebnisseiten übrig. Das ist der
   hier dokumentierte Fehler.

## Messung

Traefik-Accesslog, die tatsächlichen Nutzer-Requests:

```text
09:22:32  /search?q=rthth    DownstreamStatus=200  Duration=2143ms
09:25:26  /search?q=wiso+steuer  DownstreamStatus=200  Duration=2020ms
```

Beide lagen exakt auf dem Cap von `outgoing.request_timeout: 2.0`. Korrespondierend im
SearXNG-Log:

```text
ERROR:searx.engines.google cse: engine timeout
ERROR:searx: call to ResultContainer.add_unresponsive_engine after ResultContainer.close
ERROR:searx: call to ResultContainer.add_timing after ResultContainer.close
```

Die Engine-Antwort kam nach Ablauf des Caps. In diesem Fall schließt SearXNG den
`ResultContainer`, bevor die Engine ihre Ergebnisse meldet; die nachfolgende Meldung
`add_unresponsive_engine after ResultContainer.close` ist der Beleg dafür. Bereits
gesammelte Treffer werden dabei verworfen.

Entscheidend: Der Fehler präsentiert sich als **leere Seite**, nicht als Fehlermeldung.
Ein Engine-Timeout ist damit nicht von "Dienst kaputt" unterscheidbar, was die
Fehlersuche deutlich verlängert hat.

Gegenprobe mit denselben Queries direkt gegen den Pod:

```text
wiso steuerung    -> 20 Treffer  524 / 251 / 1020 ms
rthth             -> 20 Treffer  318 / 364 /  202 ms
kubernetes        -> 20 Treffer  253 / 363 /  239 ms
proxmox backup    -> 20 Treffer 1027 / 342 /  250 ms
```

Die Antwortzeiten lagen mit 0,2-1,0 s überwiegend komfortabel unter 2,0 s, aber mit
Ausreißern bis 1027 ms. Das Cap hatte damit keinen Puffer: Ein unter 2,0 s liegender
Normalfall und ein darüber liegender Ausreißer trennen nur noch der Cap selbst.

## Ursache

ADR-041 hat brave, duckduckgo, startpage, bing, qwant, mojeek, yahoo und wikidata
deaktiviert. Übrig bleibt `google cse` als einzige General-Web-Engine. Das
2,0-s-Cap stammt aus REL-033, das die Worst-Case-Latenz über ~70 parallel angefragte
Engines begrenzen wollte.

Die Randbedingungen haben sich geändert: Es laufen nicht mehr ~70 aktive Engines, sondern
eine einzelne. Der Schutzzweck von REL-033 (Ausreißer eines Motors darf die Seite nicht
aufhalten) ist mit einer einzelnen Engine nahezu gegenstandslos, das Cap selbst wurde aber
nicht nachgezogen. Es stand damit exakt auf der realen Latenz der einen verbliebenen
Engine. Zusätzlicher Druck kam von außen: Der Host hatte in diesem Zeitraum
iowait-Spitzen bis 84 % (siehe ADR-044 und die NVMe-Analyse in der Load-Investigierung),
was die Antwortzeiten von `google cse` in den Cap-Bereich hob.

## Entscheidung

`outgoing.request_timeout` von 2.0 auf 4.0 und `max_request_timeout` von 4.0 auf 6.0
erhöht. Der Worst-Case-Bound aus REL-033 bleibt damit erhalten, aber mit Abstand zur
beobachteten Latenz.

Nicht geändert: die Engine-Auswahl. Dass nur `google cse` übrig ist, ist ein eigenes
Problem aus ADR-041 und wird hier nicht erneut aufgerollt.

## Alternativen erwogen

- **Nur `google cse` zeitlich entschärfen** (eigenes `timeout:` pro Engine) statt des
  globalen Caps. Sauberer, weil es den globalen Wert für die übrigen Engines unangetastet
  lässt. Zurückgestellt, weil SearXNG `use_default_settings: true` mit den sehr
  unterschiedlichen `engines:`-Einträgen in dieser Datei (deaktivierte Engines als
  explizite Listen) eine fehleranfällige Merge-Reihenfolge hat — die Konfiguration
  verhält sich dann nicht mehr wie eine einzelne Source of Truth.
- **Cap auf 3,0 s.** Reicht an den Rand, aber ohne Reserve gegenüber Ausreißern.

## Verifikation

Nach dem Merge: `request_timeout` in der laufenden ConfigMap, ConfigMap in der
laufenden Instanz, und dieselben Nutzer-Queries nochmals gegen den Pod, mit
Anschlagmessung über den LoadBalancer.
