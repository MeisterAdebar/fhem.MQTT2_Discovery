# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Model;

use strict;
use warnings;

our $SCHEMA_VERSION = 1;

# Diese Mengen bilden die bewusst kleine, validierbare Aussengrenze des
# kanonischen Modells. Neue Operationen oder Klassen muessen hier freigegeben
# und anschliessend vom Mapper unterstuetzt werden.
my %OPERATION = map { $_ => 1 } qw(upsert delete delete_device);
my %KIND = map { $_ => 1 } qw(
	sensor binary_sensor switch button number select text light cover fan lock climate
	media_player update device_tracker event device_automation
);

my %INTERNAL = map { $_ => 1 } qw(
	operation prefix format component node_id object_id discovery_topic entity_key
	component_key unique_id name preferred_entity_name device raw_metadata device_topic supplemental_signals internal_rebuild
	entity_category json_autocreate json_reading_name
	availability availability_topic availability_template availability_mode
	payload_available payload_not_available
);

# Die Tabellen beschreiben, welche Discovery-Felder ein logisches Lese- oder
# Schreibsignal speisen. Damit bleibt from_entity frei von langen Sonderfaellen.
my @SIGNAL_BINDINGS = (
	[state => 'state_topic', 'value_template', 'state_reading_name'],
	[action => 'action_topic', 'action_template'],
	[brightness => 'brightness_state_topic', 'brightness_value_template', 'brightness_reading_name'],
	[color_temperature => 'color_temp_state_topic', 'color_temp_value_template'],
	[rgb => 'rgb_state_topic', 'rgb_value_template'],
	[effect => 'effect_state_topic', 'effect_value_template'],
	[white => 'white_state_topic', 'white_value_template'],
	[position => 'position_topic', 'position_template'],
	[tilt => 'tilt_status_topic', 'tilt_status_template'],
	[percentage => 'percentage_state_topic', 'percentage_value_template'],
	[volume => 'volume_state_topic', 'volume_value_template', 'volume_reading_name'],
	[mute => 'mute_state_topic', 'mute_value_template', 'mute_reading_name'],
	[current_temperature => 'current_temperature_topic', 'current_temperature_template'],
	[current_humidity => 'current_humidity_topic', 'current_humidity_template'],
	[target_temperature => 'temperature_state_topic', 'temperature_state_template'],
	[target_temperature_high => 'temperature_high_state_topic', 'temperature_high_state_template'],
	[target_temperature_low => 'temperature_low_state_topic', 'temperature_low_state_template'],
	[target_humidity => 'target_humidity_state_topic', 'target_humidity_state_template'],
	[mode => 'mode_state_topic', 'mode_state_template'],
	[fan_mode => 'fan_mode_state_topic', 'fan_mode_state_template'],
	[swing_mode => 'swing_mode_state_topic', 'swing_mode_state_template'],
	[swing_horizontal_mode => 'swing_horizontal_mode_state_topic', 'swing_horizontal_mode_state_template'],
	[preset_mode => 'preset_mode_state_topic', 'preset_mode_value_template'],
);

my @COMMAND_BINDINGS = (
	[command => 'command_topic', 'command_template', 'command_set_name', 'command_codec'],
	[brightness => 'brightness_command_topic', undef, 'brightness_set_name', 'brightness_command_codec'],
	[color_temperature => 'color_temp_command_topic', undef],
	[rgb => 'rgb_command_topic', undef],
	[effect => 'effect_command_topic', undef],
	[white => 'white_command_topic', undef],
	[position => 'position_command_topic', undef],
	[tilt => 'tilt_command_topic', undef],
	[percentage => 'percentage_command_topic', undef],
	[volume => 'volume_command_topic', 'volume_command_template', 'volume_set_name', 'volume_command_codec'],
	[mute => 'mute_command_topic', 'mute_command_template', 'mute_set_name', 'mute_command_codec'],
	[target_temperature => 'temperature_command_topic', 'temperature_command_template'],
	[target_temperature_high => 'temperature_high_command_topic', 'temperature_high_command_template'],
	[target_temperature_low => 'temperature_low_command_topic', 'temperature_low_command_template'],
	[target_humidity => 'target_humidity_command_topic', 'target_humidity_command_template'],
	[mode => 'mode_command_topic', 'mode_command_template'],
	[fan_mode => 'fan_mode_command_topic', 'fan_mode_command_template'],
	[swing_mode => 'swing_mode_command_topic', 'swing_mode_command_template'],
	[swing_horizontal_mode => 'swing_horizontal_mode_command_topic', 'swing_horizontal_mode_command_template'],
	[preset_mode => 'preset_mode_command_topic', 'preset_mode_command_template'],
	[power => 'power_command_topic', 'power_command_template'],
);

