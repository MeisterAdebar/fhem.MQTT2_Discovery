# MQTT2_DISCOVERY

`MQTT2_DISCOVERY` verarbeitet Home-Assistant-MQTT-Discovery sowie die nativen
Discovery-Protokolle von Tasmota, Sonos2mqtt und Shelly Gen2+ in FHEM. Daraus erzeugt es
konservativ verwaltete `MQTT2_DEVICE`-Definitionen.

## Architektur und Discovery-Formate

Eingehende Konfigurationen werden zuerst durch eine geordnete Format-Registry
klassifiziert. Spezifische Adapter wie Sonos2mqtt und Tasmota stehen vor dem
allgemeinen Home-Assistant-Adapter. Ein Adapter, der ein Topic beansprucht, liefert entweder
ein gueltiges Ergebnis oder einen sichtbaren Fehler; fehlerhafte Nachrichten
fallen nicht versuchsweise auf ein anderes Format zurueck.

Jeder Adapter normalisiert sein Protokoll in das versionierte kanonische Modell
`mqtt2-discovery/1`. Es trennt Device-Identitaet, lesbare `signals`, schreibbare
`commands` und `availability`. Erst danach entscheidet der allgemeine Mapper,
was daraus am Zielgeraet entsteht: mit den Vorgaben wertet das Modul die
Nutzdaten selbst aus und bietet die Schaltbefehle selbst an, sodass am Geraet
weder `readingList` noch `setList` steht; ueber den Schluesselraum sind
stattdessen auch die Attributzeilen zu bekommen. Konservative Semantic-Metadaten
entstehen in beiden Faellen. Der Mapper kennt weder Home-Assistant-Kurzformen
noch native Tasmota- oder Sonos2mqtt-Discovery-Payloads. Das Modell und die Erweiterung um
weitere Adapter sind in [docs/canonical-model.md](docs/canonical-model.md) beschrieben.

Normale MQTT-State-Nachrichten werden nicht als Discovery beansprucht. Ein Topic
wie `zigbee2mqtt/wohnzimmer` erreicht weiterhin das passende `MQTT2_DEVICE`; nur
die zugehoerige Konfiguration unter `homeassistant/.../config` wird vom
Discovery-Modul verarbeitet (und gefiltert).

## Installation und Updates

