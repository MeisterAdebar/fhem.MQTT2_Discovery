# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use Scalar::Util qw(refaddr);
use lib 'lib/FHEM';
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::NameResolver ();
use MQTT2_Discovery::Mapper::Renderer ();
use MQTT2_Discovery::Mapper::Semantics ();
use MQTT2_Discovery::Model ();

# Die bequemen Legacy-Fassaden existieren nur noch lokal im Test. Produktionscode
# arbeitet ausschliesslich ueber das kanonische Modell und besessene Mapping-Saetze.
{
	no warnings 'redefine';
	*MQTT2_Discovery::Mapper::map_entity = sub {
		my (%args) = @_;
		my $model = MQTT2_Discovery::Model::from_entity(
			adapter => 'test', entity => $args{entity},
		);
		my $mapping = MQTT2_Discovery::Mapper::map_model(%args, model => $model);
		return $mapping if !$mapping->{ok};
		my %runtime_references;

		for my $group (qw(reading_lines set_lines)) {
			for my $entry (@{ $mapping->{$group} || [] }) {
				$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry(
					$entry, undef, \%runtime_references,
				);
			}
		}

		$mapping->{_test_runtime_refs} = \%runtime_references;
		return $mapping;
	};
	*MQTT2_Discovery::Mapper::resolve_mapping_names = sub {
		my ($source, $reserved) = @_;
		my $json = JSON::PP->new;
		my $owned = $json->decode($json->encode(ref($source) eq 'ARRAY' ? $source : []));
		return MQTT2_Discovery::Mapper::NameResolver::resolve_owned($owned, $reserved);
	};
}

# Loest die kurze Referenz einer bereits testweise gerenderten Mapping-Zeile auf.
sub descriptor_from_references {
	my ($references, $line) = @_;
	my ($reference) = ($line // '') =~ /'(r_[a-f0-9]+)'/;
	return defined($reference) ? $references->{$reference} : undef;
}

sub runtime_descriptor {
	my ($mapping, $line) = @_;
	return descriptor_from_references($mapping->{_test_runtime_refs}, $line);
}

# Rendert Gruppen samt separat pruefbarer deklarativer Runtime-Registry.
sub render_with_references {
	my ($entries, $device_topic, $reserved) = @_;
	my %references;
	my $rendered = MQTT2_Discovery::Mapper::render_entries(
		$entries, $device_topic, $reserved, \%references,
	);
	return ($rendered, \%references);
}

# Erzeugt eine kanonische Test-Entity mit gezielt ueberschreibbaren Feldern.
sub entity {
	my ($component, %extra) = @_;
	return {
		operation => 'upsert', component => $component, object_id => $extra{object_id} || $component,
		entity_key => "topic|$component", discovery_topic => 'homeassistant/device/node/config',
		unique_id => "node_$component", state_topic => "node/$component/state",
		command_topic => "node/$component/set", device => { identifiers => ['node'], name => 'Node' },
		raw_metadata => {}, %extra,
	};
}

my %extra = (
	sensor         => {},
	binary_sensor  => { payload_on => 'YES', payload_off => 'NO' },
	switch         => { payload_on => '1', payload_off => '0' },
	button         => { payload_press => 'PRESS' },
	number         => { min => -10, max => 50, step => 0.5 },
	select         => { options => ['Auto', 'Eco mode', 'A,B'] },
	text           => {},
	light          => { brightness_command_topic => 'node/light/brightness/set', brightness_state_topic => 'node/light/brightness' },
	cover          => { position_command_topic => 'node/cover/position/set', position_topic => 'node/cover/position' },
	climate        => {
		current_temperature_topic => 'node/climate/current',
		temperature_state_topic => 'node/climate/target', temperature_command_topic => 'node/climate/target/set',
		min_temp => 16, max_temp => 30, temp_step => 0.5,
		mode_state_topic => 'node/climate/mode', mode_command_topic => 'node/climate/mode/set', modes => [qw(off auto heat)],
	},
	fan            => { percentage_command_topic => 'node/fan/percentage/set', percentage_state_topic => 'node/fan/percentage' },
	media_player => {
		preferred_entity_name => 'player', value_template => '{{ value_json.transportState }}',
		state_reading_name => 'transportState',
		volume_state_topic => 'node/media/state', volume_value_template => '{{ value_json.volume.Master }}',
		volume_reading_name => 'volume', volume_command_topic => 'node/media/control',
		volume_command_codec => { format => 'json', key => 'input', value_type => 'number', constants => { command => 'volume' } },
		mute_state_topic => 'node/media/state', mute_value_template => '{{ value_json.mute.Master }}',
		mute_reading_name => 'mute', mute_command_topic => 'node/media/control',
		payload_mute => '{"command":"mute"}', payload_unmute => '{"command":"unmute"}',
		payload_play => '{"command":"play"}',
	},
	update         => { command_set_name => 'install', payload_install => '{"id":"node"}' },
	lock           => {},
	device_tracker => {},
	event          => { event_types => [qw(single double)] },
	device_automation => {
		state_topic => 'node/button_1', payload => 'PRESS', type => 'button_short_press', subtype => 'button_1',
	},
);

for my $component (sort keys %extra) {
	my $result = MQTT2_Discovery::Mapper::map_entity(
		entity => entity($component, %{ $extra{$component} }), io_name => 'mqtt', cid => 'client',
	);
	ok($result->{ok}, "$component wird gemappt");
	is($result->{identity}, 'mqtt|id|node', "$component verwendet die starke Device-ID");
	is($result->{proposed_name}, 'Node', "$component ergibt standardmaessig einen Devicenamen ohne Prefix");
	ok(@{ $result->{reading_lines} } || @{ $result->{set_lines} }, "$component erzeugt keine leere Aenderung");
}

my $pac = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', device => { identifiers => ['dc1ed51b96f8'], name => 'pac-1b96f8' }),
	io_name => 'mqtt', cid => 'client',
);
is($pac->{proposed_name}, 'pac_1b96f8', 'Devicename mit Bindestrich wird FHEM-konform normalisiert');

my $prefixed = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor'), io_name => 'mqtt', cid => 'client', name_prefix => 'Tasmota_',
);
is($prefixed->{proposed_name}, 'Tasmota_Node', 'ein optionaler eigener Prefix wird vorangestellt');

subtest 'optionale Features' => sub {
	my $light = MQTT2_Discovery::Mapper::map_entity(entity => entity('light'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /brightness/ } @{ $light->{set_lines} }), 'Light ohne Brightness-Topic erzeugt keinen Brightness-Setter');
	my $cover = MQTT2_Discovery::Mapper::map_entity(entity => entity('cover'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /position/ } @{ $cover->{set_lines} }), 'Cover ohne Position-Topic erzeugt keinen Position-Setter');
	my $fan = MQTT2_Discovery::Mapper::map_entity(entity => entity('fan'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /percentage/ } @{ $fan->{set_lines} }), 'Fan ohne Percentage-Topic erzeugt keinen Percentage-Setter');
	my $json_light = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('light', value_template => '{{ value_json.state }}',
			preferred_reading_name => 'state', state_reading_name => 'state', command_set_name => 'state',
			command_codec => { format => 'json', key => 'state', value_type => 'string' },
			brightness_state_topic => 'node/light/state', brightness_command_topic => 'node/light/set',
			brightness_value_template => '{{ value_json.brightness }}',
			brightness_reading_name => 'brightness', brightness_set_name => 'brightness',
			brightness_command_codec => { format => 'json', key => 'brightness', value_type => 'number' }),
		io_name => 'mqtt', cid => 'c');
	ok(grep({ $_->{name} =~ /brightness/ } @{ $json_light->{set_lines} }), 'JSON-Light erhaelt Brightness-Setter auf dem Command-Topic');
	is($json_light->{reading_name}, 'state',
		'JSON-Light leitet seinen Hauptnamen aus dem impliziten state-Feld ab');
	is($json_light->{set_lines}[0]{line},
		q{state:ON,OFF node/light/set {"state":"$EVTPART1"}},
		'JSON-Light sendet ON/OFF als gueltiges JSON statt als skalaren Payload');
	is($json_light->{set_lines}[1]{line},
		q{brightness:slider,0,1,255 node/light/set {"brightness":$EVTPART1}},
		'JSON-Light sendet Helligkeit numerisch im gemeinsamen JSON-Payload');
};

