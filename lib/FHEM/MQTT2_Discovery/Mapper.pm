# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Mapper;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use MQTT2_Discovery::Helper qw(safe_name stable_suffix stable_unique);
use MQTT2_Discovery::Template ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper::Common qw(capability_set_name choice_values is_numeric);
use MQTT2_Discovery::Mapper::NameResolver ();
use MQTT2_Discovery::Mapper::Renderer ();
use MQTT2_Discovery::Mapper::Semantics ();


# Erzeugt die stabile Device-Identitaet aus Herstellerkennung und Verbindungsdaten.
sub _identity {
	my ($entity, $io_name) = @_;
	my $device = $entity->{device} || {};

	# Starke Device-Merkmale haben Vorrang. Topic/Entity-Daten sind nur der
	# stabile Fallback fuer Discovery-Payloads ohne Device-Block.
	if (ref($device->{identifiers}) eq 'ARRAY' && @{ $device->{identifiers} }) {
		return join('|', $io_name, 'id', sort map { ref($_) ? encode_json($_) : $_ } @{ $device->{identifiers} });
	}

	# Fehlen explizite Identifier, sind Transportverbindungen noch immer ein
	# geraeteweiter und damit staerkerer Schluessel als einzelne Entity-Topics.
	if (ref($device->{connections}) eq 'ARRAY' && @{ $device->{connections} }) {
		return join('|', $io_name, 'connection', sort map { ref($_) ? encode_json($_) : $_ } @{ $device->{connections} });
	}
	return join('|', $io_name, 'entity', grep { defined($_) && $_ ne '' }
		($entity->{unique_id}, $entity->{node_id}, $entity->{discovery_topic}));
}

# Normalisiert einen fachlichen Namen zu einem gueltigen FHEM-Readingnamen.
sub _reading_name {
	my ($entity) = @_;

	# Eine Root-Entity wiederholt im object_id lediglich den Devicenamen. Ohne
	# fachlicheren Binding-Namen beschreibt deshalb die Komponentenrolle das Reading.
	my $source = $entity->{_canonical_root}
		? $entity->{component}
		: ($entity->{object_id} || $entity->{name} || $entity->{component});
	my $fallback = safe_name($source, 'state');
	return _state_path_reading_name($entity->{state_topic}, $fallback);
}

# Extrahiert einen sicheren Readingnamen aus einem einfachen value_json-Pfad.
sub _simple_json_reading_name {
	my ($template) = @_;
	return undef if !defined($template) || ref($template) || $template eq '';
	my $compiled = MQTT2_Discovery::Template::compile($template);
	return undef if !$compiled->{ok};
	my $name = MQTT2_Discovery::Mapper::Renderer::simple_json_key($template, $compiled);
	return defined($name) && $name ne '' ? safe_name($name, '') : undef;
}

# Leitet aus Entity und Binding einen kollisionsarmen logischen Readingpfad ab.
sub _logical_reading_path {
	my ($entity) = @_;
	my $component = safe_name($entity->{component}, 'entity');
	my $fallback = _reading_name($entity);
	my $extensions = ref($entity->{_canonical_extensions}) eq 'HASH'
		? $entity->{_canonical_extensions} : {};
	my $entity_name = defined($entity->{preferred_entity_name})
			&& !ref($entity->{preferred_entity_name})
		? safe_name($entity->{preferred_entity_name}, $fallback) : undef;
	my $json_name = defined($entity->{preferred_reading_name})
			&& !ref($entity->{preferred_reading_name})
		? safe_name($entity->{preferred_reading_name}, $fallback)
		: !$extensions->{json_autocreate}
			? _simple_json_reading_name($entity->{value_template}) : undef;

	# Device-Discovery-Komponentenschluessel sind ueblicherweise mit ihrer
	# Plattform qualifiziert (z. B. sensor_battery). Der Plattformteil ist ein
	# Namensraum und wird nur benoetigt, wenn der eigentliche Name kollidiert.
	if (($entity->{_canonical_layout} || '') eq 'device'
			&& defined($entity->{component_key}) && !ref($entity->{component_key})) {
		my $key = safe_name($entity->{component_key}, $fallback);

		# Ein vom Adapter nach dem Quellprotokoll bestimmter Entity-Name ist das
		# sichtbare Blatt; der Komponentenschluessel bleibt Kollisionsreserve.
		if (defined($entity_name) && $entity_name ne '') {
			my $namespace = $key eq $entity_name
				? $component : $key =~ /_\Q$entity_name\E\z/
					? substr($key, 0, length($key) - length($entity_name) - 1)
					: undef;
			return [safe_name($namespace, $component), $entity_name]
				if defined($namespace);
			return [$component, $key, $entity_name];
		}

		# Wenn Komponentenschluessel und JSON-Blatt zusammenpassen, bleibt ihr
		# Plattformanteil nur als Namensraum erhalten und nicht im Reading selbst.
		if (defined($json_name) && $json_name ne ''
				&& ($key eq $json_name || $key =~ /_\Q$json_name\E\z/)) {
			my $namespace = $key eq $json_name
				? $component : substr($key, 0, length($key) - length($json_name) - 1);
			return [safe_name($namespace, $component), $json_name];
		}

		# Weicht der Komponentenschluessel vom JSON-Blatt ab, bleibt er als zweite
		# Kollisionsstufe erhalten; der sichtbare Name ist trotzdem zuerst das Blatt.
		return [$component, $key, $json_name]
			if defined($json_name) && $json_name ne '';
		my $prefix = $component . '_';
		my $leaf = index($key, $prefix) == 0 && length($key) > length($prefix)
			? substr($key, length($prefix)) : $key;
		return [$component, safe_name($leaf, $fallback)];
	}

	# Auch klassische Entity-Discovery behaelt technische IDs nur als Reserve,
	# wenn der Adapter einen ausdruecklichen logischen Entity-Namen geliefert hat.
	if (defined($entity_name) && $entity_name ne '') {
		return [$component, $entity_name] if $fallback eq $entity_name;
		if ($fallback =~ /\A(.+)_\Q$entity_name\E\z/) {
			return [$component, safe_name($1, $component), $entity_name];
		}
		return [$component, $fallback, $entity_name];
	}

	# Auch klassische Entity-Discovery darf den fachlichen JSON-Blattnamen
	# verwenden. Entity- und Komponentenname bleiben Reserven fuer Kollisionen.
	if (defined($json_name) && $json_name ne '') {
		return [$component, $json_name] if $fallback eq $json_name;
		return [$component, $fallback, $json_name];
	}

	# ESPHome und aehnliche Publisher stellen ihrer object_id haeufig die
	# normalisierte node_id voran. Der Geraeteteil bleibt Kollisionsreserve,
	# waehrend nur der fachliche Suffix als sichtbarer Readingname dient.
	if (defined($entity->{node_id}) && !ref($entity->{node_id})
			&& $entity->{node_id} ne '') {
		my $node = safe_name($entity->{node_id}, 'node');

		# Nur ein vollstaendiger Segmentprefix darf entfernt werden; bloss
		# aehnlich beginnende technische IDs bleiben unveraendert.
		if ($fallback =~ /\A\Q$node\E_(.+)\z/) {
			return [$component, $node, safe_name($1, $fallback)];
		}

	}

	return [$component, $fallback];
}