Dieses Repository ist ein Fork von
[next81/fhem.MQTT2_Discovery](https://github.com/next81/fhem.MQTT2_Discovery).
Diese Fassung ist **nicht** als Updatequelle veroeffentlicht. Sie wird
installiert, indem `FHEM/10_MQTT2_DISCOVERY.pm` und `lib/FHEM/MQTT2_Discovery/`
in die FHEM-Installation kopiert werden; danach `shutdown restart`. Das Original
laesst sich ueber sein Controlfile installieren:

```text
update all https://raw.githubusercontent.com/next81/fhem.MQTT2_Discovery/main/controls_MQTT2_DISCOVERY.txt
shutdown restart
```

Danach wird das Discovery-Device angelegt und aktiviert:

```text
define mqttDiscovery MQTT2_DISCOVERY <mqttServer>
set mqttDiscovery activate
```

`<mqttServer>` ist hierbei das Device fuer die MQTT2-Schnittstelle
(`MQTT2_SERVER` oder `MQTT2_CLIENT`). `activate` ergaenzt
`MQTT2_DISCOVERY` in `clientOrder`, ohne andere Parser zu entfernen.

Damit regulaere FHEM-Updates das Original automatisch beruecksichtigen, wird es
einmalig als zusaetzliche Updatequelle registriert:

```text
update add https://raw.githubusercontent.com/next81/fhem.MQTT2_Discovery/main/controls_MQTT2_DISCOVERY.txt
```

Anschliessend zeigen `update check` bzw. `update` auch neue Versionen an. Nach
einem Modulupdate ist `shutdown restart` erforderlich. Ein solches Update holt
die Fassung des Originals und ueberschreibt damit die dieses Zweiges.

## Konfiguration

- `keys`: Einstellungen als `schluessel=wert`, durch Leerzeichen getrennt,
  optional mit vorangestellter Familie, siehe [Schluessel statt
  Einzelattribute](#schluessel-statt-einzelattribute)
- `discoveryPrefixes`: kommaseparierte Prefixe, Default
  `homeassistant,tasmota/discovery,sonos2mqtt`
- `shellyDiscovery`: native Shelly-Erkennung unabhaengig von `discoveryPrefixes`, Default `1`.
  Mit `0` werden keine neuen Shelly-Abfragen gestartet; bestehende Device-Bindings bleiben nutzbar.
- `deviceNamePrefix`: optionaler Prefix fuer neu angelegte Device-Namen. Ohne das
  Attribut wird nichts vorangestellt, beispielsweise entsteht der Name `Node`.
  Mit `attr mqttDiscovery deviceNamePrefix Tasmota_` wird daraus `Tasmota_Node`.
- `existingDevice`: `conservative`, `ignore` oder `replace`
- `extraJsonReadings`: `include` oder `ignore`, Default `include`; `include`
  entpackt auch nicht konkret angekuendigte JSON-Felder, `ignore` rendert nur
  die durch Discovery bekannten Felder
- `autoCreate`: `0` oder `1`, Default `1`
- `autoDelete`: `0` oder `1`, Default `0`
- `createReadings`: `0` oder `1`, Default `0`; bei `1` werden sicher aus
  Discovery ableitbare State-Readings sofort mit leerem Wert angelegt
- `disable`: `0` oder `1`, Default `0`; bei `1` werden Discovery-Nachrichten ohne Aenderungen konsumiert

Die Zielauflösung folgt dabei der Geräteidentität des FHEM-`MQTT2_DEVICE`-
Autocreate: Ein bereits unter derselben CID/`DEF` registriertes `MQTT2_DEVICE`
wird unabhängig von seinem aktuellen FHEM-Namen wiederverwendet. Damit bleiben
auch umbenannte Devices ihrem MQTT-Client zugeordnet. Vor der CID-Suche werden
vorhandene `bridgeRegexp`-Regeln gegen die von Discovery angekündigten
State-Topics ausgewertet; die daraus entstehende virtuelle CID wird wie beim
FHEM-Autocreate als `DEF` eines neuen Bridge-Unterdevices verwendet. Bereits
anderen Discovery-Identitäten zugeordnete Targets werden nicht erneut verwendet,
da eine Transport-CID bei einer Bridge mehrere logische Geräte vertreten kann.
Ein `MQTT2_CLIENT` kennt die Client-ID des urspruenglichen Publishers nicht.
Falls keine `bridgeRegexp` greift, erzeugt das Modul deshalb aus der stabilen
Discovery-Geraeteidentitaet eine lokale CID der Form
`mqtt2_discovery_<hash>`. Unterschiedliche Discovery-Devices teilen dadurch
nicht die gemeinsame Client-ID der Brokerverbindung. Bei `MQTT2_SERVER` bleibt
die vom Publisher empfangene CID unveraendert; eine fehlende CID erhaelt
denselben sicheren Fallback.

Eine Aenderung von `deviceNamePrefix` gilt fuer Devices, die danach erstmals
entdeckt und angelegt werden.


Mit `attr mqttDiscovery disable 1` kann das Modul bereits beim FHEM-Start kontrolliert
deaktiviert bleiben. Nach `deleteattr mqttDiscovery disable` verarbeitet es wieder neue
Discovery-Nachrichten. Retained Nachrichten eines `MQTT2_SERVER` koennen danach gezielt
mit `set mqttDiscovery rescan` verarbeitet werden.

`rescan` verarbeitet beim `MQTT2_SERVER` dessen lokalen Retain-Cache. `MQTT2_CLIENT` besitzt keinen entsprechenden Cache; dort muessen retained Discovery-Nachrichten durch Broker-Replay bzw. Reconnect eintreffen.

Mit `get mqttDiscovery devices` zeigt FHEMWEB alle aktuell vorhandenen
`MQTT2_DEVICE`-Devices am gebundenen IODev in einem Popup. Zwei alphabetisch
sortierte Tabellen trennen die von dieser Discovery-Instanz verwalteten Devices
von den nicht verwalteten. Auch uebernommene Bestandsdevices gelten als
verwaltet; veraltete Registry-Eintraege ohne vorhandenes Device werden nicht
angezeigt. Jeder Devicename fuehrt als Link direkt zur FHEMWEB-Detailansicht.

Mit `set mqttDiscovery rebuildDevice <MQTT2_DEVICE>` werden `devicetopic`,
`readingList` und `setList` eines bereits verwalteten Devices vollstaendig aus
dem gespeicherten Discovery-Stand neu erzeugt. `devicetopic` wird dabei auf den
tiefsten gemeinsamen segmentgenauen Topic-Stamm normalisiert und beide Listen
werden passend relativ dazu aufgebaut. Vorhandene manuelle Zeilen sowie ein
abweichendes `devicetopic` werden unabhaengig von `existingDevice` verworfen;
andere Attribute und bestehende Readingwerte bleiben unveraendert. Der Befehl
fordert keine neuen Nachrichten vom Broker an.

Der optionale Zusatz
`set mqttDiscovery rebuildDevice <MQTT2_DEVICE> clearReadings` entfernt erst
nach dem erfolgreichen Listen-Neuaufbau alle nicht versteckten Readings,
einschliesslich manueller Werte. Versteckte Readings mit fuehrendem Punkt bleiben
erhalten. Availability und durch `createReadings` ausgewaehlte Readings werden
danach neu initialisiert; alle anderen Werte erscheinen erst mit neuen
MQTT-Nachrichten wieder.

Fehler bleiben pro Discovery-Topic sichtbar, bis genau dieses Topic korrigiert
oder geloescht wird. `errorCount`, `lastError`, `lastErrorAdapter` und
`lastErrorTopic` zeigen abgelehnte Konfigurationen. Entsprechend dokumentieren
`warningCount`, `lastWarning`, `lastWarningAdapter` und `lastWarningTopic`
weiterhin bestehende Teilabbildungen. Eine erfolgreiche Nachricht eines anderen
Geraets verdeckt einen vorhandenen Fehler nicht.

## Schluessel statt Einzelattribute

Verhaltensschalter liegen nicht mehr je ein Attribut nebeneinander, sondern in
einem gemeinsamen Schluesselraum. Ein Schluessel wird von unten nach oben
gesucht:

1. am Zielgeraet im Attribut `mqttDiscoveryKeys`,
2. am Discovery-Device im Attribut `keys` fuer die Familie des Geraets,
3. am Discovery-Device im Attribut `keys` ohne Familie,
4. in der Vorgabe des Moduls.

Die Familie ist der Adapter, der das Geraet erkannt hat: `shelly`, `tasmota`,
`homeassistant` oder `sonos2mqtt`. Sie steht dem Schluessel mit Doppelpunkt
voran.

```
attr mqttDiscovery keys style=fhem shelly:sets=hook
set mqttDiscovery deviceKey Werkstatt sets=hook
```

Bekannte Schluessel:

| Schluessel | Werte | Vorgabe | Bedeutung |
| --- | --- | --- | --- |
| `style` | `raw`, `fhem` | `fhem` | Readingnamen roh aus der Discovery oder nach FHEM-Konvention |
| `sets` | `list`, `hook` | `hook` | Schaltbefehle als `setList`-Zeilen oder ueber die `SetExtensionsFn` |
| `readings` | `list`, `parse` | `parse` | Readings ueber `readingList`-Zeilen oder ueber die eigene Auswertung |
| `reachability` | `full`, `sources`, `none` | `sources` | verdichtetes Reading und Quellen, nur Quellen oder nichts davon |
| `forceNEXT` | `0`, `1` | `0` | Discovery-Nachricht zusaetzlich an weitere Module durchreichen |
| `hide` | Readingnamen, kommasepariert | leer | einzelne Readings nicht anlegen |

Mit `readings=parse` wertet das Modul die Nutzdaten selbst aus, statt sie ueber
`readingList`-Zeilen an `MQTT2_DEVICE` zu geben. Sein `Match` steht dann weit,
sodass jede Nachricht des IODev durch das Modul laeuft. Die gespeicherten Muster
werden deshalb nicht linear durchsucht, sondern ueber einen Index nach Topic
angesprochen; fremde Nachrichten kosten damit unter eine Mikrosekunde statt
einiger hundert.

Uebernommen werden beide Arten erzeugter Zeilen: die mit fester Feldliste ueber
ihre Laufzeitreferenz und die Sammelzeilen, die einen ganzen JSON-Payload
abflachen -- fuer sie liegen Namensraum und Umbenennungsliste strukturiert in
der Registry. Im Attribut bleibt nur, was mehr ist als beides, etwa Tasmotas
`INFO`-Zeile, die den Payload vor der Auswertung auspackt. Manuelle Zeilen des
Anwenders bleiben ohnehin unberuehrt.

Trifft eine Nachricht beide Arten, schreibt zuerst die Sammelzeile und danach
die Laufzeitreferenz. Die ausdruecklich angekuendigte Zuordnung setzt sich damit
gegen die rohe durch: `{"POWER":"ON"}` wird zu `state` mit `on`, nicht mit `ON`.

Ein leerer Wert nimmt einen Schluessel auf seiner Ebene zurueck, sodass wieder
die naechsthoehere gilt. `set <name> deviceKey <device> <schluessel>=<wert>`
schreibt die Geraeteebene und prueft dabei Schluessel und Wert; eine Familie ist
dort nicht erlaubt, weil die Familie des Geraets bereits feststeht.

Ein Geraet, das unter `style=fhem` entstanden ist, behaelt die
Konvention auch dann, wenn der Schluessel spaeter wieder entfaellt; sonst
kippten bestehende Readingwerte auf neue Namen.

## Erreichbarkeit: lwt und availability

Zwei verschiedene Aussagen, deshalb zwei Readings:

- `lwt` ist der beim Broker angemeldete letzte Wille des Geraets selbst. Er
  entsteht, sobald ein Adapter die Quelle als solche kennt, und traegt bei allen
  Adaptern denselben Namen.
- `availability` verdichtet alle Quellen eines Geraets und beruecksichtigt
  zusaetzlich, ob FHEM gerade eine Brokerverbindung hat. Bei Brokerverlust steht
  dort `offline`, waehrend der retained `lwt` weiter die letzte Aussage des
  Geraets zeigt. Es entsteht nur mit `reachability=full`.

Der einheitliche Name ist eine bewusste Entscheidung. Die Geraete selbst
benennen dasselbe voellig verschieden; an einem Broker mit sechzehn Clients
stehen fuer den letzten Willen sieben verschiedene Topic-Blaetter:

```
tele/tasmota_E768B3/LWT:Offline          shellies/shelly1-BA4327/online:false
wled/18b3c8/status:offline               sonos/connected:0
ebusd/global/running:false               inverter/mqtt:not connected
valetudo/<name>/$state:lost
```

Ein Reading nach dem Topic-Blatt zu benennen hiesse, diese Zufaelligkeit in die
Geraete zu tragen. Nicht jede Quelle ist ein letzter Wille: `zigbee2mqtt` meldet
den eigenen unter `zigbee2mqtt/bridge/state`, waehrend
`zigbee2mqtt/<geraet>/availability` eine Aussage der Bruecke ueber ein Geraet
ist. Die bleibt eine gewoehnliche Quelle und damit versteckt.

## Geraetenamen

Ohne eigenen Namen liefern die Protokolle nichts Unterscheidendes: Tasmota
meldet als Geraetenamen schlicht `Tasmota`, Shelly gar keinen. Der Name entsteht
deshalb aus drei Teilen:

- **Name, Art und Kennung** als Regelfall, etwa `Tasmota_Switch_005301` oder
  `Shelly_Switch_00005e005302`. Die Art kommt aus dem Protokoll (bei Tasmota aus
  den Relaytypen, dem Lichttyp und iFan, bei Shelly aus den konfigurierten
  Komponenten), die Kennung aus dem eigenen Topic und ersatzweise aus dem Ende
  der MAC.
- **Name und Kanalname**, wenn das Geraet genau einen benannten Kanal hat
  (`fn` bei Tasmota, der Komponentenname bei Shelly): `Tasmota_Wasser`.
- Ist der so entstandene Name bereits belegt, gilt wieder Name, Art und Kennung.

Ein selbst vergebener Geraetename ersetzt nur den Vorgabenamen des Herstellers
und bleibt sonst unangetastet; `deviceNamePrefix` wirkt zusaetzlich.

## Mehrkanalige Geraete

Meldet ein Geraet mehr als einen Kanal, entsteht je Kanal ein eigenes
`MQTT2_DEVICE`. Das Hauptgeraet behaelt, was zu keinem einzelnen Kanal gehoert,
also Telemetrie und Erreichbarkeit, und schaltet selbst nichts. Jedes
Kanalgeraet schaltet genau seinen Ausgang, liest genau seinen Zustand und kennt
die Erreichbarkeit des gemeinsamen Geraets.

Die Kanalnamen stammen aus der Discovery; fehlen sie, haengt der Kanal seine
Nummer an den Geraetenamen (`Schwimmbad_Switch_CF9A44_1`). Leere Steckplaetze
verschieben die Nummerierung nicht: Tasmota zaehlt nach der Position in `rl`,
ein unbelegter erster Steckplatz bleibt unbelegt.

## Payloads weitergeben

Wer bei einem Fehler helfen soll, braucht die Nachrichten, aus denen ein Geraet
entstanden ist. `get <name> payloads <device>` zeigt genau diese Nachrichten in
einem Fenster zum Kopieren; eine Datei entsteht dabei nicht.

Geheimnisse (Passwoerter, Tokens, Schluessel) stehen als `xxx`. Angaben zum Netz
des Anwenders werden nicht geschwaerzt, sondern durch unverfaengliche ersetzt,
damit die Nachricht auswertbar bleibt: Hostnamen werden zu `host`, SSIDs zu
`WLAN`, Adressen zu Beispieladressen aus RFC 5737 und RFC 3849.

Topics und Geraetekennungen bleiben unveraendert. Ersetzt man sie, beschreibt der
Block nicht mehr das Geraet, aus dem er stammt: Sein Zwilling sendet dann auf
einen Zweig, auf dem keine Hardware antwortet, und kann nie schalten. Weil die
Kennungen stehen bleiben, trifft der eigene Block dieselbe Identitaet wie das
Geraet selbst -- zweimal einspielen legt nichts Neues an, und ein gerade
fehlendes Geraet wird daraus wiederhergestellt, mit seiner eigenen Client-ID.

Ein Block aus einer fremden Anlage beschreibt Hardware, die es hier nicht gibt.
Sein Geraet sendet auf dem richtigen Befehlszweig, es antwortet nur niemand, und
sein `state` bleibt darum auf `set_<befehl>` stehen; das Geraet traegt einen
`comment`, der das sagt. Trifft sein Name den eines verwalteten Geraets, bekommt
der fremde den Ausweichnamen -- ein Name, den ein anderer Datensatz haelt, gilt
auch ohne sein Geraet als belegt.

`set <name> replayPayloads` spielt einen solchen Block wieder ein. Ohne Angabe
oeffnet FHEMWEB ein Eingabefeld, in das der Block eingefuegt wird; alternativ
nimmt der Befehl den Pfad einer selbst angelegten Datei. Beides erzeugt dieselben
Devices, als haetten die Nachrichten den Broker erreicht -- bei Shelly
einschliesslich der Antworten auf die eigenen Abfragen, ohne dass ein Geraet im
Netz vorhanden sein muss.

## Native Shelly-Discovery (Gen2, Gen3 und Gen4)

Das Modul erkennt Shelly-Geraete mit Originalfirmware direkt
ueber MQTT. Home Assistant und ein Discovery-Skript auf dem Shelly werden nicht
benoetigt. Der Shelly 1 Gen4 wird mit Relais, Schalteingang, Geraetetemperatur,
WLAN-Signalstaerke und Laufzeit abgebildet, soweit diese Komponenten Werte melden.

Am Shelly muessen MQTT und MQTT-RPC aktiviert sein. Fuer laufende Werte muss
mindestens **RPC status notifications over MQTT** (`rpc_ntf`) oder
**Generic status update over MQTT** (`status_ntf`) aktiviert sein. Fuer die
automatische Suche per `announce` wird zusaetzlich **MQTT Control** benoetigt.
Das Modul aendert keine dieser Shelly-Einstellungen selbst.

Beim Aktivieren, nach dem FHEM-Start und nach einer erneuten Brokerverbindung
fordert das Modul mit `announce` auf `shellies/command` die Geraeteinformationen
an. Native Online-Meldungen und noch unbekannte RPC-Ereignisse koennen die
Erkennung ebenfalls starten. Die Suche laesst sich manuell wiederholen:

```text
set mqttDiscovery discoverShelly
```

Ein individuelles Topic-Prefix kann direkt angegeben werden. Das funktioniert
auch bei deaktiviertem MQTT Control und fuer bereits verbundene Geraete, die
gerade keine Ereignisse senden:

```text
set mqttDiscovery discoverShelly shelly1g4-aabbccddeeff
set mqttDiscovery discoverShelly haus/werkstatt/licht
```

Der Adapter fragt `Shelly.GetDeviceInfo`, `Shelly.GetConfig` und `Shelly.GetStatus`
nacheinander ab. Erst ein vollstaendiger, validierter Antwortsatz wird in das
gemeinsame Modell uebernommen. Antworten sind pro Instanz, Geraet und Abfrage
getrennt; alte oder unpassende Request-IDs werden ignoriert. Nach dem Anwenden
der Device-Bindings folgt eine weitere Statusabfrage fuer die Initialwerte.
Die Abfragen und Schaltbefehle werden ohne MQTT-Retain gesendet.

Bei eingeschraenkten Broker-ACLs oder `MQTT2_CLIENT subscriptions` muessen
`shellies/announce`, die jeweiligen Shelly-Topics und
`mqtt2_discovery/<Discovery-Devicename>/shelly/#` empfangbar sein. Publishes auf
`shellies/command` und `<Shelly-Prefix>/rpc` muessen erlaubt sein.
Auch `ignoreRegexp` darf diese Nachrichten nicht ausfiltern.

Unterstuetzter Umfang:

- `switch:<id>`: ein oder mehrere Relais, beispielsweise `switch_0` mit
  `set <Shelly-Device> switch_0 on` beziehungsweise `off`.
- `input:<id>`: Schalteingaenge, vorhandene Analog-Prozentwerte und Zaehler.
- Gemeldete Relaismesswerte: Temperatur, Leistung, Spannung, Strom, Frequenz,
  bezogene und zurueckgespeiste Energie in Wh.
- Temperatur- und Feuchtesensoren, Batteriestand, WLAN-RSSI und Laufzeit,
  sofern als unterstuetzte Komponente im Snapshot vorhanden.
- Erreichbarkeit ueber `<prefix>/online` und die initiale Statusantwort.

- `cct:<id>`: CCT-Leuchten wie die Shelly Duo Bulb Gen3, mit Ein/Aus,
  Helligkeit von 0 bis 100 Prozent und Farbtemperatur in Kelvin. Beispielsweise:
  `set <Shelly-Device> cct_0 on`,
  `set <Shelly-Device> cct_0_brightness 50` und
  `set <Shelly-Device> cct_0_ct 4600`.
  Der erlaubte Kelvinbereich folgt `ct_range`; bei der Duo Bulb Gen3 gilt ohne
  Angabe der dokumentierte Standard 2700 bis 6500 K. Andere CCT-Geraete ohne
  verlaesslichen Bereich erhalten nur ein lesbares Farbtemperatur-Reading.
  Ungueltige Zahlen und Werte ausserhalb des Bereichs werden nicht gesendet.
- Bereits am Shelly gekoppelte `bthomedevice:<id>`- und
  `bthomesensor:<id>`-Komponenten: Sensorwerte, Batterie, Bluetooth-RSSI,
  Paketnummer und Zeitstempel, soweit vom Geraet geliefert. Die Readings gehoeren
  zum Shelly-Gateway, beispielsweise `bthomesensor_201` oder
  `bthomedevice_200_battery`. Sensorwerte behalten ihre native Darstellung;
  fuer unbekannte Sensorarten werden keine Einheiten oder Geraeteklassen geraten.
  Noch unbekannte Werte schlafender Sensoren verhindern ihre Einrichtung nicht.
- BLU-Ereignisse aus `NotifyEvent`: pro gekoppelter Komponente entstehen
  `..._event`, `..._idx`, `..._channel` und `..._ts`, sofern die Nachricht
  diese Felder enthaelt. Damit sind unter anderem Einfach-, Doppel- und
  Langdruck sowie Drehereignisse lesbar. Bei mehreren Ereignissen derselben
  Komponente in einer Nachricht enthalten die Readings den letzten passenden Wert.

Die BLU-Erkennung liest alle Seiten von `Shelly.GetComponents`, bevor sie einen
Snapshot anwendet. Fehlerhafte oder widerspruechliche Seiten ersetzen keine
bestehende Abbildung. Nach dem Anlernen oder Entfernen von BLU-Komponenten am
Shelly die Suche mit `set mqttDiscovery discoverShelly <mqtt-prefix>` wiederholen.
Das Modul koppelt keine Bluetooth-Geraete selbst und benoetigt keine Installation
eines Shelly-Skripts. Eigene MQTT-Formate beliebiger BLU-Skripte werden nicht
automatisch erkannt. Fuer Tasterereignisse muessen RPC-Statusmeldungen
(`rpc_ntf`) aktiviert sein; generische Komponentenstatusmeldungen allein reichen
dafuer nicht.

Bei bestehenden Devices erhaelt `existingDevice conservative` manuelle
`readingList`-Regeln, auch `json2nameValue($EVENT)`, sowie vorhandene Readingwerte
und `userReadings`. Fehlende Discovery-Eintraege koennen ergaenzt werden.
Ein manueller JSON-Sammelhandler hat fuer dasselbe Topic Vorrang; Discovery
meldet dabei die nicht uebernommenen Bindings als Konflikt. Mit
`existingDevice ignore` werden unverwaltete Bestandsdevices nicht uebernommen.
`rebuildDevice` funktioniert nur fuer bereits verwaltete Devices und ersetzt
auch manuelle Listenregeln. `clearReadings` loescht zusaetzlich sichtbare
BLU-Readings; sie kommen nur zurueck, wenn die neuen Regeln passende Nachrichten
auswerten. Die expliziten BLU-Bindings bleiben auch bei
`extraJsonReadings ignore` erhalten.

Relais- und Eingangszustaende werden als `true`/`false` gelesen; die semantische
Oberflaeche ordnet sie `on`/`off` zu. Komponentenstatus und RPC-Teilstatus lesen
dieselben Readings, ohne fehlende Werte anderer Komponenten zu ueberschreiben.
Komponenten bekommen stabile Namen wie `switch_0_temperature` oder `input_0`.

Protokollgrundlagen: [Shelly MQTT](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Mqtt/),
[RPC-Rahmen](https://shelly-api-docs.shelly.cloud/gen2/General/RPCProtocol/) und
[Komponentenabfragen](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Shelly/),
[CCT](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/CCT/),
[BTHomeDevice](https://shelly-api-docs.shelly.cloud/gen2/DynamicComponents/BTHome/BTHomeDevice/) und
[BTHomeSensor](https://shelly-api-docs.shelly.cloud/gen2/DynamicComponents/BTHome/BTHomeSensor/).
Die lokale Testabdeckung steht in `tests/28_shelly.t` und
`tests/29_shelly_cct_blu.t`; ein Hardwaretest ist darin
nicht enthalten.

## Home-Assistant Discovery

Der Home-Assistant-Adapter verarbeitet sowohl klassische Entity-Discovery unter
`homeassistant/<component>/[<node_id>/]<object_id>/config` als auch
Device-Discovery unter `homeassistant/device/<object_id>/config`. Unterstuetzte
Komponenten sind `sensor`, `binary_sensor`, `switch`, `button`, `number`,
`select`, `text`, `light`, `cover`, `fan`, `lock`, `climate`, `device_tracker`,
`event` und `device_automation`. Dabei werden sowohl ausgeschriebene
Konfigurationsfelder als auch die von Home Assistant definierten Kurzformen
erkannt.

Angekuendigte State-Topics werden als FHEM-Readings in die `readingList`
uebernommen, schreibbare Command-Topics mit ihren Wertebereichen und Optionen in
die `setList`. Mit `createReadings 1` legt das Modul sicher angekuendigte
Reading-Namen sofort mit leerem Wert an, ohne bereits vorhandene Werte zu
ueberschreiben. Die Darstellung des leeren Wertes bleibt FHEM ueberlassen. Frei
entpackte JSON-Felder und JSON-Sequenzen entstehen weiterhin erst mit den
entsprechenden Nutzdaten. Availability, Templates, Einheiten, Geraete- und Zustandsklassen
sowie weitere Komponenteneigenschaften fliessen in die Abbildung und die
Semantic-Metadaten ein. Zusammengehoerige Entities werden anhand der von
Discovery gelieferten Geraeteidentitaet einem gemeinsamen `MQTT2_DEVICE`
zugeordnet. Ein leerer retained Config-Payload entfernt die zuvor ueber dieses
Topic angekuendigte Entity beziehungsweise das gesamte Device aus der
Discovery-Verwaltung.

Das sichtbare Reading fuer die Erreichbarkeit (`lwt` oder `availability`, siehe
oben) verknuepft die angekuendigten Availability-Quellen mit dem Zustand des am `MQTT2_DISCOVERY` gebundenen IODev.
Verliert beispielsweise ein `MQTT2_CLIENT` seine Brokerverbindung, gehen alle
von dieser Discovery-Instanz verwalteten Devices offline. Nach dem Reconnect
werden die zuletzt bekannten Quellen erneut ausgewertet. Devices ohne eigene
Availability-Quelle folgen direkt dem IODev-Zustand. Ist eine angekuendigte
Quelle noch nie eingetroffen, bleibt das sichtbare Reading auf `unknown`. Fuer
jedes neu angewendete Availability-Topic an einem `MQTT2_CLIENT` wird genau ein
Timer angelegt, der nach 60 Sekunden nur dieses Retained-Topic abonniert. Der
normale MQTT-Datenstrom wird dabei weder gecacht noch von Discovery ausgewertet.
Ein gleichnamiges Nutzdatenfeld wird kollisionsfrei mit seinem qualifizierten
Entity-Namen angelegt. Wird das gebundene
`MQTT2_SERVER`- oder `MQTT2_CLIENT`-Device geloescht, verwirft Discovery zudem
seine ausstehende Queue, setzt alle verwalteten Ziele offline und wechselt selbst
auf `inactive`.

Gueltige MQTT-Wildcards in eingehenden HA-Topicfiltern werden unterstuetzt:
`+` steht fuer genau ein Topicsegment, ein abschliessendes `#` fuer beliebig
viele Untersegmente. Der sichere Template-Interpreter versteht ausserdem den
HA-Filter `is_defined`, die Existenztests `is defined`, `is not defined` und
`is undefined`, bedingte Ausdruecke mit optionalem `else` sowie flache
`if`/`elif`/`else`-Bloecke. Bei `device_automation` stehen die Triggerpfade
`trigger.value`, `trigger.value_json`, `trigger.payload` und
`trigger.payload_json` zur Verfuegung.

## Tasmota Discovery

Aktuelle Tasmota-Versionen senden standardmaessig keine klassischen
`homeassistant/.../config`-Nachrichten mehr. Stattdessen werden je Geraet die
beiden retained Topics `tasmota/discovery/<MAC>/config` und
`tasmota/discovery/<MAC>/sensors` veroeffentlicht. Home Assistant und Tasmota
Discovery sind gemeinsam mit Sonos2mqtt standardmaessig aktiv. Falls
`discoveryPrefixes` bereits abweichend gesetzt ist, laesst sich der aktuelle
Default so wiederherstellen:

```text
deleteattr mqttDiscovery discoveryPrefixes
set mqttDiscovery rescan
```

Der Adapter fuehrt beide Nachrichten anhand der MAC-Adresse zusammen. Unterstuetzt
werden Relais/Schalter, dimmbare und farbige Leuchten mit Farbtemperatur und
Effekten, Rolllaeden inklusive Position und Tilt, iFan-Geschwindigkeit, physische
Switches als Binary-Sensoren, Button-/Switch-Aktionen als Event-Readings sowie die
in der `sensors`-Nachricht enthaltenen skalaren Telemetriesensoren. Ein gemeldeter
Kamerastream wird als Warnung ausgewiesen, weil er kein MQTT-State/Command-Paar
fuer ein `MQTT2_DEVICE` darstellt.

Bei mehrkanaligen Tasmota-Messwerten werden Klasse und Einheit auch fuer einzelne
Arraykanaele uebernommen, beispielsweise `Power[0]` als `power` in `W`,
`ApparentPower[0]` als `apparent_power` in `VA`, `ReactivePower[0]` als
`reactive_power` in `var` und `Current[0]` als `current` in `A`. Der von Tasmota
zwischen `0` und `1` gelieferte Leistungsfaktor bleibt dimensionslos.

## Sonos2mqtt Discovery

Sonos2mqtt verwendet ein eigenes, retained Discovery-Format unter
`sonos2mqtt/discovery/<mqttPrefix>/<RINCON>`. Der Adapter normalisiert jeden
angekuendigten Speaker als kanonischen `media_player` und legt pro Sonos-Raum ein
`MQTT2_DEVICE` an.

Das Device liest `transportState`, `volume`, `mute` und die gemeinsame
Sonos2mqtt-Verfuegbarkeit. Es stellt die Sets `play`, `pause`, `stop`, `toggle`,
`next`, `previous`, `volume` und `mute` bereit. Beim Availability-Topic
`<mqttPrefix>/connected` gilt nur der Sonos2mqtt-Status `2` als online; `0` und
`1` bleiben offline, weil dabei keine verwendbare Verbindung zu den Speakern
besteht.

Live eintreffende Discovery-Konfigurationen werden ueber eine kurze interne Queue
in getrennten Topic- und Device-Schritten verarbeitet. Pro Timer-Tick wird hoechstens
ein Topic ausgewertet oder ein Zieldevice aktualisiert. Die Registry wird fuer einen
kompletten Schub nur einmal kopiert und persistiert. Dadurch blockiert ein Schub vieler
retained Topics FHEMs Event-Loop nicht fuer die Dauer des gesamten Schubs. Mehrere noch
nicht verarbeitete Nachrichten desselben Config-Topics werden auf den zuletzt
empfangenen Stand zusammengefasst.

## Lesbare Reading-Auswertung

Native Tasmota-JSON-State-Topics wie `RESULT` und `SENSOR` verwenden wie
MQTT2-Autocreate jeweils genau eine kurze Zeile
`{ json2nameValue($EVENT,'',$JSONMAP) }`. Dadurch entstehen die von FHEM
abgeflachten Reading-Namen unveraendert, beispielsweise `POWER`, `Dimmer` oder
`ENERGY_Power_1`, und ein vorhandenes geraeteweites `jsonMap` bleibt wirksam.
Discovery-IDs und Set-Namen bleiben davon getrennt; SemanticUI liest aus den
tatsaechlich erzeugten Rohreadings. Da jeweils der komplette Payload ausgewertet
wird, koennen auch weitere von Tasmota gesendete Felder als Readings erscheinen.

Einfache Home-Assistant-Templates wie `{{ value_json.ENERGY.Power[0] }}` werden
nicht als einzelne Runtime-Aufrufe gespeichert. Alle explizit angekuendigten
JSON-Pfade und komplexen Templates desselben State-Topics werden in einer einzigen
kompakten `MQTT2_DISCOVERY_runtimeRef()`-Zeile zusammengefasst. Dasselbe gilt fuer die
gleichwertige Jinja-Schreibweise mit literalem Schluessel, beispielsweise
`{{ value_json.get('battery') }}`. Die sichere Template-Engine liest dabei nur die
tatsaechlich angekuendigten Werte; weitere Felder desselben Payloads erzeugen keine
zusaetzlichen Readings. Enthalten umfangreiche JSON-Payloads selbst escapete
JSON-Beispiele, bleiben diese fuer nicht angekuendigte Felder unangetastet.

Verwendet Availability dasselbe MQTT-Topic wie ein fachliches Reading, liefert
dieselbe Runtime-Zeile beide Ergebnisse atomar. Damit reagiert jede erzeugte
`readingList` pro Funktionstopic nur einmal auf eine Nachricht.

Nur Adapter mit aktiviertem `json_autocreate`, insbesondere die nativen
Tasmota-State-Klassen, entpacken weiterhin bewusst alle Felder eines Payloads.
Topic-lokale Umbenennungen vermeiden Kollisionen zwischen gleichnamigen
JSON-Schluesseln verschiedener Topics. Komplexe Templates mit Filtern oder
Bedingungen verwenden weiterhin die sichere Template-Engine; das Template steht
dabei lesbar im Aufruf statt als Base64-Text. Auch komplexe `setList`-Fallbacks
enthalten Topics, Payloads, Command-Templates und Auswahl-Mappings als sicher
escapeten Klartext. Erzeugte `readingList`- und `setList`-Attribute verwenden
kein Base64.

Besitzt eine schreibbare Entity ein Zustandsreading, verwendet ihr Setter exakt
dessen endgueltigen FHEM-Namen. Das gilt protokollunabhaengig fuer Home-Assistant-
und Tasmota-Discovery einschliesslich Gross-/Kleinschreibung; beispielsweise wird
ein Reading `POWER1` auch mit `set <device> POWER1 ...` geschaltet.

Entity-Namen verwenden innerhalb eines Zieldevices den kuerzesten eindeutigen
Suffix ihres logischen Discovery-Pfads. Eine allein vorkommende Komponente
`sensor_battery` erzeugt deshalb `battery`. Erst bei gleichnamigen Komponenten
werden die kollidierenden Namen qualifiziert, beispielsweise `sensor_battery`
und `device_battery`. Die Regel gilt einheitlich fuer Readings, Setter und die
darauf verweisenden SemanticUI-Metadaten.

## Readingnamen nach FHEM-Konvention

Mit `style=fhem` folgen die Readingnamen den Namen, die FHEM fuer bekannte
Rollen vorsieht. Massgeblich ist das Wiki `DevelopmentGuidelinesReadings`.
Vier Dinge weichen dadurch vom rohen Discovery-Namen ab:

- Der Praefix der Komponente faellt weg, wenn die Komponente im Geraet nur
  einmal vorkommt: aus `thermostat_target_temperature` wird `desired-temp`, aus
  `switch_0_temperature` bei einem Relais `temperature`. Bei zwei Relais stellt
  die Namensaufloesung `switch_0_temperature` und `switch_1_temperature` wieder
  her.
- Bekannte Rollen tragen ihren FHEM-Namen: Sollwert `desired-temp`, Istwert
  `temperature`. Der zugehoerige Setter heisst ebenso.
- Die Batterie folgt den drei vorgesehenen Namen: `batteryPercent` fuer den
  Prozentwert, `batteryVoltage` fuer die Spannung, `batteryState` fuer die
  binaere Meldung.
- `batteryState` meldet `ok` und `low` statt `on` und `off`.

Umbenannt wird nur, wenn der Zielname im Geraet frei bleibt; zwei Readings
duerfen nicht auf denselben Namen fallen. Ohne den Schluessel bleibt alles so,
wie die Discovery es liefert.

## SemanticUI

Automatisch angelegte `MQTT2_DEVICE`-Devices erhalten direkt am Device strukturierte
`SEMANTIC_METADATA`. Klassen, Capabilities, Lese-/Schreibpfade, Wertebereiche,
Einheiten und Home-Assistant-`device_class`/`state_class` werden aus den Discovery-Daten
abgeleitet. Das Semantic-Modul erkennt diese Metadaten als externe Quelle mit hoher
Konfidenz; die Devices erscheinen dadurch ohne zusaetzliche Attribute automatisch in
SemanticUI. Ohne vorhandenes `room` bzw. `semanticRoom` werden sie unter
`Nicht zugeordnet` einsortiert. Manuell gesetzte Semantic-Attribute haben weiterhin
Vorrang.

Schaltzustaende bleiben dabei exakt so erhalten, wie sie im erzeugten FHEM-Device
stehen. Liefert `setList` beispielsweise `POWER1:ON,OFF`, enthalten auch die
Semantic-Metadaten `options: ["ON", "OFF"]`; es findet keine Umbenennung in
`on`/`off` statt. `activeValue` und `inactiveValue` kennzeichnen ausschliesslich die
Darstellung und veraendern weder Reading- noch Set-Werte.

`readingList` und `setList` bleiben von der Semantic-Auswahl vollstaendig getrennt:
Discovery bildet dort weiterhin alle sicher auswertbaren Topics und Befehle ab.
SemanticUI erhaelt dagegen bewusst nur eine konservative Teilmenge. Automatisch
sichtbar werden sicher abgebildete Setter sowie typische Read-only-Sensoren mit einer
expliziten, zugelassenen Home-Assistant-`device_class`, etwa Temperatur,
Luftfeuchtigkeit, Batterie, Leistung, Druck, Beleuchtungsstaerke oder relevante
Binaerzustaende. Unklassifizierte Werte und `entity_category=diagnostic` bleiben als
normale FHEM-Readings erhalten, erscheinen aber nicht automatisch in SemanticUI.
Manuelle Semantic-Attribute koennen diese Auswahl erweitern.

Die Semantic-Auswahl leitet keine Bedeutung aus Hersteller-, Topic- oder Entitynamen
ab. Bei genau einer ueber eine starke Geraeteidentitaet gruppierten Climate-Entity
werden schreibbare atomare Geschwister allgemein komponiert: `switch`, `select`,
`number`, `text` und `button` werden zu frei benannten Capabilities mit einer
expliziten Darstellungsart. Gibt es keine oder mehrere Climate-Hauptentities, bleiben
alle Entities getrennt. Dasselbe gilt fuer schwach zugeordnete sowie als `config` oder
`diagnostic` kategorisierte Geschwister. Ein bereits im Geraetenamen enthaltener
Praefix wird lediglich allgemein aus dem Anzeigenamen der Semantic-Entity entfernt.

Die Metadaten werden nur an Devices angebracht, die `MQTT2_DISCOVERY` selbst angelegt
hat. Im `replace`-Modus uebernommene Bestandsdevices bleiben davon unberuehrt.

Das Semantic-Modul beginnt die Integrationsmarkierung bei `DEFINED` automatisch. Wenn
es das optionale Fertig-Signal bereitstellt, meldet Discovery nach dem vollstaendigen
Anwenden von `devicetopic`, `readingList`, `setList` und `SEMANTIC_METADATA` den
Abschluss. SemanticUI kann die Lade-Karte dadurch sofort ausblenden; ohne Fertig-Signal
greift der automatisch verlaengerte Ruhe-Timer. Ohne Semantic-Modul bleibt der gesamte
Discovery-Ablauf unveraendert funktionsfaehig.

`device_automation`-Discoveries werden als eingehende, auf Topic und optionales
Payload gefilterte Readings abgebildet. Sie stellen Ereignisse des physischen
Geraets dar und werden deshalb nicht in SemanticUI angezeigt.
Bei MQTT-`number` gelten fuer fehlende Werte unabhaengig voneinander die
Home-Assistant-Defaults `min=0`, `max=100` und `step=1`.
MQTT-`text` kennzeichnet seine schreibbare Semantic-Capability als Texteingabe
und uebergibt eine vorhandene maximale Laenge an SemanticUI.
Das Home-Assistant-Feld `retain` (Kurzform `ret`) wird fuer ausgehende Befehle
uebernommen. Dadurch erreichen retained Sollwerte auch schlafende MQTT-Geraete wie
HomeButtons beim naechsten Aufwachen.

## TortoiseGit-Commits und CHANGED

Die repositoryweite [`.tgitconfig`](.tgitconfig) bindet
`tools/tortoisegit_pre_commit.pl` als TortoiseGit-Pre-Commit-Hook ein. TortoiseGit
haengt die Parameter `PATH`, `MESSAGEFILE` und `CWD` beim Aufruf automatisch an und
uebergibt dem Hook nach dem Klick auf **Commit** die endgueltige Nachricht. Der Hook
erzeugt daraus `CHANGED`, staged die Datei und laesst sie dadurch in denselben Commit
wie die ausgewaehlten Aenderungen eingehen. Jeder Versuch beginnt bei der in `HEAD`
gespeicherten `CHANGED`, sodass eine nach einem abgebrochenen Versuch geaenderte
Commit-Nachricht keinen veralteten Eintrag hinterlaesst.

TortoiseGit fragt beim ersten Verwenden der repositoryweiten Hook-Konfiguration aus
Sicherheitsgruenden nach einer Bestaetigung. Der Hook muss aktiviert und **Wait for
the script to finish** eingeschaltet bleiben. Die lokale Perl-Installation muss ueber
`perl` erreichbar sein. Technische Commits koennen die bestehende Markierung
`[skip-changed]` verwenden.

## Logging

Verbose:
- `1` - Verarbeitungs-, Parser- und Konfigurationsfehler
- `2` - Lifecycle, Warnungen sowie angelegte, uebernommene oder entfernte Devices
- `3` - allgemeiner Ablauf von Sets, Rescan und Discovery-Verarbeitung
- `4` - Diagnosewerte zu Nachrichten, Mapping, Entities und erzeugten Zeilen
- `5` - gekuerzte Discovery-Payloads; sensible Felder werden geschwaerzt


## Unittests

```text
cpanm --installdeps --with-develop .
prove -I tests/lib -lv tests
PERL5OPT=-Mwarnings=FATAL prove -I tests/lib -lv tests
```

Coverage kann lokal mit `Devel::Cover` erzeugt werden:

```text
cover -delete
PERL5OPT=-MDevel::Cover prove -I tests/lib tests
cover
```

Die Schichten, injizierbaren Abhaengigkeiten und Grenzen der simulierten
FHEM-Umgebung sind in [`docs/testing-architecture.md`](docs/testing-architecture.md)
beschrieben. Dieselben Tests laufen in der CI gegen mehrere Perl-Versionen.

Vor einer Veroeffentlichung muss das FHEM-Controlfile nach allen Aenderungen an
Produktionsmodulen neu erzeugt und anschliessend die Testsuite ausgefuehrt werden:

```text
perl tools/generate_controls.pl
PERL5OPT=-Mwarnings=FATAL prove -I tests/lib -lv tests
```


## Copyright

Copyright (C) 2026 Andreas Planer. Weitere Angaben zum Autor und Projekt stehen
in [`LICENSE.md`](LICENSE.md).
