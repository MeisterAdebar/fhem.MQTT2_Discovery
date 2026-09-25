# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Encode ();
use Test2::V0;
use JSON::PP ();
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value command_log);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

my %json_readings = map {
	($_ => q{MQTT2_DISCOVERY_jsonReadings($NAME,'} . $_ . q{',$EVENT)})
} qw(info result sensor state uptime);

# Setzt eine vollstaendig isolierte FHEM-Testumgebung mit Discovery-Device auf.
sub setup {
	my (%args) = @_;
	reset_env();
	add_iodev('mqtt', $args{type} || 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$main::attr{discovery}{discoveryPrefixes} = $args{prefixes} if $args{prefixes};
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_' if !exists $args{device_name_prefix};
	$main::attr{discovery}{deviceNamePrefix} = $args{device_name_prefix}
		if exists($args{device_name_prefix}) && $args{device_name_prefix} ne '';
	$main::attr{discovery}{createReadings} = $args{create_readings}
		if exists $args{create_readings};
	my $activate_error = FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'activate');
	die $activate_error if $activate_error;
	return $hash;
}

# Loest die in einer Attributzeile sichtbare Kurzreferenz aus der persistenten
# Discovery-Registry auf, damit Tests weiterhin deren deklarativen Inhalt pruefen.
sub runtime_descriptor_for_line {
	my ($device, $line) = @_;
	my ($reference) = defined($line) && !ref($line)
		? $line =~ /MQTT2_DISCOVERY_runtimeRef\(\$NAME, '(r_[a-f0-9]+)'/ : ();
	return undef if !defined $reference;
	my $stored = reading_value('discovery', '.registry');
	my $registry = eval { JSON::PP->new->decode($stored) };
	return undef if ref($registry) ne 'HASH' || ref($registry->{devices}) ne 'HASH';

	for my $record (values %{ $registry->{devices} }) {
		next if ref($record) ne 'HASH' || ($record->{name} || '') ne $device
			|| ref($record->{runtime_refs}) ne 'HASH';
		return $record->{runtime_refs}{$reference};
	}

	return undef;
}

# Erzeugt einen typischen HA-Schalterpayload fuer wiederverwendbare Integrationstests.
sub switch_payload {
	my (%args) = @_;
	my $id = $args{id} || 'node';
	my $object = $args{object} || 'power';
	my $state = $args{state} || "$id/$object/state";
	my $command = $args{command} || "$id/$object/set";
	return qq({"name":"$object","uniq_id":"${id}_$object","stat_t":"$state","cmd_t":"$command","pl_on":"1","pl_off":"0","dev":{"ids":["$id"],"name":"Node $id"}});
}

subtest 'klassischer Switch und Dispatch-Konsum' => sub {
	setup();
	my $seen = dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config', switch_payload());
	is($seen, ['MQTT2_DISCOVERY'], 'Discovery wird konsumiert und erreicht MQTT2_DEVICE/Bridge nicht');
	ok($main::defs{MQTT2_Node_node}, 'MQTT2_DEVICE wurde angelegt');
	is($main::defs{MQTT2_Node_node}{DEF}, 'client1',
		'MQTT2_SERVER behaelt die tatsaechlich dispatchte Publisher-CID');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/\$DEVICETOPIC\/state/,
		'readingList verwendet das gemeinsame MQTT2-Devicetopic');
	like(attr_value('MQTT2_Node_node', 'setList'), qr/power:on,off/, 'setList enthaelt Switch-Setter');
	ok(!exists($main::defs{MQTT2_Node_node}{READINGS}{power}),
		'ohne createReadings bleibt das fachliche Reading bis zur ersten State-Nachricht aus');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{confidence}, 0.95,
		'neu angelegtes Device liefert Semantic-Metadaten mit hoher Konfidenz');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{class}, 'switch',
		'Semantic-Klasse wird am Device bereitgestellt');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{capabilities}{power}{write}, 'power',
		'Semantic-Capability verweist auf den tatsaechlichen Set-Namen');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'ein Device erkannt');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'eine Entity erkannt');

	my $normal = dispatch_message('mqtt', 'client1', 'node/power/state', '1');
	is($normal, ['MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'normales Topic laeuft an nachfolgende Consumer weiter');
};

subtest 'EMS-ESP Jinja-Fallback und Unicode-Payload bleiben hinter Referenzen' => sub {
	setup();
	my $umlaut = chr(0xdf);
	my $json = JSON::PP->new->canonical(1)->utf8(1);
	my $device = {
		ids => ['ems-esp-boiler'], name => 'EMS ESP Boiler',
		mf => 'EMS-ESP', mdl => 'Boiler',
	};
	my $sensor = $json->encode({
		name => 'Heating temperature', uniq_id => 'ems_boiler_heatingtemp',
		stat_t => 'ems-esp/boiler/data',
		val_tpl => "{{ value_json['heatingtemp'] if value_json['heatingtemp'] is defined else 0 }}",
		dev => $device,
	});
	my $switch = $json->encode({
		name => 'Boost', uniq_id => 'ems_boiler_boost',
		stat_t => 'ems-esp/boiler/boost', cmd_t => 'ems-esp/boiler/command',
		pl_on => "hei${umlaut}", pl_off => 'aus',
		dev => $device,
	});
	dispatch_message('mqtt', 'ems-esp',
		'homeassistant/sensor/ems-esp-boiler/heatingtemp/config', $sensor);
	dispatch_message('mqtt', 'ems-esp',
		'homeassistant/switch/ems-esp-boiler/boost/config', $switch);
	my $target = 'MQTT2_EMS_ESP_Boiler';
	my $reading_list = attr_value($target, 'readingList');
	my ($reading_line) = grep { /runtimeRef/ } split /\n/, $reading_list;
	like($reading_line, qr/MQTT2_DISCOVERY_runtimeRef\(\$NAME, 'r_[a-f0-9]{16}', \$EVENT\)/,
		'das bedingte EMS-Template erscheint nur als kurze Referenz');
	unlike($reading_list, qr/is defined|value_json/,
		'das Jinja-Template steht nicht mehr sichtbar in readingList');
	is(reading_value('discovery', 'warningCount'), 0,
		'das sichere is-defined-Template erzeugt keine Discovery-Warnung');
	my $reading_descriptor = runtime_descriptor_for_line($target, $reading_line);
	my $reading_name = $reading_descriptor->{configuration}{readings}[0]{name};
	my ($reading_reference) = $reading_line =~ /'(r_[a-f0-9]+)'/;
	is(FHEM::MQTT2_DISCOVERY::runtimeRef(
			$target, $reading_reference, '{"heatingtemp":55}'),
		{ $reading_name => '55' },
		'is defined liefert den vorhandenen EMS-Wert als Reading');
	is(FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reading_reference, '{}'),
		{ $reading_name => '0' },
		'is defined liefert bei fehlendem EMS-Feld den deklarierten Fallback');

	my $set_list = attr_value($target, 'setList');
	my ($set_line) = grep { /runtimeRef/ } split /\n/, $set_list;
	like($set_line, qr/MQTT2_DISCOVERY_runtimeRef/,
		'das Unicode-Mapping erscheint nur als kurze Set-Referenz');
	ok($set_line !~ /[^\x00-\x7f]/ && $set_line !~ /\\u00df/i,
		'setList enthaelt weder das Umlautzeichen noch dessen JSON-Escape');
	my ($set_reference) = $set_line =~ /'(r_[a-f0-9]+)'/;
	my ($set_name) = $set_line =~ /^([^: ]+)/;
	my $command = FHEM::MQTT2_DISCOVERY::runtimeRef(
		$target, $set_reference, "$set_name on",
	);
	my $expected = Encode::encode('UTF-8', "ems-esp/boiler/command hei${umlaut}");
	is(unpack('H*', $command), unpack('H*', $expected),
		'die Referenz liefert das scharfe s als echte UTF-8-Bytes an MQTT2_DEVICE');
	ok(!utf8::is_utf8($command), 'der MQTT-Befehl ist ein expliziter Bytestrom');
};

subtest 'Runtime-Readings liefern Unicode genau einmal als UTF-8-Bytestrom' => sub {
	setup();
	my $description = Encode::decode('UTF-8',
		"Es wird kein aktiver Ger\xC3\xA4tefehler gemeldet.");
	my $json = JSON::PP->new->canonical(1)->utf8(1);
	my $state_topic = 'ecovacs/ecovacs-eg/state';
	my $configuration = $json->encode({
		name => 'Error description', uniq_id => 'ecovacs_eg_error_description',
		stat_t => $state_topic, val_tpl => '{{ value_json.errorDescription }}',
		dev => { ids => ['ecovacs-eg'], name => 'Ecovacs EG' },
	});
	dispatch_message('mqtt', 'ecovacs',
		'homeassistant/sensor/ecovacs-eg/errorDescription/config', $configuration);
	my ($target) = grep {
		($main::defs{$_}{TYPE} || '') eq 'MQTT2_DEVICE'
	} sort keys %main::defs;
	ok(defined($target), 'UTF-8-Test hat ein MQTT2_DEVICE angelegt');
	my ($reading_line) = grep { /runtimeRef/ }
		split /\n/, attr_value($target, 'readingList');
	my $descriptor = runtime_descriptor_for_line($target, $reading_line);
	my $reading_name = $descriptor->{configuration}{readings}[0]{name};
	my ($reference) = $reading_line =~ /'(r_[a-f0-9]+)'/;
	my $state = $json->encode({ errorDescription => $description });
	my $result = FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $state);
	my $expected = Encode::encode('UTF-8', $description);
	is(unpack('H*', $result->{$reading_name}), unpack('H*', $expected),
		'Topic-Referenz liefert das ae als korrekte UTF-8-Bytes');
	ok(!utf8::is_utf8($result->{$reading_name}),
		'Topic-Referenz liefert einen expliziten FHEM-Bytestrom');

	my $already_encoded = FHEM::MQTT2_DISCOVERY::mqttReadingBytes({
		errorDescription => $expected,
	});
	is(unpack('H*', $already_encoded->{errorDescription}), unpack('H*', $expected),
		'bereits codierte MQTT-Bytes werden nicht doppelt codiert');
};

subtest 'createReadings legt sichere Namen leer an und erhaelt Werte' => sub {
	setup(create_readings => 1);
	my $topic = 'homeassistant/switch/node/power/config';
	dispatch_message('mqtt', 'client1', $topic, switch_payload());
	is(reading_value('MQTT2_Node_node', 'power'), '',
		'angekuendigtes State-Reading wird unmittelbar leer angelegt');

	main::readingsSingleUpdate($main::defs{MQTT2_Node_node}, 'power', '1', 1);
	dispatch_message('mqtt', 'client1', $topic, switch_payload());
	is(reading_value('MQTT2_Node_node', 'power'), '1',
		'erneute Discovery ueberschreibt keinen bereits empfangenen Wert');
};

subtest 'Sonos2mqtt-Speaker wird als bedienbarer Media-Player angelegt' => sub {
	setup();
	my $uuid = 'RINCON_804AF28451D201400';
	my $topic = "sonos2mqtt/discovery/sonos/$uuid";
	my $payload = qq|{"device":{"identifiers":["$uuid"],"manufacturer":"Sonos, Inc.","model":"Sonos Era 300","name":"Wohnen","sw_version":"94.1-75110","connections":[["host","192.168.1.141:1400"],["mqtt","sonos/$uuid"],["mac","80:4A:F2:84:51:D2"]]},"device_class":"speaker","icon":"mdi:speaker","name":"Wohnen","state_topic":"sonos/$uuid","command_topic":"sonos/$uuid/control","unique_id":"sonos2mqtt_${uuid}_speaker","availability_topic":"sonos/connected"}|;
	my $seen = dispatch_message('mqtt', 'sonosbridge', $topic, $payload);
	is($seen, ['MQTT2_DISCOVERY'], 'native Sonos2mqtt-Discovery wird vom neuen Adapter konsumiert');
	my $target = 'MQTT2_Wohnen';
	ok($main::defs{$target}, 'fuer den Sonos-Raum wurde ein MQTT2_DEVICE angelegt');
	is($main::defs{$target}{DEF}, 'sonosbridge',
		'MQTT2_SERVER behaelt die Publisher-CID der Sonos2mqtt-Instanz');
	my $reading_list = attr_value($target, 'readingList');
	my ($speaker_line) = grep { /^\$DEVICETOPIC:/ } split /\n/, $reading_list;
	like($speaker_line, qr/MQTT2_DISCOVERY_runtimeRef/,
		'readingList liest den Transportstatus ueber eine relative kompakte Referenz');
	my $speaker_descriptor = runtime_descriptor_for_line($target, $speaker_line);
	ok(grep({ ($_->{name} || '') eq 'transportState' }
		@{ $speaker_descriptor->{configuration}{readings} || [] }),
		'die Referenz behaelt das Transportstatus-Reading deklarativ bei');
	like(attr_value($target, 'readingList'), qr/sonos\/connected/,
		'readingList bindet die bridgeweite Sonos-Verfuegbarkeit ein');
	like(attr_value($target, 'setList'),
		qr/volume:slider,0,1,100 \$DEVICETOPIC\/control \{"command":"volume","input":\$EVTPART1\}/,
		'setList steuert die Lautstaerke mit dem Sonos2mqtt-JSON-Vertrag');
	like(attr_value($target, 'setList'),
		qr/play:noArg \$DEVICETOPIC\/control \{"command":"play"\}/,
		'setList enthaelt argumentlose Transportaktionen');
	is($main::defs{$target}{SEMANTIC_METADATA}{entities}[0]{class}, 'media_player',
		'Device stellt Media-Player-Semantik bereit');
	is($main::defs{$target}{SEMANTIC_METADATA}{entities}[0]{capabilities}{volume}{write}, 'volume',
		'semantische Lautstaerke verweist auf den tatsaechlichen Setter');
	is(reading_value('discovery', 'lastAdapter'), 'sonos2mqtt', 'verwendeter Adapter ist sichtbar');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'ein Sonos-Device wurde erkannt');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'eine Media-Player-Entity wurde erkannt');

	my $normal = dispatch_message('mqtt', 'sonosbridge', "sonos/$uuid", '{"transportState":"PLAYING"}');
	is($normal, ['MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'],
		'normales Sonos-State-Topic bleibt bei den nachfolgenden Consumern');
};

