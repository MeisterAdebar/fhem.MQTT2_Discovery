# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FHEMGateway ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $id = 'shelly1g4-aabbccddeeff';
my $target = 'Werkstatt';
my $info = { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' };
my @published;

# Ein Schalter mit Temperatur; die Komponente traegt den kritischen Doppelpunkt.
sub configuration {
	return {
		sys => { device => { name => $target } },
		mqtt => { topic_prefix => $id, rpc_ntf => JSON::PP::false, status_ntf => JSON::PP::true },
		'switch:0' => { id => 0 },
	};
}

sub status {
	return {
		'switch:0' => { id => 0, output => JSON::PP::true, temperature => { tC => 42.5 } },
		sys => { uptime => 1234 },
	};
}

sub setup {
	reset_env();
	@published = ();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		publish_mqtt => sub {
			my (undef, $topic, $payload) = @_;
			push @published, { topic => $topic, payload => $payload };
			return undef;
		},
	);
	main::MQTT2_DISCOVERY_activate($hash);
	return $hash;
}

# Beantwortet die drei Abfragen und liefert die erzeugte readingList.
sub discover {
	my ($hash) = @_;
	@published = ();
	main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $id);

	for my $result ($info, configuration(), status()) {
		my $request = shift @published;
		return '' if !$request;
		my $rpc = decode_json($request->{payload});
		dispatch_message('mqtt', 'shelly-client', "$rpc->{src}/rpc",
			encode_json({ id => $rpc->{id}, src => $id, result => $result }));
	}

	return attr_value($target, 'readingList') // '';
}

# Wertet alle passenden readingList-Zeilen fuer ein konkretes Topic aus.
sub readings_for {
	my ($topic, $data) = @_;
	my $payload = encode_json($data);
	my %updates;

	for my $line (split /\n/, attr_value($target, 'readingList') // '') {
		my ($pattern) = split /\s+/, $line, 2;
		next if "$topic:$payload" !~ /^$pattern$/s;
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
		next if !defined($reference);
		my $values = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, $payload);
		%updates = (%updates, %$values) if ref($values) eq 'HASH';
	}

	return \%updates;
}

subtest 'Ohne readingList schreibt das Modul die Readings selbst' => sub {
	my $hash = setup();
	$main::attr{discovery}{readingsViaParse} = 1;
	discover($hash);
	is(attr_value($target, 'readingList'), undef, 'am Zielgeraet entsteht kein readingList-Attribut');
	is($main::modules{MQTT2_DISCOVERY}{Match}, '.*', 'das Modul sieht dafuer alle Nachrichten');
	my ($record) = values %{ main::MQTT2_DISCOVERY_registry($hash)->{devices} };
	ok(scalar(@{ $record->{parse_readings} || [] }), 'die Zeilen liegen in der Registry');

	# Eine gewoehnliche Nutzdatennachricht muss die Readings aktualisieren.
	dispatch_message('mqtt', 'shelly-client', "$id/status/switch_0",
		encode_json({ output => JSON::PP::false, temperature => { tC => 21.5 } }));
	is($main::defs{$target}{READINGS}{switch_0}{VAL}, 'false', 'der Schaltzustand wird geschrieben');
	is($main::defs{$target}{READINGS}{switch_0_temperature}{VAL}, '21.5', 'die Temperatur wird geschrieben');

	# Die Nachricht bleibt im Dispatch, damit manuelle Zeilen weiter arbeiten.
	is(dispatch_message('mqtt', 'shelly-client', "$id/status/sys", encode_json({ uptime => 5 })),
		['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'],
		'die Nachricht wird nicht verschluckt');
	is($main::defs{$target}{READINGS}{sys_uptime}{VAL}, '5', 'auch danach entstehen Readings');
};

subtest 'Ohne das Attribut bleibt alles beim Alten' => sub {
	my $hash = setup();
	my $reading_list = discover($hash);
	like($reading_list, qr{\$DEVICETOPIC/status/switch_0:}, 'die readingList entsteht wie bisher');
	isnt($main::modules{MQTT2_DISCOVERY}{Match}, '.*', 'der enge Match bleibt erhalten');
};

done_testing();
