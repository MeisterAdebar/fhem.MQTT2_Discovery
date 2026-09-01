# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use lib 'lib/FHEM';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Renderer ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Parser::Sonos2mqtt ();
use MQTT2_Discovery::Template ();

my $uuid = 'RINCON_804AF28451D201400';
my $topic = "sonos2mqtt/discovery/sonos/$uuid";

# Erzeugt das aktuelle Sonos2mqtt-Discovery-Payload mit gezielt ueberschreibbaren Feldern.
sub sonos_payload {
	my (%extra) = @_;
	my $mqtt_prefix = delete($extra{mqtt_prefix}) // 'sonos';
	my $speaker_uuid = delete($extra{uuid}) // $uuid;
	my $payload = {
		device => {
			identifiers => [$speaker_uuid], manufacturer => 'Sonos, Inc.',
			model => 'Sonos Era 300', name => 'Wohnen', sw_version => '94.1-75110',
			connections => [
				['host', '192.168.1.141:1400'],
				['mqtt', "$mqtt_prefix/$speaker_uuid"],
				['mac', '80:4A:F2:84:51:D2'],
			],
		},
		device_class => 'speaker', icon => 'mdi:speaker', name => 'Wohnen',
		state_topic => "$mqtt_prefix/$speaker_uuid",
		command_topic => "$mqtt_prefix/$speaker_uuid/control",
		unique_id => "sonos2mqtt_${speaker_uuid}_speaker",
		availability_topic => "$mqtt_prefix/connected",
		%extra,
	};
	return JSON::PP->new->canonical(1)->encode($payload);
}

# Fuehrt eine Nachricht ueber die reale Format-Registry bis zum kanonischen Modell.
sub consume {
	my ($message_topic, $payload, $prefixes) = @_;
	return MQTT2_Discovery::FormatRegistry::consume(
		topic => $message_topic, payload => $payload,
		prefixes => $prefixes || ['homeassistant', 'tasmota/discovery', 'sonos2mqtt'],
		states => {},
	);
}

subtest 'Topic-Erkennung bleibt auf Sonos2mqtt-Discovery begrenzt' => sub {
	ok(MQTT2_Discovery::Parser::Sonos2mqtt::matches(
		topic => $topic, prefixes => ['sonos2mqtt']),
		'aktuelle Topicform wird erkannt');
	ok(!MQTT2_Discovery::Parser::Sonos2mqtt::matches(
		topic => "sonos/$uuid", prefixes => ['sonos2mqtt']),
		'normales Speaker-State-Topic wird nicht beansprucht');
	ok(!MQTT2_Discovery::Parser::Sonos2mqtt::matches(
		topic => "sonos2mqtt/discovery/sonos/$uuid/extra", prefixes => ['sonos2mqtt']),
		'zusaetzliche Topicsegmente werden abgelehnt');
	is(consume($topic, sonos_payload(), ['homeassistant'])->{status}, 'next',
		'nicht konfiguriertes Sonos2mqtt-Prefix wird weitergereicht');
};

subtest 'Speaker wird kanonischer Media-Player' => sub {
	my $result = consume($topic, sonos_payload());
	is([$result->{status}, $result->{adapter}], ['ok', 'sonos2mqtt'],
		'spezifischer Sonos2mqtt-Adapter wurde ausgewaehlt');
	my $event = $result->{events}[0];
	is($event->{entity}{kind}, 'media_player', 'kanonische Geraeteklasse ist media_player');
	is($event->{source}{key}, "$topic|", 'Discovery-Topic ist der stabile Entity-Schluessel');
	is($event->{device}{identifiers}, [$uuid], 'RINCON bleibt die starke Device-Identitaet');
	is([map { $_->{id} } @{ $event->{signals} }], [qw(state volume mute)],
		'Status, Lautstaerke und Mute sind getrennte Signale');
	is([map { $_->{id} } @{ $event->{commands} }], [qw(command volume mute)],
		'Transport, Lautstaerke und Mute sind getrennte Commands');
	my %commands = map { ($_->{id} => $_) } @{ $event->{commands} };
	is($commands{volume}{codec}, {
		format => 'json', key => 'input', value_type => 'number',
		constants => { command => 'volume' },
	}, 'Lautstaerke verwendet den allgemeinen JSON-Codec mit konstantem Command');
	is($event->{availability}, [{
		topic => 'sonos/connected', value_template => "{{ value == '2' }}",
		payload_available => '1', payload_not_available => '0',
	}], 'nur Sonos2mqtt-Status 2 wird als online normalisiert');
	is(MQTT2_Discovery::Model::validate($event), undef, 'Media-Player-Modell ist gueltig');

	for my $case ([0, 0], [1, 0], [2, 1]) {
		my ($input, $expected) = @$case;
		my $rendered = MQTT2_Discovery::Template::render(
			$event->{availability}[0]{value_template}, value => "$input",
		);
		is($rendered->{value}, "$expected", "Connected-Zustand $input wird korrekt normalisiert");
	}
};