subtest 'Alte Sonos-Discovery funktioniert ueber SERVER und CLIENT bis zur Laufzeit und Loeschung' => sub {
	# Beide Transportarten muessen auch mit einem eigenen HA-Discovery-Prefix funktionieren.
	for my $io_type (qw(MQTT2_SERVER MQTT2_CLIENT)) {
		my $hash = setup(type => $io_type, prefixes => 'haus/ha,sonos2mqtt');
		$main::attr{discovery}{availabilityReading} = 'sonosStatus';
		my $uuid = 'RINCON_804AF28451D201400';
		my $legacy_topic = "haus/ha/music_player/$uuid/sonos/config";
		my $current_topic = "sonos2mqtt/discovery/sonos/$uuid";
		my $payload = qq|{"device":{"identifiers":["$uuid"],"manufacturer":"Sonos","name":"Wohnen"},"device_class":"speaker","name":"Wohnen","state_topic":"sonos/$uuid","command_topic":"sonos/$uuid/control","unique_id":"sonos2mqtt_${uuid}_speaker","availability_topic":"sonos/connected","payload_available":"2","json_attributes":true,"json_attributes_topic":"sonos/$uuid","available_commands":["play","pause","volume","mute","unmute"]}|;
		is(dispatch_message('mqtt', 'sonosbridge', $legacy_topic, $payload), ['MQTT2_DISCOVERY'],
			"$io_type: alte Discovery wird konsumiert");
		my $target = 'MQTT2_Wohnen';
		ok($main::defs{$target}, "$io_type: Speaker wurde angelegt");
		is(reading_value('discovery', 'lastAdapter'), 'sonos2mqtt', 'Sonos-Adapter ist zustaendig');
		is(reading_value('discovery', 'errorCount'), 0, 'keine Unsupported-Meldung vom HA-Parser');
		my $reading_list = attr_value($target, 'readingList');
		my $set_list = attr_value($target, 'setList');
		my ($speaker_line) = grep { /^\$DEVICETOPIC:/ } split /\n/, $reading_list;
		my ($reference) = $speaker_line =~ /'(r_[a-f0-9]+)'/;
		my $state = '{"transportState":"PLAYING","volume":{"Master":23},"mute":{"Master":false}}';
		is(FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $state),
			{ transportState => 'PLAYING', volume => '23', mute => 'false' },
			'gemeinsame Runtime liest Transportstatus, Lautstaerke und Mute');
		like($set_list, qr/^play:noArg \$DEVICETOPIC\/control \{"command":"play"\}$/m,
			'Transportbefehl verwendet das richtige Command-Topic und JSON');
		like($set_list, qr/^volume:slider,0,1,100 \$DEVICETOPIC\/control \{"command":"volume","input":\$EVTPART1\}$/m,
			'Lautstaerke verwendet denselben numerischen Setter wie das neue Format');
		my ($mute_line) = grep { /^mute:/ } split /\n/, $set_list;
		my ($mute_ref) = $mute_line =~ /'(r_[a-f0-9]+)'/;
		is(FHEM::MQTT2_DISCOVERY::runtimeRef($target, $mute_ref, 'mute off'),
			qq|sonos/$uuid/control {"command":"unmute"}|, 'Mute-Auswahl wird korrekt codiert');
		my ($availability_line) = grep { /^sonos\/connected:/ } split /\n/, $reading_list;
		my ($availability_ref) = $availability_line =~ /'(r_[a-f0-9]+)'/;

		# Die alte payload_available-Angabe fuehrt zur selben dreistufigen Bridge-Auswertung.
		for my $case ([0, 'offline'], [1, 'offline'], [2, 'online']) {
			my $updates = FHEM::MQTT2_DISCOVERY::runtimeRef($target, $availability_ref, "$case->[0]");
			is($updates->{sonosStatus}, $case->[1],
				'Availability wird unter dem konfigurierten Readingnamen ausgewertet');
		}

		dispatch_message('mqtt', 'sonosbridge', $legacy_topic, $payload);
		is(attr_value($target, 'readingList'), $reading_list, 'erneute alte Discovery erzeugt keine Reading-Duplikate');
		is(attr_value($target, 'setList'), $set_list, 'erneute alte Discovery behaelt stabile Sets');

		# Nach dem Verwerfen der Laufzeitcaches muss die persistierte Registry ausreichen.
		delete $hash->{helper}{registry};
		delete $main::defs{$target}{helper}{mqtt2_discovery_runtime_refs};
		is(FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $state),
			{ transportState => 'PLAYING', volume => '23', mute => 'false' },
			'Reading-Referenz wird aus der gespeicherten Registry wiederhergestellt');

		# Beide Quellen duerfen dasselbe Geraet verwalten; Loeschungen bleiben Topic-bezogen.
		dispatch_message('mqtt', 'sonosbridge', $current_topic, $payload);
		is(reading_value('discovery', 'discoveredDevices'), 1, 'Formatwechsel legt kein zweites Device an');
		dispatch_message('mqtt', 'sonosbridge', $legacy_topic, '');
		is(reading_value('discovery', 'discoveredEntities'), 1, 'alte Loeschmeldung erhaelt die neue Quelle');
		ok($main::defs{$target}, 'Speaker bleibt unter demselben Namen vorhanden');
		is(attr_value($target, 'setList'), $set_list, 'neue Quelle bietet weiterhin dieselben Befehle');
		dispatch_message('mqtt', 'sonosbridge', $current_topic, '');
		is(reading_value('discovery', 'discoveredEntities'), 0, 'beide Quellen wurden vollstaendig entfernt');
	}
};

subtest 'MQTT2_CLIENT trennt mehrere Discovery-Geraete trotz gemeinsamer Transport-CID' => sub {
	setup(type => 'MQTT2_CLIENT');
	is(dispatch_message(
		'mqtt', 'shared_client', 'homeassistant/switch/alpha/power/config',
		switch_payload(id => 'alpha'),
	), ['MQTT2_DISCOVERY'], 'erstes Client-Discovery-Device wird konsumiert');
	is(dispatch_message(
		'mqtt', 'shared_client', 'homeassistant/switch/beta/power/config',
		switch_payload(id => 'beta'),
	), ['MQTT2_DISCOVERY'], 'zweites Client-Discovery-Device wird konsumiert');

	my $alpha_cid = $main::defs{MQTT2_Node_alpha}{DEF};
	my $beta_cid = $main::defs{MQTT2_Node_beta}{DEF};
	like($alpha_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'erstes Ziel besitzt eine virtuelle Discovery-CID');
	like($beta_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'zweites Ziel besitzt eine virtuelle Discovery-CID');
	isnt($alpha_cid, $beta_cid,
		'gemeinsame MQTT2_CLIENT-CID wird nicht zwischen Zieldevices geteilt');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{$alpha_cid}, [$main::defs{MQTT2_Node_alpha}],
		'erstes Device besitzt einen eindeutigen CID-Bucket');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{$beta_cid}, [$main::defs{MQTT2_Node_beta}],
		'zweites Device besitzt einen eindeutigen CID-Bucket');
};

subtest 'HA-Switch verwendet fuer Lesen und Schreiben exakt denselben Namen' => sub {
	setup();
	dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config',
		'{"name":"Power","uniq_id":"node_power","stat_t":"node/state/POWER1","cmd_t":"node/command/power1","pl_on":"ON","pl_off":"OFF","dev":{"ids":["node"],"name":"Node node"}}');

	like(attr_value('MQTT2_Node_node', 'readingList'),
		qr{^\$DEVICETOPIC/state/POWER1:\.\* POWER1$}m,
		'HA-State wird als POWER1 gelesen');
	like(attr_value('MQTT2_Node_node', 'setList'),
		qr{^POWER1:ON,OFF \$DEVICETOPIC/command/power1$}m,
		'HA-Setter heisst ebenfalls exakt POWER1');
	my $power = $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{capabilities}{power};
	is([$power->{read}, $power->{write}], ['POWER1', 'POWER1'],
		'SemanticUI verwendet fuer Lesen und Schreiben denselben Namen');
	is($power->{options}, ['ON', 'OFF'],
		'SemanticUI verwendet die nativen FHEM-Set-Zustaende');
	ok(!exists($power->{valueMap}), 'Power-Zustaende werden nicht umbenannt');
};

subtest 'Device-Namen werden standardmaessig ohne Prefix angelegt' => sub {
	setup(device_name_prefix => '');
	dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config', switch_payload());
	ok($main::defs{Node_node}, 'ohne deviceNamePrefix wird der Discovery-Name verwendet');
	ok(!$main::defs{MQTT2_Node_node}, 'MQTT2_ wird nicht implizit vorangestellt');
};

subtest 'native Tasmota-Discovery fuehrt config und sensors zusammen' => sub {
	setup();
	my $config = '{"dn":"Workshop Plug","fn":["Soldering Iron"],"mac":"AABBCCDDEEFF","md":"Generic","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"workshop_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0,"30":0},"ver":1}';
	my $sensors = '{"sn":{"Time":"2026-08-18T12:00:00","ENERGY":{"Power":42,"Voltage":230.1}},"ver":1}';

	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCDDEEFF/config', $config),
		['MQTT2_DISCOVERY'], 'Tasmota config wird konsumiert');
	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCDDEEFF/sensors', $sensors),
		['MQTT2_DISCOVERY'], 'Tasmota sensors wird konsumiert');
	ok($main::defs{MQTT2_Workshop_Plug_Soldering_Iron}, 'ein gemeinsames MQTT2_DEVICE wurde angelegt');
	like(attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'readingList'), qr{stat/workshop_plug/RESULT},
		'Relay-Status ist enthalten');
	my ($result_line) = grep { /^stat\/workshop_plug\/RESULT:/ }
		split /\n/, attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'readingList');
	# Der Alias POWER1 steht in der Umbenennungsliste: Tasmota meldet denselben
	# Kanal je nach SetOption26 unter dem einen oder dem anderen Schluessel, und
	# die Option gehoert nicht zur Discovery.
	is($result_line, q!stat/workshop_plug/RESULT:.* { !
		. $json_readings{result} =~ s/\)\z/,{"POWER1" => "POWER"})/r . q! }!,
		'Tasmota-RESULT verwendet ebenfalls die kurze JSON-Auswertung');
	like(attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'readingList'), qr{tele/workshop_plug/SENSOR},
		'Telemetriesensoren sind enthalten');
	my ($sensor_line) = grep { /^tele\/workshop_plug\/SENSOR:/ }
		split /\n/, attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'readingList');
	# Die Zuordnung eines Schluessels gilt im ganzen Geraet und steht deshalb an
	# jeder Sammelzeile, auch wenn dieses Topic den Schluessel nie liefert.
	is($sensor_line, q!tele/workshop_plug/SENSOR:.* { !
		. $json_readings{sensor} =~ s/\)\z/,{"POWER1" => "POWER"})/r . q! }!,
		'Tasmota-SENSOR verwendet dieselbe kurze JSON-Auswertung wie MQTT2-Autocreate');
	is(scalar(() = attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'readingList') =~ /tele\/workshop_plug\/SENSOR/g), 1,
		'alle Tasmota-Telemetriewerte teilen sich eine JSON-Auswertung');
	like(attr_value('MQTT2_Workshop_Plug_Soldering_Iron', 'setList'), qr{POWER:ON,OFF\s+cmnd/workshop_plug/POWER},
		'Relay-Befehl verwendet exakt den Reading-Namen');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'Tasmota ergibt ein Device');
	is(reading_value('discovery', 'discoveredEntities'), 3, 'Relay und zwei Sensoren sind registriert');
};

