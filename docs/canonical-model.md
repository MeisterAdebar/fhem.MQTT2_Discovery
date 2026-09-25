# Kanonisches Discovery-Modell

`MQTT2_DISCOVERY` trennt Protokollerkennung, Normalisierung und FHEM-Abbildung.
Formatadapter duerfen keine fertigen `readingList`- oder `setList`-Zeilen
erzeugen. Sie liefern ausschliesslich Modellversion 1 an den gemeinsamen Mapper.

## Verarbeitung

```text
MQTT-Nachricht
  -> FormatRegistry
  -> Format::<Adapter>
  -> Model Version 1 + Validator
  -> Mapper
  -> FHEM-Renderer und atomare Anwendung
```

Die Registry prueft spezifische Formate zuerst. Sonos2mqtt und Tasmota stehen vor
dem allgemeinen Home-Assistant-Adapter. Ein Adapter kann eine Nachricht ablehnen
(`error`) oder als nicht
zustaendig kennzeichnen (`next`). Sobald ein Adapter ein Topic beansprucht hat,
gibt es nach einem Parserfehler keinen Fallback auf ein anderes Format.

## Modellstruktur

Jedes Event ist ein Hash mit diesen Pflichtfeldern:

```perl
{
  schema_version => 1,
  operation      => 'upsert',       # upsert, delete, delete_device

  source => {
    adapter => 'homeassistant',
    prefix  => 'homeassistant',
    topic   => 'homeassistant/sensor/node/temperature/config',
    key     => 'homeassistant/sensor/node/temperature/config|',
    layout  => 'entity',            # entity oder device
  },

  device => {
    identifiers   => ['node'],
    connections   => [],
    name          => 'Node',
    manufacturer  => 'Example',
    model         => 'TH-1',
    kind          => 'Switch',     # Art des Geraets aus dem Protokoll
    short_id      => '005301',     # unterscheidende Kennung
    friendly_name => 'Wasser',     # Name des einzigen benannten Kanals
  },

  entity => {
    id            => 'temperature',
    kind          => 'sensor',
    name          => 'Temperature',
    logical_name  => 'temperature',
    channel       => undef,        # Nummer des Kanals, falls mehrkanalig
    channel_name  => undef,        # Name dieses Kanals
    category      => undef,
    configuration => { ... },
  },

  signals      => [ ... ],
  commands     => [ ... ],
  availability => [
    {
      topic                 => 'node/availability',
      value_template        => '{{ value_json.state }}',
      payload_available     => 'online',
      payload_not_available => 'offline',
    },
  ],
  availability_mode => 'latest',
  extensions   => {},
}
```

`source` ist Herkunft und stabile Ownership. Der Mapper darf daraus keine
geraetespezifische Semantik erraten. `entity.configuration` enthaelt nur bereits
normalisierte, ausgeschriebene Domainfelder, die weder Signal noch Command sind.
Binding-Topics, Templates, Namen und Codecs stehen ausschliesslich in `signals`
beziehungsweise `commands`; Rohabkuerzungen eines Discovery-Protokolls gehoeren
nicht in diese Ebene.

`device.kind`, `device.short_id` und `device.friendly_name` bestimmen den
Geraetenamen. Der Formatadapter fuellt sie nach den Regeln seines Protokolls;
der Mapper setzt daraus Name, Art und Kennung zusammen oder, bei genau einem
benannten Kanal, Name und Kanalname. Die Zuordnung eines Eintrags zu einem Kanal
steht in `entity.channel` und `entity.channel_name`. Mehrkanalige Geraete werden
daraus in ein Hauptgeraet und je Kanal ein Geraet aufgeteilt; Eintraege ohne
Kanal bleiben beim Hauptgeraet.

`entity.name` bewahrt den ausdruecklichen Anzeigenamen des Quellprotokolls.
`entity.logical_name` ist dagegen ein optionaler, bereits vom Formatadapter nach
den Regeln dieses Protokolls bestimmter maschinenlesbarer Name. Beispielsweise
verwendet Home Assistant fuer einen namenlosen MQTT-Button dessen `device_class`
als Namen. Der gemeinsame Mapper wertet dafuer weder MQTT-Topics noch
Home-Assistant-Felder aus, sondern nutzt nur diesen kanonischen Wert.

