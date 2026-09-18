# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::FHEMGateway ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $id = 'shelly1g4-aabbccddeeff';
my $target = 'Werkstatt';
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
	main::MQTT2_DISCOVERY_activate($hash);
	@published = ();
	return $hash;
}

# Beantwortet die Discovery-Abfragen; liefert die erzeugte readingList zurueck.
sub discover {
	my ($hash, %ntf) = @_;

	# Die Statusabfrage nach dem Apply bleibt sonst als Rest in der Warteschlange.
	@published = ();
	main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $id);

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
		my $values = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, $payload);
		%updates = (%updates, %$values) if ref($values) eq 'HASH';
	}

	return \%updates;
}

subtest 'Nur die am Geraet aktiven Meldewege erzeugen Zeilen' => sub {
	my $hash = setup();
	my $reading_list = discover($hash, status => 1);
	unlike($reading_list, qr{\Qevents/rpc\E}, 'ohne rpc_ntf entsteht keine Ereigniszeile');
	like($reading_list, qr{\Qstatus/switch:0\E}, 'mit status_ntf entsteht die Komponentenzeile');

	$hash = setup();
	$reading_list = discover($hash, rpc => 1);
	like($reading_list, qr{\Qevents/rpc\E}, 'mit rpc_ntf entsteht die Ereigniszeile');
	unlike($reading_list, qr{\Qstatus/switch\E}, 'ohne status_ntf entsteht keine Komponentenzeile');
	is(readings_for("$id/events/rpc",
		{ src => $id, method => 'NotifyStatus', params => { 'switch:0' => { output => JSON::PP::false } } })->{switch_0},
		'false', 'der Ereignisweg liefert den Wert');

	# Die Antwort der eigenen Abfrage traegt in beiden Faellen die Initialwerte.
	like($reading_list, qr{\Qmqtt2_discovery/discovery/shelly/\E}, 'die Abfrageantwort bleibt immer gebunden');
};

subtest 'Ohne jeden Meldeweg bleibt die Abfrage samt Warnung' => sub {
	my $hash = setup();
	my $reading_list = discover($hash);
	unlike($reading_list, qr{\Qevents/rpc\E}, 'keine Ereigniszeile');
	unlike($reading_list, qr{\Qstatus/switch\E}, 'keine Komponentenzeile');
	like($reading_list, qr{\Qmqtt2_discovery/discovery/shelly/\E}, 'die Abfrageantwort bleibt');
	like(reading_value('discovery', 'lastWarning'), qr/weder rpc_ntf noch status_ntf/,
		'die Warnung benennt die fehlenden Wege');
};

done_testing();