subtest 'Auswahlwerte werden einheitlich normalisiert' => sub {
	my $select = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('select', options => ['eco', 'eco', 'A B', 'A,B']),
		io_name => 'mqtt', cid => 'c',
	);
	my @set_tokens = split /,/, $select->{set_lines}[0]{spec};
	is(scalar @set_tokens, 3, 'doppelte Select-Option wird nur einmal angeboten');
	is([@set_tokens[0, 1]], ['eco', 'A_B'], 'gueltige und normalisierte Tokens bleiben stabil');
	like($set_tokens[2], qr/^A_B_[0-9a-f]{4,}$/, 'kollidierende Select-Option erhaelt einen Suffix');
	is($select->{semantic_entity}{capabilities}{value}{options}, \@set_tokens,
		'Sets und semantische Metadaten verwenden dieselben Tokens');
	is($select->{semantic_entity}{capabilities}{value}{valueMap}{read}{'A,B'}, $set_tokens[2],
		'semantische Rueckabbildung zeigt auf den kollisionsfreien Token');
};

subtest 'MQTT Update bildet Status und Installation ab' => sub {
	my $update = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('update', command_set_name => 'install',
			payload_install => '{"id":"node"}'),
		io_name => 'mqtt', cid => 'client');
	ok($update->{ok}, 'Update-Entity wird sicher gemappt');
	is($update->{reading_lines}[0]{name}, 'update',
		'Status verwendet den stabilen Entity-Namen');
	is($update->{set_lines}[0]{line},
		'install:noArg node/update/set {"id":"node"}',
		'Installationsaktion sendet payload_install unveraendert an command_topic');
	is($update->{semantic_entity}{class}, 'update',
		'semantische Klasse bleibt Update');
	is($update->{semantic_entity}{capabilities}{install}{write}, 'install',
		'semantische Installationsaktion verweist auf denselben Setter');
};

subtest 'Root-Entities wiederholen den Devicenamen nicht als Reading' => sub {
	my $root_update = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('update', object_id => 'Node', command_set_name => 'install',
			payload_install => '{"id":"node"}'),
		io_name => 'mqtt', cid => 'client');
	is($root_update->{reading_lines}[0]{name}, 'update',
		'Root-Update verwendet seine Komponentenrolle statt des Devicenamens');

	my $root_binary = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('binary_sensor', object_id => 'Node'),
		io_name => 'mqtt', cid => 'client');
	is($root_binary->{reading_lines}[0]{name}, 'binary_sensor',
		'die allgemeine Root-Regel gilt auch fuer andere Komponenten');

	my $root_with_json_name = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'Node',
			value_template => '{{ value_json.temperature }}'),
		io_name => 'mqtt', cid => 'client');
	is($root_with_json_name->{reading_lines}[0]{name}, 'temperature',
		'ein fachlicher JSON-Name behaelt vor der Root-Komponentenrolle Vorrang');

	my $child = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'firmware_status'),
		io_name => 'mqtt', cid => 'client');
	is($child->{reading_lines}[0]{name}, 'firmware_status',
		'eine normale Unter-Entity behaelt weiterhin ihre eigene object_id');
};

subtest 'Jinja-dict.get wird als einfaches JSON-Reading gruppiert' => sub {
	my $battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'sensor_battery', state_topic => 'findmy/person/device/state',
			value_template => "{{ value_json.get('battery') }}"),
		io_name => 'mqtt', cid => 'fm_person_device');
	ok($battery->{ok}, 'FindMy-Sensor wird sicher gemappt');
	is($battery->{reading_lines}[0]{kind}, 'json_reading',
		'dict.get wird nicht als komplexes Runtime-Template behandelt');
	is($battery->{reading_lines}[0]{json_key}, 'battery', 'JSON-Schluessel bleibt erhalten');
	like($battery->{reading_lines}[0]{line}, qr/json2nameValue/, 'lesbare FHEM-JSON-Auswertung wird erzeugt');
	unlike($battery->{reading_lines}[0]{line}, qr/runtimeRef/, 'kein Runtime-Fallback erforderlich');
};

subtest 'HA-Button verwendet den vom Adapter normalisierten Entity-Namen' => sub {
	my $button = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('button', object_id => 'schalter_wand_sz_identify',
			state_topic => undef, command_topic => 'zigbee2mqtt/SCHALTER_WAND_SZ/set/topic_leaf',
			preferred_entity_name => 'identify', device_class => 'identify', payload_press => 'identify'),
		io_name => 'mqtt', cid => 'client');
	is($button->{reading_name}, 'identify',
		'zustandsloser Button verwendet den normalisierten logischen Entity-Namen');
	is($button->{set_lines}[0]{line},
		'identify:noArg zigbee2mqtt/SCHALTER_WAND_SZ/set/topic_leaf identify',
		'Button-Name bleibt unabhaengig vom nicht ausgewerteten Command-Topic');
	is($button->{semantic_entity}{capabilities}{press}{write}, 'identify',
		'SemanticUI verweist auf denselben kurzen Button-Namen');

	my $second = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('button', object_id => 'second_identify', entity_key => 'topic|button_2',
			state_topic => undef, command_topic => 'unrelated/command',
			preferred_entity_name => 'identify', device_class => 'identify', payload_press => 'identify'),
		io_name => 'mqtt', cid => 'client');
	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names([$button, $second]);
	my @names = sort map { $_->{set_lines}[0]{name} } @$resolved;
	is(\@names, [qw(schalter_wand_sz_identify second_identify)],
		'gleichnamige Buttons werden mit ihren stabilen Entity-Pfaden qualifiziert');
	isnt($names[0], $names[1], 'die aufgeloesten Button-Namen bleiben eindeutig');
	is([sort map { $_->{semantic_entity}{capabilities}{press}{write} } @$resolved], \@names,
		'SemanticUI uebernimmt auch die kollisionsfrei aufgeloesten Namen');
};

subtest 'Namensaufloesung respektiert die Besitzgrenze der Mappings' => sub {
	my $source = {
		entity_key => 'sensor|availability',
		reading_name => 'availability',
		reading_path => [qw(sensor availability)],
		reading_lines => [{ kind => 'raw', name => 'availability' }],
		set_lines => [],
		set_state_list => [],
	};
	my $resolved_copy = MQTT2_Discovery::Mapper::resolve_mapping_names(
		[$source], { availability => 1 },
	);
	is($source->{reading_name}, 'availability',
		'die allgemeine Schnittstelle veraendert das fremde Mapping nicht');
	is($source->{reading_lines}[0]{name}, 'availability',
		'auch verschachtelte Originaldaten bleiben unveraendert');
	isnt(refaddr($resolved_copy->[0]), refaddr($source),
		'die allgemeine Schnittstelle liefert weiterhin eine eigene Tiefenkopie');
	is($resolved_copy->[0]{reading_name}, 'sensor_availability',
		'der reservierte Name wird auf der Kopie aufgeloest');

	my $owned = JSON::PP->new->decode(JSON::PP->new->encode([$source]));
	my $resolved_owned = MQTT2_Discovery::Mapper::resolve_owned_mapping_names(
		$owned, { availability => 1 },
	);
	is(refaddr($resolved_owned->[0]), refaddr($owned->[0]),
		'die Besitzschnittstelle verwendet dasselbe Mapping ohne zweite Kopie');
	is($owned->[0]{reading_name}, 'sensor_availability',
		'die Namensaufloesung arbeitet direkt auf der exklusiven Kopie');
};

