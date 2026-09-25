# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery attr_value reading_value command_log log_entries);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

subtest 'Initialize und Define' => sub {
	reset_env();
	my $module = $main::modules{MQTT2_DISCOVERY};
	# Die Schnittstellen sind Code-Referenzen in dieses Paket, keine Namen in main.
	is($module->{DefFn}, \&FHEM::MQTT2_DISCOVERY::Define, 'DefFn registriert');
	is($module->{GetFn}, \&FHEM::MQTT2_DISCOVERY::Get, 'GetFn registriert');
	is($module->{ParseFn}, \&FHEM::MQTT2_DISCOVERY::Parse, 'ParseFn registriert');
	is($module->{NotifyFn}, \&FHEM::MQTT2_DISCOVERY::Notify, 'NotifyFn registriert');
	is($main::modules{MQTT2_DEVICE}{SetExtensionsFn}, ['MQTT2_DISCOVERY_SetExtensions'],
		'der Hook reiht den in main sichtbaren Namen in die Kette ein');
	is($module->{FW_deviceOverview}, 1, 'kontextbezogene FHEMWEB-Hilfe ist aktiviert');
	like($module->{Match}, qr/config/, 'globales Match erfasst Config-Topics');
	like($module->{Match}, qr/sensors/, 'globales Match erfasst native Tasmota-Sensor-Topics');
	like($module->{Match}, qr/discovery/, 'globales Match erfasst native Sonos2mqtt-Discovery-Topics');
	like($module->{AttrList}, qr/(?:^| )disable:0,1(?: |$)/, 'disable ist als Standardattribut registriert');
	like($module->{AttrList}, qr/(?:^| )createReadings:0,1(?: |$)/,
		'optionale direkte Reading-Erzeugung ist registriert');
	like($module->{AttrList}, qr/(?:^| )deviceNamePrefix(?: |$)/, 'optionaler Device-Namensprefix ist registriert');
	like($module->{AttrList}, qr/(?:^| )extraJsonReadings:include,ignore(?: |$)/,
		'Modus fuer zusaetzliche JSON-Readings ist registriert');

	my ($missing, $missing_error) = define_discovery('bad', 'missing');
	like($missing_error, qr/existiert nicht/, 'fehlendes IODev wird abgelehnt');
	$main::defs{dummy} = { NAME => 'dummy', TYPE => 'dummy' };
	my ($wrong, $wrong_error) = define_discovery('wrong', 'dummy');
	like($wrong_error, qr/weder MQTT2_SERVER noch MQTT2_CLIENT/, 'falscher IO-Typ wird abgelehnt');

	add_iodev('server', 'MQTT2_SERVER');
	my ($first, $first_error) = define_discovery('discovery', 'server');
	is($first_error, undef, 'Server-Discovery wird definiert');
	is($first->{NOTIFYDEV}, 'global,server',
		'Notify ist auf Lebenszyklus und gebundenes IODev begrenzt');
	is(FHEM::MQTT2_DISCOVERY::prefixes($first), ['homeassistant', 'tasmota/discovery', 'sonos2mqtt'],
		'Home Assistant, Tasmota und Sonos2mqtt Discovery sind standardmaessig aktiv');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{server}, $first, 'Registry enthaelt IODev-Zuordnung');
	my ($second, $second_error) = define_discovery('discovery2', 'server');
	like($second_error, qr/bereits discovery definiert/, 'zweite Instanz am selben IODev wird abgelehnt');

	add_iodev('client', 'MQTT2_CLIENT');
	my ($other, $other_error) = define_discovery('discoveryClient', 'client');
	is($other_error, undef, 'anderes IODev darf eigene Instanz haben');
	is(FHEM::MQTT2_DISCOVERY::Undef($other, 'discoveryClient'), undef, 'Undef erfolgreich');
	ok(!exists $main::modules{MQTT2_DISCOVERY}{defptr}{client}, 'Undef entfernt nur eigenen Registry-Eintrag');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{server}, $first, 'andere Registry-Zuordnung bleibt erhalten');
};

subtest 'modify wechselt IODev ohne veraltete Registrierung' => sub {
	reset_env();
	add_iodev('serverA', 'MQTT2_SERVER');
	add_iodev('serverB', 'MQTT2_SERVER');
	my ($hash, $define_error) = define_discovery('discovery', 'serverA');
	is($define_error, undef, 'Ausgangsdefinition ist gueltig');
	$hash->{helper}{queue} = { order => [], messages => {}, scheduled => 1 };

	$hash->{OLDDEF} = 'serverA';
	my $modify_error = FHEM::MQTT2_DISCOVERY::Define(
		$hash, 'discovery MQTT2_DISCOVERY serverB'
	);
	delete $hash->{OLDDEF};

	is($modify_error, undef, 'Wechsel auf anderes IODev ist erfolgreich');
	ok(!exists $main::modules{MQTT2_DISCOVERY}{defptr}{serverA},
		'alte IODev-Registrierung wurde entfernt');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverB}, $hash,
		'neue IODev-Registrierung zeigt auf dasselbe Device');
	is($hash->{IODevName}, 'serverB', 'interne IODev-Zuordnung wurde aktualisiert');
	ok(!exists $hash->{helper}{queue}, 'ausstehende Arbeit des alten IODev wurde verworfen');
};

subtest 'fehlgeschlagenes modify erhaelt bisherige Registrierung' => sub {
	reset_env();
	add_iodev('serverA', 'MQTT2_SERVER');
	add_iodev('serverB', 'MQTT2_SERVER');
	my ($hash, $define_error) = define_discovery('discoveryA', 'serverA');
	my ($occupied, $occupied_error) = define_discovery('discoveryB', 'serverB');
	is($define_error, undef, 'erste Ausgangsdefinition ist gueltig');
	is($occupied_error, undef, 'zweite Ausgangsdefinition ist gueltig');

	$hash->{OLDDEF} = 'serverA';
	my $modify_error = FHEM::MQTT2_DISCOVERY::Define(
		$hash, 'discoveryA MQTT2_DISCOVERY serverB'
	);
	delete $hash->{OLDDEF};

	like($modify_error, qr/bereits discoveryB definiert/,
		'belegtes Ziel-IODev wird abgelehnt');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverA}, $hash,
		'bisherige Registrierung bleibt nach Fehler erhalten');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverB}, $occupied,
		'bestehende Registrierung des Ziel-IODev bleibt unveraendert');
	is($hash->{IODevName}, 'serverA', 'interne IODev-Zuordnung bleibt unveraendert');
};

