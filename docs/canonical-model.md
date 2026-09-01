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
    identifiers  => ['node'],
    connections  => [],
    name         => 'Node',
    manufacturer => 'Example',
    model        => 'TH-1',
  },

  entity => {
    id            => 'temperature',
    kind          => 'sensor',
    name          => 'Temperature',
    logical_name  => 'temperature',
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
FHEM-Readings; sichtbar ist nur das berechnete Reading `availability`. Ein
Adapter darf ein Protokollsignal zusaetzlich als normales Reading beschreiben,
wenn dessen bestehende Oberflaeche erhalten bleiben soll. Tasmota nutzt dies
beispielsweise fuer das weiterhin sichtbare Reading `LWT`.

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
`payload`, `json_flatten` und `json_sequence` definiert. Dadurch kann der
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