subtest 'kuerzeste eindeutige logische Entity-Namen' => sub {
	my $battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', format => 'device', component_key => 'sensor_battery',
			object_id => 'sensor_battery', entity_key => 'device|sensor_battery',
			state_topic => 'node/state', value_template => '{{ value_json.battery }}',
			device_class => 'battery'),
		io_name => 'mqtt', cid => 'client');
	is($battery->{reading_name}, 'battery',
		'Plattformprefix einer eindeutigen Device-Discovery-Komponente entfaellt');
	is(MQTT2_Discovery::Mapper::resolve_mapping_names([$battery])->[0]{reading_name}, 'battery',
		'eindeutiger kurzer Name bleibt unveraendert');

	my $device_battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', format => 'device', component_key => 'device_battery',
			object_id => 'device_battery', entity_key => 'device|device_battery',
			state_topic => 'node/state', value_template => '{{ value_json.battery }}',
			device_class => 'battery'),
		io_name => 'mqtt', cid => 'client');
	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names([$battery, $device_battery]);
	my %by_key = map { $_->{entity_key} => $_ } @$resolved;
	is($by_key{'device|sensor_battery'}{reading_name}, 'sensor_battery',
		'erste Kollision wird mit dem naechsten logischen Pfadelement qualifiziert');
	is($by_key{'device|device_battery'}{reading_name}, 'device_battery',
		'zweite Kollision wird ebenfalls symmetrisch qualifiziert');
	is($by_key{'device|sensor_battery'}{reading_lines}[0]{name}, 'sensor_battery',
		'Reading-Eintrag verwendet den aufgeloesten Namen');
	is($by_key{'device|sensor_battery'}{semantic_entity}{capabilities}{value}{read}, 'sensor_battery',
		'SemanticUI-Verweis verwendet denselben aufgeloesten Namen');

	my $inside = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'inside', entity_key => 'entity|inside',
			state_topic => 'room/inside', value_template => '{{ value_json.temperature }}'),
		io_name => 'mqtt', cid => 'client');
	my $outside = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'outside', entity_key => 'entity|outside',
			state_topic => 'room/outside', value_template => '{{ value_json.temperature }}'),
		io_name => 'mqtt', cid => 'client');
	$resolved = MQTT2_Discovery::Mapper::resolve_mapping_names([$inside, $outside]);
	%by_key = map { $_->{entity_key} => $_ } @$resolved;
	is($by_key{'entity|inside'}{reading_name}, 'inside_temperature',
		'klassische JSON-Kollision wird erst bei Bedarf mit der Entity qualifiziert');
	is($by_key{'entity|outside'}{reading_name}, 'outside_temperature',
		'zweite klassische JSON-Kollision wird symmetrisch lesbar qualifiziert');

	my $audio_target = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('select', node_id => 'slwf08-tv-cec-4dd380',
			object_id => 'slwf08_tv_cec_4dd380_audioziel',
			entity_key => 'slwf08|audioziel', options => ['TV-Lautsprecher', 'Audiosystem'],
			state_topic => 'slwf08/tv_cec/345f454dd380/config/audio_target/state',
			command_topic => 'slwf08/tv_cec/345f454dd380/config/audio_target/set'),
		io_name => 'mqtt', cid => 'slwf08');
	is($audio_target->{reading_path}, [qw(select slwf08_tv_cec_4dd380 audioziel)],
		'die node_id bleibt nur als Kollisionsreserve im logischen Pfad');
	is($audio_target->{reading_name}, 'audioziel',
		'ein ESPHome-Prefix aus node_id und Unterstrich entfaellt im sichtbaren Namen');
	is($audio_target->{set_lines}[0]{name}, 'audioziel',
		'der gekoppelte Setter verwendet denselben kurzen Namen');
	is(MQTT2_Discovery::Mapper::resolve_mapping_names([$audio_target])->[0]{reading_name},
		'audioziel', 'ein eindeutiger ESPHome-Suffix bleibt auch deviceweit kurz');

	my $similar_prefix = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', node_id => 'slwf08-tv-cec-4dd380',
			object_id => 'slwf08_tv_cec_4dd380x_status',
			entity_key => 'slwf08|similar-prefix'),
		io_name => 'mqtt', cid => 'slwf08');
	is($similar_prefix->{reading_name}, 'slwf08_tv_cec_4dd380x_status',
		'ein nur aehnlicher Prefix ohne Segmentgrenze bleibt unveraendert');
};

subtest 'gefilterter JSON-Hauptpfad steuert Reading und Setter' => sub {
	my $permit_join = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch',
			object_id => 'zigbee2mqtt_bridge_permit_join',
			entity_key => 'bridge|permit_join',
			state_topic => 'zigbee2mqtt/bridge/info',
			value_template => '{{ value_json.permit_join | lower }}',
			preferred_reading_name => 'permit_join', state_reading_name => 'permit_join',
			command_topic => 'zigbee2mqtt/bridge/request/permit_join',
			payload_on => '{"time": 254}', payload_off => '{"time": 0}',
			state_on => 'true', state_off => 'false'),
		io_name => 'mqtt', cid => 'zigbee2mqtt',
	);
	ok($permit_join->{ok}, 'gefilterte Zigbee2MQTT-Bridge-Entity wird gemappt');
	is($permit_join->{reading_name}, 'permit_join',
		'der technische Object-ID-Prefix gelangt nicht in den Readingnamen');
	like($permit_join->{reading_lines}[0]{line}, qr/MQTT2_DISCOVERY_runtimeRef/,
		'lower wird ueber eine kompakte Runtime-Referenz ausgewertet');
	is(runtime_descriptor($permit_join, $permit_join->{reading_lines}[0]{line}), {
		operation => 'reading', runtime => 'reading',
		template => '{{ value_json.permit_join | lower }}', name => 'permit_join',
	}, 'die Referenz enthaelt Template und kurzen Readingnamen deklarativ');
	is($permit_join->{set_lines}[0]{name}, 'permit_join',
		'der zugehoerige Setter verwendet exakt denselben kurzen Namen');
	is($permit_join->{semantic_entity}{capabilities}{power}, {
		read => 'permit_join', write => 'permit_join', kind => 'boolean',
		options => ['on', 'off'], activeValue => 'on', inactiveValue => 'off',
		valueMap => { read => { true => 'on', false => 'off' } },
	}, 'SemanticUI trennt boolesche Readingwerte von den JSON-Befehlspayloads');
};

subtest 'Retained Command-Publishes' => sub {
	my $text = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => 'true'), io_name => 'mqtt', cid => 'c');
	is($text->{set_lines}[0]{line}, 'text node/text/set:r',
		'HA-retain markiert ein direktes Command-Topic fuer MQTT2_DEVICE');

	my $templated = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => JSON::PP::true(),
			command_template => '{{ value | upper }}'), io_name => 'mqtt', cid => 'c');
	like($templated->{set_lines}[0]{line}, qr/MQTT2_DISCOVERY_runtimeRef/,
		'Runtime-Publish verwendet eine kompakte Referenz');
	is(runtime_descriptor($templated, $templated->{set_lines}[0]{line}), {
		operation => 'set', kind => 'publish', topic => 'node/text/set:r',
		template => '{{ value | upper }}',
	}, 'Retain-Topic und Command-Template bleiben deklarativ registriert');
	unlike($templated->{set_lines}[0]{line}, qr/bm9|e3sg/,
		'Runtime-Publish verwendet kein Base64');

	my $not_retained = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => 'false'), io_name => 'mqtt', cid => 'c');
	is($not_retained->{set_lines}[0]{line}, 'text node/text/set',
		'retain=false veraendert das Command-Topic nicht');
};

subtest 'lesbare Runtime-Command-Fallbacks' => sub {
	my $choice = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', command_topic => 'node/{switch}', payload_on => 'YES', payload_off => 'NO'),
		io_name => 'mqtt', cid => 'c');
	like($choice->{set_lines}[0]{line}, qr/MQTT2_DISCOVERY_runtimeRef/,
		'Choice-Fallback verwendet eine kompakte Referenz');
	is(runtime_descriptor($choice, $choice->{set_lines}[0]{line}), {
		operation => 'set', kind => 'choice', topic => 'node/{switch}',
		mapping => { off => 'NO', on => 'YES' },
	}, 'Choice-Topic und Payload-Mapping bleiben deklarativ registriert');

	my $button = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('button', command_topic => 'node/{button}', payload_press => 'PRESS'),
		io_name => 'mqtt', cid => 'c');
	is(runtime_descriptor($button, $button->{set_lines}[0]{line}), {
		operation => 'set', kind => 'button', topic => 'node/{button}', payload => 'PRESS',
	}, 'Button-Fallback registriert Topic und Payload deklarativ');

	my $json = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('light', command_topic => 'node/{light}', value_template => '{{ value_json.state }}',
			preferred_reading_name => 'state', state_reading_name => 'state', command_set_name => 'state',
			command_codec => { format => 'json', key => 'state', value_type => 'string' },
			brightness_state_topic => 'node/light/state', brightness_command_topic => 'node/{light}',
			brightness_value_template => '{{ value_json.brightness }}',
			brightness_reading_name => 'brightness', brightness_set_name => 'brightness',
			brightness_command_codec => { format => 'json', key => 'brightness', value_type => 'number' }),
		io_name => 'mqtt', cid => 'c');
	my @descriptors = map { runtime_descriptor($json, $_->{line}) }
		@{ $json->{set_lines} };
	ok(grep({ ref($_) eq 'HASH' && ($_->{kind} || '') eq 'json'
		&& ($_->{key} || '') eq 'brightness' && ($_->{topic} || '') eq 'node/{light}' }
		@descriptors), 'JSON-Fallback registriert Topic und JSON-Schluessel deklarativ');
};