subtest 'Get devices trennt verwaltete und nicht verwaltete MQTT-Devices' => sub {
	reset_env();
	my $server = add_iodev('server');
	my $other_server = add_iodev('otherServer');
	my ($hash, $error) = define_discovery('discovery', 'server');
	my ($other_hash, $other_error) = define_discovery('otherDiscovery', 'otherServer');
	is($error, undef, 'zu pruefende Discovery-Instanz wird definiert');
	is($other_error, undef, 'zweite Discovery-Instanz wird definiert');
	$main::attr{global}{language} = 'DE';

	# Die simulierten Devices decken beide Gruppen, fremde IODevs und HTML-Zeichen ab.
	for my $spec (
		['A&Managed', $server, 'adopted'],
		['Z.Managed', $server, 'created'],
		['Renamed.Device', $server, 'renamed-cid'],
		['B<Unmanaged', $server, 'unmanaged-b'],
		['M.Unmanaged', $server, 'unmanaged-m'],
		['WrongIo.Record', $server, 'wrong-io'],
		['OtherBroker.Device', $other_server, 'other-cid'],
	) {
		my ($name, $iodev, $cid) = @$spec;
		$main::defs{$name} = {
			NAME => $name, TYPE => 'MQTT2_DEVICE', IODev => $iodev,
			CID => $cid, DEF => $cid, READINGS => {},
		};
	}

	$main::defs{NotMqtt} = {
		NAME => 'NotMqtt', TYPE => 'dummy', IODev => $server, READINGS => {},
	};
	my $registry = FHEM::MQTT2_DISCOVERY::registry($hash);
	$registry->{devices} = {
		adopted => {
			name => 'A&Managed', created => 0, io => 'server',
			cid => 'adopted', entities => {},
		},
		created => {
			name => 'Z.Managed', created => 1, io => 'server',
			cid => 'created', entities => { state => {} },
		},
		duplicate => {
			name => 'Z.Managed', created => 1, io => 'server',
			cid => 'created', entities => {},
		},
		renamed => {
			name => 'Old.Device', created => 1, io => 'server',
			cid => 'renamed-cid', entities => { state => {} },
		},
		stale => {
			name => 'Missing.Device', created => 1, io => 'server',
			cid => 'missing-cid', entities => { state => {} },
		},
		wrong_io => {
			name => 'WrongIo.Record', created => 1, io => 'otherServer',
			cid => 'wrong-io', entities => { state => {} },
		},
	};
	FHEM::MQTT2_DISCOVERY::registry($other_hash)->{devices} = {
		other => {
			name => 'OtherBroker.Device', created => 1, io => 'otherServer',
			cid => 'other-cid', entities => { state => {} },
		},
	};

	my ($managed, $unmanaged) = FHEM::MQTT2_DISCOVERY::device_groups($hash);
	is($managed, ['A&Managed', 'Renamed.Device', 'Z.Managed'],
		'angelegte, uebernommene und eindeutig umbenannte Registry-Ziele sind verwaltet');
	is($unmanaged, ['B<Unmanaged', 'M.Unmanaged', 'WrongIo.Record'],
		'nur uebrige MQTT2_DEVICEs desselben IODev sind nicht verwaltet');

	my $json = JSON::PP->new->canonical(1);
	my $registry_before = $json->encode($registry);
	my $readings_before = $json->encode($hash->{READINGS});
	my $commands_before = [ @{ command_log() } ];
	my $html = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'devices');
	like($html, qr{\A<html>.*</html>\z}s, 'Get liefert den FHEMWEB-Popup-Wrapper');
	like($html, qr/MQTT2-Devices an server/, 'Popup nennt das gebundene IODev');
	like($html, qr/Verwaltet \(3\)/, 'verwaltete Gruppe zeigt ihre Anzahl');
	like($html, qr/Nicht verwaltet \(3\)/, 'nicht verwaltete Gruppe zeigt ihre Anzahl');
	like($html, qr{href="\?detail=A%26Managed">A&amp;Managed</a>},
		'verwalteter Link codiert URL und sichtbaren Namen getrennt');
	like($html, qr{href="\?detail=B%3CUnmanaged">B&lt;Unmanaged</a>},
		'nicht verwalteter Link verhindert HTML-Injektion');
	my $byte_name = "K\xC3\xBCche";
	my $wide_name = Encode::decode('UTF-8', $byte_name);
	is(FHEM::MQTT2_DISCOVERY::url_encode($wide_name), 'K%C3%BCche',
		'Unicode-Zeichenkette wird einmal als UTF-8 codiert');
	is(FHEM::MQTT2_DISCOVERY::url_encode($byte_name), 'K%C3%BCche',
		'FHEM-Bytestream wird nicht doppelt als UTF-8 codiert');
	unlike($html, qr/Missing\.Device|OtherBroker\.Device|NotMqtt/,
		'verwaiste, fremde und typfremde Devices fehlen');
	ok(index($html, 'A&amp;Managed') < index($html, 'Renamed.Device')
			&& index($html, 'Renamed.Device') < index($html, 'Z.Managed'),
		'verwaltete Links sind alphabetisch sortiert');
	ok(index($html, 'B&lt;Unmanaged') < index($html, 'M.Unmanaged')
			&& index($html, 'M.Unmanaged') < index($html, 'WrongIo.Record'),
		'nicht verwaltete Links sind alphabetisch sortiert');
	is($json->encode($registry), $registry_before, 'Get veraendert die Registry nicht');
	is($json->encode($hash->{READINGS}), $readings_before, 'Get veraendert keine Readings');
	is(command_log(), $commands_before, 'Get fuehrt keine FHEM-Kommandos aus');
	like(FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery'), qr/devices:noArg/,
		'fehlender Get-Befehl nennt die Auswahl');
	like(FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'unknown'), qr/devices:noArg/,
		'unbekannter Get-Befehl nennt die Auswahl');
	like(FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'devices', 'extra'), qr/devices:noArg/,
		'devices lehnt Zusatzargumente ab');
};

subtest 'Get devices zeigt auch leere Gruppen' => sub {
	reset_env();
	add_iodev('server');
	my ($hash, $error) = define_discovery('discovery', 'server');
	is($error, undef, 'Discovery ohne MQTT2_DEVICEs wird definiert');
	$main::attr{global}{language} = 'DE';
	my $html = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'devices');
	like($html, qr/Verwaltet \(0\)/, 'leere verwaltete Gruppe bleibt sichtbar');
	like($html, qr/Nicht verwaltet \(0\)/, 'leere nicht verwaltete Gruppe bleibt sichtbar');
	is(() = $html =~ /Keine Devices/g, 2, 'beide leeren Gruppen erklaeren ihren Zustand');
};

subtest 'Get devices reserviert Direktnamen vor dem CID-Rename-Fallback' => sub {
	reset_env();
	my $server = add_iodev('server');
	my ($hash, $error) = define_discovery('discovery', 'server');
	is($error, undef, 'Discovery fuer den CID-Reihenfolgetest wird definiert');

	# Beide Devices teilen absichtlich dieselbe CID; nur der aktuelle Direktname
	# macht das verbleibende umbenannte Device anschliessend eindeutig.
	for my $name (qw(Current.Device Renamed.Device)) {
		$main::defs{$name} = {
			NAME => $name, TYPE => 'MQTT2_DEVICE', IODev => $server,
			CID => 'shared-cid', DEF => 'shared-cid', READINGS => {},
		};
	}

	FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} = {
		a_stale => {
			name => 'Old.Device', created => 1, io => 'server',
			cid => 'shared-cid', entities => {},
		},
		z_current => {
			name => 'Current.Device', created => 1, io => 'server',
			cid => 'shared-cid', entities => {},
		},
	};

	my ($managed, $unmanaged) = FHEM::MQTT2_DISCOVERY::device_groups($hash);
	is($managed, ['Current.Device', 'Renamed.Device'],
		'Direktname und danach eindeutiger Rename-Fallback sind verwaltet');
	is($unmanaged, [], 'kein Registry-Ziel bleibt wegen der Identity-Sortierung uebrig');
};

subtest 'Kontextbezogene Commandref-Hilfe' => sub {
	reset_env();
	add_iodev('server');
	define_discovery('discovery', 'server');

	open my $module_file, '<', 'FHEM/10_MQTT2_DISCOVERY.pm'
		or die "Moduldatei kann nicht gelesen werden: $!";
	my $commandref = do { local $/; <$module_file> };
	close $module_file;
	for my $anchor (qw(
		MQTT2_DISCOVERY-get-devices
		MQTT2_DISCOVERY-set-activate MQTT2_DISCOVERY-set-deactivate
		MQTT2_DISCOVERY-set-rebuildDevice MQTT2_DISCOVERY-set-rescan
		MQTT2_DISCOVERY-attr-discoveryPrefixes MQTT2_DISCOVERY-attr-deviceNamePrefix
		MQTT2_DISCOVERY-attr-existingDevice MQTT2_DISCOVERY-attr-autoCreate
		MQTT2_DISCOVERY-attr-autoDelete MQTT2_DISCOVERY-attr-createReadings
		MQTT2_DISCOVERY-attr-extraJsonReadings MQTT2_DISCOVERY-attr-keys
		MQTT2_DISCOVERY-attr-disable
	)) {
		like($commandref, qr/id="\Q$anchor\E"/, "$anchor ist dokumentiert");
	}
};

subtest 'Attributvalidierung' => sub {
	reset_env();
	add_iodev('server');
	define_discovery('discovery', 'server');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant, ha,homeassistant'), undef, 'mehrere Prefixe sind gueltig');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant,,ha'), qr/nicht leer/, 'leerer Prefix wird abgelehnt');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant/#'), qr/Ungueltiger/, 'Wildcard wird abgelehnt');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'existingDevice', 'replace'), undef, 'replace ist gueltig');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'existingDevice', 'force'), qr/muss/, 'unbekannter Modus wird abgelehnt');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'extraJsonReadings', 'ignore'), undef,
		'extraJsonReadings=ignore ist gueltig');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'extraJsonReadings', 'strict'), qr/include oder ignore/,
		'extraJsonReadings akzeptiert nur die beiden dokumentierten Modi');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'autoDelete', 'yes'), qr/0 oder 1/, 'Boolean wird validiert');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'createReadings', '1'), undef,
		'createReadings=1 ist gueltig');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'createReadings', 'unknown'), qr/0 oder 1/,
		'createReadings akzeptiert nur Boolean-Werte');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'deviceNamePrefix', 'MQTT2_'), undef, 'sicherer Device-Prefix ist gueltig');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'deviceNamePrefix', 'bad prefix'), qr/darf nur/, 'Leerzeichen im Device-Prefix werden abgelehnt');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'deviceNamePrefix', '2bad'), qr/beginnen/, 'ungueltiger Anfang im Device-Prefix wird abgelehnt');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'disable', 'yes'), qr/0 oder 1/, 'disable wird validiert');
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'disable', '1'), undef, 'disable=1 ist gueltig');
	is(reading_value('discovery', 'state'), 'disabled', 'disable=1 wird im Status sichtbar');
	is(FHEM::MQTT2_DISCOVERY::Attr('del', 'discovery', 'disable'), undef, 'disable kann geloescht werden');
	is(reading_value('discovery', 'state'), 'inactive', 'Loeschen stellt den Parserstatus wieder her');
};