subtest 'extraJsonReadings wechselt ohne neue Discovery zwischen offen und angekuendigt' => sub {
	my $hash = setup();
	my $config = '{"dn":"Strict Plug","fn":["Power"],"mac":"AABBCCDDEE01",'
		. '"state":["OFF","ON"],"t":"strict_plug","ft":"%prefix%/%topic%/",'
		. '"tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0},"ver":1}';
	dispatch_message('mqtt', 'tasmota',
		'tasmota/discovery/AABBCCDDEE01/config', $config);
	my $target = 'MQTT2_Strict_Plug_Power';
	my $inclusive = attr_value($target, 'readingList');
	like($inclusive, qr/MQTT2_DISCOVERY_jsonReadings/,
		'der Default include erzeugt weiterhin offene Tasmota-JSON-Readings');
	like($inclusive, qr{^stat/strict_plug/POWER:\.\* POWER$}m,
		'das explizit angekuendigte Power-Reading ist im Default enthalten');

	is(FHEM::MQTT2_DISCOVERY::Attr(
			'set', 'discovery', 'extraJsonReadings', 'ignore',
		), undef, 'der restriktive JSON-Modus wird akzeptiert');
	$main::attr{discovery}{extraJsonReadings} = 'ignore';
	FHEM::MQTT2_DISCOVERY::process_queue($hash);
	my $strict = attr_value($target, 'readingList');
	unlike($strict, qr/MQTT2_DISCOVERY_jsonReadings/,
		'ignore entfernt alle offenen JSON-Sammelhandler');
	unlike($strict, qr{^tele/strict_plug/(?:STATE|SENSOR|INFO|UPTIME):}m,
		'ignore entfernt nicht konkret angekuendigte Tasmota-Zusatzfelder');
	my ($strict_result_line) = grep { /^stat\/strict_plug\/RESULT:/ }
		split /\n/, $strict;
	my $strict_result = runtime_descriptor_for_line($target, $strict_result_line);
	is([map { $_->{name} } @{ $strict_result->{configuration}{readings} || [] }], ['POWER'],
		'RESULT wertet im restriktiven Modus nur das angekuendigte POWER-Feld aus');
	like($strict, qr{^stat/strict_plug/POWER:\.\* POWER$}m,
		'ignore behaelt das explizit angekuendigte Power-Feld');
	like($strict, qr{^tele/strict_plug/LWT:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'ignore behaelt die angekuendigte Availability-Auswertung');

	# Die Rueckkehr zu include rendert die offenen Felder aus der Registry neu;
	# es wird bewusst keine zweite Discovery-Nachricht gesendet.
	is(FHEM::MQTT2_DISCOVERY::Attr(
			'set', 'discovery', 'extraJsonReadings', 'include',
		), undef, 'der inklusive Defaultmodus kann wiederhergestellt werden');
	$main::attr{discovery}{extraJsonReadings} = 'include';
	FHEM::MQTT2_DISCOVERY::process_queue($hash);
	like(attr_value($target, 'readingList'), qr/MQTT2_DISCOVERY_jsonReadings/,
		'die Registry stellt die offenen JSON-Felder ohne neue Discovery wieder her');
};

subtest 'konservativer Tasmota-Merge vermeidet doppelte JSON-Sammelhandler' => sub {
	setup();
	my $target = 'ExistingTasmota';
	is(main::CommandDefine(undef, "$target MQTT2_DEVICE tasmota mqtt"), undef,
		'vorhandenes Tasmota-Device wird mit derselben Transport-CID registriert');
	my @manual = (
		q!tele/tasmota_44768C/STATE:.* { json2nameValue($EVENT,'',$JSONMAP) }!,
		q!tele/tasmota_44768C/SENSOR:.* { json2nameValue($EVENT,'',$JSONMAP) }!,
		q!tele/tasmota_44768C/INFO.:.* { json2nameValue($EVENT,'',$JSONMAP) }!,
		q!tele/tasmota_44768C/UPTIME:.* { json2nameValue($EVENT,'',$JSONMAP) }!,
		q!stat/tasmota_44768C/RESULT:.* { json2nameValue($EVENT,'',$JSONMAP) }!,
	);
	$main::attr{$target}{readingList} = join("\n", @manual);
	my $config = '{"dn":"Existing Tasmota","mac":"AABBCC44768C","state":["OFF","ON"],"t":"tasmota_44768C","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0},"ver":1}';

	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCC44768C/config', $config),
		['MQTT2_DISCOVERY'], 'Tasmota-Discovery wird fuer das Bestandsdevice konsumiert');
	my $reading_list = attr_value($target, 'readingList');

	for my $line (@manual) {
		is(scalar(grep { $_ eq $line } split /\n/, $reading_list), 1,
			"manueller JSON-Sammelhandler bleibt genau einmal erhalten: $line");
	}

	my @overlapping = grep {
		m{^(?:tele/tasmota_44768C/(?:STATE|SENSOR|INFO.|UPTIME)|stat/tasmota_44768C/RESULT):}
	} split /\n/, $reading_list;
	is(scalar(@overlapping), scalar(@manual),
		'Discovery fuegt fuer die bereits abgedeckten Topics keine zweite JSON-Auswertung hinzu');
	unlike(join("\n", @overlapping), qr/MQTT2_DISCOVERY_jsonReadings/,
		'die konservativ verdraengten JSON-Auswertungen umgehen die manuellen Regeln nicht');
	like($reading_list, qr{^tele/tasmota_44768C/LWT:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'unabhaengige Discovery-Availability bleibt trotz manueller JSON-Topics aktiv');
	like(reading_value('discovery', 'conflicts'), qr/(?:^|,)STATE(?:,|$)/,
		'der verdraengte STATE-Sammelhandler wird als Konflikt gemeldet');
	like(reading_value('discovery', 'conflicts'), qr/(?:^|,)INFO(?:,|$)/,
		'die verdraengte INFO-Sequenz wird als Konflikt gemeldet');
};

subtest 'native Tasmota-Klassen werden bis readingList und setList abgebildet' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"ip":"192.0.2.12","dn":"All Classes","fn":["Color Light","Shutter",""],"hn":"all-classes","mac":"112233445566","md":"ESP32","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"all_classes","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[2,3,3],"swc":[5,13],"swn":["Door","Motion"],"btn":[1,0],"so":{"4":0,"11":0,"13":0,"30":0,"68":0,"73":1,"82":1,"114":1},"if":1,"cam":0,"ty":0,"lk":1,"lt_st":5,"sho":[0],"sht":[[0,90,10]],"ver":1}';
	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/112233445566/config', $config),
		['MQTT2_DISCOVERY'], 'erweiterte Tasmota config wird konsumiert');
	ok($main::defs{MQTT2_All_Classes_Fan_445566}, 'alle Klassen werden in einem MQTT2_DEVICE gruppiert');
	my $reading_list = attr_value('MQTT2_All_Classes_Fan_445566', 'readingList');
	my $set_list = attr_value('MQTT2_All_Classes_Fan_445566', 'setList');

	like($set_list, qr{power_brightness:slider,0,1,100\s+cmnd/all_classes/Dimmer}, 'Dimmer wird schreibbar');
	like($set_list, qr{power_colorTemp:slider,200,1,380\s+cmnd/all_classes/CT}, 'Farbtemperatur wird schreibbar');
	like($set_list, qr{power_color\s+cmnd/all_classes/Color2}, 'RGB-Farbe wird schreibbar');
	like($set_list, qr{power_effect:}, 'Lichteffekte werden schreibbar');
	like($set_list, qr{fan_percentage:slider,0,1,3\s+cmnd/all_classes/FanSpeed}, 'iFan-Speed wird schreibbar');
	like($set_list, qr{shutter_action:open,close,stop}, 'Shutter-Aktionen werden schreibbar');
	like($set_list, qr{shutter_position:slider,0,1,100\s+cmnd/all_classes/ShutterPosition1}, 'Shutter-Position wird schreibbar');
	like($set_list, qr{shutter_tilt:slider,0,1,90\s+cmnd/all_classes/ShutterTilt1}, 'Shutter-Tilt wird schreibbar');

	my ($result_line) = grep { m{^stat/all_classes/RESULT:} } split /\n/, $reading_list;
	is($result_line, q!stat/all_classes/RESULT:.* { !
		. $json_readings{result} . q! }!,
		'alle JSON-Zustaende aus RESULT teilen sich die Autocreate-Auswertung');
	is(scalar(() = $reading_list =~ m{stat/all_classes/RESULT}g), 1,
		'RESULT wird trotz vieler Tasmota-Komponenten nur einmal ausgewertet');
	my %semantic = map { $_->{id} => $_ } @{ $main::defs{MQTT2_All_Classes_Fan_445566}{SEMANTIC_METADATA}{entities} };
	is($semantic{power}{capabilities}{power}{read}, 'POWER1',
		'Lichtstatus liest bei mehreren Ausgaengen das nummerierte Rohreading');
	is($semantic{power}{capabilities}{power}{write}, 'POWER1',
		'Lichtstatus schreibt ueber denselben Namen wie das Rohreading');
	is($semantic{power}{capabilities}{brightness}{read}, 'Dimmer',
		'Helligkeit liest das rohe Dimmer-Reading');
	ok(!exists($semantic{switch_1}),
		'unklassifizierter physischer Eingang bleibt als Reading ausserhalb der SemanticUI');
	is($semantic{shutter}{capabilities}{position}{read}, 'Shutter1_Position',
		'Shutter liest die abgeflachte Tasmota-Position');
	is($semantic{fan}{capabilities}{percentage}{read}, 'FanSpeed',
		'Fan liest das rohe FanSpeed-Reading');
	is(reading_value('discovery', 'discoveredEntities'), 7, 'alle sieben Entities sind registriert');
};

subtest 'SemanticUI filtert mehrkanalige Tasmota-Messwerte konservativ' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"dn":"Meter","fn":["Channel 1","Channel 2"],"mac":"A1B2C3D4E5F6","state":["OFF","ON","TOGGLE","HOLD"],"t":"meter","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1],"so":{"4":0},"ver":1}';
	my $sensors = '{"sn":{"ENERGY":{"Power":[1688,0],"ApparentPower":[1700,0],"ReactivePower":[200,0],"Current":[7.3,0],"Factor":[0.99,0]}},"ver":1}';
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/A1B2C3D4E5F6/config', $config);
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/A1B2C3D4E5F6/sensors', $sensors);

	# Zwei Kanaele ergeben zwei Geraete; die Messwerte bleiben beim Hauptgeraet.
	my %semantic = map { $_->{id} => $_ }
		@{ $main::defs{MQTT2_Meter_Switch_D4E5F6}{SEMANTIC_METADATA}{entities} };
	my %kanal1 = map { $_->{id} => $_ }
		@{ $main::defs{MQTT2_Meter_Channel_1}{SEMANTIC_METADATA}{entities} };
	my %kanal2 = map { $_->{id} => $_ }
		@{ $main::defs{MQTT2_Meter_Channel_2}{SEMANTIC_METADATA}{entities} };
	is($kanal1{power}{capabilities}{power}{read}, 'POWER1',
		'erster Aktorkanal liest das tatsaechlich erzeugte nummerierte Reading');
	is($kanal1{power}{capabilities}{power}{write}, 'POWER1',
		'erster Aktorkanal schreibt ueber denselben Namen wie sein Reading');
	is($kanal2{power2}{capabilities}{power}{read}, 'POWER2',
		'zweiter Aktorkanal liest sein nummeriertes Reading');
	is([$semantic{energy_power_0}{device_class},
			$semantic{energy_power_0}{capabilities}{value}{unit}],
		['power', 'W'], 'Wirkleistung erreicht SemanticUI mit W');
	ok(!exists($semantic{energy_apparentpower_0}),
		'Scheinleistung bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_reactivepower_0}),
		'Blindleistung bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_current_0}),
		'Strom bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_factor_0}),
		'Leistungsfaktor bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
};

subtest 'Tasmota-Zweikanalgeraet erhaelt die vollstaendige Standard-readingList' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"dn":"SchwimmbadEntfeuchter","fn":["Entfeuchter","Luefter"],"mac":"AABBCCCF9A44","state":["OFF","ON"],"t":"tasmota_CF9A44","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1],"so":{"4":0,"26":0},"ver":1}';
	my $sensors = '{"sn":{"Time":"2026-08-19T12:00:00","ENERGY":{"Power":42}},"ver":1}';
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/config', $config);
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/sensors', $sensors);

	# Zwei Kanaele ergeben drei Geraete: Die geraeteweite Telemetrie bleibt beim
	# Hauptgeraet, jeder Kanal bekommt sein eigenes mit Zustand und Befehl.
	my $haupt = 'MQTT2_SchwimmbadEntfeuchter_Switch_CF9A44';
	my $reading_list = attr_value($haupt, 'readingList');
	my @expected = (
		q!tele/tasmota_CF9A44/STATE:.* { ! . $json_readings{state} . q! }!,
		q!tele/tasmota_CF9A44/SENSOR:.* { ! . $json_readings{sensor} . q! }!,
		q!tele/tasmota_CF9A44/INFO(?:1|2|3):.* { $EVENT =~ m,^..Info(?:1|2|3)..(.+).$, ?  MQTT2_DISCOVERY_jsonReadings($NAME,'info',$1) : !
			. $json_readings{info} . q! }!,
		q!tele/tasmota_CF9A44/UPTIME:.* { ! . $json_readings{uptime} . q! }!,
		q!stat/tasmota_CF9A44/RESULT:.* { ! . $json_readings{result} . q! }!,
	);
	for my $line (@expected) {
		is(scalar(grep { $_ eq $line } split /\n/, $reading_list), 1,
			"readingList des Hauptgeraets enthaelt genau einmal: $line");
	}
	# Der letzte Wille erzeugt genau eine Zeile: die Quelle der Availability-Kette.
	# Ein zusaetzliches rohes Reading LWT waere dieselbe Aussage ein zweites Mal.
	is(scalar(grep { m{^tele/tasmota_CF9A44/LWT:} } split /\n/, $reading_list), 1,
		'das LWT-Topic erzeugt genau eine Zeile');
	like($reading_list,
		qr{^tele/tasmota_CF9A44/LWT:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'und die speist die Availability-Auswertung');
	is(attr_value($haupt, 'setList'), undef, 'das Hauptgeraet schaltet nichts');

	for my $kanal (1, 2) {
		my $name = "MQTT2_SchwimmbadEntfeuchter_" . ($kanal == 1 ? 'Entfeuchter' : 'Luefter');
		ok($main::defs{$name}, "Kanal $kanal traegt den Namen aus der Discovery");
		like(attr_value($name, 'readingList'), qr{^stat/tasmota_CF9A44/POWER$kanal:\.\* POWER$kanal$}m,
			"Kanal $kanal liest seinen eigenen Zustand");
		is(attr_value($name, 'setList'),
			"POWER$kanal:ON,OFF cmnd/tasmota_CF9A44/POWER$kanal",
			"Kanal $kanal schaltet genau seinen Ausgang");
	}
};

