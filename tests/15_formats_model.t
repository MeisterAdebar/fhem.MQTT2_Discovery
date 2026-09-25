# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Renderer ();

my $prefixes = ['homeassistant', 'tasmota/discovery'];

# Liefert ein kontrolliertes Adapterergebnis fuer Format- und Modellvertragstests.
sub consume {
	my ($topic, $payload, $states) = @_;
	return MQTT2_Discovery::FormatRegistry::consume(
		topic => $topic, payload => $payload, prefixes => $prefixes,
		states => $states || {},
	);
}

subtest 'gemeinsame Parser-Modell-Grenze validiert Ergebnisse' => sub {
	my $missing = MQTT2_Discovery::Model::from_parser_result(
		adapter => 'test', parsed => undef,
	);
	is([$missing->{status}, $missing->{adapter}, $missing->{error_class}],
		['error', 'test', 'format'], 'unstrukturiertes Parserergebnis wird kontrolliert abgewiesen');

	my $invalid = MQTT2_Discovery::Model::from_parser_result(
		adapter => 'test', parsed => { status => 'ok', entities => [{}] },
	);
	is([$invalid->{status}, $invalid->{adapter}, $invalid->{error_class}],
		['error', 'test', 'canonical'], 'ungueltige Parser-Entity scheitert an der kanonischen Grenze');
};

subtest 'grobe Formaterkennung trennt Discovery von State' => sub {
	is(consume('zigbee2mqtt/wohnzimmer', '{"temperature":21}')->{status}, 'next',
		'normales Zigbee2MQTT-State-Topic wird nicht beansprucht');
	is(consume('homeassistant/sensor/node/temperature/state', '21')->{status}, 'next',
		'HA-aehnliches State-Topic wird nicht als Discovery behandelt');
	my $bad = consume('homeassistant/sensor/node/temperature/config', '{');
	is([$bad->{status}, $bad->{adapter}, $bad->{error_class}],
		['error', 'homeassistant', 'json'],
		'erkannte, aber defekte HA-Discovery faellt nicht auf ein anderes Format zurueck');
};

subtest 'Home Assistant normalisiert in Modellversion 1' => sub {
	my $result = consume(
		'homeassistant/switch/node/power/config',
		'{"stat_t":"node/state/power","cmd_t":"node/command/power","pl_on":"1","pl_off":"0","stat_on":"enabled","stat_off":"disabled","dev":{"ids":["node"],"name":"Node"}}',
	);
	is([$result->{status}, $result->{adapter}], ['ok', 'homeassistant'], 'HA-Adapter wurde ausgewaehlt');
	my $event = $result->{events}[0];
	is($event->{schema_version}, 1, 'kanonische Modellversion ist explizit');
	is($event->{entity}{kind}, 'switch', 'Geraeteklasse ist normalisiert');
	is($event->{signals}[0]{topic}, 'node/state/power', 'State-Kanal ist als Signal beschrieben');
	is($event->{commands}[0]{topic}, 'node/command/power', 'Command-Kanal ist separat beschrieben');
	ok(!exists($event->{entity}{configuration}{state_topic})
		&& !exists($event->{entity}{configuration}{command_topic}),
		'Binding-Felder werden nicht zusaetzlich in configuration dupliziert');
	is([$event->{entity}{configuration}{state_on}, $event->{entity}{configuration}{state_off}],
		['enabled', 'disabled'],
		'getrennte Switch-Zustandswerte passieren die kanonische Modellgrenze');
	is(MQTT2_Discovery::Model::validate($event), undef, 'kanonisches Modell ist gueltig');
	my $mapping = MQTT2_Discovery::Mapper::map_model(model => $event, io_name => 'mqtt');
	ok($mapping->{ok}, 'allgemeiner Mapper verarbeitet das Modell ohne Formatparser');
};

subtest 'Availability passiert die kanonische Modellgrenze als eigene Rolle' => sub {
	my $result = consume(
		'homeassistant/light/node/light/config',
		'{"schema":"json","stat_t":"node/state","cmd_t":"node/set","avty":[{"t":"node/availability","val_tpl":"{{ value_json.state }}"},{"t":"controller/health","val_tpl":"{{ value_json.status }}"}],"avty_mode":"all","pl_avail":"up","pl_not_avail":"down","dev":{"ids":["node"],"name":"Node"}}',
	);
	my $event = $result->{events}[0];
	is($event->{availability_mode}, 'all',
		'der HA-Modus ist eine ausdrueckliche kanonische Verknuepfungsregel');
	is($event->{availability}, [
		{
			topic => 'node/availability', value_template => '{{ value_json.state }}',
			payload_available => 'up', payload_not_available => 'down',
		},
		{
			topic => 'controller/health', value_template => '{{ value_json.status }}',
			payload_available => 'up', payload_not_available => 'down',
		},
	], 'jede Availability-Quelle enthaelt Topic, Template und Vergleichsvertrag');
	ok(!exists($event->{entity}{configuration}{availability}),
		'Availability wird nicht als normale Komponenten-Konfiguration dupliziert');
	my ($legacy, $error) = MQTT2_Discovery::Model::to_entity($event);
	is($error, undef, 'kanonische Availability laesst sich fuer den Mapper projizieren');
	is([$legacy->{availability_mode}, $legacy->{availability}],
		['all', $event->{availability}], 'Mapper-Projektion erhaelt Quellen und Modus unveraendert');

	my $invalid = { %$event, availability_mode => 'xor' };
	is(MQTT2_Discovery::Model::validate($invalid), 'Ungueltiger Availability-Modus',
		'nicht definierte Verknuepfungsarten werden an der Modellgrenze abgewiesen');
};