subtest 'sicher vorhersagbare Reading-Namen' => sub {
	is(FHEM::MQTT2_DISCOVERY::expected_reading_names([
		{ kind => 'reading', name => 'state' },
		{ kind => 'json_reading', name => 'temperature' },
		{ kind => 'json_autocreate', name => 'POWER', json_key => 'POWER' },
		{ kind => 'json_autocreate', name => 'RESULT' },
		{ kind => 'json_sequence', name => 'INFO' },
		{ kind => 'device_automation_group', name => 'action' },
		{ kind => 'reading', name => '.internal' },
		{ kind => 'availability', role => 'availability', name => 'availability' },
	]), [qw(POWER action state temperature)],
		'explizite Readings sind bekannt, dynamische und technische Namen bleiben aus');
};

subtest 'gespeichertes disable gilt bereits beim Define' => sub {
	reset_env();
	add_iodev('server');
	$main::attr{startupDiscovery}{disable} = 1;
	my ($hash, $error) = define_discovery('startupDiscovery', 'server');
	is($error, undef, 'Device wird mit vorhandenem disable-Attribut definiert');
	is(reading_value('startupDiscovery', 'state'), 'disabled', 'Startzustand ist disabled');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'startupDiscovery', 'activate'), undef,
		'Parserposition kann trotz disable vorbereitet werden');
	is(reading_value('startupDiscovery', 'state'), 'disabled', 'activate umgeht disable nicht');
};

subtest 'activate und deactivate erhalten fremde Clients' => sub {
	reset_env();
	my $io = add_iodev('server');
	$io->{Clients} = ':CUSTOM:MQTT2_DEVICE:MQTT_GENERIC_BRIDGE:';
	my ($hash) = define_discovery('discovery', 'server');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'activate'), undef, 'activate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DISCOVERY MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'Discovery wird vor MQTT2_DEVICE eingefuegt');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'activate'), undef, 'zweites activate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DISCOVERY MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'activate ist idempotent');
	is(reading_value('discovery', 'state'), 'active', 'Status ist active');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deactivate'), undef, 'deactivate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'nur eigener Eintrag wird entfernt');
};

subtest 'passendes IODev-ignoreRegexp wird einmalig geloggt' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	$main::attr{client}{ignoreRegexp} = 'homeassistant/[^:"]+/config';
	my ($client_hash, $client_error) = define_discovery('clientDiscovery', 'client');
	is($client_error, undef, 'Client-Discovery wird mit gespeichertem Filter definiert');
	like(reading_value('clientDiscovery', 'lastWarning'),
		qr/IODev client blockiert Discovery-Topic homeassistant\/sensor\/example\/config/,
		'Warnungsreading nennt IODev und blockiertes Beispieltopic');
	my @client_warnings = grep {
		$_->[2] =~ /ignoreRegexp am IODev client blockiert Discovery-Topic/
	} @{ log_entries() };
	is(scalar(@client_warnings), 1, 'Define schreibt genau eine Filterwarnung ins Log');
	is($client_warnings[0][1], 2, 'Filterwarnung verwendet die sichtbare Logstufe 2');
	like($client_warnings[0][2], qr/regexp=homeassistant\/\[\^:"\]\+\/config/,
		'Logmeldung enthaelt die verursachende ignoreRegexp');

	# INITIALIZED prueft gespeicherte Attribute erneut, darf dieselbe Warnung
	# innerhalb desselben Laufs jedoch nicht vervielfachen.
	FHEM::MQTT2_DISCOVERY::Notify($client_hash, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	@client_warnings = grep {
		$_->[2] =~ /ignoreRegexp am IODev client blockiert Discovery-Topic/
	} @{ log_entries() };
	is(scalar(@client_warnings), 1, 'INITIALIZED dupliziert dieselbe Logmeldung nicht');

	reset_env();
	add_iodev('server', 'MQTT2_SERVER');
	my ($server_hash, $server_error) = define_discovery('serverDiscovery', 'server');
	is($server_error, undef, 'Server-Discovery startet ohne Filterwarnung');
	$main::attr{server}{ignoreRegexp} = 'tasmota/discovery/.+/sensors';
	FHEM::MQTT2_DISCOVERY::Notify($server_hash, {
		NAME => 'global',
		CHANGED => ['ATTR server ignoreRegexp tasmota/discovery/.+/sensors'],
	});
	my @server_warnings = grep {
		$_->[2] =~ /ignoreRegexp am IODev server blockiert Discovery-Topic/
	} @{ log_entries() };
	is(scalar(@server_warnings), 1, 'spaetere IODev-Attributaenderung wird sofort geloggt');
	like($server_warnings[0][2], qr{tasmota/discovery/001122AABBCC/sensors},
		'Tasmota-sensors wird als konkret blockiertes Beispieltopic genannt');
};

subtest 'Rescan-Grenzen' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	my ($client_hash) = define_discovery('clientDiscovery', 'client');
	like(FHEM::MQTT2_DISCOVERY::Set($client_hash, 'clientDiscovery', 'rescan'), qr/keinen lokalen Retain-Cache/, 'Client meldet ehrliche Grenze');

	my $server = add_iodev('server', 'MQTT2_SERVER');
	$server->{retain}{'homeassistant/sensor/node/temp/config'} = {
		val => '{"stat_t":"node/temp","uniq_id":"temp","dev":{"ids":["node"],"name":"Node"}}',
	};
	$server->{retain}{'homeassistant/sensor/node/humidity/config'} = {
		val => '{"stat_t":"node/humidity","uniq_id":"humidity","dev":{"ids":["node"],"name":"Node"}}',
	};
	my ($server_hash) = define_discovery('serverDiscovery', 'server');
	my $before_rescan = scalar @{ command_log() };
	is(FHEM::MQTT2_DISCOVERY::Set($server_hash, 'serverDiscovery', 'rescan'), undef, 'Server-Rescan verarbeitet Cache');
	my @rescan_commands = @{ command_log() }[$before_rescan .. $#{ command_log() }];
	is(reading_value('serverDiscovery', 'discoveredEntities'), 2, 'Rescan hat beide Entities registriert');
	is(reading_value('serverDiscovery', 'lastRescan'), 'processed=2 failed=0', 'Rescan-Ergebnis ist nachvollziehbar');
	is(scalar(grep { /^attr Node readingList / } @rescan_commands), 1,
		'Rescan schreibt readingList pro Zieldevice nur einmal');

	$main::attr{serverDiscovery}{disable} = 1;
	like(FHEM::MQTT2_DISCOVERY::Set($server_hash, 'serverDiscovery', 'rescan'), qr/deaktiviert/,
		'deaktiviertes Modul fuehrt keinen Rescan aus');
};

subtest 'Rescan verarbeitet retained Tasmota config und sensors gemeinsam' => sub {
	reset_env();
	my $server = add_iodev('server', 'MQTT2_SERVER');
	$server->{retain}{'tasmota/discovery/AABBCCDDEEFF/config'} = {
		val => '{"dn":"Retained Plug","fn":["Relay"],"mac":"AABBCCDDEEFF","t":"retained_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"state":["OFF","ON"],"so":{"4":0},"ver":1}',
	};
	$server->{retain}{'tasmota/discovery/AABBCCDDEEFF/sensors'} = {
		val => '{"sn":{"ENERGY":{"Power":18,"Voltage":229}},"ver":1}',
	};
	my ($hash, $error) = define_discovery('tasmotaDiscovery', 'server');
	is($error, undef, 'Tasmota-Discovery wird definiert');

	my $before_rescan = scalar @{ command_log() };
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'tasmotaDiscovery', 'rescan'), undef,
		'Server-Rescan verarbeitet beide Tasmota-Topics');
	my @rescan_commands = @{ command_log() }[$before_rescan .. $#{ command_log() }];

	ok($main::defs{Retained_Plug_Relay}, 'retained Tasmota-Discovery verwendet standardmaessig keinen Prefix');
	is(reading_value('tasmotaDiscovery', 'discoveredEntities'), 3,
		'Relay und beide Telemetriesensoren sind registriert');
	is(reading_value('tasmotaDiscovery', 'lastRescan'), 'processed=2 failed=0',
		'beide retained Tasmota-Nachrichten wurden erfolgreich verarbeitet');
	is(scalar(grep { /^attr Retained_Plug_Relay readingList / } @rescan_commands), 1,
		'Tasmota-Rescan schreibt die finale readingList nur einmal');
	is(scalar(grep { /^attr Retained_Plug_Relay setList / } @rescan_commands), 1,
		'Tasmota-Rescan schreibt die finale setList nur einmal');
};

