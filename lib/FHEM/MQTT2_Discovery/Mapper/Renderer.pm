# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::Renderer;

use strict;
use warnings;
use JSON::PP ();
use MQTT2_Discovery::Template ();


# Alle Renderer behandeln Discovery-Daten als untrusted Input. Escaping und
# Validierung passieren deshalb hier zentral, bevor FHEM-Attributtext entsteht.
sub _regex_literal {
	my ($value) = @_;
	$value =~ s{([\\.^$|()\[\]{}*+?])}{\\$1}g;
	return $value;
}

# Uebersetzt gueltige MQTT-Filtersegmente in einen sicheren FHEM-Regulaerausdruck.
sub _mqtt_filter_regex {
	my ($filter) = @_;
	my @parts = split m{/}, $filter, -1;
	my $regex = '';

	# MQTT-Wildcards besitzen nur als vollstaendige Topicsegmente Bedeutung;
	# abweichende Plus- oder Rautezeichen bleiben sichere Literale.
	for my $index (0 .. $#parts) {
		my $part = $parts[$index];

		# Die abschliessende Mehrsegment-Wildcard umfasst auch das Elterntopic
		# ohne nachfolgenden Slash, wie es die MQTT-Subscription definiert.
		if ($part eq '#' && $index == $#parts) {
			$regex .= $index == 0 ? '.*' : '(?:/.*)?';
			last;
		}

		$regex .= '/' if $index > 0;
		$regex .= $part eq '+' ? '[^/]*' : _regex_literal($part);
	}

	return $regex;
}

# Maskiert einen MQTT-Topicfilter zu einem sicheren FHEM-Regulaerausdruck.
sub _regex {
	my ($topic, $device_topic, $payload) = @_;
	my $regex;

	# Nur echte Topic-Prefixe werden durch $DEVICETOPIC ersetzt; aehnlich
	# beginnende Segmente duerfen nicht versehentlich zusammenfallen.
	if (defined($device_topic) && $device_topic ne ''
			&& ($topic eq $device_topic || index($topic, "$device_topic/") == 0)) {
		$regex = '$DEVICETOPIC'
			. _mqtt_filter_regex(substr($topic, length($device_topic)));
	} else {
		$regex = _mqtt_filter_regex($topic);
	}
	return $regex . ':' . (defined($payload) && !ref($payload)
		? _regex_literal($payload) . '$' : '.*');
}

# Ersetzt einen gemeinsamen devicetopic-Stamm durch die FHEM-Variable $DEVICETOPIC.
sub _topic {
	my ($topic, $device_topic) = @_;
	return $topic if !defined($device_topic) || $device_topic eq '';
	return '$DEVICETOPIC' if $topic eq $device_topic;
	return '$DEVICETOPIC' . substr($topic, length($device_topic))
		if index($topic, "$device_topic/") == 0;
	return $topic;
}

# Liefert ein validiertes Topic ohne zusaetzliche FHEM- oder Regex-Syntax.
sub _plain_topic {
	my ($topic) = @_;
	return 0 if !defined($topic) || $topic eq '' || $topic =~ /[\s\x00-\x1f{}]/;
	return 0 if $topic =~ /\$/ && $topic !~ /^\$DEVICETOPIC(?:\/[A-Za-z0-9_.:+-]+)*$/;
	return 1;
}

# Bereitet ein Topic fuer eingebettete Perl-Ausdruecke in readingList oder setList auf.
sub _inline_topic {
	my ($topic) = @_;
	return defined($topic) && ($topic =~ /^\$DEVICETOPIC(?:\/[A-Za-z0-9_.:+-]+)*$/
		|| $topic =~ m{^[A-Za-z0-9_.:+/-]+$});
}

# Quotiert einen skalaren Wert als sicheres einfaches Perl-Stringliteral.
sub _perl_quote {
	my ($value) = @_;
	return undef if !defined($value) || ref($value) || $value =~ /[\x00-\x1f]/;

	# Literale werden fuer einfach quotierten generierten Perl-Text maskiert.
	$value =~ s/\\/\\\\/g;
	$value =~ s/'/\\'/g;
	return "'$value'";
}

