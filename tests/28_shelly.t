# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Template ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);
my $id = 'shelly1g4-aabbccddeeff';
my $info = { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' };

# Baut einen dokumentierten Shelly-1-Gen4-Snapshot mit gezielt variierbarem MQTT-Prefix.
sub configuration {
	my ($prefix) = @_;
	return {
		sys => { device => { name => 'Werkstatt' } },
		mqtt => { topic_prefix => $prefix, rpc_ntf => JSON::PP::true, status_ntf => JSON::PP::false },
		'input:0' => { type => 'switch' }, 'switch:0' => { id => 0 },
		wifi => { sta => { pass => 'nicht-persistieren' } },
	};
}

# Der Grundtyp besitzt keine Leistungsmessung; diese darf der Adapter nicht erfinden.
sub status {
	return {
		'switch:0' => { id => 0, output => JSON::PP::true, temperature => { tC => 42.5 } },
		'input:0' => { id => 0, state => JSON::PP::false },
		wifi => { rssi => -57 }, sys => { uptime => 1234 },
	};
}

# Verpackt eine Antwort exakt fuer die zuletzt erzeugte RPC-Anfrage.
sub response {
	my ($request, $result, %extra) = @_;
	my $rpc = decode_json($request->{payload});
	return ("$rpc->{src}/rpc", encode_json({ id => $rpc->{id}, src => $id, result => $result, %extra }));
}

# Fuehrt einen kompletten Snapshot ueber die echte Format-Registry aus.
sub snapshot {
	my (%args) = @_;
	my $prefix = $args{prefix} // $id;
	my $state = {};
	my %common = (state => $state, reply_prefix => 'mqtt2_discovery/test/shelly', now => 100);
	my $step = MQTT2_Discovery::Format::Shelly::begin(%common, mqtt_prefix => $prefix);

	for my $part ($args{info} || $info, $args{config} || configuration($prefix), $args{status} || status()) {
		my ($topic, $payload) = response($step->{requests}[0], $part);
		$step = MQTT2_Discovery::FormatRegistry::consume(
			%common, states => { shelly => $state }, topic => $topic, payload => $payload,
		);
		last if $step->{status} ne 'ok';
	}

	return ($step, $state);
}

subtest 'Native Identifikation, Prefixe und fremde Nachrichten' => sub {
	my $state = {};
	my @before = keys %$state;
	ok(MQTT2_Discovery::Format::Shelly::claims(topic => "$id/online", payload => 'true', state => $state), 'native ID wird erkannt');
	is([keys %$state], \@before, 'claims veraendert den Zustand nicht');
	ok(!MQTT2_Discovery::Format::Shelly::claims(topic => 'other/online', payload => 'true', state => $state), 'fremder Onlinestatus bleibt unbelegt');
	ok(!MQTT2_Discovery::Format::Shelly::claims(topic => 'shellies/announce', payload => '{"id":"shelly1-ABCDEF","model":"SHSW-1"}'), 'Gen1 wird nicht als Gen2+ behandelt');
	ok(!MQTT2_Discovery::Format::Shelly::claims(topic => "$id/online", payload => 'true', shelly_enabled => 0), 'native Erkennung kann abgeschaltet werden');
	ok(MQTT2_Discovery::Format::Shelly::claims(topic => 'haus/licht/events/rpc', payload => encode_json({ src => $id, method => 'NotifyStatus', params => {} })), 'RPC-Ereignis erkennt individuellen Prefix');

	# Publish-Pfade duerfen weder Wildcards noch FHEM-Kommandotrenner enthalten.
	for my $prefix ('x/#', 'x/+', 'x;set', 'x:r', 'x y', '../bad', '', 'x/') {
		ok(!MQTT2_Discovery::Parser::Shelly::valid_prefix($prefix), "unsicherer Prefix abgelehnt: $prefix");
	}
};

subtest 'Gen4 wird mit echten Komponenten und sicheren Schaltbefehlen abgebildet' => sub {
	my ($result, $state) = snapshot(prefix => 'haus/licht');
	is([$result->{status}, $result->{adapter}], ['ok', 'shelly'], 'kanonischer Shelly-Snapshot');
	my @entities = grep { $_->{operation} eq 'upsert' } @{ $result->{events} };
	is([sort map { $_->{entity}{id} } @entities], [sort qw(switch_0 switch_0_temperature input_0 wifi_rssi sys_uptime)], 'nur vorhandene Gen4-Funktionen');
	is($result->{events}[0]{operation}, 'delete_device', 'Snapshot ersetzt eigenen Komponentenbestand');
	ok($result->{events}[0]{extensions}{internal_rebuild}, 'Ersetzung ist keine externe Loeschanforderung');
	unlike(encode_json($state), qr/nicht-persistieren/, 'Konfigurationsgeheimnisse bleiben nicht im Adaptercache');
	my ($relay) = grep { $_->{entity}{kind} eq 'switch' } @entities;
	is($relay->{device}{name}, 'Werkstatt', 'Shelly-Name wird verwendet');
	is($relay->{device}{identifiers}, [$id], 'Identitaet ist unabhaengig vom MQTT-Prefix');
	my $mapped = MQTT2_Discovery::Mapper::map_model(model => $relay, io_name => 'mqtt', cid => 'client');
	ok($mapped->{ok}, 'gemeinsamer Mapper akzeptiert Shelly');
	is($mapped->{warnings}, [], 'Relais hat keine Mapping-Warnungen');
	my $on = decode_json($relay->{entity}{configuration}{payload_on});
	is($on, { id => 1, src => 'haus/licht/events', method => 'Switch.Set', params => { id => 0, on => JSON::PP::true } }, 'Einschalten sendet einen vollstaendigen RPC-Rahmen mit echtem JSON-Boolean');
	is($relay->{commands}[0]{topic}, 'haus/licht/rpc', 'Schaltbefehl verwendet individuellen Prefix');
	is(decode_json($result->{after_apply}[0]{payload})->{method}, 'Shelly.GetStatus', 'Initialstatus wartet bis nach dem Device-Apply');
};

subtest 'Leistungsmessung, mehrere Relais und unbekannte Komponenten' => sub {
	my $status = status();
	$status->{'switch:0'}{apower} = 12.3;
	$status->{'switch:0'}{aenergy} = { total => 456.7 };
	$status->{'switch:1'} = { id => 1, output => JSON::PP::false };
	$status->{'cover:0'} = { state => 'stopped' };
	my ($result) = snapshot(status => $status);
	my %entities = map { $_->{entity}{id} => $_ } grep { $_->{operation} eq 'upsert' } @{ $result->{events} };
	ok($entities{switch_0_power} && $entities{switch_0_energy} && $entities{switch_1}, 'zusaetzliche echte Komponenten erkannt');
	is($entities{switch_0_energy}{entity}{configuration}{unit_of_measurement}, 'Wh', 'Energie bleibt in Shellys nativer Einheit');
	is(decode_json($entities{switch_1}{entity}{configuration}{payload_off})->{params}{id}, 1, 'zweites Relais adressiert Kanal 1');
	like(join(';', @{ $result->{warnings} }), qr/cover:0/, 'nicht unterstuetzter Cover wird sichtbar gemeldet');
};

subtest 'Fehlerhafte, veraltete und doppelte Antworten erzeugen keine Teilgeraete' => sub {
	my $state = {};
	my %common = (state => $state, now => 100);
	my $begin = MQTT2_Discovery::Format::Shelly::begin(%common, mqtt_prefix => $id);
	is(scalar(@{ MQTT2_Discovery::Format::Shelly::begin(%common, mqtt_prefix => $id)->{requests} }), 0, 'Wiederholungen sind begrenzt');
	my ($topic, $payload) = response($begin->{requests}[0], $info, id => 999);
	my $wrong = MQTT2_Discovery::Format::Shelly::consume(%common, topic => $topic, payload => $payload);
	is($wrong->{events}, [], 'falsche Request-ID wird ignoriert');
	($topic, $payload) = response($begin->{requests}[0], $info);
	my $expired = MQTT2_Discovery::Format::Shelly::consume(%common, now => 221, topic => $topic, payload => $payload);
	is($expired->{events}, [], 'abgelaufene Antwort wird ignoriert');
	my ($bad) = snapshot(config => configuration('anderes/geraet'));
	is($bad->{status}, 'error', 'abweichender Prefix wird abgelehnt');
	my $broken = status();
	$broken->{'switch:0'}{output} = {};
	($bad) = snapshot(status => $broken);
	is($bad->{status}, 'error', 'ungueltiger Relaiszustand verwirft den Snapshot');
	($bad) = snapshot(status => {});
	is($bad->{status}, 'error', 'leerer Status darf keinen bestehenden Komponentenbestand entfernen');
	($bad) = snapshot(status => { sys => {} });
	is($bad->{status}, 'error', 'unvollstaendiger Snapshot mit fehlendem Relais wird ebenfalls abgelehnt');
	my $invalid = MQTT2_Discovery::Format::Shelly::consume(%common, topic => $topic, payload => '{');
	is($invalid->{status}, 'error', 'beschaedigter RPC-Rahmen bleibt sichtbar');
};

my (@published, @timers);

# Richtet einen lokalen Gateway ein, der MQTT ausschliesslich protokolliert.
sub setup {
	my ($type, $async) = @_;
	reset_env();
	@published = ();
	@timers = ();
	my $io = add_iodev('mqtt', $type || 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		publish_mqtt => sub {
			my (undef, $topic, $payload) = @_;
			push @published, { topic => $topic, payload => $payload };
			return undef;
		},
		($async ? (
			can_schedule => sub { 1 },
			schedule => sub { push @timers, [@_]; return; },
			cancel_timer => sub { @timers = (); return; },
		) : ()),
	);
	main::MQTT2_DISCOVERY_activate($hash);
	is(\@published, [{ topic => 'shellies/command', payload => 'announce' }], 'Aktivierung startet native Erkennung');
	@published = ();
	return ($hash, $io);
}

# Fuehrt die begrenzte Timerwarteschlange aus, ohne auf echte Zeit oder ein Netzwerk zu warten.
sub drain {
	my $count = 0;

	while (@timers) {
		die 'Timer-Endlosschleife' if ++$count > 50;
		my $timer = shift @timers;
		no strict 'refs';
		&{ "main::$timer->[2]" }($timer->[1]);
	}

}

# Beantwortet die drei Discovery-Abfragen am simulierten MQTT-Dispatch.
sub discover {
	my ($hash, $prefix, $status) = @_;
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $prefix), undef, 'gezielte Erkennung gestartet');

	for my $result ($info, configuration($prefix), $status || status()) {
		my $request = shift @published;
		ok($request, 'lesende RPC-Abfrage wurde gesendet');
		my ($topic, $payload) = response($request, $result);
		is(dispatch_message('mqtt', 'shelly-client', $topic, $payload), ['MQTT2_DISCOVERY'], 'eigene RPC-Antwort wird konsumiert');
		drain();
	}

}