subtest 'Tasmota-Neuaufbau und echtes Delete verwenden getrennte Logstufen' => sub {
	reset_env();
	add_iodev('server', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('tasmotaDiscovery', 'server');
	is($error, undef, 'Tasmota-Discovery wird definiert');
	$main::attr{tasmotaDiscovery}{verbose} = 4;
	my $topic = 'tasmota/discovery/AABBCCDDEEFF/config';
	my $payload = '{"dn":"Log Plug","fn":["Relay"],"mac":"AABBCCDDEEFF",'
		. '"t":"log_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],'
		. '"rl":[1],"state":["OFF","ON"],"so":{"4":0},"ver":1}';
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'tasmota', $topic, $payload),
		'consumed', 'Ausgangsmodell wird angelegt');

	@{ log_entries() } = ();
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'tasmota', $topic, $payload),
		'consumed', 'identisches Tasmota-Modell wird intern neu aufgebaut');
	my @rebuild_logs = grep {
		$_->[2] =~ /temporarily removed .* during internal rebuild/
	} @{ log_entries() };
	is(scalar(@rebuild_logs), 1, 'interner Neuaufbau erzeugt genau eine Loeschmeldung');
	is($rebuild_logs[0][1], 4, 'interner Neuaufbau wird nur auf Level 4 protokolliert');
	ok(!grep({ $_->[1] == 2 && $_->[2] =~ /removed .* discovery entity/ } @{ log_entries() }),
		'interner Neuaufbau erzeugt keine sichtbare Level-2-Loeschmeldung');

	@{ log_entries() } = ();
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'tasmota', $topic, ''),
		'consumed', 'leerer Config-Payload wird als echtes Delete verarbeitet');
	my @delete_logs = grep {
		$_->[2] =~ /removed .* discovery entity\/entities from Log_Plug_Relay/
	} @{ log_entries() };
	is(scalar(@delete_logs), 1, 'echtes Delete erzeugt genau eine Loeschmeldung');
	is($delete_logs[0][1], 2, 'echtes Delete bleibt auf Level 2 sichtbar');
};

subtest 'rebuildDevice ersetzt beide Listen unabhaengig vom Bestandsmodus' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"node/state","cmd_t":"node/set","uniq_id":"node_power",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'client', 'homeassistant/switch/node/power/config', $payload,
		), 'consumed', 'Ausgangs-Discovery wird verarbeitet');
	my $generated_reading = attr_value('Node', 'readingList');
	my $generated_set = attr_value('Node', 'setList');
	my $device_topic = attr_value('Node', 'devicetopic');
	$main::attr{Node}{room} = 'Manuell';
	$main::defs{Node}{READINGS}{state} = {
		VAL => 'ON', TIME => '2026-08-18 12:00:00',
	};

	# Jeder normale Bestandsmodus wird fuer den ausdruecklichen Listen-Neuaufbau ignoriert.
	for my $mode (qw(conservative ignore replace)) {
		$main::attr{discovery}{existingDevice} = $mode;
		$main::attr{Node}{readingList}
			= "$generated_reading\nmanual/topic:.* manual";
		$main::attr{Node}{setList}
			= "$generated_set\nmanualSet:noArg manual/topic 1";
		is(FHEM::MQTT2_DISCOVERY::Set(
				$hash, 'discovery', 'rebuildDevice', 'Node',
			), undef, "rebuildDevice ist im Modus $mode erfolgreich");
		is(attr_value('Node', 'readingList'), $generated_reading,
			"readingList enthaelt im Modus $mode nur generierte Zeilen");
		is(attr_value('Node', 'setList'), $generated_set,
			"setList enthaelt im Modus $mode nur generierte Zeilen");
	}

	is(attr_value('Node', 'devicetopic'), $device_topic,
		'devicetopic wird beim Listen-Neuaufbau erneut aus Discovery abgeleitet');
	is(attr_value('Node', 'room'), 'Manuell',
		'andere manuelle Attribute bleiben unveraendert');
	is(reading_value('Node', 'state'), 'ON',
		'vorhandene Readingwerte bleiben unveraendert');
	like(FHEM::MQTT2_DISCOVERY::Set(
			$hash, 'discovery', 'rebuildDevice', 'Unmanaged',
		), qr/nicht verwaltet/, 'nicht verwaltete Devices werden abgelehnt');

	$main::defs{Node}{READINGS}{manualReading} = {
		VAL => 'alt', TIME => '2026-08-18 12:00:00',
	};
	$main::defs{Node}{READINGS}{'.internal'} = {
		VAL => 'keep', TIME => '2026-08-18 12:00:00',
	};
	my $availability = FHEM::MQTT2_DISCOVERY::availability_reading($hash);
	is(FHEM::MQTT2_DISCOVERY::Set(
			$hash, 'discovery', 'rebuildDevice', 'Node', 'clearReadings',
		), undef, 'clearReadings ist nach erfolgreichem Listen-Neuaufbau erfolgreich');
	ok(!exists($main::defs{Node}{READINGS}{state}),
		'vorhandenes Nutzdaten-Reading wird geloescht');
	ok(!exists($main::defs{Node}{READINGS}{manualReading}),
		'manuell angelegtes sichtbares Reading wird ebenfalls geloescht');
	is($main::defs{Node}{READINGS}{'.internal'}{VAL}, 'keep',
		'verstecktes technisches Reading bleibt erhalten');
	ok(exists($main::defs{Node}{READINGS}{$availability}),
		'Availability wird nach dem Loeschen neu synchronisiert');
	is(attr_value('Node', 'readingList'), $generated_reading,
		'clearReadings veraendert die neu erzeugte readingList nicht');
	is(attr_value('Node', 'setList'), $generated_set,
		'clearReadings veraendert die neu erzeugte setList nicht');
	like(FHEM::MQTT2_DISCOVERY::Set(
			$hash, 'discovery', 'rebuildDevice', 'Node', 'clear',
		), qr/Unknown argument/, 'unbekannte Rebuild-Optionen werden abgelehnt');
};

subtest 'rebuildDevice normalisiert devicetopic eines uebernommenen Devices' => sub {
	reset_env();
	my $io = add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::defs{Node} = {
		NAME => 'Node', TYPE => 'MQTT2_DEVICE', CID => 'client', DEF => 'client',
		IODev => $io, READINGS => {},
	};
	push @{ $main::modules{MQTT2_DEVICE}{defptr}{cid}{client} }, $main::defs{Node};
	$main::attr{Node}{devicetopic} = 'root';
	my $payload = '{"stat_t":"root/node/state","cmd_t":"root/node/set","uniq_id":"node_power",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'client', 'homeassistant/switch/node/power/config', $payload,
		), 'consumed', 'bestehendes MQTT2_DEVICE wird uebernommen');
	my ($record) = values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	is($record->{created}, 0, 'Registry kennzeichnet das Ziel als uebernommenes Device');
	is($record->{owned_devicetopic}, undef,
		'bestehendes devicetopic gehoert vor dem Neuaufbau nicht dem Modul');
	is(attr_value('Node', 'devicetopic'), 'root',
		'normale Discovery erhaelt das gueltige breitere Bestands-devicetopic');
	like(attr_value('Node', 'readingList'), qr{^\$DEVICETOPIC/node/state:}m,
		'Bestands-devicetopic wird vor dem Neuaufbau in der readingList beruecksichtigt');
	like(attr_value('Node', 'setList'), qr{\$DEVICETOPIC/node/set},
		'Bestands-devicetopic wird vor dem Neuaufbau in der setList beruecksichtigt');

	is(FHEM::MQTT2_DISCOVERY::Set(
			$hash, 'discovery', 'rebuildDevice', 'Node',
		), undef, 'rebuildDevice normalisiert das uebernommene Device');
	is(attr_value('Node', 'devicetopic'), 'root/node',
		'das tiefste gemeinsame Discovery-Prefix ersetzt das Bestands-devicetopic');
	like(attr_value('Node', 'readingList'), qr{^\$DEVICETOPIC/state:}m,
		'readingList wird relativ zum normalisierten devicetopic erzeugt');
	unlike(attr_value('Node', 'readingList'), qr{^\$DEVICETOPIC/node/}m,
		'readingList enthaelt keinen Rest des vorherigen devicetopic-Prefixes');
	like(attr_value('Node', 'setList'), qr{\$DEVICETOPIC/set},
		'setList wird relativ zum normalisierten devicetopic erzeugt');
	is($record->{owned_devicetopic}, 'root/node',
		'die Registry uebernimmt das normalisierte devicetopic als modulverwaltet');
};