# Binding-Felder werden ausschliesslich ueber signals beziehungsweise commands
# transportiert und dadurch nicht noch einmal in configuration dupliziert.
my %BINDING_CONFIGURATION_KEY = map { ($_ => 1) }
	grep { defined($_) } map { @$_[1 .. $#$_] } (@SIGNAL_BINDINGS, @COMMAND_BINDINGS);

# Normalisiert einzelne oder mehrere Topic-Bindings in eine kanonische Liste.
sub _binding_list {
	my ($configuration, $specs) = @_;
	my @bindings;

	for my $spec (@$specs) {
		my ($id, $topic_key, $template_key, $name_key, $codec_key) = @$spec;
		my $topic = $configuration->{$topic_key};
		next if !defined($topic) || ref($topic) || $topic eq '';
		my %binding = (id => $id, topic => $topic);

		# Ein Template gehoert nur dann ins Binding, wenn das Format dafuer ein
		# konkretes Feld definiert hat.
		$binding{template} = $configuration->{$template_key}
			if defined($template_key) && defined($configuration->{$template_key});
		$binding{name} = $configuration->{$name_key}
			if defined($name_key) && defined($configuration->{$name_key});
		$binding{codec} = { %{ $configuration->{$codec_key} } }
			if defined($codec_key) && ref($configuration->{$codec_key}) eq 'HASH';
		push @bindings, \%binding;
	}

	return \@bindings;
}

# Projiziert kanonische Bindings fuer den bestehenden flachen Mapperzugang zurueck.
sub _project_bindings {
	my ($configuration, $bindings, $specs) = @_;
	return if ref($configuration) ne 'HASH' || ref($bindings) ne 'ARRAY' || ref($specs) ne 'ARRAY';
	my %spec_by_id = map { ($_->[0] => $_) } @$specs;

	for my $binding (@$bindings) {
		next if ref($binding) ne 'HASH' || !defined($binding->{id});
		my $spec = $spec_by_id{$binding->{id}};
		next if !$spec;
		my (undef, $topic_key, $template_key, $name_key, $codec_key) = @$spec;
		$configuration->{$topic_key} = $binding->{topic};
		$configuration->{$template_key} = $binding->{template}
			if defined($template_key) && exists($binding->{template});
		$configuration->{$name_key} = $binding->{name}
			if defined($name_key) && exists($binding->{name});
		$configuration->{$codec_key} = { %{ $binding->{codec} } }
			if defined($codec_key) && ref($binding->{codec}) eq 'HASH';
	}
	return;
}

# Konvertiert eine Parser-Entity in ein formatunabhaengiges kanonisches Event.
sub from_entity {
	my (%args) = @_;
	my $source = $args{entity};
	return undef if ref($source) ne 'HASH';
	my $operation = $source->{operation} || 'upsert';
	my %configuration = map { ($_ => $source->{$_}) }
		grep { !$INTERNAL{$_} && !$BINDING_CONFIGURATION_KEY{$_} } keys %$source;
	my @availability;
	my $payload_available = exists($source->{payload_available})
		? $source->{payload_available} : 'online';
	my $payload_not_available = exists($source->{payload_not_available})
		? $source->{payload_not_available} : 'offline';

	# Einzelne Availability-Topics und Listen werden auf dieselbe kanonische
	# Quellenstruktur mit expliziten Vergleichswerten normalisiert.
	if (defined($source->{availability_topic}) && !ref($source->{availability_topic})) {
		push @availability, {
			topic => $source->{availability_topic},
			(defined($source->{availability_template})
				? (value_template => $source->{availability_template}) : ()),
			payload_available => $payload_available,
			payload_not_available => $payload_not_available,
		};
	}

	if (ref($source->{availability}) eq 'ARRAY') {

		for my $entry (@{ $source->{availability} }) {
			if (ref($entry) eq 'HASH') {
				my %copy = %$entry;
				$copy{payload_available} = $payload_available
					if !exists($copy{payload_available});
				$copy{payload_not_available} = $payload_not_available
					if !exists($copy{payload_not_available});
				push @availability, \%copy;
			} else {
				push @availability, $entry;
			}
		}

	}

	my $layout = $source->{format} || 'entity';
	my $component = $source->{component};
	my $signals = _binding_list($source, \@SIGNAL_BINDINGS);
	my $commands = _binding_list($source, \@COMMAND_BINDINGS);

	# Ab diesem Punkt werden Protokolldetails nur noch als Source/Extensions
	# transportiert; die Kernfelder haben fuer alle Adapter dieselbe Bedeutung.
	my $model = {
		schema_version => $SCHEMA_VERSION,
		operation => $operation,
		source => {
			adapter => $args{adapter} || 'unknown',
			prefix  => $source->{prefix},
			topic   => $source->{discovery_topic},
			key     => $source->{entity_key},
			layout  => $layout,
		},
		device => ref($source->{device}) eq 'HASH' ? { %{ $source->{device} } } : {},
		entity => {
			id            => $source->{object_id},
			component_key => $source->{component_key},
			kind          => $component,
			node_id       => $source->{node_id},
			unique_id     => $source->{unique_id},
			channel       => $source->{channel},
			channel_name  => $source->{channel_name},
			name          => $source->{name},
			logical_name  => $source->{preferred_entity_name},
			category      => $source->{entity_category},
			configuration => \%configuration,
		},
		signals => $signals,
		commands => $commands,
		availability => \@availability,
		availability_mode => @availability
			? ($source->{availability_mode} // 'latest') : undef,
		extensions => {},
	};

	$model->{extensions}{device_topic} = $source->{device_topic}
		if defined($source->{device_topic}) && !ref($source->{device_topic});
	# Die Markierung unterscheidet einen rein technischen Replace-Schritt von
	# einem extern ausgeloesten Discovery-Loeschereignis.
	$model->{extensions}{internal_rebuild} = 1 if $source->{internal_rebuild};

	for my $key (qw(json_autocreate json_reading_name)) {
		$model->{extensions}{$key} = $source->{$key} if exists($source->{$key});
	}

	# Weitere JSON-Schluessel, die denselben Wert transportieren. Tasmota meldet
	# den ersten Kanal je nach SetOption26 als POWER oder als POWER1, sagt in der
	# Discovery aber nicht, welches von beiden.
	$model->{extensions}{json_key_aliases} = [
		grep { defined($_) && !ref($_) && $_ =~ /^[A-Za-z_][A-Za-z0-9_]*\z/ }
			@{ $source->{json_key_aliases} }
	] if ref($source->{json_key_aliases}) eq 'ARRAY';

	$model->{extensions}{supplemental_signals} = [
		map { ref($_) eq 'HASH' ? { %$_ } : $_ } @{ $source->{supplemental_signals} }
	] if ref($source->{supplemental_signals}) eq 'ARRAY';

	# Die Root-Markierung ist eine Adapterentscheidung. Der Mapper muss weder
	# object_id noch protokollspezifische Device-Namen interpretieren.
	my $device_name = $model->{device}{name};

	# Nur zwei skalare Namen erlauben einen stabilen Vergleich; bei fehlenden
	# Angaben bleibt die Entity vorsichtshalber eine normale Unter-Entity.
	if (defined($source->{object_id}) && !ref($source->{object_id})
			&& defined($device_name) && !ref($device_name)) {
		require MQTT2_Discovery::Helper;
		my $object_name = MQTT2_Discovery::Helper::safe_name($source->{object_id}, 'entity');
		my $safe_device_name = MQTT2_Discovery::Helper::safe_name($device_name, 'device');

		# HA schreibt object_id haeufig klein; die Schreibweise allein erzeugt keine Unter-Entity.
		$model->{entity}{root} = lc($object_name) eq lc($safe_device_name) ? 1 : 0;
	}

	return $model;
}

# Validiert Struktur und Pflichtfelder eines kanonischen Events ohne Seiteneffekte.
sub validate {
	my ($model) = @_;
	return 'Kanonisches Discovery-Modell fehlt' if ref($model) ne 'HASH';
	return 'Nicht unterstuetzte Modellversion'
		if !defined($model->{schema_version}) || $model->{schema_version} != $SCHEMA_VERSION;
	return 'Ungueltige kanonische Operation'
		if !defined($model->{operation}) || !$OPERATION{$model->{operation}};
	return 'Kanonische Quelle fehlt' if ref($model->{source}) ne 'HASH';
	return 'Kanonischer Quellschluessel fehlt'
		if !defined($model->{source}{key}) || ref($model->{source}{key}) || $model->{source}{key} eq '';
	return undef if $model->{operation} ne 'upsert';

	# Delete-Events benoetigen nur ihre Quelle. Die strengeren Entity-Pruefungen
	# gelten ausschliesslich fuer neu anzulegende oder zu aktualisierende Daten.
	return 'Kanonische Entity fehlt' if ref($model->{entity}) ne 'HASH';
	return 'Nicht unterstuetzte kanonische Geraeteklasse'
		if !defined($model->{entity}{kind}) || !$KIND{$model->{entity}{kind}};
	return 'Kanonische Konfiguration fehlt' if ref($model->{entity}{configuration}) ne 'HASH';
	return 'Ungueltiger kanonischer Entity-Name'
		if defined($model->{entity}{logical_name}) && ref($model->{entity}{logical_name});
	return 'Kanonische Signals-Liste fehlt' if ref($model->{signals}) ne 'ARRAY';
	return 'Kanonische Commands-Liste fehlt' if ref($model->{commands}) ne 'ARRAY';

	for my $collection (qw(signals commands availability)) {
		return "Ungueltiger Eintrag in $collection"
			if grep { ref($_) ne 'HASH' } @{ $model->{$collection} || [] };
	}
	return 'Ungueltiger Availability-Modus'
		if defined($model->{availability_mode})
			&& $model->{availability_mode} !~ /^(?:all|any|latest)$/;

	for my $availability (@{ $model->{availability} || [] }) {
		return 'Ungueltige Availability-Quelle'
			if !defined($availability->{topic}) || ref($availability->{topic})
				|| $availability->{topic} eq '';

		for my $key (qw(value_template payload_available payload_not_available)) {
			return "Ungueltiger Availability-Wert $key"
				if exists($availability->{$key}) && ref($availability->{$key});
		}

	}

	for my $collection (qw(signals commands)) {

		# Bindings duerfen nur sichere skalare Namen sowie den kleinen allgemeinen
		# JSON-Codecvertrag enthalten; Adapter-Rohdaten sind hier nicht zulaessig.
		for my $binding (@{ $model->{$collection} }) {
			return "Ungueltiges Binding in $collection"
				if !defined($binding->{id}) || ref($binding->{id}) || $binding->{id} eq ''
					|| !defined($binding->{topic}) || ref($binding->{topic}) || $binding->{topic} eq '';
			return "Ungueltiger Binding-Name in $collection"
				if defined($binding->{name}) && (ref($binding->{name})
					|| $binding->{name} !~ /^[A-Za-z_][A-Za-z0-9_.\/-]*$/);
			next if !exists($binding->{codec});
			my $codec = $binding->{codec};
			return "Ungueltiger Command-Codec in $collection"
				if ref($codec) ne 'HASH' || ($codec->{format} || '') ne 'json'
					|| !defined($codec->{key}) || ref($codec->{key})
					|| $codec->{key} !~ /^[A-Za-z_][A-Za-z0-9_]*$/
					|| ($codec->{value_type} || '') !~ /^(?:string|number)$/;
			next if !exists($codec->{constants});
			return "Ungueltige Command-Codec-Konstanten in $collection"
				if ref($codec->{constants}) ne 'HASH';

			# Konstante JSON-Felder duerfen weder den dynamischen Wertschluessel
			# ueberschreiben noch verschachtelte oder unsichere Werte einschleusen.
			for my $key (keys %{ $codec->{constants} }) {
				my $value = $codec->{constants}{$key};
				return "Ungueltige Command-Codec-Konstante $key in $collection"
					if $key !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || $key eq $codec->{key}
						|| !defined($value) || ref($value) || $value =~ /[\x00-\x1f]/;
			}

		}

	}

	return undef;
}

# Uebersetzt ein erfolgreiches Parserergebnis an einer Stelle in kanonische Events.
sub from_parser_result {
	my (%args) = @_;
	my $parsed = $args{parsed};
	my $adapter = $args{adapter} || 'unknown';
	return {
		status => 'error', adapter => $adapter, error_class => 'format',
		error => "$adapter lieferte kein strukturiertes Parserergebnis",
	} if ref($parsed) ne 'HASH';
	return $parsed if ($parsed->{status} || '') ne 'ok';

	my @events = map { from_entity(adapter => $adapter, entity => $_) }
		@{ $parsed->{entities} || [] };
	for my $event (@events) {
		my $error = validate($event);
		return {
			status => 'error', adapter => $adapter,
			error_class => 'canonical', error => $error,
		} if $error;
	}

	return {
		status => 'ok', adapter => $adapter, events => \@events,
		warnings => $parsed->{warnings} || [],
	};
}

# Rekonstruiert die Entity-Sicht fuer bestehende Delete- und Kompatibilitaetspfade.
sub to_entity {
	my ($model) = @_;
	my $error = validate($model);
	return (undef, $error) if $error;
	my $source = $model->{source};
	my $entity = $model->{entity} || {};
	my %configuration = %{ $entity->{configuration} || {} };
	_project_bindings(\%configuration, $model->{signals}, \@SIGNAL_BINDINGS);
	_project_bindings(\%configuration, $model->{commands}, \@COMMAND_BINDINGS);
	$configuration{availability} = [
		map { +{ %$_ } } @{ $model->{availability} || [] }
	] if @{ $model->{availability} || [] };
	$configuration{availability_mode} = $model->{availability_mode}
		if defined($model->{availability_mode});

	# Der Mapper verarbeitet aus Kompatibilitaetsgruenden weiterhin die flache
	# Entity-Darstellung. Diese Projektion ist die einzige Rueckuebersetzung.
	my %legacy = (
		%configuration,
		operation       => $model->{operation},
		prefix          => $source->{prefix},
		format          => 'canonical',
		component       => $entity->{kind},
		node_id         => $entity->{node_id},
		object_id       => $entity->{id},
		component_key   => $entity->{component_key},
		unique_id       => $entity->{unique_id},
		name            => $entity->{name},
		preferred_entity_name => $entity->{logical_name},
		entity_category => $entity->{category},
		discovery_topic => $source->{topic},
		entity_key      => $source->{key},
		device          => ref($model->{device}) eq 'HASH' ? { %{ $model->{device} } } : {},
		_canonical_root => $entity->{root} ? 1 : 0,
		_canonical_layout => $source->{layout},
		_canonical_extensions => $model->{extensions} || {},
	);
	return (\%legacy, undef);
}

1;
