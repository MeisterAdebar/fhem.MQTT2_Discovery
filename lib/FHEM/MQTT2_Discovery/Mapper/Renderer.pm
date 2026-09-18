# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::Renderer;

use strict;
use warnings;
use JSON::PP ();
use MQTT2_Discovery::Helper qw(stable_suffix);
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
	my $payload_regex = '.*';

	# Mehrere Device-Automation-Payloads werden als exakt verankerte Alternativen gerendert.
	if (ref($payload) eq 'ARRAY') {
		return $regex . ':(?!)' if !@$payload
			|| grep { !defined($_) || ref($_) || $_ =~ /[\x00-\x1f]/ } @$payload;
		my @literals = map { _regex_literal($_) } @$payload;
		$payload_regex = @literals == 1 ? $literals[0] . '$'
			: '(?:' . join('|', @literals) . ')$';
	} elsif (defined($payload) && !ref($payload)) {
		$payload_regex = _regex_literal($payload) . '$';
	}

	return $regex . ':' . $payload_regex;
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

# Leitet aus dem Topic beziehungsweise einer Sequenz einen kurzen stabilen
# Qualifizierer fuer kollidierende frei entpackte JSON-Readings ab.
sub _json_path_name {
	my ($entry) = @_;
	my @candidates;
	push @candidates, $entry->{key_prefix}
		if ref($entry) eq 'HASH' && defined($entry->{key_prefix})
			&& !ref($entry->{key_prefix});
	push @candidates, reverse split m{/}, $entry->{topic}
		if ref($entry) eq 'HASH' && defined($entry->{topic}) && !ref($entry->{topic});

	for my $candidate (@candidates) {
		next if !defined($candidate) || ref($candidate);
		$candidate =~ s/[^A-Za-z0-9]+/_/g;
		$candidate =~ s/^_+|_+$//g;
		return lc($candidate) if $candidate ne '';
	}

	return 'json';
}