subtest 'Mapper erzeugt Readings, Basisbefehle und Semantik' => sub {
	my $event = consume($topic, sonos_payload())->{events}[0];
	my $mapping = MQTT2_Discovery::Mapper::map_model(
		model => $event, io_name => 'mqtt', cid => 'sonosbridge',
	);
	ok($mapping->{ok}, 'Media-Player wird vom gemeinsamen Mapper verarbeitet');
	is($mapping->{proposed_name}, 'Wohnen', 'Sonos-Raumname wird zum vorgeschlagenen Device-Namen');
	is($mapping->{device_topic}, "sonos/$uuid", 'Speaker-State-Topic ist das gemeinsame Device-Topic');
	my %readings = map { (($_->{name} // '') => $_) }
		grep { ($_->{role} // '') ne 'availability' } @{ $mapping->{reading_lines} };
	is([sort keys %readings], [qw(mute transportState volume)],
		'die drei fachlichen State-Readings werden erzeugt');
	my %sets = map { ($_->{name} => $_) } @{ $mapping->{set_lines} };
	my %runtime_references;
	$_->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry(
		$_, undef, \%runtime_references,
	) for values %sets;
	is([sort keys %sets], [sort qw(volume mute play pause stop toggle next previous)],
		'alle vereinbarten Basisbefehle werden erzeugt');
	is($sets{volume}{line},
		qq|volume:slider,0,1,100 sonos/$uuid/control {"command":"volume","input":\$EVTPART1}|,
		'Lautstaerke sendet Command und numerischen Input als ein JSON-Objekt');
	my ($mute_reference) = $sets{mute}{line} =~ /'(r_[a-f0-9]+)'/;
	like($runtime_references{$mute_reference}{mapping}{on}, qr/\Q{"command":"mute"}\E/,
		'Mute-Auswahl enthaelt das feste Mute-Kommando');

	for my $command (qw(play pause stop toggle next previous)) {
		is($sets{$command}{line},
			qq|$command:noArg sonos/$uuid/control {"command":"$command"}|,
			"$command sendet ein festes Sonos2mqtt-JSON-Kommando");
	}

	my $semantic = $mapping->{semantic_entity};
	is($semantic->{class}, 'media_player', 'semantische Klasse ist media_player');
	is([$semantic->{capabilities}{volume}{read}, $semantic->{capabilities}{volume}{write}],
		[qw(volume volume)], 'Lautstaerke verbindet Reading und Setter');
	is([$semantic->{capabilities}{mute}{read}, $semantic->{capabilities}{mute}{write}],
		[qw(mute mute)], 'Mute verbindet Reading und Setter');
	is($semantic->{capabilities}{play}, { write => 'play', argument => 0 },
		'Play wird als argumentlose semantische Aktion beschrieben');
};

subtest 'Delete und fehlerhafte Discovery werden kontrolliert behandelt' => sub {
	my $delete = consume($topic, '');
	is([$delete->{status}, $delete->{events}[0]{operation}, $delete->{events}[0]{source}{key}],
		['ok', 'delete', "$topic|"], 'leerer retained Payload entfernt genau dieselbe Entity');
	is(consume($topic, '{')->{error_class}, 'json', 'defektes JSON wird klassifiziert');
	is(consume($topic, sonos_payload(device_class => 'switch'))->{error_class}, 'schema',
		'falsche Geraeteklasse wird abgelehnt');
	is(consume($topic, sonos_payload(command_topic => 'sonos/other/control'))->{error_class}, 'schema',
		'fremdes Command-Topic wird abgelehnt');
	is(consume($topic, sonos_payload(availability_topic => 'other/connected'))->{error_class}, 'schema',
		'fremdes Availability-Topic wird abgelehnt');

	my $event = consume($topic, sonos_payload())->{events}[0];
	my $invalid = JSON::PP::decode_json(JSON::PP::encode_json($event));
	my ($volume) = grep { $_->{id} eq 'volume' } @{ $invalid->{commands} };
	$volume->{codec}{constants}{input} = 'collision';
	like(MQTT2_Discovery::Model::validate($invalid), qr/Command-Codec-Konstante input/,
		'das kanonische Modell verhindert eine Ueberschreibung des dynamischen JSON-Feldes');
};

done_testing;