subtest 'rebuildDevice rollt einen unvollstaendigen ActionPlan sofort zurueck' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"root/node/state","cmd_t":"root/node/set","uniq_id":"node_power",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	FHEM::MQTT2_DISCOVERY::process(
		$hash, 'client', 'homeassistant/switch/node/power/config', $payload,
	);
	$main::attr{Node}{devicetopic} = 'root';
	$main::attr{Node}{readingList} .= "\nmanual/topic:.* manual";
	$main::attr{Node}{setList} .= "\nmanualSet:noArg manual/topic 1";
	$main::defs{Node}{READINGS}{manualReading} = {
		VAL => 'alt', TIME => '2026-08-18 12:00:00',
	};
	my $old_device_topic = attr_value('Node', 'devicetopic');
	my $old_reading = attr_value('Node', 'readingList');
	my $old_set = attr_value('Node', 'setList');
	my ($record) = values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	my $old_owned_device_topic = $record->{owned_devicetopic};
	my $old_owned_reading = [ @{ $record->{owned_reading} } ];
	my $old_owned_set = [ @{ $record->{owned_set} } ];
	my $command_attr = \&main::CommandAttr;

	# Der simulierte setList-Fehler tritt erst nach der readingList-Aenderung auf.
	{
		no warnings 'redefine';
		local *main::CommandAttr = sub {
			my (undef, $definition) = @_;
			return 'simulierter setList-Fehler' if $definition =~ /^Node setList /;
			return $command_attr->(@_);
		};
		like(FHEM::MQTT2_DISCOVERY::Set(
				$hash, 'discovery', 'rebuildDevice', 'Node', 'clearReadings',
			), qr/simulierter setList-Fehler/, 'ActionPlan-Fehler wird zurueckgegeben');
	}
	is(attr_value('Node', 'devicetopic'), $old_device_topic,
		'vorheriges devicetopic wurde sofort wiederhergestellt');
	is(attr_value('Node', 'readingList'), $old_reading,
		'bereits geaenderte readingList wurde sofort wiederhergestellt');
	is(attr_value('Node', 'setList'), $old_set,
		'fehlgeschlagene setList blieb unveraendert');
	is($record->{owned_reading}, $old_owned_reading,
		'Reading-Besitz wurde nach dem Rollback nicht umgestellt');
	is($record->{owned_set}, $old_owned_set,
		'Set-Besitz wurde nach dem Rollback nicht umgestellt');
	is($record->{owned_devicetopic}, $old_owned_device_topic,
		'devicetopic-Besitz wurde nach dem Rollback nicht umgestellt');
	is($main::defs{Node}{READINGS}{manualReading}{VAL}, 'alt',
		'Readings werden bei fehlgeschlagenem ActionPlan nicht geloescht');
};

subtest 'Bestandsmodi und autoCreate' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::attr{discovery}{autoCreate} = 0;
	my $payload = '{"stat_t":"node/state","cmd_t":"node/set","uniq_id":"node_power","dev":{"ids":["node"],"name":"Node"}}';
	FHEM::MQTT2_DISCOVERY::process($hash, 'c', 'homeassistant/switch/node/power/config', $payload);
	ok(!$main::defs{Node}, 'autoCreate=0 legt kein Device an');
	like(reading_value('discovery', 'lastError'), qr/autoCreate/, 'autoCreate-Konflikt ist sichtbar');

	reset_env();
	add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::defs{Node} = { NAME => 'Node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{discovery}{existingDevice} = 'ignore';
	FHEM::MQTT2_DISCOVERY::process($hash, 'c', 'homeassistant/switch/node/power/config', $payload);
	like(reading_value('discovery', 'lastError'), qr/ignore-Modus/, 'ignore veraendert bestehendes Device nicht');
	ok(!attr_value('Node', 'setList'), 'ignore erzeugt keine Attribute');

	reset_env();
	add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::defs{Node} = { NAME => 'Node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{Node}{setList} = "power:on,off manual/topic value\nreboot:noArg manual/reboot 1";
	$main::attr{discovery}{existingDevice} = 'replace';
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'c', 'homeassistant/switch/node/power/config', $payload), 'consumed', 'replace uebernimmt vorhandenes MQTT2_DEVICE');
	like(attr_value('Node', 'setList'), qr/reboot:noArg manual\/reboot 1/, 'replace erhaelt nicht kollidierende manuelle Zeile');
	unlike(attr_value('Node', 'setList'), qr/manual\/topic/, 'replace ersetzt kollidierende manuelle Zeile');
};

subtest 'FHEM-Autocreate-Identitaet folgt CID und bridgeRegexp statt Device-Name' => sub {
	my $payload = '{"stat_t":"sonos/state","cmd_t":"sonos/set","uniq_id":"sonos_power","dev":{"ids":["sonos"],"name":"Neuer Anzeigename"}}';

	reset_env();
	my $io = add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::defs{'Sonos.Wintergarten'} = {
		NAME => 'Sonos.Wintergarten', TYPE => 'MQTT2_DEVICE',
		CID => 'RINCON_804AF2CB96C201400', DEF => 'RINCON_804AF2CB96C201400',
		IODev => $io, READINGS => {},
	};
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'RINCON_804AF2CB96C201400',
		'homeassistant/switch/sonos/power/config', $payload,
	), 'consumed', 'vorhandene FHEM-CID wird unabhaengig vom Namen erkannt');
	ok(!$main::defs{Neuer_Anzeigename}, 'kein zweites Device aus dem Discovery-Namen angelegt');
	like(attr_value('Sonos.Wintergarten', 'setList'), qr/sonos\/set/,
		'Discovery erweitert das vorhandene CID-Device konservativ');

	my $old_name = 'Sonos.Wintergarten';
	my $new_name = 'Audio.Wintergarten';
	my $renamed = delete $main::defs{$old_name};
	$renamed->{NAME} = $new_name;
	$main::defs{$new_name} = $renamed;
	$main::attr{$new_name} = delete($main::attr{$old_name}) || {};
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'RINCON_804AF2CB96C201400',
		'homeassistant/switch/sonos/power/config', $payload,
	), 'consumed', 'umbenanntes MQTT2_DEVICE wird ueber seine CID wiedergefunden');
	is($hash->{helper}{registry}{devices}{'server|id|sonos'}{name}, $new_name,
		'Registry uebernimmt den aktuellen FHEM-Namen');
	ok(!$main::defs{$old_name} && !$main::defs{Neuer_Anzeigename},
		'Rename erzeugt kein weiteres Device');

	reset_env();
	$io = add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::modules{MQTT2_DEVICE}{defptr}{bridge} = {
		'zigbee2mqtt/([^/:]+)(?:/[^:]*)?:.*' => {
			name => '"zigbee_" . $1', parent => 'zigbee2mqtt',
		},
	};
	my $zigbee_payload = '{"stat_t":"zigbee2mqtt/0x00124b/state","uniq_id":"z2m_temp","dev":{"ids":["z2m_0x00124b"],"name":"Temperatursensor"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'zigbee2mqtt',
		'homeassistant/sensor/z2m_0x00124b/temperature/config', $zigbee_payload,
	), 'consumed', 'bridgeRegexp wird auf das Discovery-State-Topic angewandt');
	is($main::defs{Temperatursensor}{DEF}, 'zigbee_0x00124b',
		'virtuelle Bridge-CID wird wie beim FHEM-Autocreate als DEF verwendet');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{'zigbee_0x00124b'},
		[$main::defs{Temperatursensor}],
		'Bridge-Unterdevice ist unter derselben newCid registriert, die FHEM spaeter prueft');
};

subtest 'MQTT2_CLIENT erhaelt stabile virtuelle Discovery-CIDs' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	my ($hash) = define_discovery('discovery', 'client');
	my $node = '{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}';
	my $other = '{"stat_t":"other/state","uniq_id":"other_state","dev":{"ids":["other"],"name":"Other"}}';

	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'shared_client', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'erstes Client-Device wird verarbeitet');
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'shared_client', 'homeassistant/sensor/other/state/config', $other,
	), 'consumed', 'zweites Client-Device wird verarbeitet');

	my $node_cid = $main::defs{Node}{DEF};
	my $other_cid = $main::defs{Other}{DEF};
	like($node_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'Client-Device verwendet eine erkennbare virtuelle CID');
	like($other_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'zweites Client-Device verwendet ebenfalls eine virtuelle CID');
	isnt($node_cid, $other_cid, 'unterschiedliche Discovery-Identitaeten teilen keine CID');
	ok(!$main::modules{MQTT2_DEVICE}{defptr}{cid}{shared_client},
		'gemeinsame MQTT2_CLIENT-Transport-CID registriert kein Discovery-Ziel');

	my $first_cid = $node_cid;
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'changed_transport', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'wiederholte Discovery bleibt trotz anderer Transport-CID gueltig');
	is($main::defs{Node}{DEF}, $first_cid,
		'virtuelle CID bleibt aus der stabilen Discovery-Identitaet reproduzierbar');

	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	($hash) = define_discovery('discovery', 'client');
	$main::modules{MQTT2_DEVICE}{defptr}{bridge} = {
		'node/state:.*' => { name => '"bridge_node"', parent => 'general_bridge' },
	};
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'shared_client', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'Client-Discovery mit passender Bridge-Regel wird verarbeitet');
	is($main::defs{Node}{DEF}, 'bridge_node',
		'vorhandene bridgeRegexp besitzt Vorrang vor der gehashten Fallback-CID');

	reset_env();
	add_iodev('server', 'MQTT2_SERVER');
	($hash) = define_discovery('discovery', 'server');
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, '', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'Discovery ohne Transport-CID wird verarbeitet');
	like($main::defs{Node}{DEF}, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'fehlende Server-CID verwendet denselben sicheren Identity-Fallback');
};

