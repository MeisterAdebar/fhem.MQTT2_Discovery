# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::NameResolver;

use strict;
use warnings;
use JSON::PP ();
use MQTT2_Discovery::Helper qw(safe_name stable_suffix);


# Sammelt Readingnamen, die eine technische Rolle exklusiv fuer sich beansprucht.
sub _reserved_reading_names {
	my ($mappings, $extra_reserved) = @_;
	my %reserved = ref($extra_reserved) eq 'HASH'
		? map { ($_ => $extra_reserved->{$_} ? 1 : 0) } keys %$extra_reserved
		: ();

	for my $mapping (values %{ $mappings || {} }) {
		next if ref($mapping) ne 'HASH';

		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || !$entry->{reserved_reading};
			my $name = $entry->{name};
			$reserved{$name} = 1
				if defined($name) && !ref($name) && $name ne '';
		}

	}

	return \%reserved;
}

# Berechnet fuer alle Mappings eindeutige Reading- und Set-Namen mit stabilen Suffixen.
sub _resolved_mapping_names {
	my ($mappings, $reserved) = @_;
	my (%depth, %candidate, %resolved);
	my @keys = sort grep {
		ref($mappings->{$_}) eq 'HASH'
			&& ref($mappings->{$_}{reading_path}) eq 'ARRAY'
			&& @{ $mappings->{$_}{reading_path} }
	} keys %{ $mappings || {} };
	$depth{$_} = 1 for @keys;

	# Beginne mit dem letzten Pfadsegment. Nur kollidierende Namen werden
	# schrittweise um weitere Elternsegmente erweitert.
	while (@keys) {
		my (%groups, %needs_more);

		for my $key (@keys) {
			my $path = $mappings->{$key}{reading_path};
			my $count = $depth{$key} > @$path ? scalar(@$path) : $depth{$key};
			my $start = @$path - $count;
			my $name = safe_name(join('_', @$path[$start .. $#$path]), $path->[-1]);
			$candidate{$key} = $name;
			push @{ $groups{$name} }, $key;
		}

		my $changed = 0;
		$needs_more{$_} = 1
			for grep { $reserved->{ $candidate{$_} } } @keys;

		for my $group (values %groups) {
			next if @$group < 2;
			$needs_more{$_} = 1 for @$group;
		}

		for my $key (keys %needs_more) {
			my $path = $mappings->{$key}{reading_path};

			# Nur Pfade mit noch ungenutzten Elternsegmenten koennen bei einer
			# normalen oder rollenbedingten Kollision weiter praezisiert werden.
			if ($depth{$key} < @$path) {
				++$depth{$key};
				$changed = 1;
			}

		}

		last if !$changed;
	}

	# Sind selbst die vollstaendigen Pfade gleich, trennt ein stabiler Hash die
	# Namen reproduzierbar, ohne von der Eingabereihenfolge abzuhaengen.
	my %groups;
	push @{ $groups{ $candidate{$_} } }, $_ for @keys;

	for my $name (keys %groups) {
		my @group = @{ $groups{$name} };

		# Ein bereits eindeutiger Kandidat bleibt lesbar und benoetigt keinen
		# technischen Hashsuffix.
		if (@group == 1) {
			$resolved{$group[0]} = $name;
			next;
		}
		$resolved{$_} = safe_name($name . '_' . stable_suffix($_, 6), $name) for @group;
	}
	my %used = map { ($_ => 1) } values %resolved;

	# Ein vollstaendiger logischer Pfad kann theoretisch noch exakt einem
	# reservierten Rollennamen entsprechen. Dann sorgt ein lesbarer Fallback
	# ohne Protokoll- oder Topicwissen fuer einen getrennten Namen.
	for my $key (sort keys %resolved) {
		my $name = $resolved{$key};
		next if !$reserved->{$name};
		my $base = safe_name("state_$name", 'state_value');
		my $candidate = $base;
		my $index = 2;

		while ($reserved->{$candidate} || $used{$candidate}) {
			$candidate = safe_name($base . '_' . $index++, $base);
		}

		$resolved{$key} = $candidate;
		$used{$candidate} = 1;
	}

	return \%resolved;
}

# Passt einen abgeleiteten Namen nur an, wenn er auf den umbenannten Basisnamen zeigt.
sub _rename_derived_name {
	my ($value, $old, $new) = @_;
	return $value if !defined($value) || ref($value) || !defined($old) || $old eq '' || $old eq $new;
	return $new if $value eq $old;
	return $new . substr($value, length($old)) if index($value, $old . '_') == 0;
	return $value;
}

# Uebertraegt aufgeloeste Reading- und Set-Namen rekursiv in semantische Capabilities.
sub _rename_semantic_capabilities {
	my ($value, $old, $new) = @_;
	return if ref($value) ne 'HASH';

	for my $key (keys %$value) {

		# Direkte read/write-Referenzen werden umbenannt; verschachtelte
		# Capability-Objekte werden rekursiv nach denselben Referenzen durchsucht.
		if (($key eq 'read' || $key eq 'write') && !ref($value->{$key})) {
			$value->{$key} = _rename_derived_name($value->{$key}, $old, $new);
		} elsif (ref($value->{$key}) eq 'HASH') {
			_rename_semantic_capabilities($value->{$key}, $old, $new);
		}
	}

	return;
}

# Benennt fuer nachgelagerte Einzelkollisionen nur exakt passende Referenzen um.
sub _rename_semantic_capabilities_exact {
	my ($value, $old, $new) = @_;
	return if ref($value) ne 'HASH';

	for my $key (keys %$value) {
		if (($key eq 'read' || $key eq 'write') && !ref($value->{$key})) {
			$value->{$key} = $new if defined($value->{$key}) && $value->{$key} eq $old;
		} elsif (ref($value->{$key}) eq 'HASH') {
			_rename_semantic_capabilities_exact($value->{$key}, $old, $new);
		}
	}

	return;
}

# Loest gekoppelte Reading-/Set-Namen gemeinsam und deviceweit auf.
sub _resolve_linked_entry_names {
	my ($mappings, $reserved) = @_;
	my (%units, %locations, %blocked);

	# Pro Mapping werden nur explizit gekoppelte Setter und ihre gleich markierten
	# Readings als eine gemeinsame, deviceweit aufloesbare Einheit erfasst.
	for my $mapping (@{ $mappings || [] }) {
		next if ref($mapping) ne 'HASH';
		my %linked = map { ($_->{semantic_name} => 1) }
			grep {
				ref($_) eq 'HASH' && defined($_->{semantic_name})
					&& !ref($_->{semantic_name}) && $_->{semantic_name} ne ''
			} @{ $mapping->{set_lines} || [] };

		# Jede logische Capability erhaelt genau einen gemeinsamen Namenskandidaten.
		for my $semantic_name (sort keys %linked) {
			my @readings = grep {
				ref($_) eq 'HASH' && !$_->{reserved_reading}
					&& defined($_->{semantic_name}) && $_->{semantic_name} eq $semantic_name
			} @{ $mapping->{reading_lines} || [] };
			my @sets = grep {
				ref($_) eq 'HASH' && defined($_->{semantic_name})
					&& $_->{semantic_name} eq $semantic_name
			} @{ $mapping->{set_lines} || [] };
			my $candidate = @readings ? $readings[0]{name} : $sets[0]{name};
			next if !defined($candidate) || ref($candidate) || $candidate eq '';
			my $key = join("\x1f", $mapping->{entity_key} // '', $semantic_name);
			my @path = ref($mapping->{reading_path}) eq 'ARRAY'
				? @{ $mapping->{reading_path} } : ();
			push @path, $candidate if !@path || $path[-1] ne $candidate;
			$units{$key} = { reading_path => \@path };
			$locations{$key} = {
				mapping => $mapping, semantic_name => $semantic_name, old => $candidate,
			};
		}

		# Nicht gekoppelte Readings duerfen von der neuen Aufloesung nicht verdraengt werden.
		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || $entry->{reserved_reading};
			next if defined($entry->{semantic_name}) && $linked{ $entry->{semantic_name} };
			$blocked{ $entry->{name} } = 1
				if defined($entry->{name}) && !ref($entry->{name}) && $entry->{name} ne '';
		}

		# Ebenso bleiben bestehende, unabhaengige Setter als belegte Namen geschuetzt.
		for my $entry (@{ $mapping->{set_lines} || [] }) {
			next if ref($entry) ne 'HASH';
			next if defined($entry->{semantic_name}) && $linked{ $entry->{semantic_name} };
			$blocked{ $entry->{name} } = 1
				if defined($entry->{name}) && !ref($entry->{name}) && $entry->{name} ne '';
		}

	}

	return $mappings if !keys %units;
	my %unavailable = (%{ $reserved || {} }, %blocked);
	my $resolved = _resolved_mapping_names(\%units, \%unavailable);

	# Das Ergebnis wird atomar auf Reading, Setter und alle semantischen Referenzen uebertragen.
	for my $key (sort keys %locations) {
		my $location = $locations{$key};
		my $mapping = $location->{mapping};
		my $semantic_name = $location->{semantic_name};
		my $old = $location->{old};
		my $new = $resolved->{$key} // $old;
		next if $old eq $new;

		# Alle Reading-Eintraege derselben Capability erhalten den gemeinsam aufgeloesten Namen.
		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || !defined($entry->{semantic_name});
			$entry->{name} = $new if $entry->{semantic_name} eq $semantic_name;
		}

		# Die gekoppelten Setter folgen exakt derselben Umbenennung.
		for my $entry (@{ $mapping->{set_lines} || [] }) {
			next if ref($entry) ne 'HASH' || !defined($entry->{semantic_name});
			$entry->{name} = $new if $entry->{semantic_name} eq $semantic_name;
		}

		$mapping->{set_state_list} = [ map {
			defined($_) && $_ eq $old ? $new : $_
		} @{ $mapping->{set_state_list} || [] } ];
		_rename_semantic_capabilities_exact(
			$mapping->{semantic_entity}{capabilities}, $old, $new,
		) if ref($mapping->{semantic_entity}) eq 'HASH';
	}

	return $mappings;
}

# Qualifiziert auch sekundaere Eintraege, deren Name mit einer Rolle kollidiert.
sub _resolve_reserved_entry_names {
	my ($mappings, $reserved) = @_;
	my %used;

	for my $mapping (@{ $mappings || [] }) {
		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || $entry->{reserved_reading};
			$used{ $entry->{name} } = 1
				if defined($entry->{name}) && !ref($entry->{name}) && $entry->{name} ne '';
		}
	}

	for my $mapping (@{ $mappings || [] }) {
		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || $entry->{reserved_reading};
			my $old = $entry->{name};
			next if !defined($old) || ref($old) || !$reserved->{$old};
			my $path = $mapping->{reading_path};
			my $namespace = ref($path) eq 'ARRAY' && @$path
				? $path->[0] : 'state';
			my $base = safe_name($namespace . '_' . $old, "state_$old");
			my $new = $base;
			my $index = 2;

			while ($reserved->{$new} || $used{$new}) {
				$new = safe_name($base . '_' . $index++, $base);
			}

			$entry->{name} = $new;
			$entry->{semantic_name} = $new
				if defined($entry->{semantic_name}) && $entry->{semantic_name} eq $old;
			$used{$new} = 1;

			for my $set (@{ $mapping->{set_lines} || [] }) {
				next if ref($set) ne 'HASH' || !defined($set->{name});
				$set->{name} = $new if $set->{name} eq $old;
			}

			$mapping->{set_state_list} = [ map {
				defined($_) && $_ eq $old ? $new : $_
			} @{ $mapping->{set_state_list} || [] } ];
			_rename_semantic_capabilities_exact(
				$mapping->{semantic_entity}{capabilities}, $old, $new,
			) if ref($mapping->{semantic_entity}) eq 'HASH';
		}
	}

	return $mappings;
}