subtest 'Tasmota-Power-readings folgen allgemein der rl-Kanalposition' => sub {
	my @cases = (
		{
			label => 'ein Kanal ohne SetOption26', mac => 'AABBCC000001', topic => 'one',
			relays => '[1]', options => '{"4":0,"26":0}',
			expected => ['stat/one/POWER:.* POWER'], forbidden => ['stat/one/POWER1:.* POWER1'],
		},
		{
			label => 'ein Kanal mit direkter Befehlsantwort', mac => 'AABBCC000002', topic => 'one_direct',
			relays => '[1]', options => '{"4":1,"26":0}',
			expected => ['stat/one_direct/POWER:.* POWER'],
			forbidden => ['stat/one_direct/POWER:.* power'],
		},
		{
			label => 'drei Kanaele', mac => 'AABBCC000003', topic => 'three',
			relays => '[1,1,1]', options => '{"4":0,"26":0}',
			expected => [
				'stat/three/POWER1:.* POWER1',
				'stat/three/POWER2:.* POWER2',
				'stat/three/POWER3:.* POWER3',
			],
		},
		{
			label => 'erster Steckplatz leer', mac => 'AABBCC000004', topic => 'sparse',
			relays => '[0,1]', options => '{"4":0,"26":0}',
			expected => ['stat/sparse/POWER2:.* POWER2'],
			forbidden => ['stat/sparse/POWER2:.* state'],
		},
	);

	for my $case (@cases) {
		setup(prefixes => 'homeassistant,tasmota/discovery');
		my $config = '{"dn":"' . $case->{label} . '","fn":[],"mac":"' . $case->{mac}
			. '","state":["OFF","ON"],"t":"' . $case->{topic}
			. '","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":'
			. $case->{relays} . ',"so":' . $case->{options} . ',"ver":1}';
		dispatch_message('mqtt', 'tasmota', "tasmota/discovery/$case->{mac}/config", $config);
		# Mehrere Kanaele liegen in eigenen Geraeten; geprueft wird, welche Zeilen
		# insgesamt entstehen, nicht in welchem Geraet sie stehen.
		my %lines = map { $_ => 1 }
			map { split /\n/, (attr_value($_, 'readingList') // '') }
			grep { ($main::defs{$_}{TYPE} || '') eq 'MQTT2_DEVICE' } sort keys %main::defs;
		ok($lines{$_}, "$case->{label}: $_") for @{ $case->{expected} };
		ok(!$lines{$_}, "$case->{label}: nicht $_") for @{ $case->{forbidden} || [] };
	}
};

subtest 'disable verhindert Verarbeitung bis zum Loeschen des Attributs' => sub {
	my $hash = setup();
	$main::attr{discovery}{disable} = 1;
	FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'disable', '1');
	my $payload = switch_payload(id => 'disabled_node');
	is(dispatch_message('mqtt', 'c', 'homeassistant/switch/disabled_node/power/config', $payload),
		['MQTT2_DISCOVERY'], 'deaktivierte Discovery-Nachricht wird ohne Folgewirkung konsumiert');
	ok(!$main::defs{MQTT2_Node_disabled_node}, 'disable=1 legt kein MQTT2_DEVICE an');
	is(reading_value('discovery', 'state'), 'disabled', 'Status zeigt disabled');

	delete $main::attr{discovery}{disable};
	FHEM::MQTT2_DISCOVERY::Attr('del', 'discovery', 'disable');
	is(reading_value('discovery', 'state'), 'active', 'Loeschen von disable aktiviert den vorbereiteten Parser');
	is(dispatch_message('mqtt', 'c', 'homeassistant/switch/disabled_node/power/config', $payload),
		['MQTT2_DISCOVERY'], 'nach dem Loeschen wird Discovery wieder verarbeitet');
	ok($main::defs{MQTT2_Node_disabled_node}, 'danach wird das MQTT2_DEVICE angelegt');
};

subtest 'lesbare Standard-setList mit devicetopic' => sub {
	setup();
	my $base = 'homebuttons/homebuttons423828';
	my $device = '"dev":{"ids":["homebuttons423828"],"name":"Homebuttons 423828"}';
	dispatch_message('mqtt', 'c', 'homeassistant/switch/homebuttons/awake_mode/config',
		qq({"~":"$base","stat_t":"~/state/awake_mode","cmd_t":"~/cmd/awake_mode","pl_on":"ON","pl_off":"OFF",$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/text/homebuttons/button_1_label/config',
		qq({"~":"$base","stat_t":"~/state/btn_1_label","cmd_t":"~/cmd/btn_1_label","ret":"true",$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/text/homebuttons/user_message/config',
		qq({"~":"$base","stat_t":"~/state/disp_msg","cmd_t":"~/cmd/disp_msg",$device}));

	is(attr_value('MQTT2_Homebuttons_423828', 'devicetopic'), $base,
		'HA-Topicbasis wird als devicetopic gesetzt');
	my $set_list = attr_value('MQTT2_Homebuttons_423828', 'setList');
	like($set_list,
		qr/^awake_mode:ON,OFF \$DEVICETOPIC\/cmd\/awake_mode$/m,
		'on/off-Payloadmapping verwendet die HA-Payloads ohne Perl-Ausdruck');
	like($set_list,
		qr/^btn_1_label \$DEVICETOPIC\/cmd\/btn_1_label:r$/m,
		'retained Textbefehl wird direkt mit MQTT2_DEVICE-Retain-Suffix publiziert');
	like($set_list,
		qr/^disp_msg \$DEVICETOPIC\/cmd\/disp_msg$/m,
		'freier Text verwendet die normale MQTT2_DEVICE-Syntax');
	unlike($set_list, qr/runtime(?:TemplatePublish|Choice)/,
		'triviale Setter benoetigen keinen Runtime-Wrapper');
};

subtest 'HA-Button folgt der Entity-Namensbildung von Home Assistant' => sub {
	setup();
	my $base = 'zigbee2mqtt/SCHALTER_WAND_SZ';
	my $device = '"dev":{"ids":["schalter_wand_sz"],"name":"SCHALTER_WAND_SZ"}';
	dispatch_message('mqtt', 'z2m',
		'homeassistant/button/schalter_wand_sz/schalter_wand_sz_identify/config',
		qq({"cmd_t":"$base/set/identify","default_entity_id":"button.schalter_wand_sz_identify","dev_cla":"identify","object_id":"schalter_wand_sz_identify","payload_press":"identify",$device}));

	is(attr_value('MQTT2_SCHALTER_WAND_SZ', 'devicetopic'), $base,
		'Button-Command ergibt den gemeinsamen Geraetestamm');
	like(attr_value('MQTT2_SCHALTER_WAND_SZ', 'setList'),
		qr/^identify:noArg \$DEVICETOPIC\/set\/identify identify$/m,
		'namenloser Button verwendet wie HA seine Device-Class als kurzen Namen');
	is($main::defs{MQTT2_SCHALTER_WAND_SZ}{SEMANTIC_METADATA}{entities}[0]
		{capabilities}{press}{write}, 'identify',
		'SemanticUI verwendet denselben Button-Namen');

	dispatch_message('mqtt', 'z2m',
		'homeassistant/button/schalter_wand_sz/second_identify/config',
		qq({"cmd_t":"$base/second/arbitrary","dev_cla":"identify","payload_press":"identify",$device}));
	my @set_names = map { /^([^: ]+)/ ? $1 : () }
		split /\r?\n/, attr_value('MQTT2_SCHALTER_WAND_SZ', 'setList');
	my %set_names = map { $_ => 1 } @set_names;
	is(scalar(@set_names), 2, 'beide gleichnamigen Button-Commands bleiben erhalten');
	is(scalar(keys %set_names), 2, 'der allgemeine Resolver macht beide Set-Namen eindeutig');
	is([sort map { $_->{capabilities}{press}{write} }
			@{ $main::defs{MQTT2_SCHALTER_WAND_SZ}{SEMANTIC_METADATA}{entities} }],
		[sort @set_names], 'SemanticUI verwendet die final aufgeloesten Set-Namen');
};

subtest 'HomeButtons Number-Defaults und Device-Automation' => sub {
	setup();
	my $base = 'homebuttons/homebuttons423828';
	my $device = '"dev":{"ids":["HBTNS-2510-091-423828"],"name":"homebuttons423828"}';
	dispatch_message('mqtt', 'c', 'homeassistant/number/HBTNS-2510-091-423828/schedule_wakeup/config',
		qq({"name":"Schedule wakeup","cmd_t":"$base/cmd/schedule_wakeup","stat_t":"$base/schedule_wakeup","min":5,"max":1800,$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/device_automation/HBTNS-2510-091-423828/button_1/config',
		qq({"atype":"trigger","t":"$base/button_1","pl":"PRESS","type":"button_short_press","stype":"button_1",$device}));

	like(attr_value('MQTT2_homebuttons423828', 'setList'),
		qr/^schedule_wakeup:slider,5,1,1800 \$DEVICETOPIC\/cmd\/schedule_wakeup$/m,
		'Number ohne step erhaelt einen schreibbaren Setter mit Default 1');
	like(attr_value('MQTT2_homebuttons423828', 'readingList'),
		qr/^\$DEVICETOPIC\/button_1:PRESS\$ button_1$/m,
		'Device-Automation wird als payload-gefiltertes Reading integriert');
	is([map { $_->{id} } @{ $main::defs{MQTT2_homebuttons423828}{SEMANTIC_METADATA}{entities} }],
		['schedule_wakeup'],
		'Device-Automation wird nicht als Wertanzeige an SemanticUI uebergeben');
	is(reading_value('discovery', 'discoveredEntities'), 2,
		'Number und Trigger werden beide registriert');
};

subtest 'ESPresense Number-Grenzen verwenden unabhaengige HA-Defaults' => sub {
	setup();
	my $base = 'espresense/rooms/sz';
	my $device = '"dev":{"ids":["espresense_sz"],"name":"espresense_sz"}';

	# Beide ESPresense-Konfigurationswerte liefern nur den vom Standard abweichenden Schritt.
	for my $name (qw(absorption max_distance)) {
		dispatch_message('mqtt', 'espresense_xxx',
			"homeassistant/number/espresense_xxx/$name/config",
			qq({"~":"$base","name":"$name","stat_t":"~/$name","cmd_t":"~/$name/set","step":"0.1","entity_category":"config",$device}));
	}

	my $set_list = attr_value('MQTT2_espresense_sz', 'setList');
	like($set_list,
		qr/^absorption:slider,0,0\.1,100 \$DEVICETOPIC\/absorption\/set$/m,
		'Absorption erhaelt trotz fehlender Grenzen einen Setter');
	like($set_list,
		qr/^max_distance:slider,0,0\.1,100 \$DEVICETOPIC\/max_distance\/set$/m,
		'Max Distance erhaelt trotz fehlender Grenzen einen Setter');
	is(reading_value('discovery', 'errorCount'), 0,
		'beide unvollstaendigen Number-Bereiche werden ohne Discovery-Fehler verarbeitet');
};

subtest 'Device-Automationen teilen sich topicweise das Reading action' => sub {
	setup();
	my $base = 'zigbee2mqtt/remote';
	my $device = '"dev":{"ids":["remote"],"name":"REMOTE"}';
	my %triggers = (
		action_arrow_left_click => 'arrow_left_click',
		action_arrow_left_hold => 'arrow_left_hold',
		action_arrow_right_click => 'arrow_right_click',
	);

	# Einzelne Discovery-Entities bleiben registriert, obwohl sie dasselbe Laufzeitreading speisen.
	for my $object_id (sort keys %triggers) {
		dispatch_message('mqtt', 'z2m',
			"homeassistant/device_automation/remote/$object_id/config",
			qq({"atype":"trigger","t":"$base/action","pl":"$triggers{$object_id}","type":"action","stype":"$object_id",$device}),
		);
	}

	my $reading_list = attr_value('MQTT2_REMOTE', 'readingList');
	my @action_lines = grep { / action$/ } split /\r?\n/, $reading_list;
	is(scalar(@action_lines), 1, 'alle drei Payloadvarianten erzeugen nur eine readingList-Zeile');
	like($action_lines[0], qr/:\(\?:arrow_left_click\|arrow_left_hold\|arrow_right_click\)\$ action$/,
		'das gemeinsame Reading action filtert alle angekuendigten Payloads exakt');
	unlike($reading_list, qr/action_arrow_(?:left|right)/,
		'payloadspezifische Entity-Namen erscheinen nicht mehr als eigene Readings');
	is(reading_value('discovery', 'discoveredEntities'), 3,
		'die drei Discovery-Entities bleiben getrennt in der Registry erhalten');

	dispatch_message('mqtt', 'z2m',
		'homeassistant/device_automation/remote/action_arrow_right_click/config', '');
	$reading_list = attr_value('MQTT2_REMOTE', 'readingList');
	@action_lines = grep { / action$/ } split /\r?\n/, $reading_list;
	is(scalar(@action_lines), 1, 'nach dem Loeschen einer Entity bleibt genau eine gemeinsame Zeile');
	like($action_lines[0], qr/:\(\?:arrow_left_click\|arrow_left_hold\)\$ action$/,
		'die abschliessende Pruefung entfernt nur die geloeschte Payloadvariante');
	unlike($action_lines[0], qr/arrow_right_click/,
		'die geloeschte Payload wird nicht mehr akzeptiert');
	is(reading_value('discovery', 'discoveredEntities'), 2,
		'die Registry entfernt ebenfalls nur die geloeschte Entity');

	dispatch_message('mqtt', 'z2m',
		'homeassistant/device_automation/remote/action_arrow_left_hold/config', '');
	$reading_list = attr_value('MQTT2_REMOTE', 'readingList');
	@action_lines = grep { / action$/ } split /\r?\n/, $reading_list;
	like($action_lines[0], qr/:arrow_left_click\$ action$/,
		'auch die letzte verbleibende Entity behaelt den stabilen Namen action');
};

subtest 'externes Availability-Topic verhindert PAC-devicetopic nicht' => sub {
	setup();
	my $base = 'pac-1b844c';
	my $device = '"dev":{"ids":["pac-1b844c"],"name":"pac-1b844c"}';
	dispatch_message('mqtt', 'fhem_raspi02_discovery_test',
		'homeassistant/sensor/pac/pac_outside_temperature/config',
		qq({"stat_t":"$base/sensor/pac_outside_temperature/state","avty_t":"pac/status",$device}));
	dispatch_message('mqtt', 'fhem_raspi02_discovery_test',
		'homeassistant/switch/pac/pac_mild_dry_switch/config',
		qq({"stat_t":"$base/switch/pac_mild_dry_switch/state","cmd_t":"$base/switch/pac_mild_dry_switch/command","pl_on":"ON","pl_off":"OFF",$device}));

	is(attr_value('MQTT2_pac_1b844c', 'devicetopic'), $base,
		'gemeinsame PAC-Topicbasis wird als devicetopic gesetzt');
	my $reading_list = attr_value('MQTT2_pac_1b844c', 'readingList');
	like($reading_list, qr/^pac\/status:\.\* \{ MQTT2_DISCOVERY_runtimeRef/m,
		'externes Availability-Topic bleibt vollstaendig in der HA-Verfuegbarkeitsauswertung');
	like($reading_list, qr/^\$DEVICETOPIC\/sensor\/pac_outside_temperature\/state:\.\*/m,
		'PAC-State-Topic verwendet DEVICETOPIC ohne CID-Praefix');
	like(attr_value('MQTT2_pac_1b844c', 'setList'),
		qr/^mild_dry_switch:ON,OFF \$DEVICETOPIC\/switch\/pac_mild_dry_switch\/command$/m,
		'PAC-Setter entfernt den node_id-Prefix und verwendet weiterhin DEVICETOPIC');
};

subtest 'ESPHome-PAC behaelt bestehende Setter und ergaenzt Climate vollstaendig' => sub {
	setup();
	my $id = 'dc1ed51d797c';
	my $base = 'pac-1d797c';
	my $device = qq("dev":{"ids":"$id","name":"$base","sw":"2026.7.4","mdl":"esp32-c3-devkitm-1","mf":"Espressif"});

	dispatch_message('mqtt', $base,
		"homeassistant/select/$base/pac_vertical_swing_mode/config",
		qq({"ops":["swing","auto","up","up_center","center","down_center","down"],"name":"pac vertical swing mode","stat_t":"$base/state/vertical_swing_mode","cmd_t":"$base/command/vertical_swing_mode","avty_t":"$base/status","uniq_id":"$id-select-760edd2a",$device}));
	dispatch_message('mqtt', $base,
		"homeassistant/switch/$base/pac_mild_dry_switch/config",
		qq({"name":"pac mild dry switch","stat_t":"$base/state/mild_dry","cmd_t":"$base/command/mild_dry","avty_t":"$base/status","uniq_id":"$id-switch-daa26a14",$device}));

	my $name = 'MQTT2_pac_1d797c';
	is(attr_value($name, 'setList'), join("\n",
			'mild_dry:ON,OFF $DEVICETOPIC/command/mild_dry',
			'vertical_swing_mode:swing,auto,up,up_center,center,down_center,down $DEVICETOPIC/command/vertical_swing_mode'),
		'Select und Switch verwenden die Namen ihres direkten Command-Topics');

	dispatch_message('mqtt', $base,
		"homeassistant/climate/$base/config",
		qq({"name":"pac","unique_id":"$id-climate-pac","availability_topic":"$base/status","mode_state_topic":"$base/state/mode","mode_command_topic":"$base/command/mode","power_command_topic":"$base/command/power","payload_on":"on","payload_off":"off","current_temperature_topic":"$base/state/current_temperature","temperature_state_topic":"$base/state/target_temperature","temperature_command_topic":"$base/command/target_temperature","fan_mode_state_topic":"$base/state/fan_mode","fan_mode_command_topic":"$base/command/fan_mode","swing_mode_state_topic":"$base/state/swing_mode","swing_mode_command_topic":"$base/command/swing_mode","preset_mode_state_topic":"$base/state/preset","preset_mode_command_topic":"$base/command/preset","min_temp":16,"max_temp":30,"temp_step":0.5,"precision":0.1,"modes":["off","auto","cool","heat","fan_only","dry"],"fan_modes":["Automatic","1","2","3","4","5"],"swing_modes":["off","both","vertical","horizontal"],"preset_modes":["Normal","Powerful","Quiet"],"device":{"identifiers":["$id"],"name":"$base","manufacturer":"Panasonic / ESPHome","model":"CN-CNT air conditioner"}}));

	is(attr_value($name, 'devicetopic'), $base, 'PAC-Basistopic wird als devicetopic verwendet');
	is(attr_value($name, 'setList'), join("\n",
			'fan_mode:Automatic,1,2,3,4,5 $DEVICETOPIC/command/fan_mode',
			'mild_dry:ON,OFF $DEVICETOPIC/command/mild_dry',
			'mode:off,auto,cool,heat,fan_only,dry $DEVICETOPIC/command/mode',
			'power:on,off $DEVICETOPIC/command/power',
			'preset:Normal,Powerful,Quiet $DEVICETOPIC/command/preset',
			'swing_mode:off,both,vertical,horizontal $DEVICETOPIC/command/swing_mode',
			'target_temperature:slider,16,0.5,30 $DEVICETOPIC/command/target_temperature',
			'vertical_swing_mode:swing,auto,up,up_center,center,down_center,down $DEVICETOPIC/command/vertical_swing_mode'),
		'alle PAC-Setter verwenden dieselben kurzen Namen wie ihre Readings');
	my $reading_list = attr_value($name, 'readingList');
	like($reading_list, qr/^\$DEVICETOPIC\/state\/current_temperature:\.\* current_temperature$/m,
		'Climate-Isttemperatur wird als Reading angelegt');
	like($reading_list, qr/^\$DEVICETOPIC\/state\/target_temperature:\.\* target_temperature$/m,
		'Climate-Solltemperatur wird als Reading angelegt');
	my $entities = $main::defs{$name}{SEMANTIC_METADATA}{entities};
	is(scalar @$entities, 1, 'Semantic-Metadaten enthalten eine komponierte Climate-Hauptentity');
	my $semantic = $entities->[0];
	is($semantic->{name}, 'climate',
		'Geraetehauptfunktion verwendet die allgemeine Komponenten-ID');
	is($semantic->{capabilities}{power}{read}, 'mode',
		'Power liest den Modus als einzige Zustandsquelle');
	is($semantic->{capabilities}{power}{write}, 'power',
		'Power schreibt den explizit entdeckten Power-Setter');
	is($semantic->{capabilities}{power}{valueMap}{read}, {
			off => 'off', auto => 'on', cool => 'on', heat => 'on', fan_only => 'on', dry => 'on',
		}, 'Power-Zustand wird vollstaendig aus allen Climate-Modi normalisiert');
	is($semantic->{capabilities}{mildDry}{kind}, 'boolean',
		'zusaetzlicher Switch wird als boolesche Climate-Capability beschrieben');
	is([$semantic->{capabilities}{mildDry}{read}, $semantic->{capabilities}{mildDry}{write}],
		[qw(mild_dry mild_dry)], 'Mild-Dry-Capability verwendet die realen FHEM-Pfade');
	is($semantic->{capabilities}{verticalSwingMode}{kind}, 'enum',
		'zusaetzliches Select wird als Enum-Capability beschrieben');
	is($semantic->{capabilities}{verticalSwingMode}{options},
		[qw(swing auto up up_center center down_center down)],
		'vertikale Lamellenposition behaelt alle entdeckten Optionen');
	is(reading_value('discovery', 'discoveredEntities'), 3,
		'Select, Switch und Climate bleiben intern drei Discovery-Entities');
};

subtest 'Device-Discovery verdraengt funktional gleiche klassische PAC-Entities' => sub {
	my $discovery = setup();
	my $id = 'dc1ed51b844c';
	my $base = 'pac-1b844c';
	my $device = qq("dev":{"ids":["$id"],"name":"Klima.Essen"});

	dispatch_message('mqtt', $base,
		"homeassistant/climate/$base/config",
		qq({"name":"pac","uniq_id":"$id-climate-old","mode_stat_t":"$base/state/mode","mode_cmd_t":"$base/command/mode","modes":["auto","cool","heat"],$device}));
	dispatch_message('mqtt', $base,
		"homeassistant/switch/$base/power/config",
		qq({"name":"Power","uniq_id":"$id-switch-old","stat_t":"$base/state/power","cmd_t":"$base/command/power","pl_on":"on","pl_off":"off",$device}));
	dispatch_message('mqtt', $base,
		"homeassistant/sensor/$base/humidity/config",
		qq({"name":"Humidity","uniq_id":"$id-humidity","stat_t":"$base/state/humidity",$device}));

	my $device_discovery = qq({"device":{"identifiers":["$id"],"name":"Klima.Essen"},"components":{)
		. qq("climate":{"platform":"climate","name":"Climate","unique_id":"$id-climate-new","mode_state_topic":"$base/state/mode","mode_command_topic":"$base/command/mode","modes":["auto","cool","heat"]},)
		. qq("power":{"platform":"switch","name":"Power","unique_id":"$id-switch-new","state_topic":"$base/state/power","command_topic":"$base/command/power","payload_on":"on","payload_off":"off"}}});
	dispatch_message('mqtt', $base,
		"homeassistant/device/$base/config", $device_discovery);

	my $name = 'MQTT2_Klima.Essen';
	my $reading_list = attr_value($name, 'readingList');
	my $set_list = attr_value($name, 'setList');
	is(scalar(() = $reading_list =~ m{\$DEVICETOPIC/state/mode}g), 1,
		'das gemeinsame Climate-State-Topic wird nur einmal gerendert');
	is(scalar(() = $reading_list =~ m{\$DEVICETOPIC/state/power}g), 1,
		'das gemeinsame Power-State-Topic wird nur einmal gerendert');
	is(scalar(() = $set_list =~ m{\$DEVICETOPIC/command/mode}g), 1,
		'der gemeinsame Climate-Setter wird nur einmal gerendert');
	is(scalar(() = $set_list =~ m{\$DEVICETOPIC/command/power}g), 1,
		'der gemeinsame Power-Setter wird nur einmal gerendert');
	like($reading_list, qr{\$DEVICETOPIC/state/humidity},
		'eine nur klassisch angekuendigte Zusatz-Entity bleibt erhalten');
	unlike($reading_list, qr/(?:climate|pac_1b844c)_mode/,
		'ohne Doppelkollision bleibt der kurze Readingname mode erhalten');

	# Persistierte Registry-Mappings aus der Vorversion besitzen noch keine Layout-Markierung.
	my ($record) = values %{ $discovery->{helper}{registry}{devices} };

	for my $mapping (values %{ $record->{entities} }) {
		delete $mapping->{source_layout};
	}

	is(FHEM::MQTT2_DISCOVERY::Set(
		$discovery, 'discovery', 'rebuildDevice', $name,
	), undef, 'Neuaufbau erkennt Device-Discovery auch in einer alten Registry');
	$reading_list = attr_value($name, 'readingList');
	is(scalar(() = $reading_list =~ m{\$DEVICETOPIC/state/mode}g), 1,
		'auch die alte Registry rendert das Climate-State-Topic nur einmal');

	# Nach einer echten Device-Tombstone werden die weiterhin bekannten Einzel-Entities wieder sichtbar.
	dispatch_message('mqtt', $base, "homeassistant/device/$base/config", '');
	$reading_list = attr_value($name, 'readingList');
	$set_list = attr_value($name, 'setList');
	is(scalar(() = $reading_list =~ m{\$DEVICETOPIC/state/mode}g), 1,
		'die klassische Climate-Entity wird nach der Device-Loeschung wieder verwendet');
	is(scalar(() = $set_list =~ m{\$DEVICETOPIC/command/power}g), 1,
		'die klassische Power-Entity wird nach der Device-Loeschung wieder verwendet');
};

subtest 'mehrere Entities gruppieren sich und Updates bleiben idempotent' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	my $sensor = '{"uniq_id":"node_temp","stat_t":"node/power/temperature","dev":{"ids":["node"],"name":"Node node"}}';
	my $before_sensor = scalar @{ command_log() };
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	my @sensor_commands = @{ command_log() }[$before_sensor .. $#{ command_log() }];
	is(scalar(grep { /^attr MQTT2_Node_node readingList / } @sensor_commands), 1,
		'neue klassische Entity schreibt readingList genau einmal');
	is(scalar(grep { /^attr MQTT2_Node_node setList / } @sensor_commands), 0,
		'neue Sensor-Entity schreibt unveraenderte setList nicht erneut');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'gemeinsame Device-ID gruppiert Entities');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'zwei Entities registriert');
	is(scalar @{ $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities} }, 1,
		'unklassifizierter Read-only-Sensor bleibt trotz vollstaendiger readingList aus SemanticUI heraus');
	my $before = attr_value('MQTT2_Node_node', 'readingList');
	my $before_repeat = scalar @{ command_log() };
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	is(attr_value('MQTT2_Node_node', 'readingList'), $before, 'identisches Update erzeugt keine Duplikate');
	my @repeat_commands = @{ command_log() }[$before_repeat .. $#{ command_log() }];
	is(scalar(grep { /^attr MQTT2_Node_node (?:readingList|setList) / } @repeat_commands), 0,
		'identisches Update schreibt keine Listenattribute erneut');
};

subtest 'reines Readings-Device bleibt fuer manuelle Semantic-Attribute offen' => sub {
	setup();
	my $payload = '{"name":"IP address","uniq_id":"node_ip","stat_t":"node/state/ip","dev":{"ids":["node"],"name":"Node"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/ip/config', $payload);
	like(attr_value('MQTT2_Node', 'readingList'), qr{/state/ip:\.\* ip},
		'unklassifizierter Wert bleibt vollstaendig in der readingList');
	ok(!exists($main::defs{MQTT2_Node}{SEMANTIC_METADATA}),
		'leere automatische Metadaten blockieren keine manuellen Semantic-Attribute');
};

subtest 'Device-Discovery ist atomar abbildbar' => sub {
	setup();
	my $payload = '{"~":"node","dev":{"ids":["node"],"name":"Node node"},"o":{"name":"fixture"},"cmps":{"power":{"p":"switch","stat_t":"~/power","cmd_t":"~/power/set"},"temperature":{"p":"sensor","stat_t":"~/temperature","val_tpl":"{{ value_json.temperature }}"}}}';
	my $before = scalar @{ command_log() };
	my $seen = dispatch_message('mqtt', 'c', 'homeassistant/device/node/config', $payload);
	my @commands = @{ command_log() }[$before .. $#{ command_log() }];
	is($seen, ['MQTT2_DISCOVERY'], 'Device-Discovery konsumiert');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'beide Komponenten registriert');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/runtimeRef/,
		'einfaches Template verwendet die kompakte Topic-Referenz');
	unlike(attr_value('MQTT2_Node_node', 'readingList'), qr/e3sg/,
		'einfaches Template erzeugt keinen kryptisch codierten Runtime-Aufruf');
	is(scalar(grep { /^attr MQTT2_Node_node readingList / } @commands), 1,
		'mehrere Komponenten schreiben readingList gemeinsam genau einmal');
	is(scalar(grep { /^attr MQTT2_Node_node setList / } @commands), 1,
		'mehrere Komponenten schreiben setList gemeinsam genau einmal');
};

subtest 'HA-JSON-Entities erhalten kurze Namen und tiefstes gemeinsames Devicetopic' => sub {
	setup();
	my $device = '"dev":{"ids":["z2m_light"],"name":"WZ_LIGHTSTRIP_LICHT"}';
	my @discoveries = (
		[
			'homeassistant/light/z2m_light/light/config',
			'{"schema":"json","brightness":true,"brightness_scale":254,"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT","cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set","avty":[{"t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/availability","val_tpl":"{{ value_json.state }}"},{"t":"zigbee2mqtt/bridge/state","val_tpl":"{{ value_json.state }}"}],"avty_mode":"all","uniq_id":"z2m_light_light",' . $device . '}',
		],
		[
			'homeassistant/select/z2m_light/effect/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT","stat_val_tpl":"{{ value_json.effect }}","cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set/effect","ops":["blink","breathe"],"uniq_id":"z2m_light_effect",' . $device . '}',
		],
		[
			'homeassistant/number/z2m_light/effect_speed/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT","stat_val_tpl":"{{ value_json.effect_speed }}","cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set/effect_speed","min":0,"max":1,"step":0.01,"uniq_id":"z2m_light_effect_speed",' . $device . '}',
		],
		[
			'homeassistant/sensor/z2m_light/linkquality/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT","stat_val_tpl":"{{ value_json.linkquality }}","uniq_id":"z2m_light_linkquality",' . $device . '}',
		],
	);

	for my $discovery (@discoveries) {
		is(dispatch_message('mqtt', 'z2m', @$discovery), ['MQTT2_DISCOVERY'],
			'generische HA-Discovery-Nachricht wird konsumiert');
	}

	my $name = 'MQTT2_WZ_LIGHTSTRIP_LICHT';
	is(attr_value($name, 'devicetopic'), 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT',
		'das tiefste gemeinsame segmentgenaue Nutzdaten-Prefix wird verwendet');
	my $reading_list = attr_value($name, 'readingList');
	my ($state_line) = grep { /^\$DEVICETOPIC:/ } split /\n/, $reading_list;
	like($state_line, qr/MQTT2_DISCOVERY_runtimeRef/,
		'gemeinsames State-JSON verwendet eine kompakte Registry-Referenz');
	my $state_descriptor = runtime_descriptor_for_line($name, $state_line);
	is($state_descriptor->{operation}, 'topic',
		'die Referenz behaelt die gemeinsame Topic-Auswertung');
	my %state_names = map { (($_->{name} || '') => 1) }
		@{ $state_descriptor->{configuration}{readings} || [] };
	ok($state_names{brightness} && $state_names{state},
		'gemeinsames State-JSON trennt freie Nutzdaten von der technischen Availability');
	my ($device_availability) = grep { /^\$DEVICETOPIC\/availability:/ } split /\n/, $reading_list;
	like($device_availability, qr/MQTT2_DISCOVERY_runtimeRef/,
		'geraeteeigene Availability bleibt relativ und speist die HA-Auswertung');
	is(runtime_descriptor_for_line($name, $device_availability)->{operation}, 'availability',
		'geraeteeigene Availability verweist auf den sicheren Availability-Vertrag');
	my ($bridge_availability) = grep { /^zigbee2mqtt\/bridge\/state:/ } split /\n/, $reading_list;
	like($bridge_availability, qr/MQTT2_DISCOVERY_runtimeRef/,
		'externe Bridge-Availability bleibt absolut und speist dieselbe Auswertung');
	is(runtime_descriptor_for_line($name, $bridge_availability)->{operation}, 'availability',
		'externe Bridge-Availability verweist auf denselben sicheren Vertragstyp');
	unlike($reading_list, qr/^zigbee2mqtt\/bridge\/state:\.\* state$/m,
		'Bridge-State ueberschreibt kein fachliches state-Reading');
	unlike($reading_list, qr/WZ_LIGHTSTRIP_LICHT_(?:brightness|effect|effect_speed|linkquality)/i,
		'eindeutige JSON-Fachnamen werden nicht mit dem Geraetenamen qualifiziert');

	my $set_list = attr_value($name, 'setList');
	like($set_list, qr/^state:ON,OFF \$DEVICETOPIC\/set \{"state":"\$EVTPART1"\}$/m,
		'JSON-Light-State wird als JSON auf das gemeinsame Command-Topic geschrieben');
	like($set_list, qr/^brightness:slider,0,1,254 \$DEVICETOPIC\/set \{"brightness":\$EVTPART1\}$/m,
		'JSON-Light-Brightness verwendet den deklarierten Wertebereich');
	like($set_list, qr/^effect:blink,breathe \$DEVICETOPIC\/set\/effect$/m,
		'separate HA-Commands verwenden kurze Namen und korrekt relative Topics');
};

subtest 'geraeteeigene Availability belegt ein einzelnes Zigbee2MQTT-State-Topic als Devicetopic' => sub {
	setup();

	my $payload = '{"availability":['
		. '{"topic":"zigbee2mqtt/bridge/state","value_template":"{{ value_json.state }}"},'
		. '{"topic":"zigbee2mqtt/TK_TUER_BAD/availability","value_template":"{{ value_json.state }}"}],'
		. '"availability_mode":"all","device":{"identifiers":["zigbee2mqtt_0x00158d0007e78871"],'
		. '"name":"TK_TUER_BAD"},"device_class":"door","object_id":"tk_tuer_bad_contact",'
		. '"payload_off":true,"payload_on":false,"state_topic":"zigbee2mqtt/TK_TUER_BAD",'
		. '"unique_id":"0x00158d0007e78871_contact_zigbee2mqtt",'
		. '"value_template":"{{ value_json[\\"contact\\"] }}"}';

	is(dispatch_message('mqtt', 'z2m',
		'homeassistant/binary_sensor/0x00158d0007e78871/contact/config', $payload),
		['MQTT2_DISCOVERY'], 'gemeldete Zigbee2MQTT-Discovery wird konsumiert');
	my $name = 'MQTT2_TK_TUER_BAD';
	is(attr_value($name, 'devicetopic'), 'zigbee2mqtt/TK_TUER_BAD',
		'das einzelne State-Topic wird als belegter Geraetestamm verwendet');
	my $reading_list = attr_value($name, 'readingList');
	like($reading_list, qr/^\$DEVICETOPIC:\.\*/m,
		'Geraetezustand wird direkt relativ zum Devicetopic gerendert');
	like($reading_list, qr/^\$DEVICETOPIC\/availability:\.\*/m,
		'geraeteeigene Availability bleibt relativ zum Devicetopic');
	like($reading_list, qr/^zigbee2mqtt\/bridge\/state:\.\*/m,
		'Bridge-Availability bleibt als externes Topic absolut');
	unlike($reading_list, qr/^\$DEVICETOPIC\/bridge\/state:/m,
		'Bridge-Availability verkuerzt den Geraetestamm nicht');
};

subtest 'Zigbee2MQTT-Bridge verwendet JSON-Pfade hinter lower als kurze Namen' => sub {
	setup();
	my $device = '"device":{"identifiers":["zigbee2mqtt_bridge"],"name":"Zigbee2MQTT Bridge"}';
	my @discoveries = (
		[
			'homeassistant/select/zigbee2mqtt_bridge/zigbee2mqtt_bridge_log_level/config',
			qq({"name":"Log level","unique_id":"zigbee2mqtt_bridge_log_level","state_topic":"zigbee2mqtt/bridge/info","value_template":"{{ value_json.log_level | lower }}","command_topic":"zigbee2mqtt/bridge/request/options","options":["error","warning","info","debug"],$device}),
		],
		[
			'homeassistant/switch/zigbee2mqtt_bridge/zigbee2mqtt_bridge_permit_join/config',
			qq({"name":"Permit join","unique_id":"zigbee2mqtt_bridge_permit_join","state_topic":"zigbee2mqtt/bridge/info","value_template":"{{ value_json.permit_join | lower }}","command_topic":"zigbee2mqtt/bridge/request/permit_join","payload_on":"{\\"time\\": 254}","payload_off":"{\\"time\\": 0}","state_on":"true","state_off":"false",$device}),
		],
		[
			'homeassistant/sensor/zigbee2mqtt_bridge/zigbee2mqtt_bridge_version/config',
			qq({"name":"Version","unique_id":"zigbee2mqtt_bridge_version","state_topic":"zigbee2mqtt/bridge/info","value_template":"{{ value_json.version }}",$device}),
		],
		[
			'homeassistant/binary_sensor/zigbee2mqtt_bridge/zigbee2mqtt_bridge_connection_state/config',
			qq({"name":"Connection state","unique_id":"zigbee2mqtt_bridge_connection_state","state_topic":"zigbee2mqtt/bridge/state","value_template":"{{ value_json.state }}","availability":[{"topic":"zigbee2mqtt/bridge/state","value_template":"{{ value_json.state }}"}],"payload_on":"online","payload_off":"offline",$device}),
		],
	);

	# Alle Entities muessen vor der gemeinsamen Namensaufloesung im selben
	# Device registriert sein und dabei ihre wertveraendernden Templates behalten.
	for my $discovery (@discoveries) {
		is(dispatch_message('mqtt', 'zigbee2mqtt', @$discovery), ['MQTT2_DISCOVERY'],
			'Zigbee2MQTT-Bridge-Discovery wird konsumiert');
	}

	my $name = 'MQTT2_Zigbee2MQTT_Bridge';
	my $reading_list = attr_value($name, 'readingList');
	my @info_lines = grep { /^\$DEVICETOPIC\/info:/ } split /\n/, $reading_list;
	is(scalar(@info_lines), 1, 'Bridge-Info wird in genau einer readingList-Zeile ausgewertet');
	like($info_lines[0], qr/MQTT2_DISCOVERY_runtimeRef/,
		'Bridge-Info verwendet die kompakte topicweite Runtime-Referenz');
	my $info_descriptor = runtime_descriptor_for_line($name, $info_lines[0]);
	is([map { $_->{name} } @{ $info_descriptor->{configuration}{readings} || [] }],
		[qw(log_level permit_join version)],
		'alle angekuendigten Bridge-Info-Werte bleiben in der gemeinsamen Referenz');
	unlike($info_lines[0], qr/json2nameValue/,
		'der umfangreiche Bridge-Info-Payload durchlaeuft nicht den fehlerhaften JSON-Autocreate-Parser');
	my @state_lines = grep { /^\$DEVICETOPIC\/state:/ } split /\n/, $reading_list;
	is(scalar(@state_lines), 1, 'Bridge-State wird trotz Reading und Availability nur einmal ausgewertet');
	like($state_lines[0], qr/MQTT2_DISCOVERY_runtimeRef/,
		'Bridge-State verwendet eine kompakte gemeinsame Referenz');
	my $bridge_state_descriptor = runtime_descriptor_for_line($name, $state_lines[0]);
	ok(ref($bridge_state_descriptor->{configuration}{availability}) eq 'HASH',
		'Bridge-State verbindet fachliches Reading und Availability atomar');
	my $set_list = attr_value($name, 'setList');
	like($set_list, qr/^log_level:error,warning,info,debug /m,
		'Select-Setter verwendet log_level ohne technischen Device-Prefix');
	like($set_list, qr/^permit_join:on,off /m,
		'Switch-Setter verwendet permit_join ohne technischen Device-Prefix');
	my ($permit_join) = grep { ($_->{id} // '') eq 'permit_join' }
		@{ $main::defs{$name}{SEMANTIC_METADATA}{entities} };
	is($permit_join->{capabilities}{power}, {
		read => 'permit_join', write => 'permit_join', kind => 'boolean',
		options => ['on', 'off'], activeValue => 'on', inactiveValue => 'off',
		valueMap => { read => { true => 'on', false => 'off' } },
	}, 'SemanticUI zeigt on/off statt der JSON-Befehlspayloads');
	unlike($reading_list . "\n" . $set_list,
		qr/zigbee2mqtt_bridge_(?:log_level|permit_join)/,
		'weder Reading noch Setter faellt auf die technische Object-ID zurueck');
};

subtest 'kollidierende Device-Discovery-Namen werden symmetrisch qualifiziert' => sub {
	setup();
	my $payload = <<'JSON';
{"device":{"identifiers":["collision"],"name":"Collision"},"components":{"sensor_battery":{"p":"sensor","name":"Sensor battery","state_topic":"collision/state","value_template":"{{ value_json.battery }}","device_class":"battery"},"device_battery":{"p":"sensor","name":"Device battery","state_topic":"collision/state","value_template":"{{ value_json.battery }}","device_class":"battery"}}}
JSON
	dispatch_message('mqtt', 'collision', 'homeassistant/device/collision/config', $payload);

	my $reading_list = attr_value('MQTT2_Collision', 'readingList');
	my $collision_descriptor = runtime_descriptor_for_line('MQTT2_Collision', $reading_list);
	my @collision_names = map { $_->{name} }
		@{ $collision_descriptor->{configuration}{readings} || [] };
	is(\@collision_names, [qw(device_battery sensor_battery)],
		'beide kollidierenden Pfade erhalten in der Referenz qualifizierte Namen');
	ok(!grep({ $_ eq 'battery' } @collision_names),
		'kein kollidierendes unqualifiziertes battery-Reading bleibt uebrig');
	is([sort map { $_->{id} } @{ $main::defs{MQTT2_Collision}{SEMANTIC_METADATA}{entities} }],
		[qw(device_battery sensor_battery)],
		'SemanticUI verwendet dieselben eindeutigen Namen');
};

subtest 'FindMy-Device-Discovery befuellt readingList trotz Jinja-dict.get' => sub {
	setup();
	my $payload = <<'JSON';
{"device":{"identifiers":["findmy2mqtt:person_1:ABCDEF123456"],"name":"Person1 iPhone","manufacturer":"Apple"},"origin":{"name":"findmy2mqtt","sw_version":"0.9.6"},"components":{"sensor_name":{"p":"sensor","name":"Name","unique_id":"fm_person_name","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('name') }}"},"sensor_battery":{"p":"sensor","name":"Battery","unique_id":"fm_person_battery","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('battery') }}","device_class":"battery","state_class":"measurement","unit_of_measurement":"%"},"binary_sensor_locationOld":{"p":"binary_sensor","name":"Location old","unique_id":"fm_person_locationOld","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('locationOld') }}","payload_on":"1","payload_off":"0","device_class":"problem"},"button_locate":{"p":"button","name":"Locate","unique_id":"fm_person_locate","command_topic":"findmy/person_1/ABCDEF123456/locate","payload_press":"1"},"text_message":{"p":"text","name":"Message","unique_id":"fm_person_message","command_topic":"findmy/person_1/ABCDEF123456/message","min":1,"max":255}},"qos":1}
JSON
	dispatch_message('mqtt', 'fm_person_device', 'homeassistant/device/fm_person_device/config', $payload);

	my $reading_list = attr_value('MQTT2_Person1_iPhone', 'readingList');
	my $set_list = attr_value('MQTT2_Person1_iPhone', 'setList');
	like($reading_list, qr/^\$DEVICETOPIC\/state:\.\* \{ MQTT2_DISCOVERY_runtimeRef/m,
		'gemeinsames FindMy-State-JSON wird als Referenz in readingList aufgenommen');
	my $findmy_descriptor = runtime_descriptor_for_line('MQTT2_Person1_iPhone', $reading_list);
	is([map { $_->{name} } @{ $findmy_descriptor->{configuration}{readings} || [] }],
		[qw(battery locationOld name)],
		'freie JSON-Namen bleiben hinter der Referenz erhalten');
	unlike($reading_list, qr/json2nameValue/, 'explizite FindMy-Pfade verwenden keinen JSON-Autocreate-Parser');
	like($set_list, qr/^Locate:noArg \$DEVICETOPIC\/locate 1$/m,
		'Locate-Setter verwendet den ausdruecklichen HA-Namen');
	like($set_list, qr/^message \$DEVICETOPIC\/message$/m, 'Message-Setter verwendet den kurzen Namen');
	is([sort map { $_->{id} } @{ $main::defs{MQTT2_Person1_iPhone}{SEMANTIC_METADATA}{entities} }],
		[qw(Locate battery message)],
		'SemanticUI enthaelt nur Setter und den explizit klassifizierten Battery-Sensor');
	is(reading_value('discovery', 'lastError'), 'none', 'FindMy-Discovery wird fehlerfrei verarbeitet');
};

subtest 'fremder Prefix und fehlerhaftes JSON' => sub {
	setup(prefixes => 'homeassistant');
	my $foreign = dispatch_message('mqtt', 'c', 'ha/switch/node/power/config', switch_payload());
	is($foreign, ['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'fremder Prefix wird mit NEXT weitergereicht');
	my $invalid = dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '{');
	is($invalid, ['MQTT2_DISCOVERY'], 'ungueltiges Discovery-JSON wird trotzdem konsumiert');
	like(reading_value('discovery', 'lastError'), qr/Ungueltiges JSON/, 'Parserfehler ist sichtbar');
};

subtest 'manuelle Zeilen bleiben konservativ erhalten' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	$main::attr{MQTT2_Node_node}{setList} .= "\nreboot:noArg node/reboot 1\npower:on,off manual/topic value";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload(command => 'node/power/newset'));
	my $set_list = attr_value('MQTT2_Node_node', 'setList');
	like($set_list, qr/reboot:noArg node\/reboot 1/, 'nicht kollidierende manuelle Zeile bleibt');
	like($set_list, qr/power:on,off manual\/topic value/, 'manuelle Kollision gewinnt');
	unlike($set_list, qr/newset/, 'kollidierende Discovery-Zeile wird ausgelassen');
	like(reading_value('discovery', 'conflicts'), qr/power/, 'Konflikt wird gemeldet');
};

subtest 'manuelles Reading gewinnt auch gegen gruppierte JSON-Auswertung' => sub {
	setup();
	my $sensor = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}","uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node node"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/runtimeRef/,
		'Ausgangszustand verwendet die kompakte Topic-Referenz');
	$main::attr{MQTT2_Node_node}{readingList} .= "\nmanual/topic:.* temperature";
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	is(attr_value('MQTT2_Node_node', 'readingList'), 'manual/topic:.* temperature',
		'manuelle Reading-Zeile ersetzt im konservativen Modus nur ihre JSON-Zuordnung');
	like(reading_value('discovery', 'conflicts'), qr/temperature/,
		'Konflikt der JSON-Zuordnung wird sichtbar gemeldet');
};

subtest 'Delete entfernt nur eigene Entity und Default behaelt Device' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temp/config', '{"stat_t":"node/temp","uniq_id":"node_temp","dev":{"ids":["node"],"name":"Node node"}}');
	$main::attr{MQTT2_Node_node}{readingList} .= "\nmanual/topic:.* manual";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'nur Switch-Entity entfernt');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/\$DEVICETOPIC\/temp/, 'Sensor-Entity bleibt');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/manual\/topic/, 'manuelles Reading bleibt');
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temp/config', '');
	ok($main::defs{MQTT2_Node_node}, 'letzte Entity loescht Device bei Default nicht');
	is(reading_value('discovery', 'discoveredEntities'), 0, 'keine aktive Entity mehr');
};