# Wertet die erzeugte kompakte Runtime-Referenz fuer ein konkretes MQTT-Topic aus.
sub readings_for {
	my ($target, $topic, $data) = @_;
	my $payload = encode_json($data);
	my %updates;

	for my $line (split /\n/, attr_value($target, 'readingList')) {
		my ($pattern) = split /\s+/, $line, 2;
		my $prefix = attr_value($target, 'devicetopic');
		$pattern =~ s/\$DEVICETOPIC/\Q$prefix\E/g;
		next if "$topic:$payload" !~ /^$pattern$/s;
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
		next if !defined($reference);
		my $values = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, $payload);
		%updates = (%updates, %$values) if ref($values) eq 'HASH';
	}

	# MQTT2_DEVICE uebernimmt die zurueckgegebenen Werte, einschliesslich interner Availability-Quellen.
	for my $reading (keys %updates) {
		main::readingsSingleUpdate($main::defs{$target}, $reading, $updates{$reading}, 1);
	}

	return \%updates;
}

subtest 'SERVER und CLIENT funktionieren bis zu den echten Runtime-Bindings' => sub {
	# Beide Transportarten muessen identische Funktionen mit ihrer jeweiligen CID-Regel erzeugen.
	for my $type (qw(MQTT2_SERVER MQTT2_CLIENT)) {
		my ($hash) = setup($type);
		discover($hash, 'haus/licht');
		my $target = 'Werkstatt';
		ok($main::defs{$target}, "$type: Zieldevice angelegt");
		is(reading_value('discovery', 'discoveredDevices'), 1, 'alle Komponenten gehoeren zu einem Device');
		is(reading_value('discovery', 'lastAdapter'), 'shelly', 'native Herkunft ist sichtbar');
		is(scalar(@published), 1, 'genau eine Abfrage fuer Initialwerte nach dem Apply');
		my $initial = decode_json($published[0]{payload});
		my $updates = readings_for($target, "$initial->{src}/rpc", { src => $id, result => status() });
		is($updates->{switch_0}, 'true', 'Initialstatus des Relais ist lesbar');
		is($updates->{input_0}, 'false', 'Initialstatus des Eingangs ist lesbar');
		is($updates->{availability}, 'online', 'erfolgreiche Statusantwort bestaetigt Erreichbarkeit');
		my $offline = readings_for($target, 'haus/licht/online', JSON::PP::false);
		is($offline->{availability}, 'offline', 'LWT setzt trotz frueherer RPC-Antwort verlaesslich offline');
		my $rpc = readings_for($target, 'haus/licht/events/rpc', { src => $id, method => 'NotifyStatus', params => { 'switch:0' => { output => JSON::PP::false } } });
		is($rpc->{switch_0}, 'false', 'RPC-Aenderung aktualisiert das Relais');
		ok(!exists($rpc->{input_0}), 'fehlender Eingang wird bei Teilstatus nicht ueberschrieben');
		my $before_publish = scalar(@published);
		is(dispatch_message('mqtt', 'shelly-client', 'haus/licht/events/rpc', '{"src":"shelly1g4-aabbccddeeff","method":"NotifyStatus","params":{}}'),
			['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'bekannte RPC-Telemetrie bleibt im normalen Dispatch');
		is(scalar(@published), $before_publish, 'bekannte RPC-Telemetrie erzeugt keine neuen Abfragen');
		my $component = readings_for($target, 'haus/licht/status/switch_0', { output => JSON::PP::true });
		is($component->{switch_0}, 'true', 'Komponentenstatus verwendet denselben Readingnamen');
		my ($set) = grep { /^switch_0:/ } split /\n/, attr_value($target, 'setList');
		my ($reference) = ($set // '') =~ /'(r_[a-f0-9]+)'/;
		ok($reference, 'Schaltbefehl ist als sichere Runtime-Referenz vorhanden');
		is(main::MQTT2_DISCOVERY_runtimeRef($target, $reference, 'switch_0 on'),
			'haus/licht/rpc {"id":1,"method":"Switch.Set","params":{"id":0,"on":true},"src":"haus/licht/events"}', 'on schaltet den richtigen Shelly-Kanal');
		my ($relay_semantics) = grep { $_->{class} eq 'switch' } @{ $main::defs{$target}{SEMANTIC_METADATA}{entities} };
		is($relay_semantics->{capabilities}{power}{valueMap}{read}, { true => 'on', false => 'off' }, 'Semantik verwendet dieselben Boolean-Zustaende wie die Runtime');
		my $before = attr_value($target, 'readingList');
		@published = ();
		discover($hash, 'haus/licht');
		is(attr_value($target, 'readingList'), $before, 'erneuter Snapshot erzeugt keine Duplikate');
		is(reading_value('discovery', 'discoveredDevices'), 1, 'erneute Erkennung behaelt dasselbe Device');
		my $changed = status();
		delete $changed->{'input:0'};
		@published = ();
		discover($hash, 'haus/licht', $changed);
		unlike(attr_value($target, 'readingList'), qr/input_0/, 'entfallene Komponenten verschwinden aus den generierten Bindings');
		is(reading_value('discovery', 'discoveredDevices'), 1, 'Komponentenwechsel erhaelt das Zieldevice');
		unlike(reading_value('discovery', '.registry'), qr/nicht-persistieren/, 'Registry enthaelt keine Shelly-Konfigurationsgeheimnisse');
	}
};

subtest 'Queue trennt Announcements und wartet mit Initialstatus auf den Apply' => sub {
	my ($hash) = setup('MQTT2_SERVER', 1);
	my $other = { %$info, id => 'shelly1g4-112233445566' };
	dispatch_message('mqtt', 'first', 'shellies/announce', encode_json($info));
	dispatch_message('mqtt', 'second', 'shellies/announce', encode_json($other));
	is(scalar(keys %{ $hash->{helper}{queue}{messages} }), 2, 'gemeinsames Announce-Topic behaelt beide Geraete');
	drain();
	is(scalar(@published), 2, 'beide Geraete werden separat abgefragt');
	($hash) = setup('MQTT2_SERVER', 1);
	discover($hash, $id);
	ok(attr_value('Werkstatt', 'readingList'), 'Reading-Bindings nach Queue-Abschluss vorhanden');
	is(scalar(@published), 1, 'Initialstatus erst nach Queue-Abschluss angefordert');
	dispatch_message('mqtt', 'first', "$id/events/rpc", encode_json({ src => $id, params => { 'switch:0' => { output => JSON::PP::false } } }));
	is(scalar(@timers), 0, 'laufende Telemetrie belegt keinen weiteren Queue-Timer');
};

subtest 'Neustart, Reconnect und Abbruch erhalten die Erkennungsgrenzen' => sub {
	my ($hash, $io) = setup('MQTT2_CLIENT');
	$io->{CHANGED} = ['state: opened'];
	main::MQTT2_DISCOVERY_Notify($hash, $io);
	is(\@published, [], 'wiederholtes Online-Ereignis startet keinen zweiten Broadcast');
	$io->{STATE} = 'disconnected';
	main::MQTT2_DISCOVERY_Notify($hash, $io);
	$io->{STATE} = 'opened';
	main::MQTT2_DISCOVERY_Notify($hash, $io);
	is(\@published, [{ topic => 'shellies/command', payload => 'announce' }], 'Reconnect startet eine neue Erkennung');
	@published = ();
	main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $id);
	my $pending = shift @published;
	main::MQTT2_DISCOVERY_deactivate($hash);
	main::MQTT2_DISCOVERY_activate($hash);
	@published = ();
	my ($topic, $payload) = response($pending, $info);
	dispatch_message('mqtt', 'client', $topic, $payload);
	is(\@published, [], 'Antwort einer abgebrochenen Abfrage setzt die alte Kette nicht fort');
};

subtest 'MQTT-Gateway verwendet den echten FHEM-WriteFn-Vertrag' => sub {
	my @calls;
	no warnings qw(redefine once);
	local *main::CallFn = sub { push @calls, [@_]; return undef; };
	my $gateway = MQTT2_Discovery::FHEMGateway->new();
	my $io = { NAME => 'mqtt', TYPE => 'MQTT2_CLIENT' };
	is($gateway->publish_mqtt($io, 'shellies/command', 'announce'), undef, 'Publish erfolgreich');
	is(\@calls, [['mqtt', 'WriteFn', $io, 'publish', 'shellies/command announce']], 'WriteFn bekommt IODev-Hash, Operation und Topic/Payload');
	like($gateway->publish_mqtt($io, 'x:r', 'on'), qr/Ungueltig/, 'Discovery-Publish kann kein Retain erzwingen');
	is(scalar(@calls), 1, 'ungueltige Publishes erreichen FHEM nicht');
};

subtest 'Deaktivierung und fremde Antworten loesen keine Discovery aus' => sub {
	my ($hash, $io) = setup();
	$main::attr{discovery}{disable} = 1;
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $id), 'MQTT2_DISCOVERY muss aktiv sein', 'disable blockiert manuelle Discovery');
	is(main::MQTT2_DISCOVERY_Parse($io, "cid\0$id/online\0true"), '[NEXT]', 'disable blockiert keine Shelly-Laufzeitmeldungen');
	is(\@published, [], 'disable sendet keine MQTT-Abfrage');
	delete $main::attr{discovery}{disable};
	is(main::MQTT2_DISCOVERY_Parse($io, "cid\0mqtt2_discovery/other/shelly/0123456789abcdef/info/rpc\0{}"), '[NEXT]', 'Antworten anderer Instanzen bleiben unangetastet');
	$io->{STATE} = 'closed';
	like(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $id), qr/nicht verbunden/, 'getrenntes IODev sendet keine Abfragen');
};

done_testing;
