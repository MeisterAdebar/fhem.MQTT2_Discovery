# Verifizierte FHEM-Schnittstellen

Geprueft wurde am 18.08.2026 der taeglich aktualisierte Read-only-Mirror `fhem/fhem-mirror` des offiziellen FHEM-SVN.

- `MQTT2_SERVER` und `MQTT2_CLIENT` setzen `ClientsKeepOrder`, `Clients` und `MatchList`. Das Attribut `clientOrder` ersetzt diese geordnete Liste und invalidiert `.clientArray`.
- Beide IO-Module dispatchen `autocreate=<mode>\0<client-id>\0<topic>\0<payload`.
- `ignoreRegexp` wird vor `Dispatch()` gegen `topic:payload` ausgewertet. Passende Discovery-Nachrichten koennen das Discovery-Modul daher nicht erreichen.
- `Dispatch()` ruft Parser in der berechneten Reihenfolge auf. `[NEXT]` setzt die Kette fort. Eine leere Liste setzt die Kette ebenfalls fort; ein einzelner definierter Leerstring stoppt sie ohne Device-Ereignis. `MQTT2_DISCOVERY` konsumiert deshalb mit `return ""`.
- `computeClientArray()` behaelt bei `ClientsKeepOrder` die Reihenfolge aus `Clients` bei und nimmt nur geladene Module mit `Match` auf.
- `MQTT2_DEVICE_Parse` zerlegt den MQTT-Dispatch mit `split("\0", ..., 3)`, sodass Nullzeichen oder Trennzeichen im Payload nicht unabsichtlich weiter zerlegt werden.
- `MQTT2_DEVICE_Parse` gleicht `readingList`-Ausdruecke sowohl gegen `topic:payload` als auch gegen `client-id:topic:payload` ab. Die von `MQTT2_DISCOVERY` erzeugten Zeilen verwenden deshalb nur das innerhalb des IODev eindeutige Topic und bleiben von Aenderungen der Client-ID unabhaengig.
- `MQTT2_SERVER` pflegt den Retain-Cache nur bei gesetztem Retain-Flag und aktivem `respectRetain`. `MQTT2_CLIENT` abonniert nach Connect standardmaessig `#`, besitzt aber keinen gleichwertigen lokalen Retain-Cache.
- `readingList` besteht aus Zeilen `regexp reading` oder `regexp {perl-expression}`. `setList` besteht aus `command[:widget] publish-expression`; Perl-Ausdruecke werden vor dem Publish ausgewertet. Endet das Publish-Topic auf `:r`, entfernt `MQTT2_DEVICE` diesen Zusatz und setzt beim Senden das MQTT-Retain-Flag.
- `MQTT2_DEVICE` ersetzt `$JSONMAP` in einer `readingList`-Expression durch den aus dem Attribut `jsonMap` aufgebauten Hash. `json2nameValue()` akzeptiert alternativ auch einen Hash direkt als drittes Argument; dies erlaubt topic-lokale Zuordnungen ohne Kollisionen zwischen gleichnamigen JSON-Schluesseln verschiedener Topics. Nicht im Hash enthaltene Schluessel behalten ihren Namen, sodass nur echte Umbenennungen angegeben werden muessen. Ohne Umbenennung reicht `json2nameValue($EVENT)`. Ohne optionalen Filter liefert die Funktion alle im JSON-Payload enthaltenen Felder als Readings.
- `json2nameValue()` verbindet verschachtelte Objektschluessel mit Unterstrichen und nummeriert JSON-Arrays ab `1`. Ein Template-Pfad `ENERGY.Power[0]` entspricht deshalb dem Rohreading `ENERGY_Power_1`.

Diese Beobachtungen sind in `tests/90_integration.t` als lokale Vertragstests festgeschrieben. FHEM-Kernmodule werden von diesem Projekt weder kopiert noch veraendert.

Ergaenzend am 08.09.2026 fuer native Shelly-Abfragen geprueft:

- Beide MQTT-IODev-WriteFn akzeptieren `($iodev, 'publish', '<topic> <payload>')`.
  Der Gateway verwendet dafuer `CallFn($iodev->{NAME}, 'WriteFn', ...)` und keinen
  FHEM-Kommandostring. Ohne `:r` am Topic wird kein Retain angefordert.
- Der lokale Vertragstest in `tests/28_shelly.t` prueft die Argumente der
  Gateway-Grenze und simuliert Antworten ueber beide MQTT-Dispatchpfade.

Ergaenzend am 22.09.2026 an einer laufenden FHEM-Installation geprueft:

- `CommandReload` ruft `<Modul>_Initialize` mit einem **neuen** Modulhash auf und
  setzt `$modules{<Typ>}` erst danach darauf. Wer in `Initialize` nach
  `$modules{<Typ>}{...}` schreibt statt nach `$hash->{...}`, schreibt ins alte,
  gleich verworfene Hash. Uebernommen werden nur `defptr` und `ldata`. Ein
  Modul, das seinen `Match` zur Laufzeit weitet, hat ihn nach einem `reload`
  deshalb wieder eng, waehrend die Instanzen ueber `defptr` weiterleben.
- Waehrend einer `ParseFn` setzt `fhem.pl` `$readingsUpdateDelayTrigger`, sodass
  `readingsEndUpdate($hash, 1)` an einem fremden Geraet kein Ereignis erzeugt:
  kein Longpoll in FHEMWEB, keine Notifies, keine Logs. `Dispatch()` holt den
  Trigger danach nur fuer die Geraete nach, deren Namen die `ParseFn`
  zurueckgibt. Die Marke `[NEXT]` darf diese Namen mitfuehren; `fhem.pl` nimmt
  sie nach dem `shift` in die Fundliste auf. `MQTT2_DISCOVERY` gibt deshalb
  `('[NEXT]', @geschriebene_devices)` zurueck, wenn es aus der `ParseFn` heraus
  Readings an verwalteten Geraeten schreibt.
- `MQTT2_SERVER` besitzt keine `GetFn`; seine Sets sind `publish`, `reopen` und
  `clearRetain`. Ein Zugriff auf gesehene Nachrichten ist von aussen nur ueber
  den Retain-Cache moeglich, und den fuellt der Server nur bei aktivem
  `respectRetain` (ab Featurelevel 6.1 nicht mehr Vorgabe) und nur fuer
  Nachrichten mit Retain-Flag.

Quellen: [MQTT2_CLIENT](https://raw.githubusercontent.com/fhem/fhem-mirror/master/fhem/FHEM/00_MQTT2_CLIENT.pm)
und [MQTT2_SERVER](https://raw.githubusercontent.com/fhem/fhem-mirror/master/fhem/FHEM/00_MQTT2_SERVER.pm).