subtest 'autoDelete loescht nur rein automatisch verwaltetes Device' => sub {
	setup();
	$main::attr{discovery}{autoDelete} = 1;
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	ok(!$main::defs{MQTT2_Node_node}, 'unveraendertes Auto-Device wurde geloescht');

	setup();
	$main::attr{discovery}{autoDelete} = 1;
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	$main::attr{MQTT2_Node_node}{setList} .= "\nreboot:noArg node/reboot 1";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	ok($main::defs{MQTT2_Node_node}, 'Device mit manueller Zeile wird nicht geloescht');
};

subtest 'zwei IODevs mit getrennten Prefixen' => sub {
	reset_env();
	add_iodev('mqttA');
	add_iodev('mqttB');
	my ($a) = define_discovery('discoveryA', 'mqttA');
	my ($b) = define_discovery('discoveryB', 'mqttB');
	$main::attr{discoveryA}{discoveryPrefixes} = 'haA';
	$main::attr{discoveryB}{discoveryPrefixes} = 'haB';
	FHEM::MQTT2_DISCOVERY::Set($a, 'discoveryA', 'activate');
	FHEM::MQTT2_DISCOVERY::Set($b, 'discoveryB', 'activate');
	dispatch_message('mqttA', 'a', 'haA/switch/nodeA/power/config', switch_payload(id => 'nodeA'));
	dispatch_message('mqttB', 'b', 'haB/switch/nodeB/power/config', switch_payload(id => 'nodeB'));
	is(reading_value('discoveryA', 'discoveredEntities'), 1, 'IODev A hat eigene Entity');
	is(reading_value('discoveryB', 'discoveredEntities'), 1, 'IODev B hat eigene Entity');
	is(dispatch_message('mqttA', 'a', 'haB/switch/x/power/config', switch_payload(id => 'x')),
		['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'Prefix B wird auf IODev A nicht beansprucht');
};

subtest 'Runtime-Template und Command-Payload' => sub {
	my $reading = FHEM::MQTT2_DISCOVERY::runtime(
		'reading', '{{ value_json.temperature | round(1) }}', '{"temperature":23.46}', 'temperature',
	);
	is($reading, { temperature => '23.5' }, 'lesbares Runtime-Reading wertet ein komplexes Template sicher aus');
	is(FHEM::MQTT2_DISCOVERY::runtime('triggerReading',
			'{{ trigger.value.raw }}', '{"value":42,"raw":"11427,1042,407"}', 'rf_event'),
		{ rf_event => '11427,1042,407' }, 'Triggerkontext stellt den dekodierten JSON-Wert bereit');
	is(FHEM::MQTT2_DISCOVERY::runtime('triggerReading',
			'{{ trigger.payload }}', 'PRESS', 'rf_event'),
		{ rf_event => 'PRESS' }, 'Triggerkontext behaelt das rohe MQTT-Payload');
	is(FHEM::MQTT2_DISCOVERY::runtime('triggerReading',
			'{{ trigger.value.raw }}', '{"value":42}', 'rf_event'),
		undef, 'fehlender Triggerpfad erzeugt kein Reading');
	my $trigger_filter = {
		match_all => 0, payloads => [qw(OFF ON)],
	};
	is(FHEM::MQTT2_DISCOVERY::runtime('triggerReading',
			'{{ trigger.value_json.action }}', '{"action":"ON"}', 'action', $trigger_filter),
		{ action => 'ON' }, 'gruppierter Trigger filtert den bereits gerenderten Templatewert');
	is(FHEM::MQTT2_DISCOVERY::runtime('triggerReading',
			'{{ trigger.value_json.action }}', '{"action":"HOLD"}', 'action', $trigger_filter),
		undef, 'nicht angekuendigter Templatewert erzeugt kein Reading');
	is(FHEM::MQTT2_DISCOVERY::runtime('reading',
			'e3sgdmFsdWVfanNvbi50ZW1wZXJhdHVyZSB9fQ==', '{"temperature":23.5}', 'temperature'),
		undef, 'Base64 wird nicht mehr als Runtime-Template akzeptiert');
	my $topic_configuration = {
		readings => [
			{ name => 'log_level', template => '{{ value_json.log_level | lower }}' },
			{ name => 'version', template => '{{ value_json.version }}' },
		],
	};
	my $bridge_info = JSON::PP->new->canonical(1)->encode({
		log_level => 'INFO', version => '2.6.1',
		config_schema => { description => q{topic 'zigbee2mqtt/my_bulb' payload '{"state": "ON"}'} },
	});
	is(FHEM::MQTT2_DISCOVERY::runtime('topic', 'RuntimeTopic', $bridge_info, $topic_configuration),
		{ log_level => 'info', version => '2.6.1' },
		'Topic-Runtime liest Bridge-Info trotz escapeter JSON-Beispiele ohne Parserfehler');
	my $command = FHEM::MQTT2_DISCOVERY::runtime('templatePublish', 'node/set', '{{ value }}', 'level 42');
	is($command, 'node/set 42', 'Command-Wrapper trennt Set-Namen vom Wert');
	is(FHEM::MQTT2_DISCOVERY::runtime('choice', 'node/set', { eco => 'ECO' }, 'mode eco'),
		'node/set ECO', 'Choice-Wrapper verwendet ein sichtbares Mapping');
	is(FHEM::MQTT2_DISCOVERY::runtime('templateChoice',
			'node/set', '{{ value | lower }}', { eco => 'ECO' }, 'mode eco'),
		'node/set eco', 'Choice-Template verarbeitet erst das sichtbare Mapping und dann das Template');
	is(FHEM::MQTT2_DISCOVERY::runtime('publish', 'node/set', 'PRESS'),
		'node/set PRESS', 'Publish-Wrapper verwendet Klartextargumente');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonPublish', 'node/set', 'brightness', 'brightness 128'),
		'node/set {"brightness":128}', 'JSON-Command wird kanonisch und ohne Stringverkettungs-Injection erzeugt');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonChoice',
			'node/set', 'state', { on => 'ON', off => 'OFF' }, 'state on'),
		'node/set {"state":"ON"}', 'JSON-Choice codiert nur den erlaubten gemappten Stringwert');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonPublish',
			'node/set', 'input', 'volume 42', { command => 'volume' }),
		'node/set {"command":"volume","input":42}',
		'JSON-Command verbindet validierte Konstantfelder mit dem numerischen Wert');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonChoice',
			'node/set', 'state', { on => 'ON' }, 'state on', { source => 'test' }),
		'node/set {"source":"test","state":"ON"}',
		'JSON-Choice behaelt optionale validierte Konstantfelder');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonPublish',
			'node/set', 'input', 'volume 42', { input => 'collision' }), undef,
		'dynamisches JSON-Feld kann nicht durch eine Konstante ueberschrieben werden');

	is(FHEM::MQTT2_DISCOVERY::runtime('templatePublish', 'x', 'x', 'state value'), undef,
		'Template-Publish lehnt ein ungueltiges Klartext-Template ab');
	is(FHEM::MQTT2_DISCOVERY::runtime('choice', 'x', 'x', 'state on'), undef,
		'Choice-Publish lehnt ein ungueltiges Mapping ab');
	is(FHEM::MQTT2_DISCOVERY::runtime('templateChoice', 'x', 'x', { on => 'ON' }, 'state on'), undef,
		'Choice-Template lehnt ein ungueltiges Template ab');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonPublish', 'x', 'key', 'brightness invalid'), undef,
		'JSON-Publish lehnt einen nichtnumerischen Wert ab');
	is(FHEM::MQTT2_DISCOVERY::runtime('jsonChoice',
			'x', 'state', { on => 'ON' }, 'state invalid'), undef,
		'JSON-Choice lehnt einen nicht deklarierten Auswahlwert ab');
	my $json_map = FHEM::MQTT2_DISCOVERY::runtimeJSONMap(
		{ state => 'availability', battery => 'battery' },
		{ availability => 'state_availability' },
	);
	is($json_map, {
		state => 'state_availability', availability => 'state_availability',
		battery => 'battery',
	}, 'reservierte Namen werden in vorhandenen jsonMap-Zielen und rohen JSON-Feldern getrennt');
	$main::defs{JSONMapRuntime} = {
		NAME => 'JSONMapRuntime', JSONMAP => { state => 'availability' },
	};
	is(FHEM::MQTT2_DISCOVERY::runtimeJSONMap(
			'JSONMapRuntime', { availability => 'state_availability' }), {
		state => 'state_availability', availability => 'state_availability',
	}, 'der Runtime-Wrapper liest jsonMap ueber den von MQTT2_DEVICE bereitgestellten Devicenamen');
	{
		no warnings qw(once redefine);
		local *main::json2nameValue = sub {
			my ($event, $prefix, $mapping) = @_;
			return { event => $event, prefix => $prefix, mapping => $mapping };
		};
		$main::defs{JSONMapRuntime}{helper}{mqtt2_discovery_availability_reading} = 'availability';
		is(FHEM::MQTT2_DISCOVERY::jsonReadings(
				'JSONMapRuntime', 'STATE', '{"availability":"payload"}'), {
			event => '{"availability":"payload"}', prefix => '', mapping => {
				state => 'state_availability', availability => 'state_availability',
			},
		}, 'der kompakte Wrapper qualifiziert den Defaultnamen anhand des Topic-Pfads');

		$main::defs{JSONMapRuntime}{JSONMAP} = { state => 'deviceAvailability' };
		$main::defs{JSONMapRuntime}{helper}{mqtt2_discovery_availability_reading}
			= 'deviceAvailability';
		is(FHEM::MQTT2_DISCOVERY::jsonReadings(
				'JSONMapRuntime', 'UPTIME', '{"deviceAvailability":"payload"}'), {
			event => '{"deviceAvailability":"payload"}', prefix => '', mapping => {
				state => 'uptime_deviceAvailability',
				deviceAvailability => 'uptime_deviceAvailability',
			},
		}, 'ein frei gewaehlter Availability-Name wird ebenso verbindlich reserviert');
		is(FHEM::MQTT2_DISCOVERY::jsonReadings(
				'JSONMapRuntime', 'UPTIME', '{}',
				{ deviceAvailability => 'announced_availability' }), {
			event => '{}', prefix => '', mapping => {
				state => 'announced_availability',
				deviceAvailability => 'announced_availability',
			},
		}, 'explizite Discovery-Zuordnungen behalten vor dem Reservierungsschutz Vorrang');
	}
};