# Wendet die deviceweite Namensaufloesung auf Mappings, Eintraege und Semantik an.
sub resolve {
	my ($source, $extra_reserved) = @_;
	my %source = map { (($_->{entity_key} // '') => $_) }
		grep { ref($_) eq 'HASH' && defined($_->{entity_key}) } @{ $source || [] };
	my $reserved = _reserved_reading_names(\%source, $extra_reserved);
	my $resolved = _resolved_mapping_names(\%source, $reserved);
	my @result;

	# Die tiefe JSON-Kopie verhindert, dass das Umbenennen die in der Registry
	# gespeicherten Original-Mappings veraendert.
	for my $key (sort keys %source) {
		my $mapping = JSON::PP->new->decode(JSON::PP->new->encode($source{$key}));
		my $old = $mapping->{reading_name};
		my $new = $resolved->{$key} // $old;

		# Nur eine tatsaechliche Namensaenderung darf die abgeleiteten Reading-,
		# Set- und Semantikreferenzen des kopierten Mappings anfassen.
		if (defined($old) && defined($new) && $old ne $new) {
			# Alle abgeleiteten Namen muessen gemeinsam umziehen, sonst zeigen Sets
			# oder semantische Capabilities auf nicht mehr vorhandene Readings.
			for my $entry (@{ $mapping->{reading_lines} || [] }) {
				next if ref($entry) ne 'HASH' || $entry->{reserved_reading};
				$entry->{semantic_name} = _rename_derived_name($entry->{semantic_name}, $old, $new)
					if exists $entry->{semantic_name};
				$entry->{name} = _rename_derived_name($entry->{name}, $old, $new);
			}

			for my $entry (@{ $mapping->{set_lines} || [] }) {
				next if ref($entry) ne 'HASH';
				$entry->{semantic_name} = _rename_derived_name($entry->{semantic_name}, $old, $new)
					if exists $entry->{semantic_name};
				$entry->{name} = _rename_derived_name($entry->{name}, $old, $new);
			}

			$mapping->{set_state_list} = [ map {
				_rename_derived_name($_, $old, $new)
			} @{ $mapping->{set_state_list} || [] } ];

			# Semantische Metadaten sind optional, muessen bei Vorhandensein aber
			# dieselben aufgeloesten Namen wie readingList und setList verwenden.
			if (ref($mapping->{semantic_entity}) eq 'HASH') {
				$mapping->{semantic_entity}{id} = _rename_derived_name(
					$mapping->{semantic_entity}{id}, $old, $new,
				);
				_rename_semantic_capabilities($mapping->{semantic_entity}{capabilities}, $old, $new);
			}
			$mapping->{reading_name} = $new;
		}
		push @result, $mapping;
	}

	_resolve_linked_entry_names(\@result, $reserved);
	return _resolve_reserved_entry_names(\@result, $reserved);
}

1;