subtest 'Validierung und Determinismus' => sub {
	my $bad_number = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('number', min => 10, max => 1, step => 0), io_name => 'mqtt', cid => 'c');
	like(join(' ', @{ $bad_number->{warnings} }), qr/min\/max\/step/, 'ungueltiger Slider wird gemeldet');
	is($bad_number->{set_lines}, [], 'ungueltiger Slider erzeugt keinen Setter');
	my $default_step = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('number', min => 5, max => 1800, step => undef), io_name => 'mqtt', cid => 'c');
	is($default_step->{set_lines}[0]{line}, 'number:slider,5,1,1800 node/number/set',
		'fehlendes Number-step verwendet den HA-Default 1');
	is($default_step->{semantic_entity}{capabilities}{value}{step}, 1,
		'Number-Default steht auch in den Semantic-Metadaten');
	my $first = MQTT2_Discovery::Mapper::map_entity(entity => entity('switch'), io_name => 'mqtt', cid => 'c');
	my $second = MQTT2_Discovery::Mapper::map_entity(entity => entity('switch'), io_name => 'mqtt', cid => 'c');
	is($first, $second, 'gleiches Modell erzeugt deterministisch dasselbe Mapping');

	my $escaped = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', state_topic => 'node-v1/sensor+temp:state'), io_name => 'mqtt', cid => 'client.1');
	is($escaped->{reading_lines}[0]{line}, 'node-v1/sensor\\+temp:state:.* sensor',
		'readingList ist CID-unabhaengig und maskiert echte Regex-Sonderzeichen im Topic');
};

subtest 'Device-Automation und Texteingabe-Metadaten' => sub {
	my $trigger = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('device_automation', object_id => 'button_1_double',
			state_topic => 'node/button_1_double', payload => 'PRESS',
			type => 'button_double_press', subtype => 'button_1'),
		io_name => 'mqtt', cid => 'c');
	is($trigger->{reading_lines}[0]{line}, 'node/button_1_double:PRESS$ button_1_double',
		'Trigger-Reading filtert Topic und Payload exakt');
	is($trigger->{semantic_entity}, undef,
		'eingehender Trigger bleibt als Reading erhalten, wird aber nicht in SemanticUI angezeigt');
	my $unsafe_trigger = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('device_automation', state_topic => 'node/button', payload => "PRESS\nset injected"),
		io_name => 'mqtt', cid => 'c');
	ok(!$unsafe_trigger->{ok}, 'Trigger-Payload kann keine readingList-Zeile einschleusen');

	my $text = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', max => 56), io_name => 'mqtt', cid => 'c');
	is($text->{semantic_entity}{capabilities}{value}{input}, 'text',
		'Text-Entity fordert ein Texteingabefeld an');
	is($text->{semantic_entity}{capabilities}{value}{maxLength}, 56,
		'maximale Textlaenge wird an SemanticUI uebergeben');
};

subtest 'Device-Automationen werden topicweise zu einem Reading reduziert' => sub {
	# Erzeugt eindeutig adressierbare Trigger desselben Devices fuer die deviceweite Reduktion.
	my $automation = sub {
		my (%args) = @_;
		return MQTT2_Discovery::Mapper::map_entity(
			entity => entity('device_automation',
				object_id => $args{id}, entity_key => "trigger|$args{id}",
				unique_id => "node_$args{id}", state_topic => $args{topic},
				payload => $args{payload},
				(defined($args{template}) ? (value_template => $args{template}) : ()),
			),
			io_name => 'mqtt', cid => 'c',
		);
	};
	my $collapse = sub {
		my ($mappings) = @_;
		my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names($mappings, { availability => 1 });
		return MQTT2_Discovery::Mapper::collapse_device_automation_readings(
			$resolved, { availability => 1 },
		);
	};
	my @actions = (
		$automation->(id => 'action_on', topic => 'zigbee2mqtt/remote/action', payload => 'ON'),
		$automation->(id => 'action_off', topic => 'zigbee2mqtt/remote/action', payload => 'OFF'),
		$automation->(id => 'action_stop', topic => 'zigbee2mqtt/remote/action', payload => 'STOP.+'),
	);
	my $collapsed = $collapse->(\@actions);
	my @entries = map { @{ $_->{reading_lines} || [] } } @$collapsed;
	is(scalar(@entries), 1, 'alle kompatiblen Trigger desselben Topics ergeben genau einen Eintrag');
	is($entries[0]{kind}, 'device_automation_group', 'der Eintrag bleibt bis zum Renderer strukturiert');
	is($entries[0]{name}, 'action', 'das Topicblatt bestimmt den gemeinsamen Readingnamen');
	is($entries[0]{payloads}, [qw(OFF ON), 'STOP.+'], 'alle Payloadvarianten bleiben erhalten');
	my $rendered = MQTT2_Discovery::Mapper::render_entries(\@entries, 'zigbee2mqtt/remote');
	is($rendered->[0]{line}, '$DEVICETOPIC/action:(?:OFF|ON|STOP\.\+)$ action',
		'Regex-Sonderzeichen werden innerhalb der exakten Payloadalternativen maskiert');

	my $remaining = $collapse->([$actions[2]]);
	my @remaining_entries = map { @{ $_->{reading_lines} || [] } } @$remaining;
	is($remaining_entries[0]{name}, 'action',
		'das gemeinsame Reading bleibt auch nach dem Loeschen aller anderen Trigger stabil');

	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'action', entity_key => 'sensor|action',
			unique_id => 'node_sensor_action', state_topic => 'zigbee2mqtt/remote/state'),
		io_name => 'mqtt', cid => 'c',
	);
	my $qualified = $collapse->([$sensor, @actions[0, 1]]);
	my ($qualified_group) = grep { ($_->{kind} || '') eq 'device_automation_group' }
		map { @{ $_->{reading_lines} || [] } } @$qualified;
	is($qualified_group->{name}, 'remote_action',
		'ein bereits belegtes action wird mit dem vorherigen Topicsegment qualifiziert');

	my @templated = (
		$automation->(id => 'templated_on', topic => 'zigbee2mqtt/templated/action', payload => 'ON',
			template => '{{ trigger.value_json.action }}'),
		$automation->(id => 'templated_off', topic => 'zigbee2mqtt/templated/action', payload => 'OFF',
			template => '{{ trigger.value_json.action }}'),
	);
	my $template_groups = $collapse->(\@templated);
	my @template_entries = map { @{ $_->{reading_lines} || [] } } @$template_groups;
	is(scalar(@template_entries), 1, 'identische Trigger-Templates werden ebenfalls zusammengefasst');
	my ($template_rendered, $template_references) = render_with_references(
		\@template_entries, 'zigbee2mqtt/templated', undef,
	);
	like($template_rendered->[0]{line}, qr/MQTT2_DISCOVERY_runtimeRef/,
		'die Template-Runtime verwendet eine kompakte Referenz');
	is(descriptor_from_references($template_references, $template_rendered->[0]{line})
		->{filter}, { match_all => 0, payloads => [qw(OFF ON)] },
		'die Referenz enthaelt den gemeinsamen Payloadfilter deklarativ');

	my @incompatible = (
		$automation->(id => 'raw', topic => 'zigbee2mqtt/mixed/action', payload => 'ON',
			template => '{{ trigger.payload }}'),
		$automation->(id => 'lower', topic => 'zigbee2mqtt/mixed/action', payload => 'off',
			template => '{{ trigger.payload | lower }}'),
	);
	my $unchanged = $collapse->(\@incompatible);
	my @unchanged_entries = map { @{ $_->{reading_lines} || [] } } @$unchanged;
	is(scalar(@unchanged_entries), 2, 'unterschiedliche Templates bleiben als getrennte Trigger erhalten');
	is(scalar(grep { ($_->{kind} || '') eq 'device_automation_group' } @unchanged_entries), 0,
		'inkompatible Topicbelegungen werden nicht teilweise reduziert');
};

