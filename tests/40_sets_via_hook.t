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

# FHEM laedt SetExtensions ueber 10_MQTT2_DEVICE.pm; in der Testumgebung genuegt
# ein Ersatz, der die uebergebene Kommandoliste sichtbar macht.
my @fallback;
{
	no warnings 'once';
	*main::SetExtensions = sub {
		my ($hash, $list, $name, $cmd, @a) = @_;
		push @fallback, { list => $list, cmd => $cmd };
		return "Unknown argument $cmd, choose one of $list";
	};
}

my $id = 'shelly1g4-aabbccddeeff';
my $target = 'Werkstatt_Switch_aabbccddeeff';
my $info = { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' };
my @published;

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
	@fallback = ();
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
	return $hash;
}

sub discover {
	my ($hash) = @_;
	@published = ();
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'discoverShelly', $id);

	for my $result ($info, configuration(), status()) {
		my $request = shift @published;
		return if !$request;
		my $rpc = decode_json($request->{payload});
		dispatch_message('mqtt', 'shelly-client', "$rpc->{src}/rpc",
			encode_json({ id => $rpc->{id}, src => $id, result => $result }));
	}

	return;
}

subtest 'Das Modul reiht sich in die Kette von SetExtensions ein' => sub {
	setup();

	# SE_Next ruft alle Namen auf, die als Liste unter dem Zieltyp stehen;
	# dieselbe Liste benutzt FHEM fuer AttrTemplate_Set (SetExtensions.pm).
	is($main::modules{MQTT2_DEVICE}{SetExtensionsFn}, ['MQTT2_DISCOVERY_SetExtensions'],
		'der eigene Name steht in der Kette');

	# Ein zweiter Lauf darf ihn nicht erneut anhaengen.
	FHEM::MQTT2_DISCOVERY::register_set_extensions();
	is($main::modules{MQTT2_DEVICE}{SetExtensionsFn}, ['MQTT2_DISCOVERY_SetExtensions'],
		'und steht nur einmal darin');

	# Ohne geladenes Zielmodul entstuende ein Modulhash ohne Match und ParseFn,
	# an dem FHEMs Dispatch stirbt.
	delete $main::modules{MQTT2_DEVICE}{LOADED};
	delete $main::modules{MQTT2_DEVICE}{SetExtensionsFn};
	FHEM::MQTT2_DISCOVERY::register_set_extensions();
	ok(!exists($main::modules{MQTT2_DEVICE}{SetExtensionsFn}),
		'ohne geladenes MQTT2_DEVICE wird nichts eingetragen');
};

subtest 'Mit sets=hook entsteht kein setList-Attribut' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=raw sets=hook readings=list reachability=full';
	discover($hash);
	is(attr_value($target, 'setList'), undef, 'das Zielgeraet hat kein setList-Attribut');
	my ($record) = values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	is([map { $_->{name} } @{ $record->{hook_sets} }], ['switch_0'],
		'die Befehle liegen strukturiert in der Registry');

	# Ohne das Attribut bleibt die setList erhalten; der Schluessel wird dafuer
	# ausdruecklich gesetzt, weil die Vorgabe des Moduls inzwischen hook ist.
	$hash = setup();
	$main::attr{discovery}{keys} .= ' sets=list';
	discover($hash);
	like(attr_value($target, 'setList'), qr/^switch_0:on,off /m, 'ohne Attribut bleibt die setList');
};

subtest 'Der Hook bietet die Befehle an und fuehrt sie aus' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=raw sets=hook readings=list reachability=full';
	discover($hash);
	@published = ();

	# Bei "?" ergaenzt der Hook die Auswahl und gibt sie an die Kette zurueck;
	# ein Aufruf von SetExtensions waere hier eine Schleife.
	my $antwort = FHEM::MQTT2_DISCOVERY::SetExtensions($main::defs{$target}, '', $target, '?');
	is(scalar(@fallback), 0, 'die Kette wird nicht erneut betreten');
	# Bei "?" laesst SE_Next den Befehl ungeschuetzt in sein Muster; die Antwort
	# nennt ihn deshalb nicht, sonst endete die Kette hier.
	like($antwort, qr/^Unknown argument, choose one of /, 'die Antwort folgt dem Vertrag');
	like($antwort, qr/\bswitch_0:on,off\b/, 'die Befehle stehen in der Auswahl');

	# Ein bekannter Befehl wird selbst ausgefuehrt.
	is(FHEM::MQTT2_DISCOVERY::SetExtensions($main::defs{$target}, '', $target, 'switch_0', 'on'),
		undef, 'der Schaltbefehl meldet keinen Fehler');
	is(scalar(@published), 1, 'genau ein Publish');
	is($published[0]{topic}, "$id/rpc", 'der Befehl geht an das RPC-Topic des Geraets');
	like($published[0]{payload}, qr/"method":"Switch\.Set"/, 'der Payload schaltet die Komponente');
	is($main::defs{$target}{READINGS}{state}{VAL}, 'switch_0 on',
		'state folgt dem Befehl wie bei MQTT2_DEVICE_Set');
	is(FHEM::MQTT2_DISCOVERY::SetExtensions($main::defs{$target}, '', $target, 'switch_0', 'blau'),
		'Unbekannter Wert fuer switch_0', 'ein unbekannter Wert wird abgelehnt');
};

subtest 'Mit der FHEM-Konvention steht bis zur Rueckmeldung set_' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem sets=hook';
	discover($hash);
	@published = ();

	# Nach FHEM-Konvention meldet das Reading den Befehl erst als Absicht; die
	# Rueckmeldung des Geraets ersetzt ihn spaeter durch den echten Zustand.
	is(FHEM::MQTT2_DISCOVERY::SetExtensions($main::defs{$target}, '', $target, 'on'),
		undef, 'der Schaltbefehl meldet keinen Fehler');
	is($main::defs{$target}{READINGS}{state}{VAL}, 'set_on',
		'state zeigt den Uebergang');
};

subtest 'Fremde Devices bleiben unveraendert' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=raw sets=hook readings=list reachability=full';
	discover($hash);
	@fallback = ();
	$main::defs{fremd} = { NAME => 'fremd', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	my $antwort = FHEM::MQTT2_DISCOVERY::SetExtensions(
		$main::defs{fremd}, 'on:noArg', 'fremd', '?',
	);
	is(scalar(@fallback), 0, 'die Kette wird nicht erneut betreten');
	is($antwort, 'Unknown argument, choose one of on:noArg',
		'die Kommandoliste wird unveraendert weitergereicht');
};

done_testing();