# Quotiert Template-Text fuer die kontrollierten Runtime-Wrapper ohne Codeinjektion.
sub _perl_template_quote {
	my ($value) = @_;
	return undef if !defined($value) || ref($value);

	# Doppelt quotierte Runtime-Argumente duerfen weder Variablen interpolieren
	# noch Steuerzeichen direkt in den Attributwert tragen.
	$value =~ s/\\/\\\\/g;
	$value =~ s/"/\\"/g;
	$value =~ s/\$/\\\$/g;
	$value =~ s/\@/\\\@/g;
	$value =~ s/([\x00-\x1f])/sprintf('\\x{%02x}', ord($1))/ge;
	return qq{"$value"};
}

# Rendert eine skalare Hash-Abbildung deterministisch als sicheres Perl-Literal.
sub _perl_hash_literal {
	my ($mapping) = @_;
	return undef if ref($mapping) ne 'HASH';
	my @pairs;

	for my $key (sort keys %$mapping) {
		my $quoted_key = _perl_template_quote($key);
		my $quoted_value = _perl_template_quote($mapping->{$key});
		return undef if !defined($quoted_key) || !defined($quoted_value);
		push @pairs, "$quoted_key => $quoted_value";
	}

	return '{' . join(', ', @pairs) . '}';
}

# Kombiniert FHEMs bestehendes jsonMap erst zur Laufzeit mit sicheren Umbenennungen.
sub _json_map_argument {
	my ($renames) = @_;
	return q{$JSONMAP} if ref($renames) ne 'HASH' || !keys %$renames;
	my $literal = _perl_hash_literal($renames);
	return q{$JSONMAP} if !defined($literal);
	return 'MQTT2_DISCOVERY_runtimeJSONMap($NAME, ' . $literal . ')';
}

# Erkennt Templates, die den Eingangswert ohne inhaltliche Aenderung weiterreichen.
sub identity_template {
	my ($compiled) = @_;
	my $ast = $compiled->{ast};
	return ref($ast) eq 'HASH' && ($ast->{type} || '') eq 'path'
		&& ($ast->{root} || '') eq 'value' && ref($ast->{path}) eq 'ARRAY'
		&& !@{ $ast->{path} };
}

# Extrahiert einen direkt lesbaren einzelnen JSON-Schluessel aus einem Template.
sub simple_json_key {
	my ($template, $compiled) = @_;
	return MQTT2_Discovery::Template::simple_json_key($template, $compiled);
}

# Normalisiert boolesche und numerische Retain-Angaben auf einen eindeutigen Wahrheitswert.
sub retain_enabled {
	my ($value) = @_;
	return 0 if !defined($value);
	return 0 if ref($value) && ref($value) ne 'JSON::PP::Boolean';
	my $normalised = lc("$value");
	return $normalised eq '1' || $normalised eq 'true';
}

# Liefert das validierte Zieltopic eines abstrakten Set-Eintrags.
sub _command_topic {
	my ($topic, $retain) = @_;
	return $topic . (retain_enabled($retain) ? ':r' : '');
}

# Rendert komplexe Reading-Templates ueber den sicheren Runtime-Wrapper.
sub _render_runtime_reading {
	my ($entry, $device_topic) = @_;
	my $regex = _regex($entry->{topic}, $device_topic, $entry->{payload});
	my $template = _perl_template_quote($entry->{template});
	my $reading = _perl_quote($entry->{name});
	return undef if !defined($template) || !defined($reading);
	my $function = ($entry->{template_context} || '') eq 'trigger'
		? 'MQTT2_DISCOVERY_runtimeTriggerReading' : 'MQTT2_DISCOVERY_runtimeReading';
	return $regex . ' { ' . $function . '(' . $template
		. ', $EVENT, ' . $reading . ') }';
}