subtest 'Climate bildet alle State- und Command-Kanaele ab' => sub {
	my $climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'pac-1d797c', state_topic => undef, command_topic => undef,
			device => { identifiers => ['dc1ed51d797c'], name => 'Schlafen.Klima' },
			current_temperature_topic => 'pac-1d797c/state/current_temperature',
			temperature_state_topic => 'pac-1d797c/state/target_temperature',
			temperature_command_topic => 'pac-1d797c/command/target_temperature',
			mode_state_topic => 'pac-1d797c/state/mode', mode_command_topic => 'pac-1d797c/command/mode',
			fan_mode_state_topic => 'pac-1d797c/state/fan_mode', fan_mode_command_topic => 'pac-1d797c/command/fan_mode',
			swing_mode_state_topic => 'pac-1d797c/state/swing_mode', swing_mode_command_topic => 'pac-1d797c/command/swing_mode',
			preset_mode_state_topic => 'pac-1d797c/state/preset', preset_mode_command_topic => 'pac-1d797c/command/preset',
			min_temp => 16, max_temp => 30, temp_step => 0.5,
			modes => [qw(off auto cool heat fan_only dry)], fan_modes => ['Automatic', qw(1 2 3 4 5)],
			swing_modes => [qw(off both vertical horizontal)], preset_modes => [qw(Normal Powerful Quiet)]),
		io_name => 'mqtt', cid => 'c');
	ok($climate->{ok}, 'Climate wird gemappt');
	my $readings = join("\n", map { $_->{line} } @{ $climate->{reading_lines} });
	my $sets = join("\n", map { $_->{line} } @{ $climate->{set_lines} });
	is([sort map { $_->{name} } @{ $climate->{reading_lines} }],
		[qw(current_temperature fan_mode mode preset swing_mode target_temperature)],
		'Climate-State-Readings verwenden die Namen hinter state');
	is([sort map { $_->{name} } @{ $climate->{set_lines} }],
		[qw(fan_mode mode preset swing_mode target_temperature)],
		'Climate-Setter verwenden exakt dieselben sichtbaren Namen wie ihre Readings');
	like($readings, qr{pac-1d797c/state/current_temperature:\.\* current_temperature},
		'Isttemperatur wird als Reading angelegt');
	like($readings, qr{pac-1d797c/state/target_temperature:\.\* target_temperature},
		'Solltemperatur wird als Reading angelegt');
	like($sets, qr{target_temperature:slider,16,0\.5,30 pac-1d797c/command/target_temperature},
		'Solltemperatur wird mit kurzem Capability-Namen als Slider angelegt');
	like($sets, qr{mode:off,auto,cool,heat,fan_only,dry pac-1d797c/command/mode},
		'Betriebsmodi werden mit kurzem Capability-Namen angelegt');
	like($sets, qr{fan_mode:Automatic,1,2,3,4,5 pac-1d797c/command/fan_mode},
		'numerische Fan-Modi bleiben unter fan_mode direkt bedienbar');
	like($sets, qr{swing_mode:off,both,vertical,horizontal pac-1d797c/command/swing_mode},
		'Swing-Modi werden mit kurzem Capability-Namen angelegt');
	like($sets, qr{preset:Normal,Powerful,Quiet pac-1d797c/command/preset},
		'Preset-Modi verwenden den tatsaechlichen Reading-Namen');
	is(scalar @{ $climate->{set_lines} }, 5, 'genau die fuenf angebotenen Climate-Commands werden angelegt');
	is($climate->{semantic_entity}{capabilities}{targetTemperature}{write}, 'target_temperature',
		'optionale Semantik verweist auf den realen FHEM-Setter');
	is([$climate->{semantic_entity}{capabilities}{fanMode}{read},
			$climate->{semantic_entity}{capabilities}{fanMode}{write}], [qw(fan_mode fan_mode)],
		'Fan-Mode liest und schreibt denselben Namen');
	is([$climate->{semantic_entity}{capabilities}{presetMode}{read},
			$climate->{semantic_entity}{capabilities}{presetMode}{write}], [qw(preset preset)],
		'Preset liest und schreibt ebenfalls denselben sichtbaren Namen');
	is($climate->{semantic_entity}{capabilities}{power}{read}, 'mode',
		'Power-Zustand wird aus dem Climate-Modus gelesen');
	ok(!exists($climate->{semantic_entity}{capabilities}{power}{write}),
		'ohne expliziten Power-Command bleibt die abgeleitete Capability nur lesbar');
	is($climate->{semantic_entity}{capabilities}{power}{valueMap}{read}, {
			off => 'off', auto => 'on', cool => 'on', heat => 'on', fan_only => 'on', dry => 'on',
	}, 'alle aktiven Climate-Modi werden fuer Power auf on abgebildet');
};

subtest 'Climate-Capability-Namen werden deviceweit gemeinsam aufgeloest' => sub {
	my @mappings;

	for my $zone (qw(zone1 zone2)) {
		push @mappings, MQTT2_Discovery::Mapper::map_entity(
			entity => entity('climate', object_id => $zone,
				entity_key => "climate|$zone", state_topic => undef, command_topic => undef,
				device => { identifiers => ['multi-zone'], name => 'Multi Zone' },
				fan_mode_state_topic => "hvac/$zone/state/fan_mode",
				fan_mode_command_topic => "hvac/$zone/command/fan_mode",
				fan_modes => [qw(auto low high)]),
			io_name => 'mqtt', cid => 'c',
		);
	}

	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names(\@mappings);
	my %by_key = map { ($_->{entity_key} => $_) } @$resolved;

	for my $zone (qw(zone1 zone2)) {
		my $mapping = $by_key{"climate|$zone"};
		my ($reading) = grep { ($_->{semantic_name} || '') eq "${zone}_fan_mode" }
			@{ $mapping->{reading_lines} };
		my ($set) = grep { ($_->{semantic_name} || '') eq "${zone}_fan_mode" }
			@{ $mapping->{set_lines} };
		my $expected = "${zone}_fan_mode";
		is([$reading->{name}, $set->{name}], [$expected, $expected],
			"$zone qualifiziert Reading und Setter gemeinsam");
		is([$mapping->{semantic_entity}{capabilities}{fanMode}{read},
				$mapping->{semantic_entity}{capabilities}{fanMode}{write}], [$expected, $expected],
			"$zone uebernimmt den aufgeloesten Namen in SemanticUI");
	}

};

subtest 'State-Pfad und Availability-Topic bestimmen kurze Reading-Namen' => sub {
	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'pac_ip_address',
			state_topic => 'pac-1d797c/state/ip', availability_topic => 'pac-1d797c/status'),
		io_name => 'mqtt', cid => 'c');
	my $readings = join("\n", map { $_->{line} // '' } @{ $sensor->{reading_lines} });
	like($readings, qr{pac-1d797c/state/ip:\.\* ip},
		'Name hinter state wird als Reading verwendet');
	my ($availability) = grep { ($_->{role} || '') eq 'availability' }
		@{ $sensor->{reading_lines} };
	is($availability->{topic}, 'pac-1d797c/status',
		'Availability behaelt das wirkliche Topic fuer die HA-Verfuegbarkeitsauswertung');
	like($availability->{source_reading}, qr/^\.availability_[a-f0-9]{8}$/,
		'die rohe Availability-Quelle erhaelt nur ein verborgenes stabiles Reading');
	my $rendered = join("\n", map { $_->{line} }
		@{ MQTT2_Discovery::Mapper::render_entries($sensor->{reading_lines}, undef) });
	like($rendered, qr{^pac-1d797c/status:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'Availability wird ueber die rollenbasierte Laufzeitauswertung gerendert');
	unlike($rendered, qr{^pac-1d797c/status:\.\* (?:status|state)$}m,
		'das Topic-Blatt wird nicht mehr zu einem sichtbaren State-Reading');

	my $classic = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'temperature', state_topic => 'node/temperature/state'),
		io_name => 'mqtt', cid => 'c');
	is($classic->{reading_lines}[0]{name}, 'temperature',
		'generisches abschliessendes state bleibt kollisionsfrei bei der Entity-ID');
};

