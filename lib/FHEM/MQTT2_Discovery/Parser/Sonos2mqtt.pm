# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Parser::Sonos2mqtt;

use strict;
use warnings;
use JSON::PP qw(decode_json);


# Erzeugt ein einheitlich klassifiziertes Parserergebnis fuer ungueltige Nachrichten.
sub _error {
	my ($class, $message, %extra) = @_;
	return { status => 'error', error_class => $class, error => $message, %extra };
}

# Zerlegt ein Sonos2mqtt-Discovery-Topic innerhalb der konfigurierten Prefixe.
sub _topic_parts {
	my ($topic, $prefixes) = @_;
	return if !defined($topic) || ref($topic);
	my @prefixes = grep {
		defined($_) && !ref($_) && $_ ne ''
	} @{ ref($prefixes) eq 'ARRAY' ? $prefixes : ['sonos2mqtt'] };

	# Laengere Prefixe haben Vorrang, damit verschachtelte Konfigurationen nicht
	# versehentlich von einem kuerzeren gemeinsamen Anfang beansprucht werden.
	for my $prefix (sort { length($b) <=> length($a) } @prefixes) {
		my $start = "$prefix/discovery/";
		next if index($topic, $start) != 0;
		my $rest = substr($topic, length($start));
		next if $rest !~ m{^([A-Za-z0-9_.-]+)/([A-Za-z0-9_-]+)$};
		return ($prefix, $1, $2);
	}

	return;
}

# Erkennt ausschliesslich die aktuelle Sonos2mqtt-Discovery-Topicform.
sub matches {
	my (%args) = @_;
	my @parts = _topic_parts($args{topic}, $args{prefixes});
	return @parts ? 1 : 0;
}

# Liefert nur nichtleere skalare Topicwerte aus dem Discovery-Payload.
sub _topic_value {
	my ($payload, $key) = @_;
	return undef if ref($payload) ne 'HASH' || !defined($payload->{$key})
		|| ref($payload->{$key}) || $payload->{$key} eq '';
	return $payload->{$key};
}

# Codiert ein konstantes Sonos-Steuerkommando als kanonisches JSON.
sub _command_payload {
	my ($command) = @_;
	return JSON::PP->new->canonical(1)->encode({ command => $command });
}

# Normalisiert eine aktuelle Sonos2mqtt-Speaker-Discovery in eine Media-Player-Entity.
sub parse {
	my (%args) = @_;
	my $topic = $args{topic};
	my ($prefix, $mqtt_prefix, $uuid) = _topic_parts($topic, $args{prefixes});
	return { status => 'next' } if !defined $prefix;
	my $payload = defined($args{payload}) ? $args{payload} : '';
	my $entity_key = join('|', $topic, '');

	# Ein leerer retained Payload entfernt genau den zuvor unter diesem Topic
	# verwalteten Lautsprecher.
	if ($payload eq '') {
		return {
			status => 'ok',
			entities => [{
				operation => 'delete', prefix => $prefix, format => 'sonos2mqtt',
				component => 'media_player', node_id => $mqtt_prefix,
				object_id => $uuid, discovery_topic => $topic,
				entity_key => $entity_key,
			}],
			warnings => [],
		};
	}
	my $decoded;
	my $ok = eval { $decoded = decode_json($payload); 1 };
	return _error('json', "Ungueltiges JSON: $@", topic => $topic) if !$ok;
	return _error('schema', 'Sonos2mqtt-Discovery-Payload muss ein JSON-Objekt sein', topic => $topic)
		if ref($decoded) ne 'HASH';
	return _error('schema', 'Sonos2mqtt device muss ein JSON-Objekt sein', topic => $topic)
		if ref($decoded->{device}) ne 'HASH';
	return _error('schema', 'Sonos2mqtt device_class muss speaker sein', topic => $topic)
		if !defined($decoded->{device_class}) || ref($decoded->{device_class})
			|| $decoded->{device_class} ne 'speaker';
	return _error('schema', 'Sonos2mqtt unique_id fehlt', topic => $topic)
		if !defined($decoded->{unique_id}) || ref($decoded->{unique_id}) || $decoded->{unique_id} eq '';
	my $identifiers = $decoded->{device}{identifiers};
	return _error('schema', 'Sonos2mqtt device.identifiers muss den Topic-RINCON enthalten', topic => $topic)
		if ref($identifiers) ne 'ARRAY'
			|| !grep { defined($_) && !ref($_) && $_ eq $uuid } @$identifiers;
	my $state_topic = _topic_value($decoded, 'state_topic');
	my $command_topic = _topic_value($decoded, 'command_topic');
	my $availability_topic = _topic_value($decoded, 'availability_topic');
	return _error('schema', 'Sonos2mqtt state_topic passt nicht zum Discovery-Topic', topic => $topic)
		if !defined($state_topic) || $state_topic ne "$mqtt_prefix/$uuid";
	return _error('schema', 'Sonos2mqtt command_topic passt nicht zum Lautsprecher', topic => $topic)
		if !defined($command_topic) || $command_topic ne "$state_topic/control";
	return _error('schema', 'Sonos2mqtt availability_topic passt nicht zum MQTT-Prefix', topic => $topic)
		if !defined($availability_topic) || $availability_topic ne "$mqtt_prefix/connected";
	my $device_name = $decoded->{device}{name};
	$device_name = $decoded->{name}
		if !defined($device_name) || ref($device_name) || $device_name eq '';
	$device_name = $uuid if !defined($device_name) || ref($device_name) || $device_name eq '';
	my $entity_name = $decoded->{name};
	$entity_name = $device_name
		if !defined($entity_name) || ref($entity_name) || $entity_name eq '';
	my $icon = $decoded->{icon};
	$icon = undef if defined($icon) && ref($icon);
	my %device = %{ $decoded->{device} };
	$device{name} = $device_name;
	my %entity = (
		operation => 'upsert', prefix => $prefix, format => 'sonos2mqtt',
		component => 'media_player', component_key => 'media_player',
		node_id => $mqtt_prefix, object_id => $uuid,
		unique_id => $decoded->{unique_id}, name => $entity_name,
		preferred_entity_name => 'player', device => \%device,
		device_class => 'speaker', icon => $icon,
		discovery_topic => $topic, entity_key => $entity_key,
		device_topic => $state_topic,
		state_topic => $state_topic,
		value_template => '{{ value_json.transportState }}',
		state_reading_name => 'transportState',
		volume_state_topic => $state_topic,
		volume_value_template => '{{ value_json.volume.Master }}',
		volume_reading_name => 'volume',
		mute_state_topic => $state_topic,
		mute_value_template => '{{ value_json.mute.Master }}',
		mute_reading_name => 'mute',
		command_topic => $command_topic,
		volume_command_topic => $command_topic,
		volume_set_name => 'volume',
		volume_command_codec => {
			format => 'json', key => 'input', value_type => 'number',
			constants => { command => 'volume' },
		},
		mute_command_topic => $command_topic,
		mute_set_name => 'mute',
		payload_play => _command_payload('play'),
		payload_pause => _command_payload('pause'),
		payload_stop => _command_payload('stop'),
		payload_toggle => _command_payload('toggle'),
		payload_next => _command_payload('next'),
		payload_previous => _command_payload('previous'),
		payload_mute => _command_payload('mute'),
		payload_unmute => _command_payload('unmute'),
		availability_topic => $availability_topic,
		availability_template => "{{ value == '2' }}",
		payload_available => '1', payload_not_available => '0',
	);
	return { status => 'ok', entities => [\%entity], warnings => [] };
}

1;