subtest 'optionales SemanticUI-Fertig-Signal folgt dem Device-Aufbau' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my @integration;
	my $payload = '{"stat_t":"node/state","cmd_t":"node/set","uniq_id":"node_power","dev":{"ids":["node"],"name":"Node"}}';
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		semantic_integration_end => sub {
			my ($name) = @_;
			push @integration, [
				'end', $name,
				attr_value($name, 'readingList') ? 1 : 0,
				attr_value($name, 'setList') ? 1 : 0,
				$main::defs{$name}{SEMANTIC_METADATA} ? 1 : 0,
			];
			return 1;
		},
	);
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'c', 'homeassistant/switch/node/power/config', $payload,
	), 'consumed', 'Discovery mit optionaler SemanticUI-Schnittstelle ist erfolgreich');
	is(\@integration, [
		['end', 'Node', 1, 1, 1],
	], 'Fertig-Signal folgt erst auf Attribute und Metadaten');
};

subtest 'Registry roundtrippt als nicht ausfuehrbares JSON' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"node/state","uniq_id":"node_state","unit_of_meas":"\\u00b0C","dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'c', 'homeassistant/sensor/node/state/config', $payload),
		'consumed', 'Unicode-Metadaten werden verarbeitet');
	my $stored = reading_value('discovery', '.registry');
	like($stored, qr/^\{/, 'Registry ist JSON');
	delete $hash->{helper}{registry};
	my $restored = FHEM::MQTT2_DISCOVERY::registry($hash);
	is($restored->{version}, 1, 'Registry wird aus Reading wiederhergestellt');
	is(scalar keys %{ $restored->{devices} }, 1, 'Registry mit Unicode bleibt beim Roundtrip erhalten');
	my ($record) = values %{ $restored->{devices} };
	my ($mapping) = values %{ $record->{entities} };
	is($mapping->{metadata}{unit}, "\x{b0}C", 'Unicode-Zeichenstring bleibt unveraendert');

	my $stored_bytes = $stored;
	utf8::encode($stored_bytes);
	$hash->{READINGS}{'.registry'}{VAL} = $stored_bytes;
	delete $hash->{helper}{registry};
	my $restored_bytes = FHEM::MQTT2_DISCOVERY::registry($hash);
	($record) = values %{ $restored_bytes->{devices} };
	($mapping) = values %{ $record->{entities} };
	is($mapping->{metadata}{unit}, "\x{b0}C", 'UTF-8-Bytefolge bleibt nach Neustart unveraendert');

	# FHEMs Standardmodus bytestream schreibt Zeichen bis U+00FF als einzelne
	# Bytes ins statefile. Auch dieser reale Neustartfall muss lesbar bleiben.
	my $stored_bytestream = $stored;
	utf8::downgrade($stored_bytestream, 1);
	$hash->{READINGS}{'.registry'}{VAL} = $stored_bytestream;
	delete $hash->{helper}{registry};
	my $restored_bytestream = FHEM::MQTT2_DISCOVERY::registry($hash);
	($record) = values %{ $restored_bytestream->{devices} };
	($mapping) = values %{ $record->{entities} };
	is($mapping->{metadata}{unit}, "\x{b0}C",
		'bytestream-Ein-Byte-Zeichen bleibt nach Neustart unveraendert');
};

subtest 'Device-Availability verdichtet Entity-Regeln ohne falsches Offline' => sub {
	is(FHEM::MQTT2_DISCOVERY::device_availability_status(
			[qw(online offline unknown)]), 'online',
		'mindestens eine verfuegbare Entity haelt das zusammengefasste Device online');
	is(FHEM::MQTT2_DISCOVERY::device_availability_status(
			[qw(offline offline)]), 'offline',
		'ausschliesslich ausgefallene Entities setzen das Device offline');
	is(FHEM::MQTT2_DISCOVERY::device_availability_status(
			[qw(offline unknown)]), 'unknown',
		'eine unbekannte Entity verhindert einen unbelegten Deviceausfall');
	is(FHEM::MQTT2_DISCOVERY::device_availability_status([]), 'unknown',
		'ohne Entity-Regel ist die Verdichtung selbst unbekannt');
};

subtest 'IODev-Verbindung ueberlagert alle verwalteten Availability-Zustaende' => sub {
	reset_env();
	my $client = add_iodev('client', 'MQTT2_CLIENT');
	my ($hash, $error) = define_discovery('discovery', 'client');
	is($error, undef, 'Discovery startet an einer geoeffneten Brokerverbindung');
	my $plain = '{"stat_t":"plain/state","uniq_id":"plain_state",'
		. '"dev":{"ids":["plain"],"name":"Plain"}}';
	my $guarded = '{"stat_t":"guarded/state","avty_t":"guarded/availability",'
		. '"uniq_id":"guarded_state","dev":{"ids":["guarded"],'
		. '"name":"Guarded"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'client', 'homeassistant/sensor/plain/state/config', $plain,
	), 'consumed', 'Device ohne eigene Availability wird angelegt');
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'client', 'homeassistant/sensor/guarded/state/config', $guarded,
	), 'consumed', 'Device mit eigener Availability wird angelegt');
	is(reading_value('Plain', '.availability_io'), 'online',
		'Brokerzugang wird intern am verwalteten Device gespeichert');
	is(reading_value('Plain', 'availability'), 'online',
		'Device ohne eigene Regel folgt der offenen Brokerverbindung');
	is(reading_value('Guarded', 'availability'), 'unknown',
		'Device mit noch unbekannter eigener Regel bleibt unknown');
	my $registry = FHEM::MQTT2_DISCOVERY::registry($hash);
	my ($guarded_record) = grep { $_->{name} eq 'Guarded' }
		values %{ $registry->{devices} };
	my $policies = FHEM::MQTT2_DISCOVERY::availability_policies($guarded_record);
	is(scalar(@$policies), 1, 'eigene Availability-Regel ist in der Registry auffindbar');
	$main::defs{Guarded}{READINGS}{ $policies->[0] } = { VAL => 'online' };
	FHEM::MQTT2_DISCOVERY::sync_target_availability($hash, $guarded_record, 1);
	is(reading_value('Guarded', 'availability'), 'online',
		'eigene Online-Regel und Brokerzugang ergeben gemeinsam online');

	$main::defs{Unmanaged} = {
		NAME => 'Unmanaged', TYPE => 'MQTT2_DEVICE', IODev => $client,
		READINGS => { availability => { VAL => 'online' } },
	};
	$client->{STATE} = 'disconnected';
	$client->{READINGS}{state}{VAL} = 'disconnected';
	$client->{CHANGED} = ['state: disconnected'];
	FHEM::MQTT2_DISCOVERY::Notify($hash, $client);
	is(reading_value('Plain', 'availability'), 'offline',
		'Verbindungsverlust setzt ein Device ohne eigene Regel offline');
	is(reading_value('Guarded', 'availability'), 'offline',
		'Verbindungsverlust ueberlagert auch eine eigene Online-Regel');
	is(reading_value('Unmanaged', 'availability'), 'online',
		'nicht von dieser Discovery verwaltete Devices bleiben unveraendert');

	$client->{STATE} = 'opened';
	$client->{READINGS}{state}{VAL} = 'opened';
	$client->{CHANGED} = ['state: opened'];
	FHEM::MQTT2_DISCOVERY::Notify($hash, $client);
	is(reading_value('Plain', 'availability'), 'online',
		'Reconnect setzt ein Device ohne eigene Regel wieder online');
	is(reading_value('Guarded', 'availability'), 'online',
		'Reconnect wertet den erhaltenen eigenen Zustand erneut aus');

	$main::defs{Guarded}{READINGS}{ $policies->[0] }{VAL} = 'offline';
	FHEM::MQTT2_DISCOVERY::sync_target_availability($hash, $guarded_record, 1);
	$client->{STATE} = 'disconnected';
	$client->{READINGS}{state}{VAL} = 'disconnected';
	FHEM::MQTT2_DISCOVERY::Notify($hash, $client);
	$client->{STATE} = 'opened';
	$client->{READINGS}{state}{VAL} = 'opened';
	FHEM::MQTT2_DISCOVERY::Notify($hash, $client);
	is(reading_value('Guarded', 'availability'), 'offline',
		'Reconnect ersetzt einen erhaltenen eigenen Offline-Zustand nicht');

	$main::attr{client}{disable} = 1;
	FHEM::MQTT2_DISCOVERY::Notify($hash, {
		NAME => 'global', CHANGED => ['ATTR client disable 1'],
	});
	is(reading_value('Plain', 'availability'), 'offline',
		'ein globales disable-Attributereignis aktualisiert den IO-Zustand ebenfalls');
};