subtest 'HA-Entity-Name passiert die kanonische Modellgrenze' => sub {
	my $result = consume(
		'homeassistant/button/node/node_identify/config',
		'{"command_topic":"node/set/not_the_name","default_entity_id":"button.node_identify","device_class":"identify","payload_press":"identify","device":{"identifiers":["node"],"name":"Node"}}',
	);
	my $event = $result->{events}[0];
	is($event->{entity}{logical_name}, 'identify',
		'der HA-Adapter liefert den nach HA-Regeln bestimmten logischen Entity-Namen');
	is($event->{entity}{configuration}{default_entity_id}, 'button.node_identify',
		'default_entity_id bleibt getrennt als HA-Konfiguration erhalten');
	ok(!exists($event->{commands}[0]{name}),
		'das Command-Binding erfindet keinen Namen aus seinem Topic');
	my $mapping = MQTT2_Discovery::Mapper::map_model(model => $event, io_name => 'mqtt');
	is(MQTT2_Discovery::Mapper::Renderer::render_entry($mapping->{set_lines}[0]),
		'identify:noArg node/set/not_the_name identify',
		'der protokollneutrale Mapper verwendet nur den kanonischen logischen Namen');
};

subtest 'HA-Root-Entity wird unabhaengig von der Schreibweise erkannt' => sub {
	my $result = consume(
		'homeassistant/update/node/node/config',
		'{"state_topic":"node/update","device":{"identifiers":["node"],"name":"Node"}}',
	);
	my $event = $result->{events}[0];
	is($event->{entity}{root}, 1,
		'kleingeschriebene object_id und Device-Name bezeichnen dieselbe Root-Entity');
	my ($legacy, $error) = MQTT2_Discovery::Model::to_entity($event);
	is($error, undef, 'Root-Entity laesst sich fuer den Mapper projizieren');
	is($legacy->{_canonical_root}, 1, 'die Mapper-Projektion erhaelt die Root-Markierung');
};

subtest 'HA-JSON-Light endet als allgemeiner Codecvertrag am Modell' => sub {
	my $result = consume(
		'homeassistant/light/node/light/config',
		'{"schema":"json","stat_t":"node/light","cmd_t":"node/light/set","brightness":true,"dev":{"ids":["node"],"name":"Node"}}',
	);
	my $event = $result->{events}[0];
	my %signals = map { ($_->{id} => $_) } @{ $event->{signals} };
	my %commands = map { ($_->{id} => $_) } @{ $event->{commands} };
	is($signals{state}{template}, '{{ value_json.state }}',
		'HA-Parser liefert das vollstaendig normalisierte State-Signal');
	is($commands{command}{codec},
		{ format => 'json', key => 'state', value_type => 'string' },
		'kanonischer State-Command kennt nur noch den allgemeinen JSON-Codec');
	is($commands{brightness}{codec},
		{ format => 'json', key => 'brightness', value_type => 'number' },
		'kanonischer Brightness-Command ist protokollneutral typisiert');
	delete @{$event->{entity}{configuration}}{qw(command_codec brightness_command_codec)};
	my $mapping = MQTT2_Discovery::Mapper::map_model(model => $event, io_name => 'mqtt');
	is([map { MQTT2_Discovery::Mapper::Renderer::render_entry($_) }
			@{ $mapping->{set_lines} }], [
		q{state:ON,OFF node/light/set {"state":"$EVTPART1"}},
		q{brightness:slider,0,1,255 node/light/set {"brightness":$EVTPART1}},
	], 'Mapper rendert ausschliesslich aus den kanonischen Bindings');
};

subtest 'Tasmota gewinnt vor dem HA-Fallback und liefert generische Zusatzsignale' => sub {
	my %states;
	my $config = '{"dn":"Plug","mac":"AABBCCDDEEFF","state":["OFF","ON"],"t":"plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"ver":1}';
	my $result = consume('tasmota/discovery/AABBCCDDEEFF/config', $config, \%states);
	is([$result->{status}, $result->{adapter}], ['ok', 'tasmota'], 'spezifischer Tasmota-Adapter wurde ausgewaehlt');
	my ($upsert) = grep { $_->{operation} eq 'upsert' } @{ $result->{events} };
	ok($upsert, 'Tasmota liefert ein kanonisches Upsert');
	is($upsert->{schema_version}, 1, 'auch Tasmota verwendet dieselbe Modellversion');
	is([map { $_->{type} } @{ $upsert->{extensions}{supplemental_signals} }],
		[qw(payload json_flatten json_flatten json_flatten json_sequence json_flatten payload payload)],
		'Tasmota-Profil ist als allgemeine Signaltypen normalisiert');
	ok(!grep({ exists($_->{codec}) } @{ $upsert->{commands} }),
		'Tasmota-Commands erhalten keine HA-JSON-Codecs');
};

done_testing;