subtest 'Runtime-Availability verknuepft Quellen nach HA-Semantik' => sub {
	setup();
	my $device = 'AvailabilityRuntime';
	$main::defs{$device} = {
		NAME => $device, TYPE => 'MQTT2_DEVICE', READINGS => {},
	};
	my $apply = sub {
		my ($updates) = @_;

		for my $reading (keys %{ $updates || {} }) {
			$main::defs{$device}{READINGS}{$reading} = { VAL => $updates->{$reading} };
		}

	};
	my $source_device = '.availability_device';
	my $source_bridge = '.availability_bridge';
	my $policy_all = '.availability_policy_all';
	my $policy = {
		reading => $policy_all, mode => 'all',
		sources => [$source_device, $source_bridge],
	};
	my $configuration = sub {
		my ($reading) = @_;
		return {
			sources => [{
				reading => $reading, template => '{{ value_json.state }}',
				available => 'online', unavailable => 'offline',
			}],
			policies => [$policy],
		};
	};

	my $device_online = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{"state":"online"}', $configuration->($source_device));
	is($device_online, {
		$source_device => 'online', $policy_all => 'unknown', availability => 'unknown',
	}, 'all bleibt unknown, solange die zweite Quelle noch unbekannt ist');
	$apply->($device_online);
	my $bridge_online = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{"state":"online"}', $configuration->($source_bridge));
	is($bridge_online, {
		$source_bridge => 'online', $policy_all => 'online', availability => 'online',
	}, 'all wird erst bei zwei verfuegbaren Quellen online');
	$apply->($bridge_online);
	my $bridge_offline = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{"state":"offline"}', $configuration->($source_bridge));
	is($bridge_offline->{availability}, 'offline',
		'all wird bei einer ausgefallenen Quelle wieder offline');
	$main::defs{$device}{READINGS}{'.availability_io'} = { VAL => 'offline' };
	my $broker_guard = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{"state":"online"}', $configuration->($source_bridge));
	is($broker_guard->{ $source_bridge }, 'online',
		'Quellzustand wird trotz getrennter Brokerverbindung weiter ausgewertet');
	is($broker_guard->{availability}, 'offline',
		'getrennte Brokerverbindung verhindert ein sichtbares Online-Ergebnis');
	delete $main::defs{$device}{READINGS}{'.availability_io'};
	my $source_common = '.availability_common';
	my $source_supported = '.availability_supported';
	my $source_optional = '.availability_optional';
	my $policy_supported = '.availability_policy_supported';
	my $policy_optional = '.availability_policy_optional';
	$main::defs{$device}{READINGS}{$source_common} = { VAL => 'online' };
	my $field_configuration = {
		sources => [
			{
				reading => $source_supported,
				template => q!{{'online' if value_json['supported'] is defined else 'offline'}}!,
				available => 'online', unavailable => 'offline',
			},
			{
				reading => $source_optional,
				template => q!{{'online' if value_json['optional'] is defined else 'offline'}}!,
				available => 'online', unavailable => 'offline',
			},
		],
		policies => [
			{
				reading => $policy_supported, mode => 'all',
				sources => [$source_common, $source_supported],
			},
			{
				reading => $policy_optional, mode => 'all',
				sources => [$source_common, $source_optional],
			},
		],
	};
	my $partially_supported = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{"supported":1}', $field_configuration,
	);
	is([$partially_supported->{$policy_supported},
			$partially_supported->{$policy_optional},
			$partially_supported->{availability}], [qw(online offline online)],
		'eine fehlende optionale Entity setzt ein erreichbares Sammeldevice nicht offline');
	my $unsupported = FHEM::MQTT2_DISCOVERY::runtime('availability',
		$device, '{}', $field_configuration,
	);
	is([$unsupported->{$policy_supported}, $unsupported->{$policy_optional},
			$unsupported->{availability}], [qw(offline offline offline)],
		'erst ausschliesslich ausgefallene Entity-Regeln setzen das Sammeldevice offline');

	my $custom_configuration = $configuration->($source_device);
	$custom_configuration->{reading} = 'MQTT2DiscoveryAvailability';
	my $custom = FHEM::MQTT2_DISCOVERY::runtime(
		'availability', $device, '{"state":"online"}', $custom_configuration,
	);
	is($custom->{MQTT2DiscoveryAvailability}, 'online',
		'die Runtime schreibt die Gesamtverfuegbarkeit in den konfigurierten Namen');
	ok(!exists($custom->{availability}),
		'die Runtime erzeugt bei festem Namen kein zusaetzliches Standardreading');

	my $any_configuration = {
		sources => [{
			reading => '.availability_any_a', available => 'up', unavailable => 'down',
		}],
		policies => [{
			reading => '.availability_policy_any', mode => 'any',
			sources => ['.availability_any_a', '.availability_any_b'],
		}],
	};
	my $any = FHEM::MQTT2_DISCOVERY::runtime('availability', $device, 'up', $any_configuration);
	is($any->{availability}, 'online',
		'any wird bereits durch eine einzelne verfuegbare Quelle online');

	my $latest_configuration = {
		sources => [{
			reading => '.availability_latest', available => 'up', unavailable => 'down',
		}],
		policies => [{
			reading => '.availability_policy_latest', mode => 'latest',
			sources => ['.availability_latest', '.availability_other'],
		}],
	};
	my $latest = FHEM::MQTT2_DISCOVERY::runtime(
		'availability', $device, 'down', $latest_configuration);
	is($latest->{availability}, 'offline',
		'latest uebernimmt den Zustand der zuletzt empfangenen Quelle');
	is(FHEM::MQTT2_DISCOVERY::runtime(
			'availability', $device, 'unbekannt', $latest_configuration), {},
		'nicht deklarierte Payloads veraendern keine Availability-Readings');
};

