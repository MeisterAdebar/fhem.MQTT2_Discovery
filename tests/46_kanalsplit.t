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
		'{"sn":{"ENERGY":{"Power":42}},"ver":1}');
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

subtest 'zwei Kanaele ergeben ein Haupt- und zwei Kanalgeraete' => sub {
	announce();
	is(devices(), ['Schwimmbad_Entfeuchter', 'Schwimmbad_Luefter', 'Schwimmbad_Switch_CF9A44'],
		'die Kanaele tragen ihre Namen aus der Discovery');

	# Das Hauptgeraet behaelt alles, was zu keinem Kanal gehoert.
	my $haupt = attr_value('Schwimmbad_Switch_CF9A44', 'readingList');
	like($haupt, qr{tele/tasmota_CF9A44/SENSOR}, 'Telemetrie liegt beim Hauptgeraet');
	like($haupt, qr{tele/tasmota_CF9A44/LWT}, 'die Erreichbarkeit ebenso');
	is(attr_value('Schwimmbad_Switch_CF9A44', 'setList'), undef, 'das Hauptgeraet schaltet nichts');
	unlike($haupt, qr{stat/tasmota_CF9A44/POWER\d}, 'die Kanalzustaende liegen nicht mehr dort');

	# Jeder Kanal schaltet genau seinen Ausgang und liest genau seinen Zustand.
	is(attr_value('Schwimmbad_Entfeuchter', 'setList'),
		'POWER1:ON,OFF cmnd/tasmota_CF9A44/POWER1', 'der erste Kanal schaltet POWER1');
	is(attr_value('Schwimmbad_Luefter', 'setList'),
		'POWER2:ON,OFF cmnd/tasmota_CF9A44/POWER2', 'der zweite schaltet POWER2');
	like(attr_value('Schwimmbad_Entfeuchter', 'readingList'),
		qr{^stat/tasmota_CF9A44/POWER1:\.\* POWER1$}m, 'und liest seinen eigenen Zustand');

	# Die Erreichbarkeit des Geraets gilt auch fuer seine Kanaele.
	like(attr_value('Schwimmbad_Entfeuchter', 'readingList'),
		qr{tele/tasmota_CF9A44/LWT}, 'ein Kanalgeraet kennt seine Erreichbarkeit');
};

subtest 'ohne Kanalnamen zaehlt die Nummer' => sub {
	announce(fn => []);
	is(devices(),
		['Schwimmbad_Switch_CF9A44', 'Schwimmbad_Switch_CF9A44_1', 'Schwimmbad_Switch_CF9A44_2'],
		'die Kanaele haengen ihre Nummer an den Geraetenamen');
};

subtest 'ein leerer Steckplatz verschiebt die Nummerierung nicht' => sub {
	announce(rl => [0, 1, 1], fn => ['', 'Zwei', 'Drei']);

	# Tasmota zaehlt die Kanaele nach ihrer Position in rl, nicht nach ihrer
	# Reihenfolge; ein leerer erster Steckplatz bleibt leer.
	is(devices(), ['Schwimmbad_Drei', 'Schwimmbad_Switch_CF9A44', 'Schwimmbad_Zwei'],
		'nur die belegten Steckplaetze werden zu Geraeten');
	is(attr_value('Schwimmbad_Zwei', 'setList'),
		'POWER2:ON,OFF cmnd/tasmota_CF9A44/POWER2', 'Kanal zwei behaelt seine Nummer');
};

done_testing();
