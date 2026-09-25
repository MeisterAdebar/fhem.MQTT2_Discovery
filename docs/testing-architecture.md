# Testarchitektur

Die Produktionslogik ist in drei Schichten aufgeteilt:

1. Formatadapter normalisieren MQTT-Discovery-Nachrichten in das kanonische Modell.
2. Der Mapper erzeugt daraus deklarative Reading-, Set- und Semantic-Strukturen.
3. Das FHEM-Modul plant und uebergibt Seiteneffekte an ein Gateway.

## Isolierte Bausteine

- `MQTT2_Discovery::Parser::HomeAssistant` verarbeitet ausschliesslich
  Home-Assistant-MQTT-Discovery.
- `MQTT2_Discovery::Parser::Tasmota` verarbeitet ausschliesslich native
  Tasmota-Discovery-Nachrichten.
- `MQTT2_Discovery::Parser::Sonos2mqtt` verarbeitet ausschliesslich native
  Sonos2mqtt-Speaker-Discovery.
- `MQTT2_Discovery::Mapper::Common` normalisiert gemeinsam verwendete
  Auswahlwerte, Capability-Namen und numerische Metadaten.
- `MQTT2_Discovery::Mapper::NameResolver` loest kollidierende Entity-Namen auf.
- `MQTT2_Discovery::Mapper::Renderer` rendert deklarative Eintraege in FHEM-Attribute.
- `MQTT2_Discovery::Mapper::Semantics` erzeugt semantische Metadaten.
- `MQTT2_Discovery::DevicePlanner` berechnet Topic-, Konflikt- und Attributplaene
  ohne selbst FHEM zu veraendern.
- `MQTT2_Discovery::ActionPlan` beschreibt zusammengehoerige Aenderungen und rollt
  bereits ausgefuehrte Aktionen bei einem Fehler rueckwaerts zurueck.
- `MQTT2_Discovery::FHEMGateway` kapselt FHEM-Kommandos, Readings, Timer, Logs
  und die vom `MQTT2_DEVICE`-Autocreate gefuehrte CID-Zuordnung.

Formatadapter koennen ueber das Argument `adapters` von `FormatRegistry::consume`
injiziert werden. Fuer Modultests koennen ein Gateway ueber
`$hash->{helper}{gateway}` und Adapter ueber `$hash->{helper}{format_adapters}`
eingesetzt werden. Produktion verwendet jeweils die Standardimplementierungen.

## Teststufen

- `00` bis `46`: reine Unit- und Vertragstests ohne FHEM-Laufzeit. Ab `31`
  gehoert je ein Test zu einem abgeschlossenen Verhalten, etwa `42` zum
  Schluesselraum, `43` zu den Readingnamen der FHEM-Konvention, `44` zu den
  Geraetenamen, `45` zu `payloads` und `replayPayloads` und `46` zum Kanalsplit.
- `50` und `55`: Tests des FHEM-Moduls und seiner Queue gegen das lokale Gateway.
- `90`: Komponententests der vollstaendigen Verarbeitung mit simulierter FHEM-API.
- `95` bis `98`: Tests der Ablieferung und des Stils, also `controls`, `CHANGED`,
  der TortoiseGit-Hook und `perlcritic`.

Die Tests unter `90` sind keine Tests gegen eine reale FHEM-Installation. Die
beobachteten FHEM-Vertraege sind deshalb zusaetzlich in
`docs/verified-fhem-interfaces.md` dokumentiert.

## Paket und Ersatzmodule

Das FHEM-Modul liegt im Paket `FHEM::MQTT2_DISCOVERY` und bezieht die Symbole
des Hauptprogramms ueber `GPUtils::GP_Import`; die Einstiegspunkte werden mit
`GP_Export` nach `main::` zurueckgegeben. Die Tests laden dafuer das
Ersatzmodul `tests/lib/GPUtils.pm`, das beide Richtungen nachbildet, ohne eine
FHEM-Installation vorauszusetzen. `SetExtensions` wird bewusst nicht importiert,
sondern als `main::SetExtensions` gerufen, weil FHEM eine eigene Funktion
desselben Namens fuehrt.

`tests/98_perlcritic.t` prueft den Quelltext gegen `.perlcriticrc` auf Stufe 4.
Die dort vermerkten Ausnahmen sind bewusst gesetzt; insbesondere bleibt
`return undef` erhalten, weil ein leeres `return` in Argumentposition zu einer
leeren Liste zerfaellt und damit die Argumente der aufgerufenen Funktion
verschiebt.