subtest 'mehrere Availability-Quellen kollidieren nicht mit normalen State-Readings' => sub {
	my $light = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('light', object_id => 'light',
			state_topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT',
			command_topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set',
			availability => [
				{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/availability',
					value_template => '{{ value_json.state }}' },
				{ topic => 'zigbee2mqtt/bridge/state',
					value_template => '{{ value_json.state }}' },
			],
			availability_mode => 'all'),
		io_name => 'mqtt', cid => 'z2m');
	my @availability = grep { ($_->{role} || '') eq 'availability' }
		@{ $light->{reading_lines} };
	is(scalar(@availability), 2, 'beide HA-Availability-Quellen bleiben erhalten');
	is(scalar(keys %{ { map { ($_->{source_reading} => 1) } @availability } }), 2,
		'jede unterschiedliche Quelle besitzt einen eigenen internen Zustand');
	my $rendered = join("\n", map { $_->{line} }
		@{ MQTT2_Discovery::Mapper::render_entries(
			$light->{reading_lines}, 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT') });
	like($rendered, qr{^\$DEVICETOPIC/availability:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'geraeteeigene Availability wird relativ gerendert');
	like($rendered, qr{^zigbee2mqtt/bridge/state:\.\* \{ MQTT2_DISCOVERY_runtimeRef}m,
		'externe Availability bleibt ohne Topic-Sonderbehandlung absolut');
	unlike($rendered, qr{^zigbee2mqtt/bridge/state:\.\* state$}m,
		'das externe state-Topic erzeugt kein kollidierendes state-Reading');
	like($rendered, qr{^\$DEVICETOPIC:\.\*}m,
		'das normale Nutzdaten-State-Topic bleibt unveraendert vorhanden');

	my $bridge = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'connection_state',
			state_topic => 'zigbee2mqtt/bridge/state',
			value_template => '{{ value_json.state }}',
			availability => [{
				topic => 'zigbee2mqtt/bridge/state',
				value_template => '{{ value_json.state }}',
			}]),
		io_name => 'mqtt', cid => 'z2m');
	my ($bridge_rendered, $bridge_references) = render_with_references(
		$bridge->{reading_lines}, 'zigbee2mqtt/bridge', undef,
	);
	my @bridge_lines = grep { /^\$DEVICETOPIC\/state:/ }
		map { $_->{line} } @$bridge_rendered;
	is(scalar(@bridge_lines), 1,
		'ein gemeinsames State- und Availability-Topic erzeugt genau eine Zeile');
	my $bridge_descriptor = descriptor_from_references($bridge_references, $bridge_lines[0]);
	ok(ref($bridge_descriptor->{configuration}{availability}) eq 'HASH'
		&& @{ $bridge_descriptor->{configuration}{readings} || [] } == 1,
		'die gemeinsame Topic-Runtime enthaelt State-Reading und Availability');
};

subtest 'reservierte Rollenreadings qualifizieren gleichnamige normale Werte' => sub {
	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'availability',
			state_topic => 'node/state',
			value_template => '{{ value_json.availability }}',
			device_class => 'temperature',
			availability => [{ topic => 'node/online' }]),
		io_name => 'mqtt', cid => 'node');
	is($sensor->{reading_name}, 'availability',
		'die einzelne Entity beginnt mit ihrem fachlichen Namen');
	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names([$sensor])->[0];
	is($resolved->{reading_name}, 'sensor_availability',
		'der allgemeine Pfadresolver qualifiziert die Kollision mit der technischen Rolle');
	my ($state) = grep { ($_->{role} || '') ne 'availability' }
		@{ $resolved->{reading_lines} };
	is($state->{name}, 'sensor_availability',
		'das normale State-Reading uebernimmt den aufgeloesten Namen');
	is($resolved->{semantic_entity}{capabilities}{value}{read}, 'sensor_availability',
		'SemanticUI verweist ebenfalls auf das qualifizierte normale Reading');
	my ($resolved_rendered, $resolved_references) = render_with_references(
		$resolved->{reading_lines}, 'node', undef,
	);
	my $rendered = join("\n", map { $_->{line} } @$resolved_rendered);
	like($rendered,
		qr/^\$DEVICETOPIC\/state:\.\* \{ MQTT2_DISCOVERY_runtimeRef/m,
		'das JSON-Feld wird ohne Topic-Sonderregel auf den qualifizierten Namen abgebildet');
	my ($state_line) = grep { /^\$DEVICETOPIC\/state:/ } map { $_->{line} } @$resolved_rendered;
	is(descriptor_from_references($resolved_references, $state_line)
		->{configuration}{readings}[0]{name}, 'sensor_availability',
		'die Topic-Referenz enthaelt den qualifizierten Zielnamen');
	like($rendered, qr/^\$DEVICETOPIC\/online:\.\* \{ MQTT2_DISCOVERY_runtimeRef/m,
		'das berechnete Rollenreading availability bleibt separat erhalten');

	my $button = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('button', object_id => 'identify', state_topic => undef,
			availability => [{ topic => 'node/online' }]),
		io_name => 'mqtt', cid => 'node');
	push @{ $button->{reading_lines} }, {
		kind => 'reading', topic => 'node/custom', name => 'availability',
		semantic_name => 'availability',
	};
	my $resolved_button = MQTT2_Discovery::Mapper::resolve_mapping_names([$button])->[0];
	my ($secondary) = grep { ($_->{topic} || '') eq 'node/custom' }
		@{ $resolved_button->{reading_lines} };
	is($secondary->{name}, 'button_availability',
		'auch ein sekundaeres normales Reading wird ohne Kenntnis seines Topics qualifiziert');
};

subtest 'deviceweit reserviertes availability gilt auch ohne Entity-Quelle' => sub {
	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'availability',
			state_topic => 'node/state',
			value_template => '{{ value_json.availability }}'),
		io_name => 'mqtt', cid => 'node');
	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names(
		[$sensor], { availability => 1 },
	)->[0];
	is($resolved->{reading_name}, 'sensor_availability',
		'die IO-Rolle reserviert availability auch ohne Discovery-Availability');
	my ($reserved_rendered, $reserved_references) = render_with_references(
		$resolved->{reading_lines}, 'node', { availability => 1 },
	);
	my $rendered = join("\n", map { $_->{line} } @$reserved_rendered);
	my ($reserved_line) = grep { /runtimeRef/ } map { $_->{line} } @$reserved_rendered;
	is(descriptor_from_references($reserved_references, $reserved_line)
		->{configuration}{readings}[0]{name}, 'sensor_availability',
		'gleichnamige Nutzdaten werden auf das qualifizierte Reading abgebildet');

	my $free_json = {
		kind => 'json_autocreate', topic => 'node/free', name => 'free',
		json_key => 'free',
	};
	$rendered = MQTT2_Discovery::Mapper::render_entries(
		[$free_json], 'node', { availability => 1 },
	)->[0]{line};
	is($rendered,
		q{$DEVICETOPIC/free:.* { MQTT2_DISCOVERY_jsonReadings($NAME,'free',$EVENT) }},
		'der kompakte Wrapper schuetzt frei entpacktes JSON ohne sichtbare Mappingliste');
};

subtest 'Climate bildet optionale Standardkanaele und Templates ab' => sub {
	my $climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'hvac', state_topic => undef, command_topic => undef,
			value_template => '{{ value }}',
			current_humidity_topic => 'hvac/humidity/current',
			target_humidity_state_topic => 'hvac/humidity/target',
			target_humidity_command_topic => 'hvac/humidity/target/set', min_humidity => 35, max_humidity => 80,
			swing_horizontal_mode_state_topic => 'hvac/swing_horizontal',
			swing_horizontal_mode_command_topic => 'hvac/swing_horizontal/set',
			swing_horizontal_modes => [qw(on off)],
			mode_command_topic => 'hvac/mode/set', modes => [qw(off heat)],
			mode_command_template => '{{ value | upper }}',
			power_command_topic => 'hvac/power/set', payload_on => 'START', payload_off => 'STOP'),
		io_name => 'mqtt', cid => 'c');
	ok($climate->{ok}, 'optionale Climate-Kanaele werden gemappt');
	my $readings = join("\n", map { $_->{line} } @{ $climate->{reading_lines} });
	my $sets = join("\n", map { $_->{line} } @{ $climate->{set_lines} });
	is([sort map { $_->{name} } @{ $climate->{set_lines} }],
		[qw(hvac_swing_horizontal_mode hvac_target_humidity mode power)],
		'gekoppelte Setter folgen ihrem Reading, command-only Setter bleiben kurz');
	like($readings, qr/hvac\/humidity\/current:\.\*.*hvac_current_humidity/,
		'aktuelle Luftfeuchte wird angelegt und verwendet das allgemeine State-Template');
	like($sets, qr/hvac_target_humidity:slider,35,1,80 hvac\/humidity\/target\/set/,
		'Ziel-Luftfeuchte wird als Slider angelegt');
	like($sets, qr/hvac_swing_horizontal_mode:on,off hvac\/swing_horizontal\/set/,
		'horizontaler Swing wird angelegt');
	my %set_by_name = map { ($_->{name} => $_) } @{ $climate->{set_lines} };
	my $power_descriptor = runtime_descriptor($climate, $set_by_name{power}{line});
	is([$power_descriptor->{topic}, $power_descriptor->{mapping}],
		['hvac/power/set', { off => 'STOP', on => 'START' }],
		'command-only Power verwendet den kanonischen kurzen Namen');
	my $mode_descriptor = runtime_descriptor($climate, $set_by_name{mode}{line});
	is([$mode_descriptor->{topic}, $mode_descriptor->{template}],
		['hvac/mode/set', '{{ value | upper }}'],
		'command-only Mode bleibt kurz und behaelt sein Choice-Template');
};

my $unknown = MQTT2_Discovery::Mapper::map_entity(entity => entity('vacuum'), io_name => 'mqtt', cid => 'c');
ok(!$unknown->{ok} && $unknown->{unsupported}, 'unbekannte Komponente erzeugt kein Device-Mapping');

my $template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ value_json.temperature }}'), io_name => 'mqtt', cid => 'client');
like($template->{reading_lines}[0]{line}, qr/json2nameValue/, 'einfacher JSON-Pfad verwendet FHEMs Standardauswertung');
is($template->{reading_name}, 'temperature',
	'einfacher JSON-Pfad verwendet seinen fachlichen Blattnamen direkt');
unlike($template->{reading_lines}[0]{line}, qr/'temperature'\s*=>/,
	'identische JSON- und Reading-Namen benoetigen keine Umbenennung');
unlike($template->{reading_lines}[0]{line}, qr/runtimeRef|e3sg/,
	'einfacher JSON-Pfad benoetigt weder Runtime-Wrapper noch Base64');