# Erzeugt den kompakten Wrapper-Aufruf und fuegt nur fachliche Sonderzuordnungen
# sichtbar an; der Availability-Kollisionsschutz bleibt im Wrapper verborgen.
sub _json_readings_call {
	my ($entry, $event, $renames) = @_;
	my $path = _perl_quote(_json_path_name($entry));
	return undef if !defined($path) || !defined($event) || ref($event);
	my $call = 'MQTT2_DISCOVERY_jsonReadings($NAME,' . $path . ',' . $event;

	if (ref($renames) eq 'HASH' && keys %$renames) {
		my $literal = _perl_hash_literal($renames);
		return undef if !defined($literal);
		$call .= ',' . $literal;
	}

	return $call . ')';
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

# Liefert die im Set-Widget sichtbaren Choice-Werte aus dem deklarativen Eintrag.
sub visible_set_values {
	my ($entry, $device_topic) = @_;
	return [] if ref($entry) ne 'HASH' || ($entry->{kind} || '') !~ /^(?:choice|json_choice)$/;
	my @keys = split /,/, ($entry->{spec} // ''), -1;
	return \@keys if !@keys || grep { $_ eq '' } @keys;
	my $mapping = $entry->{mapping};
	return \@keys if ref($mapping) ne 'HASH';
	my $topic = _command_topic(_topic($entry->{topic}, $device_topic), $entry->{retain});

	# Normale Choices zeigen gemappte Werte nur bei der nativen Gross- oder
	# Kleinschreibungsform; Runtime-Referenzen behalten die deklarierte Auswahl.
	if (($entry->{kind} || '') eq 'choice') {
		return \@keys if defined($entry->{template}) && $entry->{template} ne ''
			|| !_plain_topic($topic) || grep { !exists($mapping->{$_}) } @keys;
		my $all_upper = !grep { "$mapping->{$_}" ne uc($_) } @keys;
		my $all_lower = !grep { "$mapping->{$_}" ne lc($_) } @keys;
		return ($all_upper || $all_lower) ? [map { $mapping->{$_} } @keys] : \@keys;
	}

	my @values = map { $mapping->{$_} } @keys;
	my %seen;
	return \@keys if !_plain_topic($topic)
		|| grep { !defined($_) || ref($_) || $_ !~ /^[A-Za-z0-9_.-]+$/ || $seen{$_}++ } @values;
	return \@values;
}

# Liefert das validierte Zieltopic eines abstrakten Set-Eintrags.
sub _command_topic {
	my ($topic, $retain) = @_;
	return $topic . (retain_enabled($retain) ? ':r' : '');
}

# Beschreibt einen komplexen Set-Eintrag nur mit den fuer den sicheren Runtime-
# Dispatch benoetigten Daten; vorgerenderter Perl-Text wird nie gespeichert.
sub _runtime_set_descriptor {
	my ($entry) = @_;
	return undef if ref($entry) ne 'HASH';
	my $kind = $entry->{kind} || '';
	return undef if $kind !~ /^(?:publish|choice|button|json|json_choice)$/;
	my $descriptor = {
		operation => 'set', kind => $kind,
		topic => _command_topic($entry->{topic}, $entry->{retain}),
	};

	# Jede Set-Art uebernimmt ausschliesslich ihre bekannten deklarativen Felder.
	# Damit kann die spaetere Referenzaufloesung keinen Discovery-Code ausfuehren.
	if ($kind eq 'publish') {
		$descriptor->{template} = $entry->{template};
	} elsif ($kind eq 'choice') {
		$descriptor->{mapping} = $entry->{mapping};
		$descriptor->{template} = $entry->{template}
			if defined($entry->{template}) && $entry->{template} ne '';
	} elsif ($kind eq 'button') {
		$descriptor->{payload} = $entry->{payload};
	} else {
		$descriptor->{key} = $entry->{key};
		$descriptor->{constants} = $entry->{constants}
			if ref($entry->{constants}) eq 'HASH' && keys %{ $entry->{constants} };
		$descriptor->{mapping} = $entry->{mapping} if $kind eq 'json_choice';
	}
	return $descriptor;
}

# Verbindet den sichtbaren Set-Namen mit seiner registrierten Runtime-Beschreibung.
sub _runtime_set_line {
	my ($head, $entry, $references) = @_;
	my $expression = _runtime_reference_expression(
		_runtime_set_descriptor($entry), $references,
	);
	return defined($expression) ? "$head $expression" : undef;
}

# Registriert eine deklarative Runtime-Beschreibung und liefert ihren kurzen Aufruf.
sub _runtime_reference_expression {
	my ($descriptor, $references) = @_;
	return undef if ref($references) ne 'HASH' || ref($descriptor) ne 'HASH';
	my $json = JSON::PP->new->canonical(1)->ascii(1)->encode($descriptor);
	my $length = 16;
	my $reference;

	# Bei der theoretischen Kollision eines Kurz-Hashes wird derselbe SHA-1-Wert
	# schrittweise verlaengert, bis die Referenz innerhalb dieses Devices eindeutig ist.
	while ($length <= 40) {
		$reference = 'r_' . stable_suffix($json, $length);
		last if !exists($references->{$reference})
			|| JSON::PP->new->canonical(1)->ascii(1)->encode($references->{$reference}) eq $json;
		$length += 4;
	}
	return if !defined($reference) || $length > 40;
	$references->{$reference} = $descriptor;
	return "{ MQTT2_DISCOVERY_runtimeRef(\$NAME, '$reference', \$EVENT) }";
}

# Rendert komplexe Reading-Templates direkt als deklarative Runtime-Referenz.
sub _render_runtime_reading {
	my ($entry, $device_topic, $references) = @_;
	my $regex = _regex($entry->{topic}, $device_topic, $entry->{payload});
	my $expression = _runtime_reference_expression({
		operation => 'reading',
		runtime => ($entry->{template_context} || '') eq 'trigger'
			? 'triggerReading' : 'reading',
		template => $entry->{template}, name => $entry->{name},
		(ref($entry->{value_map}) eq 'HASH' ? (map => $entry->{value_map}) : ()),
	}, $references);
	return defined($expression) ? "$regex $expression" : undef;
}

# Rendert eine Topicgruppe von Device-Automationen in genau ein gemeinsames Reading.
sub _render_device_automation_group {
	my ($entry, $device_topic, $references) = @_;
	my $payloads = $entry->{payloads};
	return undef if ref($payloads) ne 'ARRAY'
		|| grep { !defined($_) || ref($_) || $_ =~ /[\x00-\x1f]/ } @$payloads;
	# Ohne Template kann bereits die readingList-Regulaerexpression alle Varianten filtern.
	if (!defined($entry->{template}) || $entry->{template} eq '') {
		my $filter = $entry->{match_all} ? undef : $payloads;
		return _regex($entry->{topic}, $device_topic, $filter) . ' ' . $entry->{name};
	}

	# Mit Template wird zuerst der HA-Triggerwert berechnet und erst danach gegen
	# die angekuendigten Payloads geprueft.
	my $expression = _runtime_reference_expression({
		operation => 'reading', runtime => 'triggerReading',
		template => $entry->{template}, name => $entry->{name},
		filter => {
			match_all => $entry->{match_all} ? 1 : 0,
			payloads => $payloads,
		},
	}, $references);
	return defined($expression)
		? _regex($entry->{topic}, $device_topic, undef) . " $expression" : undef;
}

# Rendert eine kompakte Wrapper-Zeile, die mehrere JSON-Readings automatisch erzeugt.
sub _render_json_autocreate {
	my ($entry, $device_topic, $renames) = @_;
	my $regex = _regex($entry->{topic}, $device_topic, undef);
	my $call = _json_readings_call($entry, '$EVENT', $renames);
	return defined($call) ? $regex . ' { ' . $call . ' }' : undef;
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
	my $unwrapped = _json_readings_call($entry, '$1', $renames);
	my $complete = _json_readings_call($entry, '$EVENT', $renames);
	return undef if !defined($unwrapped) || !defined($complete);
	return $regex . $part_pattern . ':.* { $EVENT =~ m,^..' . $payload_key
		. q!..(.+).$, ?  ! . $unwrapped . ' : ' . $complete . ' }';
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

# Rendert alle expliziten JSON- und Template-Readings eines Topics gemeinsam.
sub _render_topic_runtime {
	my ($topic, $entries, $availability, $device_topic, $references) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my @readings;

	for my $entry (@{ $entries || [] }) {
		return undef if ref($entry) ne 'HASH'
			|| !defined($entry->{name}) || ref($entry->{name}) || $entry->{name} eq ''
			|| !defined($entry->{template}) || ref($entry->{template}) || $entry->{template} eq '';
		push @readings, {
			name => $entry->{name}, template => $entry->{template},
			(exists($entry->{items}) ? (items => $entry->{items}) : ()),
			(ref($entry->{value_map}) eq 'HASH' ? (map => $entry->{value_map}) : ()),
			(($entry->{template_context} || '') eq 'trigger' ? (context => 'trigger') : ()),
		};
	}
	return undef if !@readings && ref($availability) ne 'HASH';
	my %configuration;
	$configuration{readings} = \@readings if @readings;
	$configuration{availability} = $availability if ref($availability) eq 'HASH';
	my $expression = _runtime_reference_expression({
		operation => 'topic', configuration => \%configuration,
	}, $references);
	return undef if !defined($expression);
	my $line = _regex($topic, $device_topic, undef) . " $expression";
	return $line;
}

# Uebersetzt genau einen abstrakten Reading- oder Set-Eintrag in FHEM-Attributsyntax.
sub render_entry {
	my ($entry, $device_topic, $references) = @_;
	$references = {} if ref($references) ne 'HASH';
	return $entry->{line} if ref($entry) ne 'HASH' || !$entry->{kind};
	my $topic = _topic($entry->{topic}, $device_topic);

	# Reading-Arten werden als regulaere readingList-Zeilen gerendert.
	if ($entry->{kind} eq 'reading') {
		return _render_topic_runtime($entry->{topic}, [$entry], undef, $device_topic, $references)
			if exists($entry->{items});
		my $regex = _regex($entry->{topic}, $device_topic, $entry->{payload});

		# Ohne Template liefert erst die Runtime die abgebildeten Werte.
		if (!defined($entry->{template}) || $entry->{template} eq '') {
			return "$regex $entry->{name}" if ref($entry->{value_map}) ne 'HASH';
			return _render_runtime_reading({ %$entry, template => '{{ value }}' },
				$device_topic, $references);
		}
		return _render_runtime_reading($entry, $device_topic, $references);
	}

	# Topicweise reduzierte Trigger besitzen ihren eigenen Payload- und Template-Renderer.
	if ($entry->{kind} eq 'device_automation_group') {
		return _render_device_automation_group($entry, $device_topic, $references);
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

	# Publish kann nur bei einem unveraenderten Identitaetstemplate direkt von
	# MQTT2_DEVICE ausgefuehrt werden; Transformationen brauchen die Runtime.
	if ($entry->{kind} eq 'publish') {
		# Ohne $EVENT/$EVTPART haengt MQTT2_DEVICE alle Set-Argumente selbst an und erhaelt auch Leerzeichen.
		return "$head $topic" if $entry->{identity} && _plain_topic($topic);
		return _runtime_set_line($head, $entry, $references);
	}

	# Choice-Eintraege waehlen je nach Mapping-Komplexitaet die kuerzeste sichere
	# setList-Darstellung und fallen andernfalls auf den Runtime-Wrapper zurueck.
	if ($entry->{kind} eq 'choice') {
		my $mapping = $entry->{mapping};
		my @keys = split /,/, $entry->{spec};

		# Ein Command-Template muss nach der Auswahl auf den gemappten Wert
		# angewendet werden und kann deshalb nicht statisch in setList stehen.
		if (defined($entry->{template}) && $entry->{template} ne '') {
			return _runtime_set_line($head, $entry, $references);
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

		}
		return _runtime_set_line($head, $entry, $references);
	}

	# Buttons verwenden fuer sichere konstante Payloads die native Kurzform und
	# ansonsten den gequoteten Runtime-Publisher.
	if ($entry->{kind} eq 'button') {
		return "$head $topic $entry->{payload}"
			if _plain_topic($topic) && defined($entry->{payload}) && $entry->{payload} !~ /[\r\n\$]/;
		return _runtime_set_line($head, $entry, $references);
	}

	# Begrenzte JSON-Auswahlen werden bei einfachen Payloadwerten direkt lesbar
	# gerendert; komplexere Abbildungen bleiben im validierten Runtime-Wrapper.
	if ($entry->{kind} eq 'json_choice') {
		my $mapping = $entry->{mapping};
		my $constants = ref($entry->{constants}) eq 'HASH' ? $entry->{constants} : {};
		my @keys = split /,/, $entry->{spec};
		my @values = ref($mapping) eq 'HASH' ? map { $mapping->{$_} } @keys : ();
		my %seen;

		# Nur eindeutige widget-sichere Werte koennen selbst die sichtbaren Choices
		# bilden und danach ohne weitere Abbildung in das JSON eingesetzt werden.
		if (_plain_topic($topic) && @values == @keys
				&& !grep { !defined($_) || ref($_) || $_ !~ /^[A-Za-z0-9_.-]+$/ || $seen{$_}++ } @values) {
			my $mapped_head = $entry->{name} . ':' . join(',', @values);
			my $payload = JSON::PP->new->canonical(1)->encode({ %$constants, $entry->{key} => '__VALUE__' });
			$payload =~ s/"__VALUE__"/"\$EVTPART1"/;
			return "$mapped_head $topic $payload";
		}
		return _runtime_set_line($head, $entry, $references);
	}

	# JSON-Sets bauen ein dynamisches Schluessel/Wert-Paar samt optionalen
	# Konstanten; der Zahlenwert bleibt dabei absichtlich unquotiert.
	if ($entry->{kind} eq 'json') {
		my $constants = ref($entry->{constants}) eq 'HASH' ? $entry->{constants} : {};

		# Bei einem einfachen Topic kann MQTT2_DEVICE das kanonische JSON direkt
		# senden; komplexe Topics werden erst zur Laufzeit sicher zusammengesetzt.
		if (_plain_topic($topic)) {
			my $payload = JSON::PP->new->canonical(1)->encode({ %$constants, $entry->{key} => '__VALUE__' });
			$payload =~ s/"__VALUE__"/\$EVTPART1/;
			return "$head $topic $payload";
		}
		return _runtime_set_line($head, $entry, $references);
	}
	return $entry->{line};
}

# Fasst Availability-Quellen pro MQTT-Topic in einen einzigen Runtime-Aufruf.
sub _render_availability_groups {
	my ($entries, $device_topic, $references) = @_;
	my (%sources, %topics, %policies);
	my %visible_readings;

	for my $entry (@{ $entries || [] }) {
		next if ref($entry) ne 'HASH' || ($entry->{kind} || '') ne 'availability';
		$visible_readings{ $entry->{name} } = 1
			if defined($entry->{name}) && !ref($entry->{name})
				&& $entry->{name} =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
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
	my $availability_reading = keys(%visible_readings) == 1
		? (keys %visible_readings)[0] : 'availability';

	for my $topic (sort keys %topics) {
		my $configuration = {
			reading => $availability_reading,
			sources => [ map { $sources{$_} } sort keys %{ $topics{$topic} } ],
			policies => \@policies,
		};
		my $expression = _runtime_reference_expression({
			operation => 'availability', configuration => $configuration,
		}, $references);
		next if !defined($expression);
		push @rendered, {
			kind => 'availability_group', role => 'availability',
			name => $availability_reading, reserved_reading => 1, topic => $topic,
			names => [
				$availability_reading, sort(keys %{ $topics{$topic} }), sort(keys %policies),
			],
			configuration => $configuration,
			line => _regex($topic, $device_topic, undef) . " $expression",
		};
	}

	return \@rendered;
}

# Gruppiert optimierbare Eintraege und rendert die vollstaendige sortierte Zeilenliste.
sub render_entries {
	my ($entries, $device_topic, $extra_reserved, $runtime_references) = @_;
	$runtime_references = {} if ref($runtime_references) ne 'HASH';
	my (@rendered, @availability, %json_groups, %json_autocreate, %runtime_topics);

	# JSON-Eintraege werden zunaechst pro Topic gesammelt. So kann eine einzige
	# sichere Runtime-Auswertung mehrere Readings gemeinsam erzeugen.
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

		# Template-Readings ohne Payloadfilter koennen zusammen mit expliziten
		# JSON-Pfaden und Availability desselben Topics ausgewertet werden.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'reading'
				&& defined($entry->{template}) && $entry->{template} ne ''
				&& !defined($entry->{payload})) {
			push @{ $runtime_topics{ $entry->{topic} } }, $entry;
			next;
		}

		# Sequenz-JSON verwendet denselben kompakten Laufzeit-Wrapper wie die spaeter
		# gruppierten JSON-Arten, obwohl jede Sequenz eine eigene Regex benoetigt.
		if (ref($entry) eq 'HASH' && ($entry->{kind} || '') eq 'json_sequence') {
			push @rendered, +{ %$entry,
				line => _render_json_sequence($entry, $device_topic) };
			next;
		}
		push @rendered, +{ %$entry,
			line => render_entry($entry, $device_topic, $runtime_references) };
	}

	for my $topic (sort keys %json_autocreate) {
		my %by_name = map { (($_->{name} // '') => $_) } @{ $json_autocreate{$topic} };
		my @entries = values %by_name;
		my %renames;

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

		# Doppelte Quell- oder Zielnamen bleiben als getrennte Auswertungen erhalten,
		# damit jede bereits aufgeloeste Zuordnung ihr eigenes Reading befuellt.
		for my $entry (@entries) {

			# Eindeutige Zuordnungen bleiben von den kollidierenden Eintraegen getrennt,
			# bevor beide Gruppen in dieselbe Topic-Runtime gelangen.
			if ($raw_count{ $entry->{json_key} } == 1 && $name_count{ $entry->{name} } == 1) {
				push @grouped, $entry;
			} else {
				push @fallback, $entry;
			}
		}

		# Die Unterscheidung erhaelt die bisherige Kollisionsbehandlung; beide Gruppen
		# werden anschliessend im selben Runtime-Aufruf ausgewertet.
		if (@grouped) {
			push @{ $runtime_topics{$topic} }, @grouped;
		}
		push @{ $runtime_topics{$topic} }, @fallback;
	}
	my %runtime_availability;

	for my $entry (@{ _render_availability_groups(
			\@availability, $device_topic, $runtime_references,
		) }) {

		# Nur bei einem gemeinsam genutzten Topic wandert Availability in denselben
		# Runtime-Aufruf; reine Availability-Zeilen behalten ihre kompakte Form.
		if ($runtime_topics{ $entry->{topic} }) {
			$runtime_availability{ $entry->{topic} } = $entry;
		} else {
			push @rendered, $entry;
		}
	}

	for my $topic (sort keys %runtime_topics) {
		my %seen;
		my @entries = sort {
			$a->{name} cmp $b->{name}
				|| $a->{template} cmp $b->{template}
				|| ($a->{template_context} || '') cmp ($b->{template_context} || '')
				|| JSON::PP->new->canonical(1)->encode($a->{items}) cmp JSON::PP->new->canonical(1)->encode($b->{items})
		} grep {
			my $signature = join("\0", $_->{name} // '', $_->{template} // '',
				$_->{template_context} // '', JSON::PP->new->canonical(1)->encode($_->{items}));
			!$seen{$signature}++;
		} @{ $runtime_topics{$topic} };
		my $availability = $runtime_availability{$topic};
		my $line = _render_topic_runtime($topic, \@entries,
			ref($availability) eq 'HASH' ? $availability->{configuration} : undef,
			$device_topic, $runtime_references);
		next if !defined($line);
		my @names = ((map { $_->{name} } @entries),
			ref($availability) eq 'HASH' ? @{ $availability->{names} || [] } : ());
		push @rendered, {
			kind => 'topic_runtime_group', name => '', topic => $topic,
			names => \@names, line => $line,
			(ref($availability) eq 'HASH' ? (role => 'availability', reserved_reading => 1) : ()),
		};
	}

	return \@rendered;
}

1;