subtest 'Availability-Topics erhalten deduplizierte Retained-Timer' => sub {
	reset_env();
	my $client = add_iodev('client', 'MQTT2_CLIENT');
	my ($hash, $error) = define_discovery('discovery', 'client');
	is($error, undef, 'Discovery startet am verbundenen MQTT2_CLIENT');
	my (@scheduled, @refreshes);
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		schedule => sub {
			push @scheduled, [@_];
			return;
		},
		refresh_retained_topic => sub {
			push @refreshes, [@_];
			return undef;
		},
	);
	my $payload = '{"stat_t":"node/state","avty":['
		. '{"t":"zigbee2mqtt/node/availability"},'
		. '{"t":"zigbee2mqtt/bridge/state"}],'
		. '"avty_mode":"all","uniq_id":"node_state",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'client', 'homeassistant/sensor/node/state/config', $payload,
	), 'consumed', 'Device mit zwei Availability-Topics wird fertig angewendet');
	is(reading_value('Node', 'availability'), 'unknown',
		'vor dem ersten Availability-Payload ist der sichtbare Zustand unknown');
	is([map { $_->[0] } @scheduled], [60, 60],
		'pro neuem Topic wird genau ein Timer mit 60 Sekunden Verzoegerung angelegt');
	is([map { $_->[2] } @scheduled], [
		\&FHEM::MQTT2_DISCOVERY::refresh_availability_topic,
		\&FHEM::MQTT2_DISCOVERY::refresh_availability_topic,
	], 'beide Timer verwenden den gezielten Availability-Callback');
	my ($record) = values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	is($record->{availability_topics}, [
		'zigbee2mqtt/bridge/state', 'zigbee2mqtt/node/availability',
	], 'angewendete Topics werden fuer spaetere Discovery-Wiederholungen gespeichert');

	# Dieselbe Retained-Discovery darf waehrend der laufenden Timer keinen zweiten
	# Satz Abrufe erzeugen.
	is(FHEM::MQTT2_DISCOVERY::process(
		$hash, 'client', 'homeassistant/sensor/node/state/config', $payload,
	), 'consumed', 'identische Discovery wird erneut verarbeitet');
	is(scalar(@scheduled), 2, 'identische Topics erzeugen keine weiteren Timer');

	# Ein zu frueh laufender Topic-Timer wartet auf den Abschluss des Queue-Batches.
	$hash->{helper}{queue} = { order => [], messages => {}, scheduled => 1 };
	my $first = $scheduled[0];
	$first->[2]->($first->[1]);
	is(scalar(@refreshes), 0, 'laufende Queue verhindert den Brokerabruf');
	is($scheduled[-1][0], 10, 'derselbe Topic-Timer wird kurz zurueckgestellt');
	my $retry = $scheduled[-1];
	delete $hash->{helper}{queue};
	$client->{STATE} = 'disconnected';
	$client->{READINGS}{state}{VAL} = 'disconnected';
	$retry->[2]->($retry->[1]);
	is(scalar(@scheduled), 3, 'getrennter Client erzeugt kein Polling');
	ok($retry->[1]{waiting_for_io}, 'Topic-Timer wartet ereignisbasiert auf den Client');

	# Erst das opened-Ereignis setzt den geparkten Abruf fort.
	$client->{STATE} = 'opened';
	$client->{READINGS}{state}{VAL} = 'opened';
	$client->{CHANGED} = ['state: opened'];
	FHEM::MQTT2_DISCOVERY::Notify($hash, $client);
	is($scheduled[-1][0], 10, 'Reconnect plant den geparkten Abruf einmal neu');
	my $resumed = $scheduled[-1];
	$resumed->[2]->($resumed->[1]);
	is($refreshes[0][1], 'zigbee2mqtt/bridge/state',
		'nach Queue und Reconnect wird genau das erste Topic angefordert');
	my $second = $scheduled[1];
	$second->[2]->($second->[1]);
	is([map { $_->[1] } @refreshes], [
		'zigbee2mqtt/bridge/state', 'zigbee2mqtt/node/availability',
	], 'jeder Topic-Timer fordert nur sein eigenes Retained-Topic an');
	ok(!exists($hash->{helper}{availability_refreshes}),
		'erfolgreiche Abrufe entfernen den vollstaendigen Timerzustand');
};

subtest 'geloeschtes IODev stoppt Arbeit und setzt Registry-Ziele offline' => sub {
	for my $case (
		['client', 'MQTT2_CLIENT', 'ClientTarget'],
		['server', 'MQTT2_SERVER', 'ServerTarget'],
	) {
		my ($io_name, $io_type, $target_name) = @$case;
		reset_env();
		add_iodev($io_name, $io_type);
		my ($hash, $error) = define_discovery('discovery', $io_name);
		is($error, undef, "$io_type wird fuer den Loeschtest definiert");
		my $payload = '{"stat_t":"node/state","uniq_id":"node_state",'
			. '"dev":{"ids":["node"],"name":"' . $target_name . '"}}';
		is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'cid', 'homeassistant/sensor/node/state/config', $payload,
		), 'consumed', "$io_type erzeugt ein verwaltetes Ziel");
		is(reading_value($target_name, 'availability'), 'online',
			"Ziel am $io_type ist vor dem Loeschen online");
		$hash->{helper}{queue} = {
			order => ['pending'], messages => { pending => [] }, scheduled => 1,
		};
		delete $main::defs{$io_name};
		delete $main::attr{$io_name};
		FHEM::MQTT2_DISCOVERY::Notify($hash, {
			NAME => 'global', CHANGED => ["DELETED $io_name"],
		});
		is(reading_value($target_name, '.availability_io'), 'offline',
			"geloeschter $io_type wird als fehlender IO-Zugang gespeichert");
		is(reading_value($target_name, 'availability'), 'offline',
			"geloeschter $io_type setzt sein verwaltetes Ziel offline");
		is(reading_value('discovery', 'state'), 'inactive',
			"Discovery am geloeschten $io_type wird inactive");
		ok(!exists($hash->{helper}{queue}),
			"ausstehende Arbeit des geloeschten $io_type wird verworfen");
		is(FHEM::MQTT2_DISCOVERY::iodev_available($hash), 0,
			"verbliebene Perl-Referenz des $io_type gilt nicht als verfuegbar");
	}
};

subtest 'Registry wird beim Start erst nach dem statefile gecacht' => sub {
	reset_env();
	add_iodev('server');
	my ($running) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}","uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
		$running, 'c', 'homeassistant/sensor/node/temperature/config', $payload,
	), 'consumed', 'Ausgangszustand fuer den simulierten Neustart wird erzeugt');
	my $stored_registry = reading_value('discovery', '.registry');
	my $reading_list = attr_value('Node', 'readingList');
	my $set_list = attr_value('Node', 'setList');
	my $device_topic = attr_value('Node', 'devicetopic');
	my $cid = $main::defs{Node}{DEF};

	# Beim Neustart werden Config-Definitionen vor den Readings des statefile geladen.
	reset_env();
	add_iodev('server');
	main::CommandDefine(undef, "Node MQTT2_DEVICE $cid server");
	$main::attr{Node}{readingList} = $reading_list;
	$main::attr{Node}{setList} = $set_list;
	$main::attr{Node}{devicetopic} = $device_topic;
	$main::init_done = 0;
	my ($restarted, $define_error) = define_discovery('discovery', 'server');
	is($define_error, undef, 'Discovery-Definition waehrend des Starts ist gueltig');
	ok(!exists($restarted->{helper}{registry}),
		'leerer Vor-statefile-Stand wird nicht im Helper gecacht');
	$restarted->{READINGS}{'.registry'} = { VAL => $stored_registry, TIME => '2026-08-22 12:00:00' };
	$main::init_done = 1;

	is(FHEM::MQTT2_DISCOVERY::process(
		$restarted, 'c', 'homeassistant/sensor/node/temperature/config', $payload,
	), 'consumed', 'retained Discovery wird nach INITIALIZED erneut verarbeitet');
	is(attr_value('Node', 'readingList'), $reading_list,
		'komplexe JSON-readingList-Zeile wird nach dem Neustart nicht dupliziert');
	my $registry = FHEM::MQTT2_DISCOVERY::registry($restarted);
	my ($record) = values %{ $registry->{devices} };
	ok($record->{created}, 'urspruenglicher Besitzstatus bleibt aus dem statefile erhalten');
};

