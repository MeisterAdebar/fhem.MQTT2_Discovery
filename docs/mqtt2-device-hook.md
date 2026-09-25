# Set-Kommandos ohne setList: die Kette von SetExtensions

Seit `SetExtensions.pm` r31666 braucht es dafuer **keine Aenderung an
10_MQTT2_DEVICE.pm**. `SE_Next` ruft alle Funktionen auf, die als Liste unter
`$modules{<Zieltyp>}{SetExtensionsFn}` stehen; dieselbe Liste benutzt FHEM fuer
`AttrTemplate_Set`.

## Vertrag

```perl
my $ret = &{$fn}($hash, $list, $name, $cmd, @a);
return $ret if(!$ret || $ret !~ m/^Unknown argument $cmd, choose one of (.*)/);
$list = $1;
```

Ein Glied der Kette fuehrt aus, was ihm gehoert, und gibt sonst die um seine
eigenen Befehle ergaenzte Auswahl zurueck. Wer `SetExtensions` selbst aufruft,
baut eine Schleife.

## Zwei Fallen

**Der Befehl steht ungeschuetzt im Muster.** Bei der Abfrage `?` — genau der,
mit der FHEMWEB seine Auswahl aufbaut — trifft `m/^Unknown argument ?, choose
one of /` den eigenen Text nicht, weil `?` das vorangehende Zeichen optional
macht. Die Kette endet damit nach dem ersten Glied. Das Modul laesst den Befehl
in diesem Fall aus seiner Antwort weg, dann passt das Muster wieder.

**Wer hinten steht, kommt bei `?` nie zum Zug.** `SetExtensions` haengt
`AttrTemplate_Set` selbst an die Liste an. Zusammen mit der ersten Falle heisst
das: Ein spaeter eingereihtes Glied wird bei der Auswahlabfrage nie gefragt.
Das Modul reiht sich deshalb vorn ein und stellt die Reihenfolge bei jedem
Rendern wieder her.

## Registrierung

```perl
$module->{SetExtensionsFn} = [] if ref($module->{SetExtensionsFn}) ne 'ARRAY';
@{ $module->{SetExtensionsFn} } = grep { $_ ne $name } @{ $module->{SetExtensionsFn} };
unshift @{ $module->{SetExtensionsFn} }, $name;
```

Eingetragen wird nur in ein geladenes `MQTT2_DEVICE`: Ein Schreibzugriff auf
`$modules{<nicht geladenes Modul>}` erzeugt dort einen Eintrag ohne `Match` und
`ParseFn`, an dem FHEMs Dispatch stirbt. Ein `reload` des Zielmoduls setzt die
Liste zurueck, deshalb wird beim Start, beim Define und bei jedem Rendern
erneut eingereiht.
