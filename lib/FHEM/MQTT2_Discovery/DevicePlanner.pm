# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::DevicePlanner;

use strict;
use warnings;
use MQTT2_Discovery::Helper qw(stable_unique split_lines line_key);
use MQTT2_Discovery::ActionPlan ();


# Ein Topic gehoert nur dann zum Prefix, wenn die Segmentgrenze stimmt.
# Dadurch wird beispielsweise "geraet2" nicht "geraet" zugeordnet.
sub topic_has_prefix {
	my ($topic, $prefix) = @_;
	return defined($topic) && defined($prefix) && $prefix ne ''
		&& ($topic eq $prefix || index($topic, "$prefix/") == 0);
}

# Ermittelt einen sicheren gemeinsamen Topic-Stamm fuer alle Nutzdaten eines Devices.
sub device_topic {
	my ($record, $entries) = @_;

	# Availability-Topics liegen haeufig ausserhalb des eigentlichen
	# Geraetebaums und duerfen das gemeinsame Prefix nicht verfaelschen.
	# Die eigenen Antworttopics des Moduls liegen in seinem Namensraum und wuerden
	# den gemeinsamen Geraetestamm sonst vollstaendig aufloesen.
	my @topics = stable_unique(map { $_->{topic} }
		grep { ref($_) eq 'HASH' && ($_->{role} // '') ne 'availability'
			&& defined($_->{topic}) && !ref($_->{topic}) && $_->{topic} ne ''
			&& $_->{topic} !~ m{^mqtt2_discovery/} }
		@{ $entries || [] });
	my @availability_topics = stable_unique(map { $_->{topic} }
		grep { ref($_) eq 'HASH' && ($_->{role} // '') eq 'availability'
			&& defined($_->{topic}) && !ref($_->{topic}) && $_->{topic} ne '' }
		@{ $entries || [] });
	return undef if !@topics;

	# Parser-Vorschlaege sind sichere Kandidaten, duerfen aber einen tieferen
	# gemeinsamen Geraetestamm nicht mehr verdecken.
	my @suggested = stable_unique(grep { defined($_) && !ref($_) && $_ ne '' }
		map { $record->{entities}{$_}{device_topic} } sort keys %{ $record->{entities} || {} });
	my $suggested = (@suggested == 1 && $suggested[0] !~ /[\s\x00-\x1f\$]/
		&& $suggested[0] !~ m{(?:^|/)[+#](?:/|$)}
		&& !grep { !topic_has_prefix($_, $suggested[0]) } @topics)
			? $suggested[0] : undef;

	# Das laengste gemeinsame segmentgenaue Prefix wird aus allen Nutzdaten-
	# Topics berechnet. Bei mehreren Topics darf das kuerzeste selbst der Stamm sein.
	my @parts = map { [ split m{/}, $_, -1 ] } @topics;
	my $limit = @{ $parts[0] };

	for my $parts (@parts) {
		$limit = @$parts if @$parts < $limit;
	}

	my @common;
	PART: for my $index (0 .. $limit - 1) {
		my $part = $parts[0][$index];
		last if !defined($part) || $part eq '' || $part eq '+' || $part eq '#';

		for my $parts (@parts) {
			last PART if $parts->[$index] ne $part;
		}

		push @common, $part;
	}

	# Ein unterhalb des einzigen Nutzdaten-Topics liegendes Availability-Topic
	# belegt, dass dieses Topic selbst bereits der stabile Geraetestamm ist.
	my $single_topic_is_device_root = @topics == 1 && grep {
		$_ ne $topics[0] && topic_has_prefix($_, $topics[0])
	} @availability_topics;

	# Ein einzelnes Topic enthaelt keinen Beleg, dass sein Blatt bereits ein
	# Geraetestamm ist; in diesem Fall bleibt das letzte Segment Nutzdatenname.
	pop @common if @topics == 1 && @common == $limit && @common > 1
		&& !$single_topic_is_device_root;

	# Generische Funktionssegmente sind kein stabiler Geraetestamm.
	pop @common if @common > 1 && $common[-1] =~ /^(?:cmd|command|set|state|status)$/i;
	my $candidate = join('/', @common);
	$candidate = undef if $candidate eq '' || $candidate =~ /[\s\x00-\x1f\$]/;

	# Der tiefere der beiden validierten Kandidaten gewinnt. Da beide alle Topics
	# umfassen, ist die Segment-Prefix-Pruefung zugleich die Eindeutigkeitspruefung.
	return $candidate if defined($candidate)
		&& (!defined($suggested) || topic_has_prefix($candidate, $suggested));
	return $suggested;
}

# Sammelt manuelle JSON-Sammelhandler, die ein komplettes Topic verarbeiten.
sub _manual_json_topic_patterns {
	my ($manual, $device_topic) = @_;
	my @patterns;

	# Nur breite json2nameValue-Regeln mit beliebigem Payload koennen eine
	# generierte JSON-Auswertung vollstaendig und nicht nur fallweise ersetzen.
	for my $line (@{ $manual || [] }) {
		my ($regexp, $code) = split /\s+/, $line, 2;
		next if !defined($regexp) || !defined($code)
			|| ($code !~ /\bjson2nameValue\s*\(\s*[^,]+\s*,\s*(['"])\1\s*(?:,|\))/
				&& $code !~ /\bjson2nameValue\s*\(\s*\$EVENT\s*\)/);
		next if $regexp !~ s/:\.\*(?:\$)?\z//;

		# $DEVICETOPIC wird wie in MQTT2_DEVICE auf den fuer den fertigen Plan
		# wirksamen Topicstamm aufgeloest; unbekannte Variablen bleiben unbewertet.
		if (index($regexp, '$DEVICETOPIC') >= 0) {
			next if !defined($device_topic) || $device_topic eq '';
			my $literal = quotemeta($device_topic);
			$regexp =~ s/\$DEVICETOPIC/$literal/g;
		}
		next if $regexp =~ /\$[A-Za-z_][A-Za-z0-9_]*/;
		my $compiled = eval { qr/\A(?:$regexp)\z/ };
		next if !$compiled;
		push @patterns, $compiled;
	}

	return \@patterns;
}

# Liefert die konkreten Topics, die ein JSON-Eintrag vollstaendig abdecken muss.
sub _json_entry_topics {
	my ($entry) = @_;
	return () if ref($entry) ne 'HASH';
	my $topic = $entry->{topic};
	return () if !defined($topic) || ref($topic) || $topic eq '';

	# MQTT-Wildcards beschreiben unendlich viele Topics und werden nicht durch
	# einzelne Stichproben als vollstaendig manuell abgedeckt eingestuft.
	return () if grep { $_ eq '+' || $_ eq '#' } split m{/}, $topic, -1;

	# Nummerierte Sequenzen wie INFO1 bis INFO3 gelten nur dann als abgedeckt,
	# wenn derselbe manuelle Handler jede angekuendigte Variante verarbeitet.
	if (($entry->{kind} || '') eq 'json_sequence') {
		my $parts = $entry->{parts};
		return () if ref($parts) ne 'ARRAY' || !@$parts
			|| grep { !defined($_) || ref($_) } @$parts;
		return map { $topic . $_ } @$parts;
	}

	return ($topic);
}

# Prueft, ob eine manuelle JSON-Regel alle Topics eines generierten Eintrags trifft.
sub _manual_json_handler_covers {
	my ($patterns, $entry, $cid) = @_;
	my @topics = _json_entry_topics($entry);
	return 0 if !@topics;

	for my $pattern (@{ $patterns || [] }) {
		my $covers_all = 1;

		for my $topic (@topics) {
			my $direct = $topic =~ $pattern;
			my $cid_scoped = defined($cid) && !ref($cid) && $cid ne ''
				&& "$cid:$topic" =~ $pattern;

			# Bereits eine nicht getroffene Sequenzvariante verhindert, dass die
			# manuelle Regel den generierten Sammelhandler sicher ersetzen kann.
			if (!$direct && !$cid_scoped) {
				$covers_all = 0;
				last;
			}
		}

		return 1 if $covers_all;
	}

	return 0;
}

# Bereitet JSON-Reading-Eintraege unter Beachtung manueller Namens- und Topickonflikte vor.
sub prepare_json_readings {
	my ($mode, $current, $previous_owned, $entries, $conflicts, $device_topic, $cid) = @_;
	my %previous = map { $_ => 1 } @{ $previous_owned || [] };
	my @current = split_lines($current);
	my @manual = grep { !$previous{$_} } @current;
	my %manual_by_key;
	push @{ $manual_by_key{ line_key('reading', $_) } }, $_ for @manual;
	my $manual_json_patterns = _manual_json_topic_patterns(\@manual, $device_topic);
	my %remove;
	my @prepared;

	# JSON-Autocreate kann mehrere Readings aus einer Zeile erzeugen. Vor dem
	# Rendern werden deshalb Konflikte gegen manuell gepflegte Namen aufgeloest.
	for my $entry (@{ $entries || [] }) {
		my $kind = ref($entry) eq 'HASH' ? ($entry->{kind} || '') : '';
		my $json_topic_entry = $kind eq 'json_reading' || $kind eq 'json_autocreate'
			|| $kind eq 'json_sequence' || ($kind eq 'reading' && exists($entry->{items}));

		# Ein vorhandener manueller JSON-Sammelhandler gewinnt konservativ fuer
		# dasselbe Topic, damit MQTT2_DEVICE den Payload nicht zweimal auswertet.
		if ($mode eq 'conservative' && $json_topic_entry
				&& _manual_json_handler_covers($manual_json_patterns, $entry, $cid)) {
			my $conflict = $entry->{name} // '';
			$conflict = 'topic:' . ($entry->{topic} // '') if $conflict eq '';
			push @$conflicts, $conflict;
			next;
		}

		# Andere Entry-Arten benoetigen keine JSON-Namensaufloesung und bleiben
		# deshalb unveraendert in ihrer urspruenglichen Reihenfolge erhalten.
		if (ref($entry) ne 'HASH'
				|| ($kind ne 'json_reading' && $kind ne 'json_autocreate')) {
			push @prepared, $entry;
			next;
		}
		my $name = $entry->{name} // '';

		# Ein gleichnamiges manuelles Reading darf nur nach der expliziten
		# existingDevice-Strategie behandelt werden.
		if ($name ne '' && $manual_by_key{$name} && @{ $manual_by_key{$name} }) {

			# replace uebertraegt die Verantwortung fuer genau diesen Namen an
			# Discovery; konservative Modi melden stattdessen einen Konflikt.
			if ($mode eq 'replace') {
				# Im replace-Modus darf Discovery die kollidierenden manuellen Zeilen
				# gezielt entfernen; andere manuelle Zeilen bleiben erhalten.
				my $manual_lines = delete $manual_by_key{$name};
				$remove{$_} = 1 for @$manual_lines;
			} else {
				push @$conflicts, $name;
				next;
			}
		}
		push @prepared, $entry;
	}

	@current = grep { !$remove{$_} } @current if %remove;
	return (\@prepared, join("\n", @current));
}

# Baut den atomar auszufuehrenden Plan fuer devicetopic, readingList und setList auf.
sub attribute_plan {
	my (%args) = @_;
	my $plan = MQTT2_Discovery::ActionPlan->new();

	# devicetopic ist optional verwaltet, readingList und setList bilden dagegen
	# immer eine gemeinsame atomare Aenderung.
	$plan->set_attribute(
		device => $args{device}, attribute => 'devicetopic', value => ($args{device_topic} // ''),
		previous_exists => $args{previous_device_topic_exists},
		previous_value => $args{previous_device_topic},
	) if $args{manage_device_topic};
	$plan->set_attribute(
		device => $args{device}, attribute => 'readingList', value => $args{reading_list},
		previous_exists => $args{previous_reading_list_exists},
		previous_value => $args{previous_reading_list},
	);
	$plan->set_attribute(
		device => $args{device}, attribute => 'setList', value => $args{set_list},
		previous_exists => $args{previous_set_list_exists},
		previous_value => $args{previous_set_list},
	);
	return $plan;
}

1;