my $complex_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ value_json.temperature | round(1) }}'), io_name => 'mqtt', cid => 'client');
like($complex_template->{reading_lines}[0]{line},
	qr/MQTT2_DISCOVERY_runtimeRef/,
	'komplexes Template verwendet eine kompakte Runtime-Referenz');
is(runtime_descriptor($complex_template, $complex_template->{reading_lines}[0]{line})
	->{template}, '{{ value_json.temperature | round(1) }}',
	'das komplexe Template bleibt deklarativ in der Registry erhalten');
unlike($complex_template->{reading_lines}[0]{line}, qr/e3sg/,
	'auch der Runtime-Fallback verbirgt das Template nicht in Base64');

my $defined_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/+/BTtoMQTT/device',
		value_template => '{{ value_json.temperature | is_defined }}'), io_name => 'mqtt', cid => 'client');
like($defined_template->{reading_lines}[0]{line}, qr{home/\[\^/\]\*/BTtoMQTT/device:\.\*},
	'eine einzelne MQTT-Wildcard wird als genau ein Topicsegment gerendert');
like($defined_template->{reading_lines}[0]{line}, qr/json2nameValue/,
	'is_defined behaelt die kompakte JSON-Auswertung fuer direkte Pfade');
is($defined_template->{warnings}, [], 'is_defined erzeugt keine Mappingwarnung');
my ($single_filter) = split /\s+/, $defined_template->{reading_lines}[0]{line}, 2;
like('home/gateway/BTtoMQTT/device:{"temperature":21}', qr/^$single_filter$/,
	'eine konkrete Nachricht trifft den gerenderten Einsegmentfilter');
unlike('home/gateway/extra/BTtoMQTT/device:{"temperature":21}', qr/^$single_filter$/,
	'die Einsegment-Wildcard akzeptiert keine zusaetzliche Topicebene');

my $ems_optional = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'ems-esp/analogsensor_data',
		value_template => "{{value_json['core_voltage'] if value_json['core_voltage'] is defined}}"),
	io_name => 'mqtt', cid => 'ems-esp');
is($ems_optional->{warnings}, [],
	'das optionale EMS-Analogtemplate ohne else erzeugt keine Mappingwarnung');

my $ems_mode = q!{%if value_json.mode is undefined%}off{%elif value_json.mode=='Manuell'%}heat{%elif value_json.mode=='Tag'%}heat{%elif value_json.mode=='Nacht'%}off{%elif value_json.mode=='aus'%}off{%else%}auto{%endif%}!;
my $ems_climate = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('climate', mode_state_template => $ems_mode,
		availability => [{
			topic => 'ems-esp/thermostat_data',
			value_template => "{{'offline' if value_json.mode is undefined else 'online'}}",
		}]),
	io_name => 'mqtt', cid => 'ems-esp');
is($ems_climate->{warnings}, [],
	'EMS-Klimamodus und Availability erzeugen keine Mappingwarnung');

my $multi_wildcard = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/gateway/433toMQTT/#'), io_name => 'mqtt', cid => 'client');
is($multi_wildcard->{reading_lines}[0]{line},
	'home/gateway/433toMQTT(?:/.*)?:.* sensor',
	'eine abschliessende MQTT-Mehrsegment-Wildcard umfasst Topic und Untertopics');
my ($multi_filter) = split /\s+/, $multi_wildcard->{reading_lines}[0]{line}, 2;
like('home/gateway/433toMQTT/15524904:{"value":15524904}', qr/^$multi_filter$/,
	'eine konkrete Nachricht trifft den gerenderten Mehrsegmentfilter');
like('home/gateway/433toMQTT:{}', qr/^$multi_filter$/,
	'der Mehrsegmentfilter umfasst gemaess MQTT auch sein Elterntopic');

my $literal_wildcard = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/sensor+backup/state'), io_name => 'mqtt', cid => 'client');
like($literal_wildcard->{reading_lines}[0]{line}, qr{sensor\\\+backup},
	'Wildcardzeichen innerhalb eines Segments bleiben sichere Literale');

my $trigger_context = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('device_automation', state_topic => 'home/gateway/433toMQTT/42', payload => undef,
		value_template => '{{ trigger.value.raw }}'), io_name => 'mqtt', cid => 'client');
like($trigger_context->{reading_lines}[0]{line}, qr/MQTT2_DISCOVERY_runtimeRef/,
	'Device-Automation verwendet den eigenen sicheren Triggerkontext');
is(runtime_descriptor($trigger_context, $trigger_context->{reading_lines}[0]{line})
	->{runtime}, 'triggerReading', 'die Referenz waehlt den Triggerkontext ausdruecklich');

my $multiline_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => "{{ value_json.temperature\n  | round(1) }}"), io_name => 'mqtt', cid => 'client');
is(runtime_descriptor($multiline_template, $multiline_template->{reading_lines}[0]{line})
	->{template}, "{{ value_json.temperature\n  | round(1) }}",
	'mehrzeiliges Template bleibt ohne Textkodierung deklarativ erhalten');
unlike($multiline_template->{reading_lines}[0]{line}, qr/e3sg/,
	'mehrzeiliges Template verwendet ebenfalls kein Base64');

my $second_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'humidity', value_template => '{{ value_json.humidity }}'),
	io_name => 'mqtt', cid => 'client');
my ($grouped, $grouped_references) = render_with_references(
	[$template->{reading_lines}[0], $second_template->{reading_lines}[0]], undef, undef,
);
is(scalar(@$grouped), 1, 'mehrere einfache JSON-Pfade desselben Topics werden zusammengefasst');
unlike($grouped->[0]{line}, qr/'temperature'\s*=>/,
	'gruppierte JSON-Auswertung behaelt auch temperature als direkten Blattnamen');
unlike($grouped->[0]{line}, qr/'humidity'\s*=>/,
	'identische JSON- und Reading-Namen werden nicht wiederholt');
is([map { $_->{name} }
		@{ descriptor_from_references($grouped_references, $grouped->[0]{line})
			->{configuration}{readings} }], [qw(humidity temperature)],
	'gruppierte JSON-Auswertung enthaelt exakt die angekuendigten Readings');
like($second_template->{reading_lines}[0]{line},
	qr/\{ json2nameValue\(\$EVENT, '', \{\}, '\^\(\?:humidity\)\$'\) \}$/,
	'auch reine Eins-zu-eins-Namen begrenzen die ausgewerteten JSON-Felder');
my $array_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'energy_power_0',
		value_template => '{{ value_json.ENERGY.Power[0] }}'), io_name => 'mqtt', cid => 'client');
is($array_template->{reading_name}, 'ENERGY_Power_1',
	'nullbasierter Template-Index wird direkt auf FHEMs einbasierten JSON-Namen abgebildet');
unlike($array_template->{reading_lines}[0]{line}, qr/'ENERGY_Power_1'\s*=>/,
	'direkter Array-Blattname benoetigt keine zusaetzliche JSON-Zuordnung');
my $autocreate_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'energy_power_0', state_topic => 'node/data',
		value_template => '{{ value_json.ENERGY.Power[0] }}', device_class => 'power',
		json_autocreate => 1), io_name => 'mqtt', cid => 'client');
is($autocreate_template->{reading_lines}[0]{line},
	q{node/data:.* { MQTT2_DISCOVERY_jsonReadings($NAME,'data',$EVENT) }},
	'Autocreate-Modus verwendet den kompakten JSON-Wrapper');
is($autocreate_template->{reading_lines}[0]{name}, 'ENERGY_Power_1',
	'Autocreate-Modus behaelt den von FHEM abgeflachten Reading-Namen');
is($autocreate_template->{semantic_entity}{id}, 'energy_power_0',
	'Discovery-ID bleibt unabhaengig vom rohen FHEM-Reading stabil');
is($autocreate_template->{semantic_entity}{capabilities}{value}{read}, 'ENERGY_Power_1',
	'SemanticUI liest das tatsaechlich von Autocreate erzeugte Reading');
my $autocreate_switch = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('switch', object_id => 'power', state_topic => 'node/result',
		value_template => '{{ value_json.POWER }}', payload_on => 'ON', payload_off => 'OFF',
		json_autocreate => 1), io_name => 'mqtt', cid => 'client');
is($autocreate_switch->{reading_lines}[0]{line},
	q{node/result:.* { MQTT2_DISCOVERY_jsonReadings($NAME,'result',$EVENT) }},
	'Autocreate gilt auch fuer native JSON-Aktorzustaende');
is($autocreate_switch->{semantic_entity}{capabilities}{power}{read}, 'POWER',
	'SemanticUI liest beim Aktor das rohe JSON-Reading');
is($autocreate_switch->{set_lines}[0]{line}, 'POWER:ON,OFF node/switch/set',
	'Set-Name entspricht auch allgemein exakt dem Rohreading');
