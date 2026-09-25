# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $target = 'Sensor';

sub setup {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	main::MQTT2_DISCOVERY_activate($hash);
	return $hash;
}

# Meldet eine HA-Entity unter ihrem Config-Topic an.
sub announce {
	my ($component, $object, $payload) = @_;
	dispatch_message('mqtt', 'client1',
		"homeassistant/$component/n1/$object/config", $payload);
	return;
}

sub device { return '"dev":{"ids":["n1"],"name":"Sensor"}'; }

# Liefert die Namen aller erzeugten Readings des Zielgeraets.
sub reading_names {
	my %names;

	for my $line (split /\n/, attr_value($target, 'readingList') // '') {
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;

		# Einfache Zeilen nennen den Readingnamen direkt hinter dem Muster.
		if (!defined($reference)) {
			my (undef, $name) = split /\s+/, $line, 2;
			$names{$name} = 1 if defined($name) && $name =~ /^[A-Za-z_][A-Za-z0-9_.-]*\z/;
			next;
		}
		my $descriptor = $main::defs{$target}{helper}{mqtt2_discovery_runtime_refs}{$reference};
		next if ref($descriptor) ne 'HASH';
		$names{ $descriptor->{name} } = 1 if defined($descriptor->{name});

		for my $reading (@{ $descriptor->{configuration}{readings} || [] }) {
			$names{ $reading->{name} } = 1 if ref($reading) eq 'HASH' && defined($reading->{name});
		}
	}

	return [sort keys %names];
}

subtest 'Batterie folgt den drei Namen der Richtlinie' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	announce('sensor', 'battery',
		'{"name":"battery","uniq_id":"n1_bat","stat_t":"n1/bat","dev_cla":"battery","unit_of_meas":"%",'
			. device() . '}');
	is(reading_names(), ['batteryPercent'], 'Prozentwert heisst batteryPercent');

	$hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	announce('sensor', 'battery_voltage',
		'{"name":"battery_voltage","uniq_id":"n1_bv","stat_t":"n1/bv","dev_cla":"voltage","unit_of_meas":"V",'
			. device() . '}');
	is(reading_names(), ['batteryVoltage'], 'Spannung heisst batteryVoltage');

	# Ohne die Konvention bleibt alles, wie es das Discovery liefert.
	$hash = setup();
	announce('sensor', 'battery',
		'{"name":"battery","uniq_id":"n1_bat","stat_t":"n1/bat","dev_cla":"battery","unit_of_meas":"%",'
			. device() . '}');
	is(reading_names(), ['battery'], 'roh bleibt der Name des Discovery');
};

subtest 'binaere Batterie meldet ok und low' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	announce('binary_sensor', 'battery',
		'{"name":"battery","uniq_id":"n1_bl","stat_t":"n1/bl","dev_cla":"battery",'
			. '"pl_on":"ON","pl_off":"OFF",' . device() . '}');
	is(reading_names(), ['batteryState'], 'der Name folgt der Richtlinie');
	my ($line) = split /\n/, attr_value($target, 'readingList') // '';
	my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
	is(main::MQTT2_DISCOVERY_runtimeRef($target, $reference, 'ON'), { batteryState => 'low' },
		'ON bedeutet low');
	is(main::MQTT2_DISCOVERY_runtimeRef($target, $reference, 'OFF'), { batteryState => 'ok' },
		'OFF bedeutet ok');
};

subtest 'Thermostat und Komponentenpraefix' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	announce('climate', 'thermostat',
		'{"name":"thermostat","uniq_id":"n1_c","temp_cmd_t":"n1/set","temp_stat_t":"n1/target",'
			. '"curr_temp_t":"n1/cur",' . device() . '}');
	is(reading_names(), ['desired-temp', 'temperature'],
		'Sollwert und Istwert tragen die FHEM-Namen');
	like(attr_value($target, 'setList'), qr/^desired-temp:/m, 'der Setter heisst ebenso');

	# Roh bleibt der Praefix der Komponente im Namen stehen.
	$hash = setup();
	announce('climate', 'thermostat',
		'{"name":"thermostat","uniq_id":"n1_c","temp_cmd_t":"n1/set","temp_stat_t":"n1/target",'
			. '"curr_temp_t":"n1/cur",' . device() . '}');
	is(reading_names(), ['thermostat_current_temperature', 'thermostat_target_temperature'],
		'ohne die Konvention bleibt der Komponentenpraefix');
};

subtest 'Tasmota meldet seinen Schaltzustand nach state' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem sets=hook readings=parse';
	dispatch_message('mqtt', 'client1', 'tasmota/discovery/AABBCCDDEEFF/config',
		'{"ip":"192.0.2.10","dn":"Workshop Plug","fn":["Soldering Iron",null],'
			. '"hn":"workshop-plug","mac":"AABBCCDDEEFF","md":"Generic","ofln":"Offline",'
			. '"onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0",'
			. '"t":"workshop_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],'
			. '"rl":[1,0],"so":{"4":0,"30":0},"ver":1}');
	my $device = 'Workshop_Plug_Soldering_Iron';
	ok($main::defs{$device}, 'das Zielgeraet entsteht');
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $device
	} values %{ main::MQTT2_DISCOVERY_registry($hash)->{devices} };

	# Eine Zeile ohne Template hat keine Laufzeitreferenz. Sie wurde beim
	# Umstellen auf parse stillschweigend weggelassen, womit die Rueckmeldung
	# des Geraets nie wieder ankam und state auf set_on stehen blieb.
	ok(scalar(@{ $record->{parse_readings} || [] }) > 1,
		'die Zustandszeile liegt in der Registry, nicht nur die Erreichbarkeit');
	dispatch_message('mqtt', 'client1', 'stat/workshop_plug/POWER', 'ON');
	is($main::defs{$device}{READINGS}{state}{VAL}, 'on', 'die Rueckmeldung landet in state');
	dispatch_message('mqtt', 'client1', 'stat/workshop_plug/POWER', 'OFF');
	is($main::defs{$device}{READINGS}{state}{VAL}, 'off', 'und folgt dem Geraet');

	# Mit SetOption26 meldet Tasmota denselben Kanal als POWER1. Die Option steht
	# nicht in der Discovery, also muessen beide Topics dasselbe Reading treffen.
	dispatch_message('mqtt', 'client1', 'stat/workshop_plug/POWER1', 'ON');
	is($main::defs{$device}{READINGS}{state}{VAL}, 'on', 'auch POWER1 landet in state');

	# Dasselbe gilt fuer die Sammelzeile: Ohne den Alias entstuende neben state
	# ein zweites Reading POWER1 mit demselben Wert.
	my ($result_line) = grep { m{^stat/workshop_plug/RESULT:} }
		split /\n/, attr_value($device, 'readingList') // '';
	like($result_line, qr/\Q"POWER1" => "state"\E/,
		'die Sammelzeile benennt den zweiten Schluessel auf dasselbe Reading um');
	like($result_line, qr/\Q"POWER" => "state"\E/, 'der erste Schluessel ebenso');

	# Denselben Zustand meldet Tasmota auch in der STATE-Telemetrie; dort gilt
	# dieselbe Zuordnung, sonst entstuende daneben ein Reading POWER1.
	my ($state_line) = grep { m{^tele/workshop_plug/STATE:} }
		split /\n/, attr_value($device, 'readingList') // '';
	like($state_line, qr/\Q"POWER1" => "state"\E/,
		'die Telemetriezeile benennt denselben Schluessel gleich um');
};

done_testing();