## Availability

Availability ist eine eigene Rolle und kein normales State-Signal. Der
Formatadapter normalisiert jede Quelle auf Topic, optionales Template und ihre
beiden Vergleichspayloads. `availability_mode` beschreibt mit `all`, `any` oder
`latest`, wie mehrere Quellen zunaechst zur Availability ihrer jeweiligen Entity
verknuepft werden. Fasst ein `MQTT2_DEVICE` mehrere Entities zusammen, ist seine
sichtbare Availability online, sobald mindestens eine Entity verfuegbar ist. Sie
ist erst offline, wenn alle Entity-Regeln ausdruecklich offline melden, und sonst
unknown. Damit kann eine fehlende optionale Funktion nicht den Ausfall des
gesamten Devices vortaeuschen.

Der gemeinsame Mapper leitet daraus keine Namen aus Topicsegmenten ab. Die
einzelnen Quellzustaende und die Verknuepfungsregeln liegen in verborgenen
FHEM-Readings. Eine Quelle darf `role => 'lwt'` tragen; das setzt nur ein
nativer Adapter, denn bei Home-Assistant-Discovery steht die Art nicht im
Payload. Eine solche Quelle wird als sichtbares Reading `lwt` gefuehrt, weil sie
die Aussage des Geraets selbst ist. Das berechnete Reading heisst
`availability` und ist die verdichtete Sicht von FHEM einschliesslich der
eigenen Brokerverbindung. Welche der beiden sichtbar sind, steuert der
Schluessel `reachability` mit `full`, `sources` und `none`.

Der Verbindungszustand des am `MQTT2_DISCOVERY` gebundenen IODev bildet eine
zusaetzliche, protokollunabhaengige Bedingung. Bei getrennter Brokerverbindung
werden alle von dieser Instanz verwalteten Devices `offline`. Nach dem Reconnect
werden die erhaltenen Quell- und Regelzustaende erneut ausgewertet; ein Device
ohne eigene Availability-Quellen folgt direkt dem IODev-Zustand. Damit bildet
die Laufzeit dieselbe uebergeordnete Brokerbedingung wie Home Assistant ab. Ein
aus FHEM geloeschtes IODev gilt unabhaengig von einer noch vorhandenen
Perl-Referenz als offline; ausstehende Discovery-Arbeit wird dabei verworfen.

Technische Rollen duerfen ihren sichtbaren Readingnamen als reserviert
markieren. Kollidiert ein normales, explizit beschriebenes Signal damit,
qualifiziert der deviceweite Namensresolver dessen logischen Entity-Pfad. Frei
entpackte JSON-Felder erhalten stattdessen einen Namen wie
`state_availability`. Diese Regel wertet weder Topicpfade noch Hersteller oder
Discovery-Formate aus und beruecksichtigt auch ein vorhandenes FHEM-`jsonMap`.
Da jedes verwaltete Device diese IO-Bedingung besitzt, ist `availability` auch
ohne protokolleigene Availability-Quelle reserviert.

## Signals und Commands

Ein Signal beschreibt einen lesbaren MQTT-Kanal:

```perl
{
  id       => 'state',
  topic    => 'node/state',
  template => '{{ value_json.temperature }}',
}
```

Ein Command beschreibt einen schreibbaren Kanal getrennt davon:

```perl
{
  id       => 'command',
  topic    => 'node/command/temperature',
  template => '{{ value }}',
}
```

Falls ein Protokoll mehrere Werte in einem JSON-Payload zusammenfasst,
normalisiert bereits der Adapter das betreffende Command-Binding:

```perl
{
  id    => 'brightness',
  topic => 'node/light/set',
  name  => 'brightness',
  codec => {
    format     => 'json',
    key        => 'brightness',
    value_type => 'number',
    constants  => { command => 'brightness' },
  },
}
```

`constants` enthaelt optionale, validierte JSON-Felder neben dem dynamischen Wert.
Der Mapper unterscheidet damit nur zwischen skalaren und typisierten JSON-Commands.
Protokollregeln wie Home Assistants `schema=json` und dessen
Felder `state` oder `brightness` werden ausschliesslich im jeweiligen Adapter
ausgewertet und gelangen nicht als Mapper-Sonderfall hinter die Modellgrenze.