# Rendert eine json2nameValue-Zeile, die mehrere Sensorreadings automatisch erzeugt.
sub _render_json_autocreate {
	my ($entry, $device_topic, $renames) = @_;
	my $regex = _regex($entry->{topic}, $device_topic, undef);
	return $regex . q! { json2nameValue($EVENT,'',!
		. _json_map_argument($renames) . ') }';
}

# Rendert mehrere JSON-Pfade eines Topics in definierter Auswertungsreihenfolge.
sub _render_json_sequence {
	my ($entry, $device_topic, $renames) = @_;
	my $topic = $entry->{topic};
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $key_prefix = $entry->{key_prefix};
	my $parts = $entry->{parts};
	return undef if !defined($key_prefix) || ref($key_prefix) || $key_prefix !~ /^[A-Za-z0-9_]+$/
		|| ref($parts) ne 'ARRAY' || !@$parts
		|| grep { !defined($_) || ref($_) || $_ !~ /^[A-Za-z0-9_-]+$/ } @$parts;
	my $part_pattern = '(?:' . join('|', map { _regex_literal("$_") } @$parts) . ')';
	my $regex = _regex($topic, $device_topic, undef);
	$regex =~ s/:\.\*$//;
	my $payload_key = _regex_literal($key_prefix) . $part_pattern;
	my $json_map = _json_map_argument($renames);
	return $regex . $part_pattern . ':.* { $EVENT =~ m,^..' . $payload_key
		. q!..(.+).$, ?  json2nameValue($1,'',! . $json_map
		. q!) : json2nameValue($EVENT,'',! . $json_map . ') }';
}

# Erzeugt einen exakten Filter aus den finalen Namen expliziter JSON-Readings.
sub _json_reading_filter {
	my ($entries) = @_;
	my %names;

	for my $entry (@{ $entries || [] }) {
		return undef if ref($entry) ne 'HASH';
		my $name = $entry->{name};
		return undef if !defined($name) || ref($name) || $name eq '';
		$names{$name} = 1;
	}

	return undef if !keys %names;
	my $pattern = '^(?:' . join('|', map { _regex_literal($_) } sort keys %names) . ')$';
	return _perl_quote($pattern);
}

# Fasst kompatible JSON-Readings eines Topics zu einer einzigen FHEM-Zeile zusammen.
sub _render_json_group {
	my ($entries, $device_topic, $extra_mapping) = @_;
	my @entries = @{ $entries || [] };
	return undef if !@entries;
	my $regex = _regex($entries[0]{topic}, $device_topic, undef);
	my $filter = _json_reading_filter(\@entries);
	return undef if !defined($filter);
	my %mapping = ref($extra_mapping) eq 'HASH' ? %$extra_mapping : ();
	$mapping{ $_->{json_key} } = $_->{name} for @entries;
	my @pairs = map { _perl_quote($_) . ' => ' . _perl_quote($mapping{$_}) }
		grep { $_ ne $mapping{$_} } sort keys %mapping;
	my $map = @pairs ? '{' . join(', ', @pairs) . '}' : '{}';
	return $regex . ' { json2nameValue($EVENT, \'\', ' . $map . ', ' . $filter . ') }';
}

# Uebersetzt genau einen abstrakten Reading- oder Set-Eintrag in FHEM-Attributsyntax.
sub render_entry {
	my ($entry, $device_topic) = @_;
	return $entry->{line} if ref($entry) ne 'HASH' || !$entry->{kind};
	my $topic = _topic($entry->{topic}, $device_topic);

	# Reading-Arten werden als regulaere readingList-Zeilen gerendert.
	if ($entry->{kind} eq 'reading') {
		my $regex = _regex($entry->{topic}, $device_topic, $entry->{payload});
		return "$regex $entry->{name}" if !defined($entry->{template}) || $entry->{template} eq '';
		return _render_runtime_reading($entry, $device_topic);
	}

	# Ein einzelnes benanntes JSON-Feld nutzt denselben Gruppenrenderer wie
	# spaeter zusammengefasste Felder und behaelt dadurch identische Syntax.
	if ($entry->{kind} eq 'json_reading') {
		return _render_json_group([$entry], $device_topic);
	}

	# Autocreate soll alle JSON-Blattwerte eines Topics durch json2nameValue
	# erzeugen und benoetigt deshalb keine feste Feldabbildung.
	if ($entry->{kind} eq 'json_autocreate') {
		return _render_json_autocreate($entry, $device_topic);
	}

	# Sequenz-Topics wie INFO1..INFO3 werden durch einen gemeinsamen regulierten
	# Renderer in dieselbe Reading-Gruppe entpackt.
	if ($entry->{kind} eq 'json_sequence') {
		return _render_json_sequence($entry, $device_topic);
	}

	my $head = $entry->{name}
		. (defined($entry->{spec}) && $entry->{spec} ne '' ? ":$entry->{spec}" : '');
	$topic = _command_topic($topic, $entry->{retain});
	my $runtime_topic = _command_topic($entry->{topic}, $entry->{retain});

	# Publish kann nur bei einem unveraenderten Identitaetstemplate direkt von
	# MQTT2_DEVICE ausgefuehrt werden; Transformationen brauchen die Runtime.
	if ($entry->{kind} eq 'publish') {
		# Ohne $EVENT/$EVTPART haengt MQTT2_DEVICE alle Set-Argumente selbst an und erhaelt auch Leerzeichen.
		return "$head $topic" if $entry->{identity} && _plain_topic($topic);
		return $head . ' { MQTT2_DISCOVERY_runtimeTemplatePublish('
			. _perl_template_quote($runtime_topic) . ', '
			. _perl_template_quote($entry->{template}) . ', $EVENT) }';
	}

	# Choice-Eintraege waehlen je nach Mapping-Komplexitaet die kuerzeste sichere
	# setList-Darstellung und fallen andernfalls auf den Runtime-Wrapper zurueck.
	if ($entry->{kind} eq 'choice') {
		my $mapping = $entry->{mapping};
		my @keys = split /,/, $entry->{spec};

		# Ein Command-Template muss nach der Auswahl auf den gemappten Wert
		# angewendet werden und kann deshalb nicht statisch in setList stehen.
		if (defined($entry->{template}) && $entry->{template} ne '') {
			return $head . ' { MQTT2_DISCOVERY_runtimeTemplateChoice('
				. _perl_template_quote($runtime_topic) . ', '
				. _perl_template_quote($entry->{template}) . ', '
			. _perl_hash_literal($mapping) . ', $EVENT) }';
		}

		# Direkte MQTT2_DEVICE-Syntax ist nur moeglich, wenn Topic und Mapping fuer
		# jede angebotene Auswahl vollstaendig und inline sicher sind.
		if (_plain_topic($topic) && !grep { !exists $mapping->{$_} } @keys) {
			# Einfache Identitaets- oder Gross/Kleinschreibungs-Mappings kann
			# MQTT2_DEVICE ohne Runtime-Wrapper direkt darstellen.
			return "$head $topic" if !grep { "$mapping->{$_}" ne $_ } @keys;
			my $all_upper = !grep { "$mapping->{$_}" ne uc($_) } @keys;
			my $all_lower = !grep { "$mapping->{$_}" ne lc($_) } @keys;

			# Reine Gross-/Kleinschreibung laesst sich bereits in der Werteliste
			# ausdruecken und benoetigt keinen Perl-Ausdruck.
			if ($all_upper || $all_lower) {
				my $mapped_head = $entry->{name} . ':' . join(',', map { $mapping->{$_} } @keys);
				return "$mapped_head $topic";
			}

			# Beliebige skalare Mappings koennen inline bleiben, solange auch das
			# Topic sicher in einen kleinen lokalen Hash-Ausdruck eingebettet wird.
			if (_inline_topic($topic)) {
				my @pairs;

				for my $key (@keys) {
					my ($quoted_key, $quoted_value) = (_perl_quote($key), _perl_quote($mapping->{$key}));
					@pairs = () and last if !defined($quoted_key) || !defined($quoted_value);
					push @pairs, "$quoted_key=>$quoted_value";
				}

				return $head . ' {my %map=(' . join(',', @pairs) . '); "' . $topic
					. ' ".$map{$EVTPART1}}' if @pairs == @keys;
			}
		}
		return $head . ' { MQTT2_DISCOVERY_runtimeChoice('
			. _perl_template_quote($runtime_topic) . ', '
			. _perl_hash_literal($mapping) . ', $EVENT) }';
	}

	# Buttons verwenden fuer sichere konstante Payloads die native Kurzform und
	# ansonsten den gequoteten Runtime-Publisher.
	if ($entry->{kind} eq 'button') {
		return "$head $topic $entry->{payload}"
			if _plain_topic($topic) && defined($entry->{payload}) && $entry->{payload} !~ /[\r\n\$]/;
		return $head . ' { MQTT2_DISCOVERY_runtimePublish('
			. _perl_template_quote($runtime_topic) . ', '
			. _perl_template_quote($entry->{payload}) . ') }';
	}

	# Begrenzte JSON-Auswahlen werden bei einfachen Payloadwerten direkt lesbar
	# gerendert; komplexere Abbildungen bleiben im validierten Runtime-Wrapper.
	if ($entry->{kind} eq 'json_choice') {
		my $mapping = $entry->{mapping};
		my @keys = split /,/, $entry->{spec};
		my @values = ref($mapping) eq 'HASH' ? map { $mapping->{$_} } @keys : ();
		my %seen;

		# Nur eindeutige widget-sichere Werte koennen selbst die sichtbaren Choices
		# bilden und danach ohne weitere Abbildung in das JSON eingesetzt werden.
		if (_plain_topic($topic) && @values == @keys
				&& !grep { !defined($_) || ref($_) || $_ !~ /^[A-Za-z0-9_.-]+$/ || $seen{$_}++ } @values) {
			my $mapped_head = $entry->{name} . ':' . join(',', @values);
			my $payload = JSON::PP->new->canonical(1)->encode({ $entry->{key} => '__VALUE__' });
			$payload =~ s/"__VALUE__"/"\$EVTPART1"/;
			return "$mapped_head $topic $payload";
		}
		return $head . ' { MQTT2_DISCOVERY_runtimeJSONChoice('
			. _perl_template_quote($runtime_topic) . ', '
			. _perl_template_quote($entry->{key}) . ', '
			. _perl_hash_literal($mapping) . ', $EVENT) }';
	}

	# JSON-Sets bauen genau ein Schluessel/Wert-Paar; der Zahlenwert bleibt dabei
	# absichtlich unquotiert, damit das Zielgeraet den richtigen Typ erhaelt.
	if ($entry->{kind} eq 'json') {

		# Bei einem einfachen Topic kann MQTT2_DEVICE das kanonische JSON direkt
		# senden; komplexe Topics werden erst zur Laufzeit sicher zusammengesetzt.
		if (_plain_topic($topic)) {
			my $payload = JSON::PP->new->canonical(1)->encode({ $entry->{key} => '__VALUE__' });
			$payload =~ s/"__VALUE__"/\$EVTPART1/;
			return "$head $topic $payload";
		}
		return $head . ' { MQTT2_DISCOVERY_runtimeJSONPublish('
			. _perl_template_quote($runtime_topic) . ', '
			. _perl_template_quote($entry->{key}) . ', $EVENT) }';
	}
	return $entry->{line};
}

# Leitet fuer beliebige reservierte Rollenreadings kollisionsfreie JSON-Ziele ab.
sub _reserved_json_renames {
	my ($entries, $extra_reserved) = @_;
	my (%reserved, %occupied, %targets, %renames);
	%reserved = map { ($_ => 1) }
		grep { $extra_reserved->{$_} } keys %$extra_reserved
		if ref($extra_reserved) eq 'HASH';

	for my $entry (@{ $entries || [] }) {
		next if ref($entry) ne 'HASH';
		my $name = $entry->{name};
		next if !defined($name) || ref($name) || $name eq '';
		if ($entry->{reserved_reading}) {
			$reserved{$name} = 1;
		} else {
			$occupied{$name} = 1;
		}
	}

	for my $name (sort keys %reserved) {
		my $base = "state_$name";
		my $target = $base;
		my $index = 2;

		while ($reserved{$target} || $occupied{$target} || $targets{$target}) {
			$target = $base . '_' . $index++;
		}

		$targets{$target} = 1;
		$renames{$name} = $target;
	}

	return \%renames;
}

# Fasst Availability-Quellen pro MQTT-Topic in einen einzigen Runtime-Aufruf.
sub _render_availability_groups {
	my ($entries, $device_topic) = @_;
	my (%sources, %topics, %policies);

	for my $entry (@{ $entries || [] }) {
		next if ref($entry) ne 'HASH' || ($entry->{kind} || '') ne 'availability';
		my $source_reading = $entry->{source_reading};
		my $topic = $entry->{topic};
		next if !defined($source_reading) || !defined($topic);
		$sources{$source_reading} ||= {
			reading => $source_reading,
			(defined($entry->{template}) ? (template => $entry->{template}) : ()),
			available => $entry->{payload_available},
			unavailable => $entry->{payload_not_available},
		};
		$topics{$topic}{$source_reading} = 1;
		my $policy = $entry->{policy};
		$policies{ $policy->{reading} } = {
			reading => $policy->{reading}, mode => $policy->{mode},
			sources => [ sort @{ $policy->{sources} || [] } ],
		} if ref($policy) eq 'HASH' && defined($policy->{reading});
	}
	my @policies = map { $policies{$_} } sort keys %policies;
	my @rendered;

	for my $topic (sort keys %topics) {
		my $configuration = JSON::PP->new->canonical(1)->encode({
			sources => [ map { $sources{$_} } sort keys %{ $topics{$topic} } ],
			policies => \@policies,
		});
		my $argument = _perl_template_quote($configuration);
		next if !defined($argument);
		push @rendered, {
			kind => 'availability_group', role => 'availability',
			name => 'availability', reserved_reading => 1, topic => $topic,
			names => [
				'availability', sort(keys %{ $topics{$topic} }), sort(keys %policies),
			],
			line => _regex($topic, $device_topic, undef)
				. ' { MQTT2_DISCOVERY_runtimeAvailability($NAME, $EVENT, '
				. $argument . ') }',
		};
	}

	return \@rendered;
}

# Gruppiert optimierbare Eintraege und rendert die vollstaendige sortierte Zeilenliste.
sub render_entries {
	my ($entries, $device_topic, $extra_reserved) = @_;
	my (@rendered, @availability, %json_groups, %json_autocreate);
	my $reserved_renames = _reserved_json_renames($entries, $extra_reserved);

	# JSON-Eintraege werden zunaechst pro Topic gesammelt. So kann ein einziges
	# json2nameValue mehrere Readings effizient erzeugen.
	for my $entry (@{ $entries || [] }) {

		# Availability benoetigt alle Quellen und Verknuepfungsregeln des Devices,
		# bevor pro Topic ein zustandsbehafteter Runtime-Aufruf entstehen kann.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'availability') {
			push @availability, $entry;
			next;
		}

		# Explizite JSON-Felder desselben Topics werden spaeter auf Eindeutigkeit
		# untersucht und moeglichst in eine gemeinsame Zeile verdichtet.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'json_reading') {
			push @{ $json_groups{ $entry->{topic} } }, $entry;
			next;
		}

		# Autocreate-Eintraege brauchen pro Topic nur eine Zeile; ihre logischen
		# Namen werden fuer Besitz- und Konfliktverwaltung dennoch gesammelt.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'json_autocreate') {
			push @{ $json_autocreate{ $entry->{topic} } }, $entry;
			next;
		}

		# Sequenz-JSON verwendet dieselben reservierten Zielnamen wie die spaeter
		# gruppierten JSON-Arten, obwohl jede Sequenz eine eigene Regex benoetigt.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'json_sequence') {
			push @rendered, +{ %$entry,
				line => _render_json_sequence($entry, $device_topic, $reserved_renames) };
			next;
		}
		push @rendered, +{ %$entry, line => render_entry($entry, $device_topic) };
	}

	for my $topic (sort keys %json_autocreate) {
		my %by_name = map { (($_->{name} // '') => $_) } @{ $json_autocreate{$topic} };
		my @entries = values %by_name;
		my %renames = %$reserved_renames;

		for my $entry (@entries) {
			next if !defined($entry->{json_key}) || !defined($entry->{name})
				|| $entry->{json_key} eq $entry->{name};
			$renames{ $entry->{json_key} } = $entry->{name};
		}

		push @rendered, {
			kind => 'json_autocreate_group', name => '', names => [ sort keys %by_name ],
			topic => $topic,
			line => _render_json_autocreate($entries[0], $device_topic, \%renames),
		} if @entries;
	}

	for my $topic (sort keys %json_groups) {
		my %pairs;

		for my $entry (@{ $json_groups{$topic} }) {
			$pairs{ $entry->{json_key} . "\0" . $entry->{name} } ||= $entry;
		}

		my @entries = values %pairs;
		my (%raw_count, %name_count);
		++$raw_count{ $_->{json_key} } for @entries;
		++$name_count{ $_->{name} } for @entries;
		my (@grouped, @fallback);

		# Doppelte Quell- oder Zielnamen sind nicht eindeutig gruppierbar und
		# erhalten deshalb jeweils eine sichere Runtime-Zeile als Fallback.
		for my $entry (@entries) {

			# Nur eine bijektive Quell-/Zielkombination kann ohne Informationsverlust
			# Teil einer gemeinsamen json2nameValue-Abbildung werden.
			if ($raw_count{ $entry->{json_key} } == 1 && $name_count{ $entry->{name} } == 1) {
				push @grouped, $entry;
			} else {
				push @fallback, $entry;
			}
		}

		# Mindestens ein eindeutiger Eintrag rechtfertigt die kompakte Gruppenzeile;
		# mehrdeutige Eintraege werden danach separat gerendert.
		if (@grouped) {
			push @rendered, {
				kind => 'json_group', name => '', names => [ map { $_->{name} } @grouped ],
				topic => $topic,
				line => _render_json_group(\@grouped, $device_topic, $reserved_renames),
			};
		}
		push @rendered, map {
			+{ %$_, kind => 'reading', line => _render_runtime_reading($_, $device_topic) }
		} @fallback;
	}
	push @rendered, @{ _render_availability_groups(\@availability, $device_topic) };

	return \@rendered;
}

1;
