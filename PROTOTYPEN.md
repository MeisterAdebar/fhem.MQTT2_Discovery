# Fork von fhem.MQTT2_Discovery: Befunde und Prototypen

Getestet mit dem Zweig `dev` (0.9.11) auf einem eigenen Test-FHEM (fhem.pl 31607) an einem
MQTT2_SERVER, Geraet ist ein Shelly 1 Mini Gen3 mit FW 2.0.0. `main` ist nicht betroffen, dort
gibt es den Shelly-Adapter noch nicht.

Jeder Zweig setzt einzeln auf `dev` auf, traegt seine vollstaendige Begruendung in der
Commit-Nachricht und ist fuer sich gruen, auch mit `PERL5OPT=-Mwarnings=FATAL`.

## Fehler

| Zweig | Inhalt |
|---|---|
| `fix/topic-conversion` | `<prefix>/status/switch:0` trifft nie, weil das IODev den Doppelpunkt zu `_` umwandelt |
| `fix/orphan-record` | Ein von Hand geloeschtes Zieldevice blockiert die Erkennung dauerhaft |
| `fix/reload-prototype` | `reload` bricht ab, weil ein aufgeloestes Array am Prototyp als ein Argument zaehlt |
| `fix/devicetopic` | Das eigene Antworttopic loest den gemeinsamen Geraetestamm auf, es entsteht kein `devicetopic` |

## Verbesserungen und Vorschlaege

| Zweig | Inhalt |
|---|---|
| `feat/active-signals` | Zeilen nur fuer die am Geraet aktiven Meldewege (`rpc_ntf`, `status_ntf`) |
| `feat/fhem-conventions` | Attribut `fhemConventions`: `state`, `on`/`off` und Wertabbildung bei einem Kanal |
| `feat/select-readings` | `lwt` als eigene Rolle, `availabilityReading none`, Auswahl der Readings per Dialog |
| `feat/sets-via-hook` | Attribut `setsViaHook`: Set-Kommandos aus der Registry statt aus dem Attribut |

## Zum Forum

`feat/sets-via-hook` gehoert zum Thread 145198 "MQTT best current practice". Die dafuer noetige
Ergaenzung in `10_MQTT2_DEVICE.pm` und der Unterschied zwischen einem fest verdrahteten
Funktionsnamen und einer Registrierung stehen in
[docs/mqtt2-device-hook.md](docs/mqtt2-device-hook.md) auf diesem Zweig.

Dort steht auch, wie sich die im Thread gemeldeten harten Abstuerze beim `reload` erzeugen
lassen: Ein Eintrag in `%modules` ohne `Match` und `ParseFn`, entstanden durch einen
Schreibzugriff auf ein noch nicht geladenes Modul, beendet FHEM beim naechsten Dispatch.

## Stand

Nichts davon ist mit dem Autor abgestimmt. Die Zweige sind als Diskussionsgrundlage gedacht,
nicht als fertige Pull Requests.