subtest 'OpenMQTTGateway-typische HA-Discovery' => sub {
	setup();
	my $gateway_sensor = '{"stat_t":"home/OMG_DEVELOPMENT/433toMQTT/#","avty_t":"home/OMG_DEVELOPMENT/LWT","name":"gatewayRF","uniq_id":"246F287AF0C4-gatewayRF","val_tpl":"{{ value_json.value | is_defined }}","pl_avail":"online","pl_not_avail":"offline","device":{"ids":["246F287AF0C4"],"name":"OMG_DEVELOPMENT","mdl":"[\\"WebUI\\",\\"RF\\"]","mf":"OMG_community"}}';
	dispatch_message('mqtt', 'omg', 'homeassistant/sensor/246F287AF0C4-gatewayRF/config', $gateway_sensor);
	ok($main::defs{MQTT2_OMG_DEVELOPMENT}, 'OMG-Gateway wird ueber seine Device-ID angelegt');
	like(attr_value('MQTT2_OMG_DEVELOPMENT', 'readingList'),
		qr{\$DEVICETOPIC\(\?:/\.\*\)\?:\.\*},
		'RF-Sensor-Wildcard wird unter dem gemeinsamen Devicetopic wirksam');
	like(attr_value('MQTT2_OMG_DEVELOPMENT', 'readingList'), qr/runtimeRef/,
		'einfaches OMG-is_defined-Template verwendet die kompakte Topic-Referenz');
	is(reading_value('discovery', 'warningCount'), 0, 'OMG-is_defined erzeugt keine Warnung');

	my $rtl_sensor = '{"stat_t":"+/+/RTL_433toMQTT/Oregon-THGR810/1/169","name":"temperature","uniq_id":"Oregon-THGR810-1-169-temperature_C","val_tpl":"{{ value_json.temperature_C | is_defined }}","unit_of_meas":"C","dev_cla":"temperature","state_class":"measurement","device":{"ids":["Oregon-THGR810-1-169"],"name":"Oregon-THGR810-1-169","mdl":"Oregon-THGR810","via_device":"OpenMQTTGateway"}}';
	dispatch_message('mqtt', 'omg', 'homeassistant/sensor/Oregon-THGR810-1-169-temperature_C/config', $rtl_sensor);
	like(attr_value('MQTT2_Oregon_THGR810_1_169', 'readingList'),
		qr{^\[\^/\]\*/\[\^/\]\*/RTL_433toMQTT/Oregon-THGR810/1/169:\.\*}m,
		'fuehrende RTL_433-Wildcards werden ohne unsicheres Devicetopic gerendert');

	my $rf_trigger = '{"atype":"trigger","p":"device_automation","type":"Received","stype":"RF-15524904","device":{"ids":["246F287AF0C4"],"name":"OMG_DEVELOPMENT","mf":"OMG_community"},"val_tpl":"{{ trigger.value.raw }}","topic":"home/OMG_DEVELOPMENT/433toMQTT/15524904"}';
	dispatch_message('mqtt', 'omg', 'homeassistant/device_automation/246F287AF0C4/15524904/config', $rf_trigger);
	my $omg_reading_list = attr_value('MQTT2_OMG_DEVELOPMENT', 'readingList');
	my ($trigger_line) = grep { /\/15524904:/ } split /\n/, $omg_reading_list;
	like($trigger_line, qr/MQTT2_DISCOVERY_runtimeRef/,
		'OMG-RF-Device-Trigger verwendet eine kompakte Referenz');
	my $trigger_descriptor = runtime_descriptor_for_line('MQTT2_OMG_DEVELOPMENT', $trigger_line);
	is($trigger_descriptor->{runtime}, 'triggerReading',
		'OMG-RF-Device-Trigger bleibt im sicheren Triggerkontext');
	is($trigger_descriptor->{filter}{match_all}, 1,
		'die unbedingte Trigger-Variante bleibt in der Referenz erhalten');
};