# Loest Namen direkt auf einem bereits exklusiv besessenen Mapping-Satz auf.
sub resolve_owned_mapping_names {
	return MQTT2_Discovery::Mapper::NameResolver::resolve_owned(@_);
}

# Leitet fuer eine Topicgruppe einen freien, vom Topicende aus lesbaren Readingnamen ab.
sub _device_automation_group_name {
	my ($topic, $used) = @_;
	my @parts = grep { $_ ne '' } split m{/}, $topic, -1;
	@parts = ('action') if !@parts;

	# Zuerst wird nur das fachliche Topicblatt verwendet; bei Kollisionen kommen
	# schrittweise die davorliegenden Topicsegmente als Namensraum hinzu.
	for my $depth (1 .. scalar(@parts)) {
		my @suffix = @parts[scalar(@parts) - $depth .. $#parts];
		my $candidate = safe_name(join('_', @suffix), 'action');
		return $candidate if !$used->{$candidate};
	}

	my $base = safe_name($parts[-1], 'action');
	my $suffix = stable_suffix($topic);
	my $candidate = "${base}_$suffix";
	my $counter = 2;

	# Der Zaehler ist nur der deterministische Fallback, falls selbst der Topic-Hash belegt ist.
	while ($used->{$candidate}) {
		$candidate = "${base}_${suffix}_" . $counter++;
	}

	return $candidate;
}

# Fasst kompatible Device-Automationen nach der deviceweiten Namensaufloesung pro Topic zusammen.
sub collapse_device_automation_readings {
	my ($mappings, $extra_reserved) = @_;
	return $mappings if ref($mappings) ne 'ARRAY' || !@$mappings;
	my %groups;

	# Jede Device-Automation steuert genau ihr primaeres Trigger-Reading zur Topicgruppe bei.
	for my $mapping_index (0 .. $#$mappings) {
		my $mapping = $mappings->[$mapping_index];
		next if ref($mapping) ne 'HASH'
			|| ref($mapping->{metadata}) ne 'HASH'
			|| ($mapping->{metadata}{component} || '') ne 'device_automation';
		my $entries = $mapping->{reading_lines};
		next if ref($entries) ne 'ARRAY' || !@$entries;
		my @entry_indexes = grep {
			ref($entries->[$_]) eq 'HASH' && ($entries->[$_]{kind} || '') eq 'reading'
		} 0 .. $#$entries;
		next if @entry_indexes != 1;
		my $entry_index = $entry_indexes[0];
		my $entry = $entries->[$entry_index];
		next if !defined($entry->{topic}) || ref($entry->{topic}) || $entry->{topic} eq '';
		push @{ $groups{ $entry->{topic} } }, {
			mapping_index => $mapping_index, entry_index => $entry_index, entry => $entry,
		};
	}

	my %collapsible;

	# Nur eine einheitliche Template- und Kontextsignatur darf dasselbe Reading befuellen.
	for my $topic (sort keys %groups) {
		my %signatures;

		for my $candidate (@{ $groups{$topic} }) {
			my $entry = $candidate->{entry};
			my $template = defined($entry->{template}) ? $entry->{template} : '';
			my $context = $template ne '' ? ($entry->{template_context} || '') : '';
			$signatures{join("\0", $template, $context)} = 1;
		}

		$collapsible{$topic} = 1 if keys(%signatures) == 1;
	}

	my (%remove, %used);
	%used = map { ($_ => 1) } keys %{ ref($extra_reserved) eq 'HASH' ? $extra_reserved : {} };

	# Die kompatiblen Quellpositionen werden vor der Namenssuche eindeutig markiert.
	for my $topic (sort keys %collapsible) {

		for my $candidate (@{ $groups{$topic} }) {
			$remove{"$candidate->{mapping_index}\0$candidate->{entry_index}"} = 1;
		}

	}

	# Namen nicht reduzierter Readings bleiben belegt und schuetzen vor neuen Kollisionen.
	for my $mapping_index (0 .. $#$mappings) {
		my $entries = ref($mappings->[$mapping_index]) eq 'HASH'
			? $mappings->[$mapping_index]{reading_lines} : undef;
		next if ref($entries) ne 'ARRAY' || !@$entries;

		for my $entry_index (0 .. $#$entries) {
			my $entry = $entries->[$entry_index];
			next if ref($entry) ne 'HASH'
				|| $remove{"$mapping_index\0$entry_index"};
			$used{ $entry->{name} } = 1
				if defined($entry->{name}) && !ref($entry->{name}) && $entry->{name} ne '';
		}
	}

	my %insert;

	# Pro kompatiblem Topic entsteht genau ein Eintrag mit allen bekannten Payloadvarianten.
	for my $topic (sort keys %collapsible) {
		my @candidates = @{ $groups{$topic} };
		my $name = _device_automation_group_name($topic, \%used);
		$used{$name} = 1;
		my @payloads = stable_unique(sort map { $_->{entry}{payload} }
			grep { defined($_->{entry}{payload}) } @candidates);
		my $match_all = grep { !defined($_->{entry}{payload}) } @candidates;
		my $template = $candidates[0]{entry}{template};
		my $context = $candidates[0]{entry}{template_context};
		my $group = {
			kind => 'device_automation_group', name => $name, semantic_name => $name,
			names => [$name], topic => $topic, payloads => \@payloads,
			match_all => $match_all ? 1 : 0,
			(defined($template) && $template ne '' ? (template => $template) : ()),
			(defined($template) && $template ne '' && defined($context)
				? (template_context => $context) : ()),
		};
		my $anchor = $candidates[0];
		$insert{"$anchor->{mapping_index}\0$anchor->{entry_index}"} = $group;
	}

	# Die Registry-Mappings bleiben einzeln erhalten; nur ihre abgeleitete Readingliste wird reduziert.
	for my $mapping_index (0 .. $#$mappings) {
		my $mapping = $mappings->[$mapping_index];
		next if ref($mapping) ne 'HASH' || ref($mapping->{reading_lines}) ne 'ARRAY';
		my @entries;

		for my $entry_index (0 .. $#{ $mapping->{reading_lines} }) {
			my $slot = "$mapping_index\0$entry_index";
			push @entries, $insert{$slot} if exists($insert{$slot});
			next if $remove{$slot};
			push @entries, $mapping->{reading_lines}[$entry_index];
		}

		$mapping->{reading_lines} = \@entries;
	}

	return $mappings;
}

# Bestimmt den Readingnamen bevorzugt aus dem JSON-Pfad des State-Bindings.
sub _state_path_reading_name {
	my ($topic, $fallback) = @_;
	return $fallback if !defined($topic) || ref($topic);
	return safe_name($1, $fallback) if $topic =~ m{(?:^|/)state/([^/]+)$};
	return $fallback;
}

# Uebernimmt einen vom Adapter normalisierten Set-Namen oder den logischen Fallback.
sub _command_set_name {
	my ($entity, $fallback) = @_;
	return safe_name($entity->{command_set_name}, $fallback)
		if defined($entity->{command_set_name}) && !ref($entity->{command_set_name});
	return $fallback;
}

# Rendert und gruppiert eine Liste abstrakter Mapping-Eintraege.
sub render_entries { return MQTT2_Discovery::Mapper::Renderer::render_entries(@_); }


# Erzeugt einen abstrakten Reading-Eintrag aus Topic, Template und Zielnamen.
sub _reading {
	my ($topic, $template, $name, $payload, $json_autocreate, $json_reading_name, $semantic_name) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	return { error => 'Trigger-Payload muss ein Skalar ohne Steuerzeichen sein' }
		if defined($payload) && (ref($payload) || $payload =~ /[\x00-\x1f]/);
	my $entry = {
		kind          => 'reading',
		topic         => $topic,
		template      => $template,
		name          => $name,
		semantic_name => defined($semantic_name) ? $semantic_name : $name,
		payload       => $payload,
	};

	# Templates werden bereits beim Mapping kompiliert, damit unsichere oder
	# nicht unterstuetzte Konstruktionen nie in eine FHEM-Zeile gelangen.
	if (defined($template) && $template ne '') {
		my $compiled = MQTT2_Discovery::Template::compile($template);
		return { error => $compiled->{error} } if !$compiled->{ok};
		my $json_key = MQTT2_Discovery::Mapper::Renderer::simple_json_key($template, $compiled);

		# Direkte value_json-Pfade koennen gemeinsam mit json2nameValue gerendert
		# werden; komplexere Templates bleiben sichere Runtime-Auswertungen.
		if (!defined($payload) && ($json_autocreate || defined($json_key))) {
			$entry->{kind} = $json_autocreate ? 'json_autocreate' : 'json_reading';
			$entry->{json_key} = defined($json_key) ? $json_key : $name;

			# Beim Autocreate darf ein vom Adapter ermittelter Rohname den generischen
			# Namen ersetzen, sofern er als FHEM-Reading sicher darstellbar ist.
			if ($json_autocreate) {
				my $raw_name = defined($json_reading_name) ? $json_reading_name : $json_key;
				$entry->{name} = $raw_name
					if defined($raw_name) && !ref($raw_name) && $raw_name =~ /^[A-Za-z0-9_.\/-]+$/;
			}
		}
	}
	return $entry;
}

# Erzeugt eine rollenbasierte Availability-Quelle mit stabilem internem Reading.
sub _availability_source {
	my ($source) = @_;
	return undef if ref($source) ne 'HASH';
	my $topic = $source->{topic};
	return { error => 'Availability-Topic fehlt' }
		if !defined($topic) || ref($topic) || $topic eq '';
	my $template = $source->{value_template};
	my $available = exists($source->{payload_available})
		? $source->{payload_available} : 'online';
	my $unavailable = exists($source->{payload_not_available})
		? $source->{payload_not_available} : 'offline';
	return { error => 'Availability-Werte muessen Skalare sein' }
		if ref($template) || ref($available) || ref($unavailable);

	# Templates werden vor dem Rendern validiert, damit untrusted Discovery-Text
	# nicht erst im laufenden MQTT-Empfang als Fehler sichtbar wird.
	if (defined($template) && $template ne '') {
		my $compiled = MQTT2_Discovery::Template::compile($template);
		return { error => $compiled->{error} } if !$compiled->{ok};
	}
	my $signature = JSON::PP->new->canonical(1)->encode({
		topic => $topic,
		(defined($template) ? (template => $template) : ()),
		available => "$available",
		unavailable => "$unavailable",
	});
	return {
		kind => 'availability', role => 'availability', name => 'availability',
		reserved_reading => 1,
		topic => $topic, template => $template,
		payload_available => "$available",
		payload_not_available => "$unavailable",
		source_reading => '.availability_' . stable_suffix($signature, 8),
	};
}

# Erzeugt einen direkten oder templatebasierten MQTT-Publish-Set-Eintrag.
sub _publish {
	my ($name, $spec, $topic, $template) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	$template = '{{ value }}' if !defined($template) || $template eq '';
	my $compiled = MQTT2_Discovery::Template::compile($template);
	return { error => $compiled->{error} } if !$compiled->{ok};
	my $entry = {
		kind => 'publish', name => $name, spec => $spec, topic => $topic, template => $template,
		identity => MQTT2_Discovery::Mapper::Renderer::identity_template($compiled) ? 1 : 0,
	};
	return $entry;
}

# Baut einen Set-Eintrag fuer eine begrenzte Auswahl mit Hin- und Rueckabbildung.
sub _choice {
	my ($name, $spec, $topic, $mapping, $template) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';

	# Ein Choice-Template transformiert den bereits gemappten Auswahlwert und
	# muss deshalb denselben sicheren Sprachumfang wie Publish verwenden.
	if (defined($template) && $template ne '') {
		my $compiled = MQTT2_Discovery::Template::compile($template);
		return { error => $compiled->{error} } if !$compiled->{ok};
	}
	my $entry = {
		kind => 'choice', name => $name, spec => $spec, topic => $topic,
		mapping => $mapping, template => $template,
	};
	return $entry;
}

# Erzeugt einen zustandslosen Button-Set-Eintrag fuer ein festes MQTT-Kommando.
sub _button {
	my ($name, $topic, $payload) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $entry = { kind => 'button', name => $name, spec => 'noArg', topic => $topic, payload => $payload };
	return $entry;
}

# Baut einen numerischen JSON-Publish-Eintrag fuer einen einzelnen Payloadschluessel.
sub _json_publish {
	my ($name, $spec, $topic, $key, $constants) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $entry = {
		kind => 'json', name => $name, spec => $spec, topic => $topic, key => $key,
		(ref($constants) eq 'HASH' ? (constants => { %$constants }) : ()),
	};
	return $entry;
}

# Baut einen JSON-Publish fuer eine begrenzte skalare Auswahl auf.
sub _json_choice {
	my ($name, $spec, $topic, $key, $mapping, $constants) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $entry = {
		kind => 'json_choice', name => $name, spec => $spec, topic => $topic,
		key => $key, mapping => $mapping,
		(ref($constants) eq 'HASH' ? (constants => { %$constants }) : ()),
	};
	return $entry;
}

# Waehlt anhand eines allgemeinen Command-Codecs zwischen skalarer und JSON-Ausgabe.
sub _choice_command {
	my ($name, $spec, $topic, $mapping, $template, $codec) = @_;
	return _choice($name, $spec, $topic, $mapping, $template) if !defined($codec);
	return { error => 'Command-Codec muss ein JSON-Objekt sein' } if ref($codec) ne 'HASH';
	return { error => 'Nicht unterstuetzter Choice-Command-Codec' }
		if ($codec->{format} || '') ne 'json' || ($codec->{value_type} || '') ne 'string'
			|| !defined($codec->{key}) || ref($codec->{key})
			|| $codec->{key} !~ /^[A-Za-z_][A-Za-z0-9_]*$/;
	return _json_choice($name, $spec, $topic, $codec->{key}, $mapping,
		$codec->{constants});
}

# Rendert numerische Commands gemaess dem normalisierten skalaren oder JSON-Codec.
sub _numeric_command {
	my ($name, $spec, $topic, $template, $codec) = @_;
	return _publish($name, $spec, $topic, $template) if !defined($codec);
	return { error => 'Command-Codec muss ein JSON-Objekt sein' } if ref($codec) ne 'HASH';
	return { error => 'Nicht unterstuetzter numerischer Command-Codec' }
		if ($codec->{format} || '') ne 'json' || ($codec->{value_type} || '') ne 'number'
			|| !defined($codec->{key}) || ref($codec->{key})
			|| $codec->{key} !~ /^[A-Za-z_][A-Za-z0-9_]*$/;
	return _json_publish($name, $spec, $topic, $codec->{key},
		$codec->{constants});
}

# Haengt einen gueltigen Eintrag an Reading- oder Set-Zielliste des Mappings an.
sub _add_entry {
	my ($list, $warnings, $entry, $context) = @_;
	return if !$entry;

	# Ein fehlerhafter Eintrag wird als lokale Mappingwarnung gesammelt, damit
	# andere sichere Funktionen derselben Entity weiterhin nutzbar bleiben.
	if ($entry->{error}) {
		push @$warnings, "$context: $entry->{error}";
		return;
	}
	push @$list, $entry;
}

# Verknuepft einen Set-Eintrag mit demselben logischen Namen wie sein Reading.
sub _linked_set {
	my ($entry, $semantic_name) = @_;
	return $entry if ref($entry) ne 'HASH' || $entry->{error};
	$entry->{semantic_name} = $semantic_name;
	return $entry;
}

# Ergaenzt zusaetzliche Parser-Signale um passende Readings oder Sets.
sub _add_supplemental_signals {
	my ($list, $warnings, $signals) = @_;
	return if ref($signals) ne 'ARRAY';

	# Supplemental Signals stammen aus Adapter-Erweiterungen, werden ab hier
	# aber wie normale formatunabhaengige Reading-Eintraege behandelt.
	for my $signal (@$signals) {
		next if ref($signal) ne 'HASH';
		my ($type, $topic, $name) = @{$signal}{qw(type topic name)};

		# Ohne stabiles Topic und Reading-Namen waere das Zusatzsignal weder
		# renderbar noch spaeter eindeutig als Discovery-eigen erkennbar.
		if (!defined($topic) || ref($topic) || $topic eq ''
				|| !defined($name) || ref($name) || $name eq '') {
			push @$warnings, 'Zusaetzliches Signal ohne gueltiges Topic oder Namen';
			next;
		}

		# Der deklarierte Signaltyp entscheidet, ob ein einzelner Payload, ein
		# flaches JSON oder eine nummerierte JSON-Sequenz gerendert wird.
		if (($type || '') eq 'payload') {
			_add_entry($list, $warnings, _reading($topic, undef, $name), "Zusatzsignal $name");
		} elsif (($type || '') eq 'template') {
			# Alternative Transportkanaele verwenden denselben sicheren Template-Compiler.
			_add_entry($list, $warnings, _reading($topic, $signal->{template}, $name), "Zusatzsignal $name");
		} elsif (($type || '') eq 'json_flatten') {
			_add_entry($list, $warnings, {
				kind => 'json_autocreate', topic => $topic, name => $name,
			}, "JSON-Zusatzsignal $name");
		} elsif (($type || '') eq 'json_sequence') {
			_add_entry($list, $warnings, {
				kind => 'json_sequence', topic => $topic, name => $name,
				key_prefix => $signal->{key_prefix}, parts => $signal->{parts},
				unwrap_single_property => $signal->{unwrap_single_property},
			}, "JSON-Sequenz $name");
		} else {
			push @$warnings, "Nicht unterstuetzter Zusatzsignaltyp: " . ($type // '');
		}
	}

}

# Validiert ein kanonisches Event und bildet es auf die gemeinsame Mapper-Ausgabe ab.
sub map_model {
	my (%args) = @_;
	my ($source_entity, $model_error) = MQTT2_Discovery::Model::to_entity($args{model});
	return {
		ok => 0,
		($model_error && $model_error =~ /Nicht unterstuetzte kanonische Geraeteklasse/
			? (unsupported => 1) : ()),
		error => $model_error,
	} if $model_error;

	# Erst nach erfolgreicher Modellvalidierung beginnt das eigentliche Mapping.
	return _map_canonical_entity(%args, entity => $source_entity);
}

# Erzeugt Identitaet, FHEM-Namen, Readings, Sets und Semantik fuer eine Entity.
sub _map_canonical_entity {
	my (%args) = @_;
	my $source_entity = $args{entity};
	return { ok => 0, error => 'Entity fehlt' } if ref($source_entity) ne 'HASH';
	my $entity = { %$source_entity };
	return { ok => 0, error => 'Delete-Ereignisse werden nicht gemappt' }
		if ($entity->{operation} || '') ne 'upsert';
	my $component = $entity->{component} || '';

	# Identitaet, Zielname und Reading-Pfad werden vor den Komponentenregeln
	# festgelegt, damit alle Zweige dieselben stabilen Namen verwenden.
	my $io_name = $args{io_name} || '';
	my $identity = _identity($entity, $io_name);
	my $device = $entity->{device} || {};
	my $base = $device->{name} || $entity->{node_id} || $entity->{unique_id} || $entity->{object_id} || $component;
	my $name_prefix = defined($args{name_prefix}) ? $args{name_prefix} : '';
	my $proposed_name = safe_name($name_prefix . $base, 'device');
	my $reading_path = _logical_reading_path($entity);
	my $reading_name = $reading_path->[-1];
	my $command_set_name = _command_set_name($entity, $reading_name);
	my $extensions = ref($entity->{_canonical_extensions}) eq 'HASH'
		? $entity->{_canonical_extensions} : {};
	my $json_autocreate = $extensions->{json_autocreate};
	my $json_reading_name = $json_autocreate ? $extensions->{json_reading_name} : undef;
	my $normalised_state_name = defined($entity->{state_reading_name})
		? $entity->{state_reading_name} : $extensions->{state_reading_name};
	my $state_reading_name = defined($normalised_state_name)
		&& !ref($normalised_state_name)
		&& $normalised_state_name =~ /^[A-Za-z0-9_.\/-]+$/
			? $normalised_state_name : $reading_name;
	my (@readings, @sets, @warnings, @set_state);

	# Jeder fehlende Number-Wert erhaelt unabhaengig seinen Home-Assistant-Default,
	# weil FHEMs Slider keine teilweise definierte Skala darstellen kann.
	if ($component eq 'number') {
		$entity->{min} = 0 if !defined($entity->{min});
		$entity->{max} = 100 if !defined($entity->{max});
		$entity->{step} = 1 if !defined($entity->{step});
	}

	my $state_entry = _reading($entity->{state_topic}, $entity->{value_template}, $state_reading_name,
		$component eq 'device_automation' ? $entity->{payload} : undef,
		$json_autocreate, $json_reading_name, $reading_name);

	# Device-Automationen duerfen in ihren Templates auf den strukturierten
	# Triggerwert zugreifen; normale State-Entities behalten ihren bisherigen Kontext.
	if (ref($state_entry) eq 'HASH' && !$state_entry->{error}
			&& $component eq 'device_automation' && defined($entity->{value_template})) {
		$state_entry->{template_context} = 'trigger';
	}
	_add_entry(\@readings, \@warnings, $state_entry, 'state');

	_add_supplemental_signals(\@readings, \@warnings, $extensions->{supplemental_signals});

	# JSON-Autocreate kann den sichtbaren Reading-Namen veraendern. Set-Befehle
	# muessen den danach tatsaechlich vorhandenen Namen verwenden.
	my %primary_read_name = MQTT2_Discovery::Mapper::Semantics::entry_read_names(\@readings);
	my $actual_reading_name = $primary_read_name{$reading_name};
	$command_set_name = $actual_reading_name if defined $actual_reading_name;

	# Die Komponente bestimmt, welche fachlichen Set- und Zusatz-Readings aus den
	# bereits normalisierten Topics und Payloads entstehen.
	if ($component eq 'binary_sensor') {
		# Das rohe Payload bleibt erhalten; normalisierte Payloadwerte sind Metadaten.
	} elsif ($component eq 'switch') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		_add_entry(\@sets, \@warnings,
			_choice_command($command_set_name, 'on,off', $entity->{command_topic}, \%mapping,
				undef, $entity->{command_codec}), 'switch');
		push @set_state, $command_set_name;
	} elsif ($component eq 'button') {
		_add_entry(\@sets, \@warnings,
			_button($command_set_name, $entity->{command_topic}, $entity->{payload_press} // 'PRESS'), 'button');
	} elsif ($component eq 'update') {
		my $install_name = _command_set_name($entity, 'install');

		# Ein Installationsbefehl ist nur mit explizitem skalarem Payload sicher
		# abbildbar; reine Status-Entities bleiben auch ohne Command gueltig.
		if (defined($entity->{command_topic})) {
			if (!defined($entity->{payload_install}) || ref($entity->{payload_install})
					|| $entity->{payload_install} eq ''
					|| $entity->{payload_install} =~ /[\x00-\x1f]/) {
				push @warnings, 'update: payload_install fehlt oder ist ungueltig';
			} else {
				_add_entry(\@sets, \@warnings,
					_button($install_name, $entity->{command_topic}, $entity->{payload_install}),
					'update install');
			}
		}
	} elsif ($component eq 'number') {
		my ($min, $max, $step) = map { $entity->{$_} } qw(min max step);

		# Nur ein positiver Schritt innerhalb eines aufsteigenden Zahlenbereichs
		# ergibt eine bedienbare und vorhersagbare Slider-Spezifikation.
		if (!defined($min) || !defined($max) || !defined($step) || $min !~ /^-?\d+(?:\.\d+)?$/
				|| $max !~ /^-?\d+(?:\.\d+)?$/ || $step !~ /^\d+(?:\.\d+)?$/ || $min >= $max || $step <= 0) {
			push @warnings, 'number: ungueltige min/max/step-Kombination';
		} else {
			_add_entry(\@sets, \@warnings,
				_numeric_command($actual_reading_name // $reading_name, "slider,$min,$step,$max",
					$entity->{command_topic}, $entity->{command_template}, $entity->{command_codec}), 'number');
		}
	} elsif ($component eq 'select') {

		# Eine Select-Entity ohne Optionen koennte keinen gueltigen FHEM-Befehl
		# anbieten und wird daher als unvollstaendig gemeldet.
		my ($tokens, $mapping) = choice_values($entity->{options});
		if (!@$tokens) {
			push @warnings, 'select: options fehlen';
		} else {
			_add_entry(\@sets, \@warnings,
				_choice_command($command_set_name, join(',', @$tokens), $entity->{command_topic}, $mapping,
					undef, $entity->{command_codec}),
				'select');
		}
	} elsif ($component eq 'climate') {
		my %climate_name;

		# Alle lesbaren Climate-Capabilities leiten ihren sichtbaren Namen einheitlich
		# aus dem State-Topic ab und merken ihn fuer den gekoppelten Setter vor.
		for my $spec (
			['action', 'action_topic', 'action_template'],
			['current_temperature', 'current_temperature_topic', 'current_temperature_template'],
			['current_humidity', 'current_humidity_topic', 'current_humidity_template'],
			['target_temperature', 'temperature_state_topic', 'temperature_state_template'],
			['target_temperature_high', 'temperature_high_state_topic', 'temperature_high_state_template'],
			['target_temperature_low', 'temperature_low_state_topic', 'temperature_low_state_template'],
			['mode', 'mode_state_topic', 'mode_state_template'],
			['fan_mode', 'fan_mode_state_topic', 'fan_mode_state_template'],
			['swing_mode', 'swing_mode_state_topic', 'swing_mode_state_template'],
			['swing_horizontal_mode', 'swing_horizontal_mode_state_topic', 'swing_horizontal_mode_state_template'],
			['preset_mode', 'preset_mode_state_topic', 'preset_mode_value_template'],
			['target_humidity', 'target_humidity_state_topic', 'target_humidity_state_template'],
		) {
			my ($suffix, $topic_key, $template_key) = @$spec;
			my $semantic_name = "${reading_name}_$suffix";
			my $visible_name = _state_path_reading_name(
				$entity->{$topic_key}, $semantic_name,
			);
			my $reading_entry = _reading($entity->{$topic_key},
				defined($entity->{$template_key}) ? $entity->{$template_key} : $entity->{value_template},
				$visible_name, undef, undef, undef, $semantic_name);

			# Nur ein tatsaechlich erzeugtes Reading darf den Namen seines gekoppelten
			# Setters vorgeben; command-only Capabilities behalten den kurzen Fallback.
			if (ref($reading_entry) eq 'HASH' && !$reading_entry->{error}) {
				$climate_name{$suffix} = $visible_name;
			}

			_add_entry(\@readings, \@warnings, $reading_entry,
				"climate $suffix state");
		}

		my $min_temp = is_numeric($entity->{min_temp}) ? $entity->{min_temp} : 7;
		my $max_temp = is_numeric($entity->{max_temp}) ? $entity->{max_temp} : 35;
		my $temp_step = is_numeric($entity->{temp_step}) ? $entity->{temp_step} : 1;

		# Ungueltige Temperaturgrenzen sperren nur die Zieltemperatur-Sets; die
		# lesbaren Climate-Werte und anderen Befehle bleiben erhalten.
		if ($min_temp >= $max_temp || $temp_step <= 0) {
			push @warnings, 'climate: ungueltige min_temp/max_temp/temp_step-Kombination';
		} else {

			# Die drei Temperaturbefehle verwenden denselben Namen wie ihr jeweiliges Reading.
			for my $spec (
				['target_temperature', 'temperature_command_topic', 'temperature_command_template'],
				['target_temperature_high', 'temperature_high_command_topic', 'temperature_high_command_template'],
				['target_temperature_low', 'temperature_low_command_topic', 'temperature_low_command_template'],
			) {
				my ($suffix, $topic_key, $template_key) = @$spec;
				my $semantic_name = "${reading_name}_$suffix";
				my $set_name = $climate_name{$suffix} // safe_name($suffix, 'set');
				_add_entry(\@sets, \@warnings,
					_linked_set(
						_publish($set_name, "slider,$min_temp,$temp_step,$max_temp",
							$entity->{$topic_key}, $entity->{$template_key}),
						$semantic_name,
					),
					"climate $suffix command");
			}

		}

		my $min_humidity = is_numeric($entity->{min_humidity}) ? $entity->{min_humidity} : 30;
		my $max_humidity = is_numeric($entity->{max_humidity}) ? $entity->{max_humidity} : 99;

		# Auch der Feuchteslider benoetigt einen echten aufsteigenden Wertebereich;
		# bei fehlerhaften Metadaten wird nur diese Capability ausgelassen.
		if ($min_humidity >= $max_humidity) {
			push @warnings, 'climate: ungueltige min_humidity/max_humidity-Kombination';
		} else {
			my $semantic_name = "${reading_name}_target_humidity";
			my $set_name = $climate_name{target_humidity} // 'target_humidity';
			_add_entry(\@sets, \@warnings,
				_linked_set(
					_publish($set_name, "slider,$min_humidity,1,$max_humidity",
						$entity->{target_humidity_command_topic}, $entity->{target_humidity_command_template}),
					$semantic_name,
				),
				'climate target_humidity command');
		}

		# Aufzaehlungs-Capabilities koppeln Reading- und Set-Namen auf dieselbe Weise.
		for my $spec (
			['mode', 'modes', 'mode_command_topic', 'mode_command_template'],
			['fan_mode', 'fan_modes', 'fan_mode_command_topic', 'fan_mode_command_template'],
			['swing_mode', 'swing_modes', 'swing_mode_command_topic', 'swing_mode_command_template'],
			['swing_horizontal_mode', 'swing_horizontal_modes', 'swing_horizontal_mode_command_topic', 'swing_horizontal_mode_command_template'],
			['preset_mode', 'preset_modes', 'preset_mode_command_topic', 'preset_mode_command_template'],
		) {
			my ($suffix, $values_key, $topic_key, $template_key) = @$spec;
			next if !defined($entity->{$topic_key});
			my ($tokens, $mapping) = choice_values($entity->{$values_key});
			my $semantic_name = "${reading_name}_$suffix";
			my $set_name = $climate_name{$suffix} // safe_name($suffix, 'set');

			# Ein vorhandenes Command-Topic ohne Auswahlwerte ist nicht sicher
			# bedienbar, weil der Mapper keine erlaubten Payloads erfinden darf.
			if (!@$tokens) {
				push @warnings, "climate $suffix: Optionen fehlen";
				next;
			}
			_add_entry(\@sets, \@warnings,
				_linked_set(
					_choice($set_name, join(',', @$tokens), $entity->{$topic_key}, $mapping,
						$entity->{$template_key}),
					$semantic_name,
				),
				"climate $suffix command");
		}

		# Power ist bei Climate optional und wird nur als eigener on/off-Befehl
		# angelegt, wenn das Discovery-Payload dafuer ein Topic bereitstellt.
		if (defined($entity->{power_command_topic})) {
			my %mapping = (
				on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'),
			);
			my $semantic_name = "${reading_name}_power";
			my $set_name = $climate_name{power} // 'power';
			_add_entry(\@sets, \@warnings,
				_linked_set(
					_choice($set_name, 'on,off', $entity->{power_command_topic}, \%mapping,
						$entity->{power_command_template}),
					$semantic_name,
				),
				'climate power command');
		}
	} elsif ($component eq 'media_player') {
		my $volume_semantic_name = "${reading_name}_volume";
		my $volume_reading_name = defined($entity->{volume_reading_name})
			&& !ref($entity->{volume_reading_name})
			? safe_name($entity->{volume_reading_name}, 'volume') : 'volume';
		my $volume_set_name = defined($entity->{volume_set_name})
			&& !ref($entity->{volume_set_name})
			? safe_name($entity->{volume_set_name}, $volume_reading_name) : $volume_reading_name;
		_add_entry(\@readings, \@warnings,
			_reading($entity->{volume_state_topic}, $entity->{volume_value_template},
				$volume_reading_name, undef, undef, undef, $volume_semantic_name),
			'media_player volume state');
		_add_entry(\@sets, \@warnings,
			_linked_set(
				_numeric_command($volume_set_name, 'slider,0,1,100',
					$entity->{volume_command_topic}, $entity->{volume_command_template},
					$entity->{volume_command_codec}),
				$volume_semantic_name,
			),
			'media_player volume command');
		my $mute_semantic_name = "${reading_name}_mute";
		my $mute_reading_name = defined($entity->{mute_reading_name})
			&& !ref($entity->{mute_reading_name})
			? safe_name($entity->{mute_reading_name}, 'mute') : 'mute';
		my $mute_set_name = defined($entity->{mute_set_name})
			&& !ref($entity->{mute_set_name})
			? safe_name($entity->{mute_set_name}, $mute_reading_name) : $mute_reading_name;
		_add_entry(\@readings, \@warnings,
			_reading($entity->{mute_state_topic}, $entity->{mute_value_template},
				$mute_reading_name, undef, undef, undef, $mute_semantic_name),
			'media_player mute state');

		# Mute und Unmute bleiben eine sichtbare binaere Auswahl, obwohl das
		# Zielprotokoll dafuer zwei unterschiedliche JSON-Kommandos verwendet.
		if (defined($entity->{payload_mute}) && !ref($entity->{payload_mute})
				&& defined($entity->{payload_unmute}) && !ref($entity->{payload_unmute})) {
			my %mute_mapping = (
				on => $entity->{payload_mute}, off => $entity->{payload_unmute},
			);
			_add_entry(\@sets, \@warnings,
				_linked_set(
					_choice($mute_set_name, 'on,off', $entity->{mute_command_topic},
						\%mute_mapping),
					$mute_semantic_name,
				),
				'media_player mute command');
		}

		# Zustandslose Transportaktionen werden nur fuer explizit vom Adapter
		# gelieferte Payloads angeboten; der Mapper erfindet keine Protokollwerte.
		for my $command (qw(play pause stop toggle next previous)) {
			my $payload_key = "payload_$command";
			my $payload = $entity->{$payload_key};
			next if !defined($payload) || ref($payload) || $payload eq '';
			_add_entry(\@sets, \@warnings,
				_button($command, $entity->{command_topic}, $payload),
				"media_player $command command");
		}

	} elsif ($component eq 'text') {
		_add_entry(\@sets, \@warnings, _publish($actual_reading_name // $reading_name, '', $entity->{command_topic}, $entity->{command_template}), 'text');
	} elsif ($component eq 'light') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		my $state_set_name = $actual_reading_name // "${reading_name}_state";
		_add_entry(\@sets, \@warnings,
			_choice_command($state_set_name, 'on,off', $entity->{command_topic}, \%mapping,
				undef, $entity->{command_codec}),
			'light state');
		my $brightness_topic = $entity->{brightness_command_topic};
		my $brightness_scale = defined($entity->{brightness_scale}) && !ref($entity->{brightness_scale})
			&& $entity->{brightness_scale} =~ /^\d+(?:\.\d+)?$/ && $entity->{brightness_scale} > 0
			? 0 + $entity->{brightness_scale} : 255;
		my $brightness_reading_name = defined($entity->{brightness_reading_name})
				&& !ref($entity->{brightness_reading_name})
			? safe_name($entity->{brightness_reading_name}, "${reading_name}_brightness")
			: "${reading_name}_brightness";
		my $brightness_set_name = defined($entity->{brightness_set_name})
				&& !ref($entity->{brightness_set_name})
			? safe_name($entity->{brightness_set_name}, $brightness_reading_name)
			: $brightness_reading_name;

		# Getrennte Bindings und ihr Codec entscheiden allein ueber Topic und
		# Payloadformat; der Mapper kennt das Quellprotokoll nicht.
		_add_entry(\@sets, \@warnings,
			_numeric_command($brightness_set_name, "slider,0,1,$brightness_scale",
				$brightness_topic, '{{ value }}', $entity->{brightness_command_codec}),
			'light brightness') if defined $brightness_topic;
		_add_entry(\@readings, \@warnings,
			_reading($entity->{brightness_state_topic}, $entity->{brightness_value_template},
				$brightness_reading_name, undef, $json_autocreate, undef, $brightness_reading_name),
			'light brightness state');
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_colorTemp", 'slider,' . ($entity->{min_mireds} // 153)
				. ',1,' . ($entity->{max_mireds} // 500), $entity->{color_temp_command_topic}, '{{ value }}'),
			'light color temperature');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{color_temp_state_topic}, $entity->{color_temp_value_template}, "${reading_name}_colorTemp",
				undef, $json_autocreate),
			'light color temperature state');
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_color", '', $entity->{rgb_command_topic}, '{{ value }}'), 'light RGB color');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{rgb_state_topic}, $entity->{rgb_value_template}, "${reading_name}_color",
				undef, $json_autocreate), 'light RGB state');

		# Effekte werden nur angeboten, wenn Discovery eine konkrete Liste liefert;
		# ihre sicheren Tokens werden auf die normalisierten Zielwerte abgebildet.
		if (ref($entity->{effect_list}) eq 'ARRAY' && @{ $entity->{effect_list} }) {
			my (%effect_mapping, @effect_tokens);

			for my $index (0 .. $#{ $entity->{effect_list} }) {
				my $effect = $entity->{effect_list}[$index];
				next if !defined($effect) || ref($effect);
				my $token = safe_name(lc($effect), 'effect');
				$token .= '_' . stable_suffix($effect, 4) if exists $effect_mapping{$token};
				$effect_mapping{$token} = $index;
				push @effect_tokens, $token;
			}

			_add_entry(\@sets, \@warnings,
				_choice("${reading_name}_effect", join(',', @effect_tokens), $entity->{effect_command_topic}, \%effect_mapping),
				'light effect') if @effect_tokens;
		}
		_add_entry(\@readings, \@warnings,
			_reading($entity->{effect_state_topic}, $entity->{effect_value_template}, "${reading_name}_effect",
				undef, $json_autocreate), 'light effect state');
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_white", 'slider,0,1,100', $entity->{white_command_topic}, '{{ value }}'), 'light white');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{white_state_topic}, $entity->{white_value_template}, "${reading_name}_white",
				undef, $json_autocreate), 'light white state');
	} elsif ($component eq 'cover') {
		my %mapping = (
			open => ($entity->{payload_open} // 'OPEN'), close => ($entity->{payload_close} // 'CLOSE'),
			stop => ($entity->{payload_stop} // 'STOP'),
		);
		_add_entry(\@sets, \@warnings, _choice("${reading_name}_action", 'open,close,stop', $entity->{command_topic}, \%mapping), 'cover');
		_add_entry(\@sets, \@warnings, _publish("${reading_name}_position", 'slider,0,1,100', $entity->{position_command_topic}, '{{ value }}'), 'cover position');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{position_topic}, $entity->{position_template}, "${reading_name}_position",
				undef, $json_autocreate), 'cover position state');

		# Tilt ist eine optionale Cover-Funktion und darf ohne Command-Topic weder
		# Slider noch zugehoeriges Status-Reading erzeugen.
		if (defined($entity->{tilt_command_topic})) {
			my $tilt_min = defined($entity->{tilt_min}) && $entity->{tilt_min} =~ /^-?\d+$/ ? $entity->{tilt_min} : 0;
			my $tilt_max = defined($entity->{tilt_max}) && $entity->{tilt_max} =~ /^-?\d+$/ ? $entity->{tilt_max} : 100;
			_add_entry(\@sets, \@warnings,
				_publish("${reading_name}_tilt", "slider,$tilt_min,1,$tilt_max", $entity->{tilt_command_topic}, '{{ value }}'),
				'cover tilt');
			_add_entry(\@readings, \@warnings,
				_reading($entity->{tilt_status_topic}, $entity->{tilt_status_template}, "${reading_name}_tilt",
					undef, $json_autocreate),
				'cover tilt state');
		}
	} elsif ($component eq 'fan') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		_add_entry(\@sets, \@warnings, _choice($actual_reading_name // "${reading_name}_state", 'on,off', $entity->{command_topic}, \%mapping), 'fan');
		my $percentage_min = defined($entity->{percentage_min}) && $entity->{percentage_min} =~ /^\d+$/ ? $entity->{percentage_min} : 0;
		my $percentage_max = defined($entity->{percentage_max}) && $entity->{percentage_max} =~ /^\d+$/ ? $entity->{percentage_max} : 100;
		my $percentage_step = defined($entity->{percentage_step}) && $entity->{percentage_step} =~ /^\d+$/ ? $entity->{percentage_step} : 1;
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_percentage", "slider,$percentage_min,$percentage_step,$percentage_max",
				$entity->{percentage_command_topic}, '{{ value }}'), 'fan percentage');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{percentage_state_topic}, $entity->{percentage_value_template}, "${reading_name}_percentage",
				undef, $json_autocreate), 'fan percentage state');
	} elsif ($component eq 'lock') {
		my %mapping = (lock => ($entity->{payload_lock} // 'LOCK'), unlock => ($entity->{payload_unlock} // 'UNLOCK'));
		_add_entry(\@sets, \@warnings, _choice($actual_reading_name // $reading_name, 'lock,unlock', $entity->{command_topic}, \%mapping), 'lock');
	}

	my @availability_entries;

	# Availability bleibt eine eigene Rolle, damit sie weder Device-Topic noch
	# fachliche State-Readings oder semantische Hauptwerte beeinflusst.
	for my $source (@{ $entity->{availability} || [] }) {
		my $entry = _availability_source($source);
		if ($entry && $entry->{error}) {
			push @warnings, 'availability: ' . $entry->{error};
			next;
		}
		push @availability_entries, $entry if $entry;
	}

	if (@availability_entries) {
		my @sources = sort stable_unique(map { $_->{source_reading} }
			@availability_entries);
		my $mode = $entity->{availability_mode} || 'latest';
		my $policy_signature = join("\0", $mode, @sources);
		my $policy = {
			reading => '.availability_policy_' . stable_suffix($policy_signature, 8),
			mode => $mode,
			sources => \@sources,
		};

		for my $entry (@availability_entries) {
			$entry->{policy} = $policy;
			_add_entry(\@readings, \@warnings, $entry, 'availability');
		}

	}

	# Retain wird deklarativ gespeichert und erst beim abschliessenden Rendern
	# an das Topic angehaengt.
	if (MQTT2_Discovery::Mapper::Renderer::retain_enabled($entity->{retain})) {
		for my $entry (@sets) {
			$entry->{retain} = 1;
		}

	}

	return { ok => 0, error => "$component: keine sicher abbildbare Funktion" }
		if !@readings && !@sets;
	my $semantic_entity = MQTT2_Discovery::Mapper::Semantics::from_mapping(
		$entity, $reading_name, \@readings, \@sets,
	);
	return {
		ok              => 1,
		entity_key      => $entity->{entity_key},
		discovery_topic => $entity->{discovery_topic},
		source_layout   => $entity->{_canonical_layout},
		identity        => $identity,
		strong_identity => (ref($device->{identifiers}) eq 'ARRAY' && @{ $device->{identifiers} })
			|| (ref($device->{connections}) eq 'ARRAY' && @{ $device->{connections} }) ? 1 : 0,
		proposed_name   => $proposed_name,
		reading_name    => $reading_name,
		reading_path    => $reading_path,
		reading_lines   => [ stable_unique(@readings) ],
		set_lines       => [ stable_unique(@sets) ],
		set_state_list  => [ stable_unique(@set_state) ],
		device_topic    => defined($extensions->{device_topic}) && !ref($extensions->{device_topic})
			? $extensions->{device_topic} : undef,
		semantic_entity => $semantic_entity,
		warnings        => \@warnings,
		metadata        => {
			component => $component,
			unit       => $entity->{unit_of_measurement},
			device_class => $entity->{device_class},
			state_class => $entity->{state_class},
			entity_category => $entity->{entity_category},
			name       => $entity->{name},
			model      => $device->{model},
			manufacturer => $device->{manufacturer},
			suggested_area => $device->{suggested_area},
		},
	};
}

1;
