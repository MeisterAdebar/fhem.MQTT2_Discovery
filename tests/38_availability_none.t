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

subtest 'mit source bleibt die Quelle sichtbar' => sub {
	my $hash = setup();

	# Ohne Verdichtung traegt die Quelle selbst den sichtbaren Namen; mit
	# combined gehoert er der Verdichtung, die zusaetzlich die Brokerverbindung
	# beruecksichtigt.
	$main::attr{discovery}{keys} = 'style=raw sets=list readings=list reachability=sources';
	discover($hash, status => 1);
	my $values = readings_for("$id/online", 'true');
	is($values->{lwt}, 'online', 'die Quelle heisst lwt');
	ok(!exists($values->{availability}), 'ein verdichtetes Reading entsteht nicht');
};

subtest 'der Wechsel von source auf none wird bemerkt und raeumt auf' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=raw sets=list readings=list reachability=sources';
	discover($hash, status => 1);
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $target
	} values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	my $sources = FHEM::MQTT2_DISCOVERY::availability_reading_names($record->{runtime_refs});
	ok(scalar(keys %$sources) > 0, 'mit source fuehrt der Datensatz Quellen');

	# Die Quellen tragen ihren zuletzt gemeldeten Wert, daneben ein Reading, das
	# nicht zur Kette gehoert.
	$main::defs{$target}{READINGS}{$_} = { VAL => 'online', TIME => '2026-09-23 12:00:00' }
		for keys %$sources;
	$main::defs{$target}{READINGS}{temperature} = { VAL => 42.5, TIME => '2026-09-23 12:00:00' };

	# Beide Stufen ergeben denselben leeren Namen des verdichteten Readings.
	# Erkannt wird der Wechsel deshalb nur ueber die mitgefuehrte Stufe.
	ok(!FHEM::MQTT2_DISCOVERY::registry_rendering_outdated($hash),
		'vor der Aenderung ist der Stand aktuell');
	$main::attr{discovery}{keys} = 'style=raw sets=list readings=list reachability=none';
	ok(FHEM::MQTT2_DISCOVERY::registry_rendering_outdated($hash),
		'der Wechsel auf none faellt auf');

	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'rebuildDevice', $target);
	is(FHEM::MQTT2_DISCOVERY::availability_reading_names($record->{runtime_refs}), {},
		'die Kette ist aus dem Datensatz verschwunden');

	# Ohne das Aufraeumen behielte jede Quelle ihren letzten Wert und meldete
	# eine Erreichbarkeit, die niemand mehr fortschreibt.
	my @left = grep { exists($main::defs{$target}{READINGS}{$_}) } sort keys %$sources;
	is(\@left, [], 'und ihre Readings sind entfernt');

	# Aufgeraeumt wird gezielt: Ein Reading, das nicht zur Kette gehoert, bleibt.
	ok($main::defs{$target}{READINGS}{temperature}, 'ein fremdes Reading bleibt stehen');
};

done_testing();