subtest 'uebernommenes Bestandsdevice erhaelt keine impliziten Semantic-Metadaten' => sub {
	setup();
	$main::defs{MQTT2_Node_node} = { NAME => 'MQTT2_Node_node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{discovery}{existingDevice} = 'replace';
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	ok(!exists $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA},
		'manuell vorhandenes Device bleibt semantisch unberuehrt');
};

subtest 'unsicheres Template erzeugt kein leeres Device' => sub {
	setup();
	my $payload = '{"stat_t":"node/secret","val_tpl":"{{ states(\"sensor.secret\") }}","uniq_id":"secret","dev":{"ids":["secret"],"name":"Secret"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/secret/value/config', $payload);
	ok(!$main::defs{MQTT2_Secret}, 'abgelehntes Template legt kein leeres MQTT2_DEVICE an');
	like(reading_value('discovery', 'lastWarning'), qr/keine sicher abbildbare Funktion/, 'Ablehnung wird sichtbar gemeldet');
};

subtest 'Zigbee2MQTT-Firmware-Update wird vollstaendig integriert' => sub {
	setup();
	my $value_template = q!{"latest_version":"{{ value_json['update']['latest_version'] }}","installed_version":"{{ value_json['update']['installed_version'] }}","update_percentage":{{ value_json['update'].get('progress', 'null') }},"in_progress":{{ (value_json['update']['state'] == 'updating')|lower }}}!;
	my $payload = JSON::PP->new->canonical(1)->encode({
		availability => [
			{ topic => 'zigbee2mqtt/bridge/state', value_template => '{{ value_json.state }}' },
			{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/availability', value_template => '{{ value_json.state }}' },
		],
		availability_mode => 'all',
		command_topic => 'zigbee2mqtt/bridge/request/device/ota_update/update',
		default_entity_id => 'update.wz_lightstrip_licht',
		device => {
			hw_version => 0,
			identifiers => ['zigbee2mqtt_0x001788010c570283'],
			manufacturer => 'Philips',
			model => 'Hue white and color ambiance LightStrip plus',
			model_id => '8718699703424',
			name => 'WZ_LIGHTSTRIP_LICHT',
			sw_version => '1.163.1',
			via_device => 'zigbee2mqtt_bridge_0x983268fffe1c1485',
		},
		device_class => 'firmware', entity_category => 'config', name => undef,
		object_id => 'wz_lightstrip_licht',
		origin => { name => 'Zigbee2MQTT', sw => '2.13.0', url => 'https://www.zigbee2mqtt.io' },
		payload_install => '{"id":"0x001788010c570283"}',
		state_topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT',
		unique_id => '0x001788010c570283_update_zigbee2mqtt',
		value_template => $value_template,
	});
	my $topic = 'homeassistant/update/0x001788010c570283/update/config';
	is(dispatch_message('mqtt', 'zigbee2mqtt', $topic, $payload), ['MQTT2_DISCOVERY'],
		'Update-Discovery wird konsumiert');
	my $target = 'MQTT2_WZ_LIGHTSTRIP_LICHT';
	ok($main::defs{$target}, 'Update wird dem vorhandenen Zigbee2MQTT-Geraet zugeordnet');
	is(reading_value('discovery', 'lastError'), 'none',
		'die Update-Komponente erzeugt keinen Parserfehler');
	is(reading_value('discovery', 'warningCount'), 0,
		'das vollstaendige Zigbee2MQTT-Template erzeugt keine Warnung');

	my $reading_list = attr_value($target, 'readingList');
	my ($state_line) = grep {
		my $candidate = runtime_descriptor_for_line($target, $_);
		ref($candidate) eq 'HASH' && ($candidate->{operation} || '') eq 'topic';
	} grep { /WZ_LIGHTSTRIP_LICHT/ && /MQTT2_DISCOVERY_runtimeRef/ }
		split /\n/, $reading_list;
	ok(defined($state_line), 'Update-State-Topic wird in readingList aufgenommen');
	my $descriptor = runtime_descriptor_for_line($target, $state_line);
	is($descriptor->{operation}, 'topic',
		'das komplexe Update-Template bleibt als sichere Topic-Referenz gespeichert');
	is($descriptor->{configuration}{readings}[0]{template}, $value_template,
		'die Referenz behaelt das originale Zigbee2MQTT-Template');
	my ($reference) = $state_line =~ /'(r_[a-f0-9]+)'/;
	my $state = '{"update":{"latest_version":"1.164.0","installed_version":"1.163.1","progress":42,"state":"updating"}}';
	my $reading_name = $descriptor->{configuration}{readings}[0]{name};
	is($reading_name, 'update',
		'die Root-Update-Entity wiederholt den Zigbee2MQTT-Devicenamen nicht als Reading');
	is(FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $state), {
		$reading_name => '{"latest_version":"1.164.0","installed_version":"1.163.1","update_percentage":42,"in_progress":true}',
	}, 'Update-State wird zur Laufzeit als gueltiges JSON ausgewertet');

	my $set_list = attr_value($target, 'setList');
	like($set_list,
		qr/^install:noArg .*bridge\/request\/device\/ota_update\/update \{"id":"0x001788010c570283"\}$/m,
		'install sendet exakt payload_install an das OTA-Command-Topic');
	is($main::defs{$target}{SEMANTIC_METADATA}{entities}[0]{class}, 'update',
		'semantische Metadaten kennzeichnen die Firmware-Update-Entity');
	is($main::defs{$target}{SEMANTIC_METADATA}{entities}[0]{capabilities}{install}{write}, 'install',
		'semantische Installationsaktion verweist auf den FHEM-Setter');
};
unlike(join("\n", @{ command_log() }), qr/(?:^|\s)save(?:\s|$)/, 'kein Integrationspfad ruft save auf');

done_testing;