Templates werden weiterhin ausschliesslich durch den sicheren eingeschraenkten
Template-Compiler verarbeitet. Nicht unterstuetzte Ausdruecke erzeugen eine
Warnung oder verhindern die unsichere Teilabbildung.

Native Protokolle koennen zusaetzliche generische Signale liefern. Derzeit sind
`payload`, `template`, `json_flatten` und `json_sequence` definiert. `template`
beschreibt einen alternativen Transportkanal fuer denselben Readingnamen und
verwendet den vorhandenen sicheren Template-Compiler. Shelly nutzt dies fuer
Komponentenstatus und RPC-Statusmeldungen. Ein solches Template-Signal kann
zusaetzlich `items => { path => ['params', 'events'],
match => { component => 'bthomedevice:200' } }` deklarieren. Dann wird das
Template fuer jedes passende Objekt dieses JSON-Arrays ausgewertet; der letzte
vorhandene Wert pro Reading gewinnt. Fehlende Arraypfade oder Felder erzeugen
keine Reading-Aenderung. Der Mapper und die Runtime kennen dabei keine
Shelly-spezifischen Feldnamen. Dadurch kann der
Tasmota-Adapter seine vollstaendige Standard-Telemetrie beschreiben, ohne dass
das Modell oder der allgemeine Mapper Tasmota-Payloads oder Tasmota-Topicbasen
kennen muss.

Alle sicher abbildbaren Signals erreichen die FHEM-`readingList`, alle Commands
die `setList`. SemanticUI erhaelt davon nur die konservative Positivmenge. Ein
Signal muss deshalb nicht automatisch in SemanticUI erscheinen.

Ein `media_player` kann getrennte Signale fuer Transportstatus, Lautstaerke und
Mute sowie schreibbare Transportaktionen besitzen. Der Sonos2mqtt-Adapter nutzt
dabei das allgemeine JSON-Codec-Feld `constants`, um beispielsweise den
dynamischen Lautstaerkewert mit dem festen Feld `command=volume` zu einem
Payload zusammenzufuehren. Der Mapper kennt dadurch weder Sonos-Kommandonamen
noch Sonos-Topics.

## Neuer Formatadapter

Der Shelly-Adapter benoetigt neben eingehenden Nachrichten lesende MQTT-Abfragen.
Er liefert diese als `requests => [{ topic => ..., payload => ... }]`;
`after_apply` enthaelt Abfragen fuer Initialwerte, die erst nach erfolgreichem
Device-Apply gesendet werden. Das Gateway uebergibt sie ohne Retain an die
MQTT-WriteFn. Bei asynchroner Verarbeitung warten Initialabfragen bis zum Ende
des Batches. Adapter erzeugen dabei weiterhin keine FHEM-Attributzeilen.

Die Registry uebergibt `claims` den vorhandenen Adapterzustand ausschliesslich
zum Lesen. Native Shelly-Laufzeitmeldungen werden zur Erkennung beobachtet und
an nachfolgende MQTT-Parser weitergereicht; nur instanzeigene Antworten auf
Discovery-Abfragen werden konsumiert. Das gemeinsame `shellies/announce`-Topic
wird in der Queue zusaetzlich nach Geraete-ID getrennt.

Ein Adapter implementiert mindestens:

```perl
sub id;
sub claims;
sub consume;
```

`claims(topic => ..., prefixes => ...)` darf keinen Adapterzustand veraendern.
`consume(...)` darf mehrere Nachrichten im uebergebenen Adapterzustand sammeln
und liefert null oder mehr kanonische Events. Vor der Rueckgabe wird jedes Event
mit `MQTT2_Discovery::Model::validate()` validiert.

Protokollspezifisch bleiben insbesondere:

- Topic- und Payloadschema
- Versionspruefung
- Abkuerzungen und Rohfelder
- Zusammenfuehrung mehrerer Discovery-Nachrichten
- stabile Quell- und Entity-IDs
- Loesch- und Birth/Death-Semantik

Zentral bleiben Namenskollisionen, manuelle FHEM-Zeilen, Registry, atomare
Updates, FHEM-Rendering und Semantic-Positivlisten.
