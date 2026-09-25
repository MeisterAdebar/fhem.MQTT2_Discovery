# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

# Baut eine Tasmota-Discovery mit frei waehlbarer Kanalzahl und -benennung.
sub announce {
	my (%args) = @_;
	my $relays = $args{rl} // [1, 1];
	my $friendly = $args{fn} // ['Entfeuchter', 'Luefter'];
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	FHEM::MQTT2_DISCOVERY::activate($hash);
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/config', sprintf(
		'{"dn":"Schwimmbad","fn":[%s],"mac":"AABBCCCF9A44","state":["OFF","ON"],'
			. '"t":"tasmota_CF9A44","ft":"%%prefix%%/%%topic%%/","tp":["cmnd","stat","tele"],'
			. '"rl":[%s],"so":{"4":0},"ver":1}',
		join(',', map { "\"$_\"" } @$friendly), join(',', @$relays),
	));
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/sensors',
		'{"sn":{"ENERGY":{"Power":42}},"ver":1}') if !$args{ohne_sensoren};
	return $hash;
}

sub devices {
	return [sort grep { ($main::defs{$_}{TYPE} // '') eq 'MQTT2_DEVICE' } keys %main::defs];
}

subtest 'ein Kanal bleibt ein Geraet' => sub {
	announce(rl => [1], fn => ['Wasser']);
	is(devices(), ['Schwimmbad_Wasser'], 'ohne zweiten Kanal wird nichts aufgeteilt');
	like(attr_value('Schwimmbad_Wasser', 'setList'), qr{^POWER:ON,OFF}m,
		'der einzige Kanal schaltet vom selben Geraet aus');
	like(attr_value('Schwimmbad_Wasser', 'readingList'), qr{tele/tasmota_CF9A44/SENSOR},
		'die Telemetrie liegt beim selben Geraet');
};

subtest 'zwei Kanaele ergeben zwei Geraete' => sub {
	announce();
	is(devices(), ['Schwimmbad_Entfeuchter', 'Schwimmbad_Luefter'],
		'ein Geraet je Kanal, benannt aus der Discovery');

	# Der erste Kanal ist das Geraet selbst: Er schaltet seinen Ausgang und
	# traegt alles, was zu keinem Kanal gehoert.
	my $erster = attr_value('Schwimmbad_Entfeuchter', 'readingList');
	like($erster, qr{tele/tasmota_CF9A44/SENSOR}, 'Telemetrie liegt beim ersten Kanal');
	like($erster, qr{tele/tasmota_CF9A44/LWT}, 'die Erreichbarkeit ebenso');
	like($erster, qr{^stat/tasmota_CF9A44/POWER1:}m, 'und er liest seinen eigenen Zustand');
	like($erster, qr/"POWER2" => ""/, 'den des zweiten Kanals verbirgt er');

	# Jeder Kanal schaltet genau seinen Ausgang und liest genau seinen Zustand.
	is(attr_value('Schwimmbad_Entfeuchter', 'setList'),
		'POWER1:ON,OFF cmnd/tasmota_CF9A44/POWER1', 'der erste Kanal schaltet POWER1');
	is(attr_value('Schwimmbad_Luefter', 'setList'),
		'POWER2:ON,OFF cmnd/tasmota_CF9A44/POWER2', 'der zweite schaltet POWER2');
	# Die Erreichbarkeit des Geraets gilt auch fuer seine weiteren Kanaele.
	like(attr_value('Schwimmbad_Luefter', 'readingList'),
		qr{tele/tasmota_CF9A44/LWT}, 'ein Kanalgeraet kennt seine Erreichbarkeit');
	unlike(attr_value('Schwimmbad_Luefter', 'readingList'),
		qr{/(?:RESULT|SENSOR|UPTIME|INFO)}, 'bekommt aber keine Sammelzeile des Geraets');
};

subtest 'ohne Kanalnamen zaehlt die Nummer' => sub {
	announce(fn => []);
	is(devices(), ['Schwimmbad_Switch_CF9A44', 'Schwimmbad_Switch_CF9A44_2'],
		'der erste Kanal ist das Geraet, die weiteren haengen ihre Nummer an');
};

subtest 'ein leerer Steckplatz verschiebt die Nummerierung nicht' => sub {
	announce(rl => [0, 1, 1], fn => ['', 'Zwei', 'Drei']);

	# Tasmota zaehlt die Kanaele nach ihrer Position in rl, nicht nach ihrer
	# Reihenfolge; ein leerer erster Steckplatz bleibt leer.
	is(devices(), ['Schwimmbad_Drei', 'Schwimmbad_Zwei'],
		'nur die belegten Steckplaetze werden zu Geraeten');
	is(attr_value('Schwimmbad_Zwei', 'setList'),
		'POWER2:ON,OFF cmnd/tasmota_CF9A44/POWER2', 'Kanal zwei behaelt seine Nummer');
};

subtest 'ein Sonoff Dual ohne Sensoren teilt genauso auf' => sub {

	# Der Fall, der lange fehlte: mehrere Kanaele, nur einer benannt, und kein
	# Sensor. Ohne Sensor gab es kein Entity ohne Kanal - die geraeteweite
	# Telemetrie landete deshalb im ersten Kanalgeraet, samt der POWER-Schluessel
	# der anderen Kanaele, und der benannte Kanal musste seinen Namen an das
	# Hauptgeraet abgeben.
	announce(rl => [1, 1], fn => ['Wasser'], ohne_sensoren => 1);
	is(devices(), ['Schwimmbad_Wasser', 'Schwimmbad_Wasser_2'],
		'der benannte erste Kanal ist das Geraet, der zweite haengt seine Nummer an');

	my $erster = attr_value('Schwimmbad_Wasser', 'readingList');
	like($erster, qr{tele/tasmota_CF9A44/SENSOR}, 'die Telemetrie liegt beim ersten Kanal');
	like($erster, qr/"POWER2" => ""/, 'er verbirgt den Zustand des zweiten');

	for my $kanal (['Schwimmbad_Wasser', 1, 'POWER2'], ['Schwimmbad_Wasser_2', 2, 'POWER1']) {
		my ($name, $nummer, $fremd) = @$kanal;
		my $liste = attr_value($name, 'readingList');
		is(attr_value($name, 'setList'), "POWER$nummer:ON,OFF cmnd/tasmota_CF9A44/POWER$nummer",
			"$name schaltet genau seinen Ausgang");
		like($liste, qr{^stat/tasmota_CF9A44/POWER$nummer:\.\* POWER$nummer$}m,
			"$name liest seinen eigenen Zustand");
		unlike($liste, qr/^stat\S+ POWER$fremd/m, "$name liest den Zustand des anderen nicht");
	}

	# Nur das Geraet selbst fuehrt die Sammelzeilen.
	unlike(attr_value('Schwimmbad_Wasser_2', 'readingList'), qr{/(?:RESULT|SENSOR|UPTIME|INFO)},
		'der zweite Kanal bekommt keine Sammelzeile');
};

subtest 'Rollladen und Schaltkanal zaehlen in derselben Nummerierung' => sub {

	# Ein Kanal ist eine Position in rl. Mit der Rollladennummer waeren ein
	# Lichtkanal 1 und ein Rollladen 1 derselbe Kanal, und ein Geraet aus beidem
	# wuerde nicht aufgeteilt.
	announce(rl => [1, 3, 3], fn => ['Licht', 'Jalousie', '']);
	is(devices(), ['Schwimmbad_Jalousie', 'Schwimmbad_Licht'],
		'Schalter und Rollladen werden zwei Geraete');
	like(attr_value('Schwimmbad_Licht', 'setList'), qr{^POWER1:ON,OFF}m,
		'der Schaltkanal ist das Geraet und schaltet seinen Ausgang');
	like(attr_value('Schwimmbad_Jalousie', 'setList'),
		qr{shutter_position:slider,0,1,100\s+cmnd/tasmota_CF9A44/ShutterPosition1},
		'der Rollladen bekommt sein eigenes Geraet');

	# Ein einzelner Rollladen ist der einzige Kanal und bleibt ein Geraet.
	announce(rl => [3, 3], fn => ['Jalousie', '']);
	is(devices(), ['Schwimmbad_Jalousie'], 'ein Rollladen allein wird nicht aufgeteilt');

	# Vier Haelften sind zwei Rollladen. Der Blick auf den Vorgaenger liess die
	# dritte Haelfte als "zweite" gelten; der zweite Rollladen entfiel ganz.
	announce(rl => [3, 3, 3, 3], fn => ['Vorn', '', 'Hinten', '']);
	is(devices(), ['Schwimmbad_Hinten', 'Schwimmbad_Vorn'], 'zwei Rollladen ergeben zwei Geraete');
	like(attr_value('Schwimmbad_Vorn', 'setList'), qr{cmnd/tasmota_CF9A44/ShutterPosition1},
		'der erste steuert Rollladen 1');
	like(attr_value('Schwimmbad_Hinten', 'setList'), qr{cmnd/tasmota_CF9A44/ShutterPosition2},
		'der zweite Rollladen 2');
};

done_testing();