subtest 'INITIALIZED synchronisiert restaurierte Ziele mit dem IODev' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	my ($running) = define_discovery('discovery', 'client');
	my $payload = '{"stat_t":"node/state","uniq_id":"node_state",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	is(FHEM::MQTT2_DISCOVERY::process(
		$running, 'client', 'homeassistant/sensor/node/state/config', $payload,
	), 'consumed', 'Ausgangsregistry fuer einen Neustart wird erzeugt');
	my $stored_registry = reading_value('discovery', '.registry');
	my $cid = $main::defs{Node}{DEF};

	# Das statefile folgt beim FHEM-Start auf die Definitionen. INITIALIZED muss
	# deshalb erst den restaurierten Registry-Stand laden und danach synchronisieren.
	reset_env();
	my $client = add_iodev('client', 'MQTT2_CLIENT');
	$client->{STATE} = 'disconnected';
	$client->{READINGS}{state}{VAL} = 'disconnected';
	main::CommandDefine(undef, "Node MQTT2_DEVICE $cid client");
	$main::init_done = 0;
	my ($restarted, $error) = define_discovery('discovery', 'client');
	is($error, undef, 'Discovery wird vor dem statefile erneut definiert');
	$restarted->{READINGS}{'.registry'} = {
		VAL => $stored_registry, TIME => '2026-08-23 12:00:00',
	};
	$main::init_done = 1;
	FHEM::MQTT2_DISCOVERY::Notify($restarted, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(reading_value('Node', '.availability_io'), 'offline',
		'INITIALIZED beruecksichtigt die getrennte Client-Verbindung');
	is(reading_value('Node', 'availability'), 'offline',
		'restauriertes verwaltetes Device wird beim Start offline gesetzt');
};

subtest 'Registry-Klonfehler wird kontrolliert behandelt' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$hash->{helper}{registry}{ungueltig} = sub { return };
	my $status = eval {
		FHEM::MQTT2_DISCOVERY::process(
			$hash, 'c', 'homeassistant/sensor/node/state/config',
			'{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}',
		);
	};
	is($@, '', 'JSON-Exception verlaesst den Verarbeitungsweg nicht');
	is($status, 'error', 'Verarbeitung meldet einen kontrollierten Fehler');
	like(reading_value('discovery', 'lastError'), qr/Registry konnte nicht kopiert werden/,
		'Decoderfehler ist im Reading sichtbar');
	ok(!$main::defs{Node}, 'vor dem Fehler wird kein MQTT2_DEVICE angelegt');
};

subtest 'Unerwartete Verarbeitungsfehler bleiben innerhalb des Moduls' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my ($status, $exception);
	{
		no warnings qw(once redefine);
		local *MQTT2_Discovery::Mapper::map_model = sub { die "simulierter Mapperfehler\n" };
		$status = eval {
			FHEM::MQTT2_DISCOVERY::process(
				$hash, 'c', 'homeassistant/sensor/node/state/config',
				'{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}',
			);
		};
		$exception = $@;
	}
	is($exception, '', 'unerwartete Exception erreicht FHEM nicht');
	is($status, 'error', 'Exception wird in einen kontrollierten Status uebersetzt');
	like(reading_value('discovery', 'lastError'), qr/Unerwarteter Fehler in der MQTT-Verarbeitung/,
		'unerwarteter Fehler ist im Reading sichtbar');
	ok(!$main::defs{Node}, 'fehlgeschlagene Abbildung legt kein Device an');
};

subtest 'Logging- und Registry-Schutz' => sub {
	{
		no warnings qw(once redefine);
		local *FHEM::MQTT2_DISCOVERY::log_redacted = sub { die "simulierter Loggingfehler\n" };
		is(FHEM::MQTT2_DISCOVERY::log_payload('{}'), '<invalid or unloggable JSON; length=2>',
			'Loggingfehler wird durch einen sicheren Platzhalter ersetzt');
	}

	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$hash->{READINGS}{'.registry'}{VAL} = '{"version":1,"devices":{"defekt":"kein Objekt"}}';
	delete $hash->{helper}{registry};
	my $registry = FHEM::MQTT2_DISCOVERY::registry($hash);
	is($registry->{devices}, {}, 'strukturell defekte Registry wird verworfen');
	is(eval { FHEM::MQTT2_DISCOVERY::update_counts($hash); 1 }, 1,
		'Zaehler bleiben bei defekter gespeicherter Registry stabil');
};

subtest 'Discovery-Fehler bleiben ihrem Topic zugeordnet' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'c', 'homeassistant/sensor/node/bad/config', '{'),
		'error', 'defekte HA-Discovery wird abgelehnt');
	is(reading_value('discovery', 'errorCount'), 1, 'Fehlerzaehler wird gesetzt');
	is(reading_value('discovery', 'lastErrorAdapter'), 'homeassistant', 'Adapter ist sichtbar');
	is(reading_value('discovery', 'lastErrorTopic'),
		'homeassistant/sensor/node/bad/config', 'fehlerhaftes Topic ist sichtbar');

	is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'c', 'homeassistant/sensor/node/good/config',
			'{"stat_t":"node/good","dev":{"ids":["node"],"name":"Node"}}'),
		'consumed', 'anderes gueltiges Topic wird verarbeitet');
	is(reading_value('discovery', 'errorCount'), 1,
		'fremder Erfolg verdeckt den bestehenden Fehler nicht');
	isnt(reading_value('discovery', 'lastError'), 'none', 'Fehlerstatus bleibt sichtbar');

	is(FHEM::MQTT2_DISCOVERY::process(
			$hash, 'c', 'homeassistant/sensor/node/bad/config',
			'{"stat_t":"node/bad","dev":{"ids":["node"],"name":"Node"}}'),
		'consumed', 'korrigiertes Topic wird verarbeitet');
	is(reading_value('discovery', 'errorCount'), 0, 'Korrektur entfernt genau diesen Fehler');
	is(reading_value('discovery', 'lastError'), 'none', 'Fehlerstatus ist wieder sauber');
};

subtest 'Logging folgt verbose 1 bis 5 und schwärzt Payloads' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::attr{discovery}{verbose} = 1;
	@{ log_entries() } = ();
	is(FHEM::MQTT2_DISCOVERY::process($hash, 'c', 'homeassistant/sensor/node/temp/config', '{'), 'error',
		'Parserfehler wird verarbeitet');
	is(scalar(@{ log_entries() }), 1, 'verbose 1 schreibt nur den Fehler');
	is(log_entries()->[0][1], 1, 'Fehler verwendet Log-Level 1');
	like(log_entries()->[0][2], qr/MQTT2_DISCOVERY discovery: parser error/, 'Logzeile hat einheitlichen Prefix');

	for my $verbose (2 .. 5) {
		reset_env();
		add_iodev('server');
		($hash) = define_discovery('discovery', 'server');
		$main::attr{discovery}{verbose} = $verbose;
		@{ log_entries() } = ();
		my $payload = '{"stat_t":"node/temp","uniq_id":"temp","password":"very-secret",'
			. '"dev":{"ids":["node"],"name":"Node","api_token":"also-secret"}}';
		is(FHEM::MQTT2_DISCOVERY::process($hash, 'client', 'homeassistant/sensor/node/temp/config', $payload),
			'consumed', "verbose $verbose verarbeitet Discovery");
		ok(!(grep { $_->[1] > $verbose } @{ log_entries() }), "verbose $verbose unterdrueckt hoehere Stufen");

		# Stufe 3 ist in FHEM den ausgefuehrten Befehlen vorbehalten. Eine
		# eingehende Discovery-Nachricht ist keiner; sie meldet auf Stufe 2, was
		# sie angelegt hat, und erklaert sich ab Stufe 4.
		my $expected = $verbose == 3 ? 2 : $verbose;
		ok((grep { $_->[1] == $expected } @{ log_entries() }),
			"verbose $verbose erzeugt Meldungen der erwarteten Stufe");
		ok(!(grep { $_->[2] =~ /processing topic=/ } @{ log_entries() }),
			'die Verarbeitung erklaert sich erst ab Stufe 4') if $verbose < 4;
	}
	my $log = join("\n", map { $_->[2] } @{ log_entries() });
	like($log, qr/discovery payload=/, 'verbose 5 protokolliert den bereinigten Payload');
	like($log, qr/\[REDACTED\]/, 'sensible Felder werden geschwaerzt');
	unlike($log, qr/very-secret|also-secret/, 'Geheimnisse erscheinen nicht im Log');
};

subtest 'keine save-Aufrufe' => sub {
	my $commands = join("\n", @{ command_log() });
	unlike($commands, qr/(?:^|\s)save(?:\s|$)/, 'Testumgebung sah niemals save');
};

done_testing;
