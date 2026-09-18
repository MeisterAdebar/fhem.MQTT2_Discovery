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

subtest 'Aktives topicConversion erzeugt umgewandelte Zeilen' => sub {
	my $hash = setup();
	my $reading_list = discover($hash);
	like($reading_list, qr{\Q$id/status/switch_0:\E}, 'der Doppelpunkt der Komponente wird umgewandelt');
	unlike($reading_list, qr{\Qstatus/switch:0\E}, 'das Rohtopic erscheint nicht mehr');
	is(readings_for("$id/status/switch_0", { output => JSON::PP::false })->{switch_0}, 'false',
		'die umgewandelte Zeile wertet den Komponentenstatus aus');
	is(readings_for("$id/status/switch:0", { output => JSON::PP::false }), {},
		'das Rohtopic trifft keine Zeile mehr');
};

subtest 'Abgeschaltetes topicConversion behaelt das Rohtopic' => sub {
	my $hash = setup();
	$main::attr{mqtt}{topicConversion} = 0;
	my $reading_list = discover($hash);
	like($reading_list, qr{\Q$id/status/switch:0:\E}, 'ohne Umwandlung bleibt der Doppelpunkt stehen');
	is(readings_for("$id/status/switch:0", { output => JSON::PP::true })->{switch_0}, 'true',
		'die Zeile wertet das Rohtopic aus');
};

subtest 'Publish-Topics bleiben unveraendert' => sub {
	my $hash = setup();
	discover($hash);
	my ($set) = grep { /^switch_0:/ } split /\n/, (attr_value($target, 'setList') // '');
	my ($reference) = ($set // '') =~ /'(r_[a-f0-9]+)'/;
	ok($reference, 'Schaltbefehl liegt als Runtime-Referenz vor');
	my $publish = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, 'switch_0 on');
	like($publish, qr{^\Q$id/rpc\E }, 'der Schaltbefehl verwendet unveraendert das Geraetetopic');
};

done_testing();