is($autocreate_switch->{semantic_entity}{capabilities}{power}{write}, 'POWER',
	'SemanticUI schreibt denselben Namen, den sie liest');
my $numbered_autocreate_switch = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('switch', object_id => 'power', state_topic => 'node/result',
		value_template => '{{ value_json.POWER1 }}', payload_on => 'ON', payload_off => 'OFF',
		json_autocreate => 1), io_name => 'mqtt', cid => 'client');
is($numbered_autocreate_switch->{semantic_entity}{capabilities}{power}{read}, 'POWER1',
	'SemanticUI uebernimmt den finalen Readingnamen statt ihn aus der Entity-ID abzuleiten');
is($numbered_autocreate_switch->{set_lines}[0]{line}, 'POWER1:ON,OFF node/switch/set',
	'abgeleiteter Set-Name entspricht exakt dem Rohreading');
is($numbered_autocreate_switch->{semantic_entity}{capabilities}{power}{write}, 'POWER1',
	'SemanticUI schreibt denselben Namen, den sie als Reading liest');
my $unsafe_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ states("sensor.secret") }}'), io_name => 'mqtt', cid => 'client');
ok(!$unsafe_template->{ok}, 'Entity mit ausschliesslich unsicherem Template erzeugt kein leeres Mapping');

subtest 'Semantic-Metadaten' => sub {
	my $switch = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', payload_on => '1', payload_off => '0'), io_name => 'mqtt', cid => 'c');
	is($switch->{semantic_entity}{class}, 'switch', 'HA-Komponente wird Semantic-Klasse');
	is($switch->{semantic_entity}{capabilities}{power}{read}, 'switch', 'Power liest das generierte Reading');
	is($switch->{semantic_entity}{capabilities}{power}{write}, 'switch', 'Power schreibt den generierten Set-Namen');
	is($switch->{semantic_entity}{capabilities}{power}{options}, ['on', 'off'],
		'SemanticUI erhaelt die nativen FHEM-Set-Zustaende');
	is([$switch->{semantic_entity}{capabilities}{power}{activeValue},
			$switch->{semantic_entity}{capabilities}{power}{inactiveValue}], ['on', 'off'],
		'aktive und inaktive FHEM-Set-Werte steuern die Darstellung');
	is($switch->{semantic_entity}{capabilities}{power}{valueMap}{read},
		{ 1 => 'on', 0 => 'off' },
		'MQTT-Zustandspayloads werden auf die FHEM-Set-Werte normalisiert');

	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'Temperatur', device_class => 'temperature',
			state_class => 'measurement', unit_of_measurement => "\x{b0}C"), io_name => 'mqtt', cid => 'c');
	is($sensor->{semantic_entity}{name}, 'Temperatur', 'Entity-Anzeigename bleibt erhalten');
	is($sensor->{semantic_entity}{device_class}, 'temperature', 'device_class wird uebernommen');
	is($sensor->{semantic_entity}{state_class}, 'measurement', 'state_class wird uebernommen');
	is($sensor->{semantic_entity}{capabilities}{value}{unit}, "\x{b0}C", 'Einheit wird uebernommen');

	my $unclassified = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'IP address'), io_name => 'mqtt', cid => 'c');
	is($unclassified->{semantic_entity}, undef,
		'unklassifiziertes Read-only-Reading bleibt ausserhalb der automatischen SemanticUI');

	my $diagnostic = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'Internal temperature', device_class => 'temperature',
			entity_category => 'diagnostic'), io_name => 'mqtt', cid => 'c');
	is($diagnostic->{semantic_entity}, undef,
		'explizite Diagnostic-Entity bleibt trotz typischer device_class ausserhalb der SemanticUI');

	my $carbon_dioxide = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'carbon_dioxide'), io_name => 'mqtt', cid => 'c');
	ok($carbon_dioxide->{semantic_entity},
		'kanonische Home-Assistant-device_class carbon_dioxide wird zugelassen');
	my $noncanonical_co2 = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'co2'), io_name => 'mqtt', cid => 'c');
	is($noncanonical_co2->{semantic_entity}, undef,
		'nicht kanonisches co2 wird nicht als device_class erraten');
	my $wrong_case = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'Temperature'), io_name => 'mqtt', cid => 'c');
	is($wrong_case->{semantic_entity}, undef,
		'device_class muss die Positivliste auch in der Schreibweise exakt treffen');

	my $pac_switch = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', object_id => 'pac_mild_dry_switch', name => 'pac mild dry switch',
			state_topic => 'pac-1d797c/state/mild_dry',
			device => { identifiers => ['dc1ed51d797c'], name => 'pac-1d797c' }),
		io_name => 'mqtt', cid => 'c');
	is($pac_switch->{semantic_entity}{name}, 'mild dry switch',
		'redundanter Geraetepraefix wird aus dem Semantic-Anzeigenamen entfernt');

	my $pac_climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'pac-1d797c', name => 'pac', state_topic => undef,
			current_temperature_topic => 'pac-1d797c/state/current_temperature',
			device => { identifiers => ['dc1ed51d797c'], name => 'pac-1d797c' }),
		io_name => 'mqtt', cid => 'c');
	is($pac_climate->{semantic_entity}{name}, 'climate',
		'reiner Geraetepraefix faellt auf die Semantic-Klasse zurueck');
};

subtest 'Geraeteweite Semantic-Komposition' => sub {
	my $climate = {
		entity_key => 'climate', strong_identity => 1, metadata => { component => 'climate' },
		semantic_entity => { id => 'climate', class => 'climate', capabilities => {
			mode => { read => 'mode', write => 'mode', options => [qw(off cool)] },
		} },
	};
	my $switch = {
		entity_key => 'mild-dry', strong_identity => 1, metadata => { component => 'switch' },
		semantic_entity => { id => 'mild_dry', class => 'switch', capabilities => {
			power => { read => 'mild_dry', write => 'mild_dry', options => [qw(ON OFF)] },
		} },
	};
	my $select = {
		entity_key => 'vertical-swing', strong_identity => 1, metadata => { component => 'select' },
		semantic_entity => { id => 'vertical_swing_mode', class => 'select', capabilities => {
			value => { read => 'vertical_swing_mode', write => 'vertical_swing_mode', options => [qw(auto up down)] },
		} },
	};
	my @items = map {{
		entity_key => $_->{entity_key}, mapping => $_,
		entry => JSON::PP->new->decode(JSON::PP->new->encode($_->{semantic_entity})),
	}} ($climate, $switch, $select);
	my $composed = MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@items);
	is(scalar @$composed, 1, 'eine eindeutige Climate-Hauptentity nimmt atomare Geschwister auf');
	my $capabilities = $composed->[0]{entry}{capabilities};
	is($capabilities->{mildDry}, {
			read => 'mild_dry', write => 'mild_dry', options => [qw(ON OFF)], kind => 'boolean',
		}, 'Switch wird ohne Namensheuristik zur typisierten booleschen Capability');
	is($capabilities->{verticalSwingMode}, {
			read => 'vertical_swing_mode', write => 'vertical_swing_mode',
			options => [qw(auto up down)], kind => 'enum',
		}, 'Select wird zur typisierten Enum-Capability');

	my @without_primary = @items[1, 2];
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@without_primary) }, 2,
		'mehrere atomare Switch-/Select-Entities ohne Hauptentity bleiben getrennt');

	my $weak_switch = {
		entity_key => 'weak-switch', mapping => {
			strong_identity => 0, metadata => { component => 'switch' },
		},
		entry => { id => 'weak_switch', class => 'switch', capabilities => {
			power => { read => 'weak_switch', write => 'weak_switch', options => [qw(ON OFF)] },
		} },
	};
	my @weak_identity = ($items[0], $weak_switch);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@weak_identity) }, 2,
		'schwach zugeordnete Geschwister werden nicht komponiert');

	my $diagnostic_switch = {
		entity_key => 'diagnostic-switch', mapping => {
			strong_identity => 1,
			metadata => { component => 'switch', entity_category => 'diagnostic' },
		},
		entry => { id => 'diagnostic_switch', class => 'switch', capabilities => {
			power => { read => 'diagnostic_switch', write => 'diagnostic_switch', options => [qw(ON OFF)] },
		} },
	};
	my @diagnostic = ($items[0], $diagnostic_switch);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@diagnostic) }, 2,
		'Diagnose- und Konfigurations-Entities bleiben eigenstaendig');

	my $second_climate = {
		entity_key => 'climate-zone-2', mapping => $climate,
		entry => { id => 'climate_zone_2', class => 'climate', capabilities => { mode => { read => 'mode_2' } } },
	};
	my @ambiguous = ($items[0], $second_climate, $items[1]);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@ambiguous) }, 3,
		'bei mehreren Climate-Entities wird keine mehrdeutige Zuordnung vorgenommen');
};

done_testing;
