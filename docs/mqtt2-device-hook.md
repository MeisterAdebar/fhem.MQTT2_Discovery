# Set-Kommandos ohne setList: der Hook in 10_MQTT2_DEVICE.pm

Damit ein von MQTT2_DISCOVERY verwaltetes Geraet ohne `setList`-Attribut auskommt, muss
`MQTT2_DEVICE` beim Setzen eines unbekannten Befehls nachfragen. Die Idee stammt aus dem
FHEM-Forum, Thread 145198 "MQTT best current practice".

## Vorgeschlagene Fassung aus dem Forum

`10_MQTT2_DEVICE.pm`, in `MQTT2_DEVICE_Set`:

```perl
my $cmd = $sets->{$cmdName};
if(!$cmd) {
  return MQTT2_DISCOVERY_SetExtensions($hash, $cmdList, @a) if defined &MQTT2_DISCOVERY_SetExtensions;
  return SetExtensions($hash, $cmdList, @a);
}
```

Sie funktioniert, nennt aber ein Fremdmodul beim Namen.

## In FHEM uebliche Fassung

In FHEM traegt sich das Fremdmodul ein, der Kern kennt es nicht. Beispiele dafuer sind
`$data{FWEXT}{...}{FUNC}` bei FHEMWEB sowie `$modules{<Typ>}{FingerprintFn}`,
`{NotifyOrderPrefix}` und `{AttrFn}` in `fhem.pl`. Eine Pruefung der Art
`defined &main::Fremdfunktion` kommt in `fhem.pl` an keiner Stelle vor.

`10_MQTT2_DEVICE.pm`:

```perl
my $cmd = $sets->{$cmdName};
if(!$cmd) {
  my $fn = $modules{MQTT2_DEVICE}{SetExtensionsFn};
  return &{$fn}($hash, $cmdList, @a) if($fn);
  return SetExtensions($hash, $cmdList, @a);
}
```

Das Fremdmodul registriert sich einmal in seinem `Initialize`:

```perl
$data{MQTT2_DEVICE}{SetExtensionsFn} = 'MQTT2_DISCOVERY_SetExtensions';
```

Die Ablage erfolgt bewusst in `%data` und nicht in `%modules`. Ein Schreibzugriff auf
`$modules{<noch nicht geladenes Modul>}{...}` legt dort durch Autovivification einen Eintrag
**ohne** `Match` und `ParseFn` an. Steht dieser Modulname in `clientOrder` und ist er bereits
im zwischengespeicherten `.clientArray`, stirbt FHEM beim naechsten Dispatch:

```
PERL WARNING: Use of uninitialized value in regexp compilation at fhem.pl line 4195.
Can't use an undefined value as a subroutine reference at fhem.pl line 4203.
```

Genau diese beiden Zeilen liessen sich auf einem Testsystem gezielt erzeugen, indem ein leerer
Eintrag in `%modules` angelegt und der Modulname in `.clientArray` aufgenommen wurde; FHEM
beendete sich dabei. `computeClientArray` filtert solche Eintraege zwar heraus, der
zwischengespeicherte Array wird beim Setzen von `clientOrder` aber nicht neu berechnet.

Genau das macht dieser Zweig. Ohne die Ergaenzung in `10_MQTT2_DEVICE.pm` bleibt der Eintrag
wirkungslos, das Modul verhaelt sich dann unveraendert.

## Offene Punkte

- Ein einzelner Eintrag laesst nur einen Registranten zu. Bei mehreren braeuchte es eine Liste
  samt Reihenfolge, sonst gewinnt stillschweigend das zuletzt geladene Modul.
- Fuer `getList` gibt es kein Gegenstueck; Abfragen bleiben also weiterhin ein Attribut.
- Ohne den Hook hat ein Geraet mit `setsViaHook 1` gar keine Befehle mehr, denn in der
  `fhem.cfg` steht nichts. Ein FHEM-Update ueberschreibt `10_MQTT2_DEVICE.pm` und damit den
  Hook. Deshalb ist die Vorgabe des Attributs 0.
