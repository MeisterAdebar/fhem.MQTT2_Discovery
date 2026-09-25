# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::DevicePlanner ();
use MQTT2_Discovery::FHEMGateway ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $id = 'shelly1g4-aabbccddeeff';
my $target = 'Werkstatt_Switch_aabbccddeeff';
my $info = { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' };
my (@published, @timers);

# Ein Schalter mit Temperatur, WLAN und Laufzeit; die Meldewege sind je Test variabel.
sub configuration {
	my (%ntf) = @_;
	return {
		sys => { device => { name => $target } },
		mqtt => { topic_prefix => $id,
			rpc_ntf => ($ntf{rpc} ? JSON::PP::true : JSON::PP::false),
			status_ntf => ($ntf{status} ? JSON::PP::true : JSON::PP::false) },
		'switch:0' => { id => 0 },
	};
}

sub status {
	return {
		'switch:0' => { id => 0, output => JSON::PP::true, temperature => { tC => 42.5 } },
		wifi => { rssi => -57 }, sys => { uptime => 1234 },
	};
}

sub response {
	my ($request, $result) = @_;
	my $rpc = decode_json($request->{payload});
	return ("$rpc->{src}/rpc", encode_json({ id => $rpc->{id}, src => $id, result => $result }));
}

sub setup {
	reset_env();
	@published = ();
	@timers = ();
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
	FHEM::MQTT2_DISCOVERY::activate($hash);
	@published = ();
	return $hash;
}

# Beantwortet die Discovery-Abfragen; liefert die erzeugte readingList zurueck.
sub discover {
	my ($hash, %ntf) = @_;

	# Die Statusabfrage nach dem Apply bleibt sonst als Rest in der Warteschlange.
	@published = ();
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'discoverShelly', $id);

	for my $result ($info, configuration(%ntf), status()) {
		my $request = shift @published;
		return if !$request;
		my ($topic, $payload) = response($request, $result);
		dispatch_message('mqtt', 'shelly-client', $topic, $payload);
	}

	return attr_value($target, 'readingList') // '';
}

# Wertet alle passenden readingList-Zeilen fuer ein konkretes Topic aus.
sub readings_for {
	my ($topic, $data) = @_;
	my $payload = ref($data) ? encode_json($data) : $data;
	my %updates;

	for my $line (split /\n/, attr_value($target, 'readingList') // '') {
		my ($pattern) = split /\s+/, $line, 2;
		my $prefix = attr_value($target, 'devicetopic');
		$pattern =~ s/\$DEVICETOPIC/\Q$prefix\E/g if defined $prefix;
		next if "$topic:$payload" !~ /^$pattern$/s;
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
		next if !defined($reference);
		my $values = FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $payload);
		%updates = (%updates, %$values) if ref($values) eq 'HASH';
	}

	return \%updates;
}

subtest 'Der Geraetestamm entsteht aus den Topics des Geraets' => sub {
	my $hash = setup();
	discover($hash, status => 1);
	is(attr_value($target, 'devicetopic'), $id, 'das Geraeteprefix wird als devicetopic gesetzt');
	my $reading_list = attr_value($target, 'readingList') // '';
	like($reading_list, qr/^\$DEVICETOPIC\/online:/m, 'die Geraetezeilen verwenden den Stamm');
	like($reading_list, qr/^mqtt2_discovery\//m, 'die eigene Abfrageantwort behaelt ihr volles Topic');

	# Die Auswertung muss unveraendert funktionieren, auch ueber den Stamm.
	is(readings_for("$id/online", 'true')->{availability}, 'online',
		'die Zeile mit Stamm wertet weiterhin aus');
};

subtest 'Ohne eigene Geraetetopics entsteht kein Stamm' => sub {
	my $entries = [
		{ topic => 'mqtt2_discovery/discovery/shelly/abc/state/rpc' },
		{ topic => 'mqtt2_discovery/discovery/shelly/abc/info/rpc' },
	];
	is(MQTT2_Discovery::DevicePlanner::device_topic({ entities => {} }, $entries), undef,
		'allein aus Modultopics entsteht kein devicetopic');
};

done_testing();
