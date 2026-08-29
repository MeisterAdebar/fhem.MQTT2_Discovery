# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Template;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Scalar::Util qw(looks_like_number);
use MQTT2_Discovery::Helper qw(trim);


# Beschreibt das bewusst unterstuetzte HA/Jinja-Subset an einer zentralen Stelle.
# source_path kennzeichnet Filter, deren fachlicher Hauptwert weiterhin aus dem
# Eingangspfad stammt; value_identity gilt nur fuer unveraenderte Durchleitungen.
my %FILTERS = (
	# Textfilter veraendern ausschliesslich die Darstellung des gelesenen Werts.
	# Der JSON-Pfad bleibt deshalb fuer die fachliche Namensableitung erhalten.
	lower => {
		min_args => 0, max_args => 0, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value) = @_;

			# Ein fehlender Quellpfad unterdrueckt wie in HA das gesamte Ergebnis;
			# ein vorhandener Nullwert wird dagegen als leerer Text weiterbehandelt.
			return (0, undef) if !$exists;
			$value = '' if !defined($value);
			return (1, lc "$value");
		},
	},
	upper => {
		min_args => 0, max_args => 0, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value) = @_;

			# upper besitzt dieselbe Existenzsemantik wie lower und unterscheidet
			# sich ausschliesslich in der eigentlichen Zeichenumwandlung.
			return (0, undef) if !$exists;
			$value = '' if !defined($value);
			return (1, uc "$value");
		},
	},
	trim => {
		min_args => 0, max_args => 0, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value) = @_;

			# trim entfernt nur umgebenden Leerraum; insbesondere darf dadurch der
			# zugrunde liegende JSON-Name nicht verloren gehen.
			return (0, undef) if !$exists;
			$value = '' if !defined($value);
			return (1, trim("$value"));
		},
	},

	# Numerische Konverter behalten den fachlichen Quellpfad. Ihr optionales
	# Argument ist der von HA definierte Rueckfallwert bei ungueltiger Eingabe.
	int => {
		min_args => 0, max_args => 1, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value, $argument_exists, $argument) = @_;
			return (0, undef) if !$exists;
			$value = '' if !defined($value);

			# Ohne expliziten Fallback bleibt eine nicht numerische Eingabe ein
			# Auswertungsfehler und erzeugt kein irrefuehrendes Reading-Update.
			return ($argument_exists ? (1, $argument) : (0, undef))
				if !looks_like_number($value);
			return (1, int($value));
		},
	},
	float => {
		min_args => 0, max_args => 1, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value, $argument_exists, $argument) = @_;
			return (0, undef) if !$exists;
			$value = '' if !defined($value);

			# float verwendet denselben HA-Fallbackvertrag wie int, erhaelt aber
			# vorhandene Nachkommastellen im numerischen Ergebnis.
			return ($argument_exists ? (1, $argument) : (0, undef))
				if !looks_like_number($value);
			return (1, 0 + $value);
		},
	},

	# round ist weiterhin pfaderhaltend, aber nicht wertidentisch. Die optionale
	# Genauigkeit beeinflusst nur die Ausgabe und niemals den Readingnamen.
	round => {
		min_args => 0, max_args => 1, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value, $argument_exists, $argument) = @_;
			return (0, undef) if !$exists;
			$value = '' if !defined($value);
			return (0, undef) if !looks_like_number($value);
			my $digits = $argument_exists ? int($argument) : 0;
			my $factor = 10 ** $digits;

			# Die explizite Berechnung vermeidet abhaengige Locale-Formatierung und
			# bildet positive wie negative Werte mit derselben Genauigkeit ab.
			my $rounded = int($value * $factor + ($value < 0 ? -0.5 : 0.5)) / $factor;
			return (1, $rounded);
		},
	},

	# default kann statt des Eingangspfads sein Argument liefern. Daher darf
	# dieser Filter weder als eindeutige Pfadquelle noch als Identitaet gelten.
	default => {
		min_args => 1, max_args => 1, source_path => 0, value_identity => 0,
		evaluate => sub {
			my ($exists, $value, $argument_exists, $argument) = @_;
			return ($exists && defined($value) ? (1, $value) : ($argument_exists, $argument));
		},
	},

	# JSON-Serialisierung veraendert den Wert vollstaendig, laesst dessen
	# fachliche Herkunft aus demselben JSON-Pfad aber weiterhin erkennen.
	tojson => {
		min_args => 0, max_args => 0, source_path => 1, value_identity => 0,
		evaluate => sub {
			my ($exists, $value) = @_;
			return (0, undef) if !$exists;
			$value = '' if !defined($value);
			return (1, encode_json($value));
		},
	},

	# is_defined ist der einzige registrierte Filter, der einen vorhandenen Wert
	# bytegleich durchreicht und deshalb auch die direkte JSON-Auswertung erlaubt.
	is_defined => {
		min_args => 0, max_args => 0, source_path => 1, value_identity => 1,
		evaluate => sub {
			my ($exists, $value) = @_;
			return ($exists, $value);
		},
	},
);


# Die Template-Engine akzeptiert absichtlich nur ein kleines Jinja-Subset.
# Sie erzeugt einen eigenen Syntaxbaum und fuehrt niemals Discovery-Text aus.
sub _fail {
	my ($message) = @_;
	return { ok => 0, error => $message };
}

# Zerlegt einen Ausdruck nur an Trennzeichen ausserhalb von Strings und Klammern.
sub _split_outside {
	my ($text, $separator) = @_;
	my @parts;
	my ($current, $quote, $depth) = ('', '', 0);

	# Separatoren innerhalb von Strings, Klammern oder Arrayzugriffen gehoeren
	# zum aktuellen Ausdruck und duerfen nicht aufgeteilt werden.
	for my $char (split //, $text) {

		# Innerhalb eines Literals haben Klammern und Separatoren keine
		# syntaktische Bedeutung; nur das passende Schlusszeichen beendet es.
		if ($quote ne '') {
			$current .= $char;
			$quote = '' if $char eq $quote;
			next;
		}

		# Ausserhalb von Literalen aktualisieren Strukturzeichen den Parserzustand
		# oder beenden am gewuenschten Separator den aktuellen Ausdrucksteil.
		if ($char eq q{'} || $char eq q{"}) {
			$quote = $char;
			$current .= $char;
		} elsif ($char eq '(' || $char eq '[') {
			++$depth;
			$current .= $char;
		} elsif ($char eq ')' || $char eq ']') {
			--$depth;
			$current .= $char;
		} elsif ($char eq $separator && $depth == 0) {
			push @parts, trim($current);
			$current = '';
		} else {
			$current .= $char;
		}
	}

	push @parts, trim($current);
	return @parts;
}

# Uebersetzt Literale, Pfade und geklammerte Teilausdruecke in AST-Knoten.
sub _parse_atom {
	my ($text) = @_;
	$text = trim($text);
	return { type => 'literal', value => $1 } if $text =~ /^'(.*)'$/s || $text =~ /^"(.*)"$/s;
	return { type => 'literal', value => 0 + $text } if $text =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
	return { type => 'literal', value => 1 } if $text eq 'true' || $text eq 'True';
	return { type => 'literal', value => 0 } if $text eq 'false' || $text eq 'False';
	return { type => 'literal', value => undef } if $text eq 'none' || $text eq 'None' || $text eq 'null';

	# Nach den Literalen bleibt nur ein Datenpfad mit gueltigem Wurzelbezeichner
	# als zulaessige atomare Ausdrucksform uebrig.
	if ($text =~ /^([A-Za-z_][A-Za-z0-9_]*)(.*)$/s) {
		my ($root, $rest) = ($1, $2);
		my @path;
		my $get_default;

		# Erlaubt sind nur reine Datenpfade; Methodenaufrufe ausser .get werden
		# bereits beim Parsen verworfen.
		while ($rest ne '') {

			# Die erlaubten Zugriffsschreibweisen werden alle in denselben neutralen
			# Pfad umgewandelt, den der Evaluator spaeter ohne Methodenaufruf liest.
			if ($rest =~ s/^\.get\(\s*(['"])([^'"]+)\1\s*,\s*((?:'[^']*'|"[^"]*"|-?(?:\d+(?:\.\d*)?|\.\d+)|true|True|false|False|none|None|null))\s*\)//) {
				push @path, $2;
				$get_default = _parse_expression($3);
				return if !$get_default || $rest ne '';
			} elsif ($rest =~ s/^\.get\(\s*(['"])([^'"]+)\1\s*\)//) {
				push @path, $2;
			} elsif ($rest =~ s/^\.([A-Za-z_][A-Za-z0-9_]*)//) {
				push @path, $1;
			} elsif ($rest =~ s/^\[(\d+)\]//) {
				push @path, 0 + $1;
			} elsif ($rest =~ s/^\[['"]([^'"]+)['"]\]//) {
				push @path, $1;
			} else {
				return;
			}
		}

		my $path = { type => 'path', root => $root, path => \@path };
		return $get_default
			? { type => 'get', input => $path, default => $get_default }
			: $path;
	}
	return;
}

# Parst Vergleiche, Bedingungen und Filterketten mit definierter Bindungsreihenfolge.
sub _parse_expression {
	my ($text) = @_;
	$text = trim($text);
	return if $text eq '';

	# Bedingte Ausdruecke und Vergleiche werden vor Filtern gebunden. Das bildet
	# genau den dokumentierten sicheren Teil der HA-Templates ab.
	if ($text =~ /^(.*?)\s+if\s+(.+?)\s+else\s+(.*?)$/s) {
		my ($yes, $condition, $no) = ($1, $2, $3);
		my ($yes_ast, $condition_ast, $no_ast) = map { _parse_expression($_) } ($yes, $condition, $no);
		return if !$yes_ast || !$condition_ast || !$no_ast;
		return { type => 'if', condition => $condition_ast, yes => $yes_ast, no => $no_ast };
	}

	# EMS-ESP laesst bei reinen Zustandswerten den else-Zweig weg. Der fehlende
	# Zweig bleibt im AST absichtlich undefiniert und erzeugt damit keinen Wert.
	if ($text =~ /^(.*?)\s+if\s+(.+)$/s) {
		my ($yes, $condition) = ($1, $2);
		my ($yes_ast, $condition_ast) = map { _parse_expression($_) } ($yes, $condition);
		return if !$yes_ast || !$condition_ast;
		return { type => 'if', condition => $condition_ast, yes => $yes_ast };
	}

	# Die Jinja-Tests pruefen ausschliesslich die Existenz eines sicheren Datenpfads.
	# undefined ist dabei die gleichwertige Negation von defined.
	if ($text =~ /^(.*?)\s+is\s+((?:not\s+)?defined|undefined)$/s) {
		my ($input_source, $test) = ($1, $2);
		my $negated = $test eq 'defined' ? 0 : 1;
		my $input = _parse_expression($input_source);
		return if !$input || ($input->{type} || '') ne 'path';
		return { type => 'defined', input => $input, negated => $negated };
	}

	my @outer_filters = _split_outside($text, '|');

	# Zigbee2MQTT klammert einen Vergleich, bevor es dessen booleschen Wert
	# mit lower in ein JSON-Token umwandelt. Nur eine vollstaendig geklammerte
	# sichere Basis darf an dieser Stelle vor einer Filterkette stehen.
	if (@outer_filters > 1 && $outer_filters[0] =~ /^\((.*)\)$/s) {
		my $base = _parse_expression($1);
		return if !$base;
		shift @outer_filters;

		for my $filter (@outer_filters) {
			return if $filter !~ /^([A-Za-z_][A-Za-z0-9_]*)(?:\((.*)\))?$/s;
			my ($name, $argument) = ($1, $2);
			my $definition = $FILTERS{$name};
			return if !$definition;
			my $argument_count = defined($argument) && trim($argument) ne '' ? 1 : 0;
			return if $argument_count < $definition->{min_args}
				|| $argument_count > $definition->{max_args};
			my $argument_ast;

			# Filterargumente bleiben auch hinter einer geklammerten Basis auf das
			# bestehende sichere Ausdruckssubset beschraenkt.
			if (defined($argument) && trim($argument) ne '') {
				$argument_ast = _parse_expression($argument);
				return if !$argument_ast;
			}
			$base = { type => 'filter', name => $name, argument => $argument_ast, input => $base };
		}

		return $base;
	}

	for my $operator (qw(== != >= <= > <)) {

		# Der erste unterstuetzte Operator teilt den Ausdruck in zwei rekursiv zu
		# parsende Operanden; unvollstaendige Seiten machen das Template ungueltig.
		if ($text =~ /^(.*?)\s*\Q$operator\E\s*(.*?)$/s) {
			my ($left_source, $right_source) = ($1, $2);
			my ($left, $right) = (_parse_expression($left_source), _parse_expression($right_source));
			return if !$left || !$right;
			return { type => 'compare', operator => $operator, left => $left, right => $right };
		}
	}

	my @parts = _split_outside($text, '|');
	my $base = _parse_atom(shift @parts);
	return if !$base;

	for my $filter (@parts) {
		return if $filter !~ /^([A-Za-z_][A-Za-z0-9_]*)(?:\((.*)\))?$/s;
		my ($name, $argument) = ($1, $2);
		my $definition = $FILTERS{$name};

		# Nur zentral registrierte HA/Jinja-Filter duerfen Teil des sicheren AST
		# werden; unbekannte Namen werden nicht erst bei der Auswertung entdeckt.
		return if !$definition;
		my $argument_count = defined($argument) && trim($argument) ne '' ? 1 : 0;

		# Die Arity stammt aus derselben Definition wie Auswertung und Metadaten,
		# damit Erweiterungen nicht an mehreren Stellen auseinanderlaufen koennen.
		return if $argument_count < $definition->{min_args}
			|| $argument_count > $definition->{max_args};
		my $argument_ast;

		# Optionale Filterargumente durchlaufen denselben sicheren Parser wie der
		# Hauptausdruck und koennen daher keinen groesseren Sprachumfang oeffnen.
		if (defined($argument) && trim($argument) ne '') {
			$argument_ast = _parse_expression($argument);
			return if !$argument_ast;
		}
		$base = { type => 'filter', name => $name, argument => $argument_ast, input => $base };
	}

	return $base;
}

# Zerlegt ein reines Ausgabetemplate in sichere Literale und Ausdrucksknoten.
sub _parse_output_template {
	my ($template) = @_;
	my @parts;
	my ($position, $expressions) = (0, 0);

	# Nur {{ ... }} wird ausgewertet; Text dazwischen bleibt ein unveraendertes
	# Literal und erweitert den erlaubten Ausdrucksumfang nicht.
	while ($template =~ /\{\{\s*(.*?)\s*\}\}/gs) {
		my $literal = substr($template, $position, $-[0] - $position);
		return if $literal =~ /\{\{|\}\}|\{%|%\}/;
		push @parts, { type => 'literal', value => $literal } if $literal ne '';
		my $expression = _parse_expression($1);
		return if !$expression;
		push @parts, $expression;
		$position = $+[0];
		++$expressions;
	}

	my $tail = substr($template, $position);
	return if !$expressions || $tail =~ /\{\{|\}\}|\{%|%\}/;
	push @parts, { type => 'literal', value => $tail } if $tail ne '';
	return @parts == 1 ? $parts[0] : { type => 'concat', parts => \@parts };
}

# Parst einen flachen Jinja-if-Block mit beliebig vielen sicheren elif-Zweigen.
sub _parse_if_template {
	my ($template) = @_;
	return if $template !~ /^\s*\{%\s*if\s+(.+?)\s*%\}/s;
	my @branches;
	my $condition_source = $1;
	my $remaining = substr($template, $+[0]);

	# Jeder Zweig darf nur einen sicheren Ausdruck als Bedingung und ansonsten
	# unveraenderten Literaltext enthalten.
	while (1) {
		return if $remaining !~ /^(.*?)\{%\s*(?:(elif)\s+(.+?)|(else))\s*%\}/s;
		my ($output, $elif, $next_condition) = ($1, $2, $3);
		my $tag_end = $+[0];
		return if $output =~ /\{\{|\}\}|\{%|%\}/;
		my $condition = _parse_expression($condition_source);
		return if !$condition;
		push @branches, {
			condition => $condition,
			yes => { type => 'literal', value => $output },
		};
		$remaining = substr($remaining, $tag_end);

		# Nur elif fuehrt zu einem weiteren Bedingungszweig; else beendet die Kette.
		if (defined $elif) {
			$condition_source = $next_condition;
			next;
		}
		last;
	}

	return if $remaining !~ /^(.*?)\{%\s*endif\s*%\}\s*$/s;
	my $fallback = $1;
	return if $fallback =~ /\{\{|\}\}|\{%|%\}/;
	my $ast = { type => 'literal', value => $fallback };

	# Die umgekehrte Verschachtelung bildet die elif-Kette aus einfachen,
	# bereits sicher auswertbaren Bedingungsknoten ab.
	for my $branch (reverse @branches) {
		$ast = { type => 'if', %$branch, no => $ast };
	}

	return $ast;
}

# Kompiliert einen Template-Text einmalig in eine Folge aus Text- und AST-Segmenten.
sub compile {
	my ($template) = @_;
	return _fail('Template fehlt') if !defined $template;
	return _fail('Nicht unterstuetzte oder unsichere Template-Konstruktion')
		if $template =~ /(?:states\s*\(|state_attr\s*\(|is_state\s*\(|__|`|;|\{%-?\s*(?:for|macro|include|import))/;
	my $ast;

	# Einzelne Ausdruecke behalten ihre direkte AST-Form fuer die Pfadmetadaten;
	# flache if/elif/else-Bloecke werden in verschachtelte Bedingungsknoten zerlegt.
	if ($template =~ /^\s*\{\{\s*(.*?)\s*\}\}\s*$/s) {
		my $source = $1;
		$ast = _parse_expression($source)
			if $source !~ /\{\{|\}\}/;
	} else {
		$ast = _parse_if_template($template);
	}

	# Mehrere sichere Ausgabeausdruecke duerfen zu einem Text zusammengesetzt
	# werden, sofern keinerlei Blocksyntax oder unvollstaendige Klammer verbleibt.
	$ast = _parse_output_template($template)
		if !$ast && index($template, '{{') >= 0 && index($template, '{%') < 0;
	return _fail('Template liegt ausserhalb des unterstuetzten sicheren Subsets') if !$ast;
	return { ok => 1, ast => $ast, source => $template };
}

# Loest einen sicheren Datenpfad schrittweise in Hashes und Arrays auf.
sub _lookup {
	my ($context, $root, $path) = @_;
	return (0, undef) if !exists $context->{$root};
	my $value = $context->{$root};

	# Jeder Pfadschritt prueft Typ und Existenz, damit fehlende Daten nicht zu
	# Perl-Autovivifikation oder Warnungen fuehren.
	for my $part (@$path) {

		# Hash-Schluessel und Arrayindizes werden entsprechend dem aktuellen
		# Containertyp gelesen; jeder Typwechsel ausserhalb dieser Formen bricht ab.
		if (ref($value) eq 'HASH' && exists $value->{$part}) {
			$value = $value->{$part};
		} elsif (ref($value) eq 'ARRAY' && $part =~ /^\d+$/ && $part < @$value) {
			$value = $value->[$part];
		} else {
			return (0, undef);
		}
	}

	return (1, $value);
}

# Bildet Template-Werte nach den bewusst einfachen Wahrheitsregeln auf Boolean ab.
sub _truthy {
	my ($value, $exists) = @_;
	return 0 if !$exists || !defined($value) || !$value;
	return 1;
}

# Wertet einen validierten AST rekursiv ohne Ausfuehrung fremden Perl-Codes aus.
sub _evaluate_ast {
	my ($ast, $context) = @_;

	# Zusammengesetzte Ausgabetemplates werten jeden bereits sicher kompilierten
	# Teil aus und verbinden ihn ohne eine zweite Interpretationsstufe.
	if ($ast->{type} eq 'concat') {
		my $result = '';

		for my $part (@{ $ast->{parts} || [] }) {
			my ($exists, $value) = _evaluate_ast($part, $context);
			return (0, undef) if !$exists;
			$value = '' if !defined $value;
			$result .= ref($value) ? encode_json($value) : "$value";
		}

		return (1, $result);
	}

	# Literale sind bereits beim Kompilieren validiert und koennen direkt in die
	# Auswertung uebernommen werden.
	if ($ast->{type} eq 'literal') {
		return (1, $ast->{value});
	}

	# Pfadknoten delegieren Existenz- und Typbehandlung an den sicheren Lookup.
	if ($ast->{type} eq 'path') {
		return _lookup($context, $ast->{root}, $ast->{path});
	}

	# Jinja-dict.get mit Default liest zuerst denselben sicheren Pfad und wertet
	# den bereits kompilierten Fallback nur bei einem fehlenden Schluessel aus.
	if ($ast->{type} eq 'get') {
		my ($exists, $value) = _evaluate_ast($ast->{input}, $context);
		return ($exists, $value) if $exists;
		return _evaluate_ast($ast->{default}, $context);
	}

	# defined unterscheidet die Existenz bewusst vom Wahrheitswert. Vorhandene
	# Null-, False- und Leerwerte gelten deshalb ebenso als definiert wie Text.
	if ($ast->{type} eq 'defined') {
		my ($exists, undef) = _evaluate_ast($ast->{input}, $context);
		my $defined = $exists ? 1 : 0;
		return (1, $ast->{negated} ? ($defined ? 0 : 1) : $defined);
	}

	# Vergleiche werten zuerst beide Seiten aus; ein fehlender Operand ergibt
	# bewusst false statt einer impliziten Perl-Konvertierung.
	if ($ast->{type} eq 'compare') {
		my ($left_exists, $left) = _evaluate_ast($ast->{left}, $context);
		my ($right_exists, $right) = _evaluate_ast($ast->{right}, $context);
		return (1, 0) if !$left_exists || !$right_exists;

		# Zahlen werden numerisch, alle anderen skalaren Werte textuell verglichen.
		my $numeric = defined($left) && defined($right) && looks_like_number($left) && looks_like_number($right);
		my $operator = $ast->{operator};
		my $result = $operator eq '==' ? ($numeric ? $left == $right : "$left" eq "$right")
			: $operator eq '!=' ? ($numeric ? $left != $right : "$left" ne "$right")
			: $operator eq '>=' ? ($numeric ? $left >= $right : "$left" ge "$right")
			: $operator eq '<=' ? ($numeric ? $left <= $right : "$left" le "$right")
			: $operator eq '>'  ? ($numeric ? $left >  $right : "$left" gt "$right")
			:                    ($numeric ? $left <  $right : "$left" lt "$right");
		return (1, $result ? 1 : 0);
	}

	# Der Bedingungsknoten wertet nur den ausgewaehlten Zweig aus. Ein fehlender
	# else-Zweig unterdrueckt die Ausgabe wie ein undefinierter Jinja-Wert.
	if ($ast->{type} eq 'if') {
		my ($exists, $condition) = _evaluate_ast($ast->{condition}, $context);
		my $branch = _truthy($condition, $exists) ? $ast->{yes} : $ast->{no};
		return (0, undef) if !defined $branch;
		return _evaluate_ast($branch, $context);
	}

	# Filter bauen auf dem Ergebnis ihres Eingangsknotens auf und behandeln ein
	# optionales Argument getrennt vom eigentlichen Wert.
	if ($ast->{type} eq 'filter') {
		my ($exists, $value) = _evaluate_ast($ast->{input}, $context);
		my ($argument_exists, $argument) = $ast->{argument}
			? _evaluate_ast($ast->{argument}, $context) : (0, undef);
		my $name = $ast->{name};

		# Jinja stellt boolesche Vergleichsergebnisse als True/False dar; dadurch
		# liefern die Textfilter lower/upper die erwarteten JSON-Tokens.
		$value = $value ? 'True' : 'False'
			if ref($ast->{input}) eq 'HASH'
				&& ($ast->{input}{type} || '') eq 'compare'
				&& ($name eq 'lower' || $name eq 'upper');
		my $definition = $FILTERS{$name};
		return (0, undef) if !$definition || ref($definition->{evaluate}) ne 'CODE';

		# Jede Filtersemantik wird ausschliesslich ueber ihre zentrale Definition
		# ausgefuehrt; neue Filter benoetigen dadurch keinen zweiten Dispatch-Zweig.
		return $definition->{evaluate}->($exists, $value, $argument_exists, $argument);
	}
	return (0, undef);
}

# Rendert ein kompiliertes oder rohes Template gegen den uebergebenen Wertekontext.
sub render {
	my ($template, %args) = @_;
	my $compiled = ref($template) eq 'HASH' ? $template : compile($template);
	return $compiled if !$compiled->{ok};
	my $value = defined($args{value}) ? $args{value} : '';
	my %context = (value => $value, %{ $args{vars} || {} });

	# value_json wird nur aus echtem JSON aufgebaut. Ungueltiges JSON bleibt ein
	# normaler value-String fuer einfache Templates.
	if (!exists $context{value_json}) {
		my $decoded;
		$context{value_json} = $decoded if eval { $decoded = decode_json($value); 1 };
	}
	my ($exists, $result) = _evaluate_ast($compiled->{ast}, \%context);
	return _fail('Templatewert ist nicht vorhanden oder ungueltig') if !$exists;
	$result = '' if !defined $result;
	return { ok => 1, value => ref($result) ? encode_json($result) : "$result" };
}

# Extrahiert einen JSON-Pfad nach Massgabe einer zentralen Filtereigenschaft.
sub _json_key_with_filter_property {
	my ($template, $compiled, $property) = @_;

	# Nur ein erfolgreich kompiliertes Template besitzt einen vertrauenswuerdigen
	# AST; rohe oder strukturfremde Eingaben liefern bewusst keinen Namen.
	return undef if !defined($template) || ref($compiled) ne 'HASH';
	my $ast = $compiled->{ast};

	# Nur Filter mit der angeforderten Eigenschaft duerfen bis zum eigentlichen
	# Datenpfad durchlaufen werden; Argumente bleiben Teil der Werttransformation.
	while (ref($ast) eq 'HASH' && ($ast->{type} || '') eq 'filter') {
		my $definition = $FILTERS{ $ast->{name} || '' };
		return undef if !$definition || !$definition->{$property};
		$ast = $ast->{input};
	}

	# Nach dem Entfernen geeigneter Filter muss exakt ein nichtleerer value_json-
	# Pfad verbleiben; Bedingungen oder Literale besitzen keinen eindeutigen Key.
	return undef if ref($ast) ne 'HASH' || ($ast->{type} || '') ne 'path'
		|| ($ast->{root} || '') ne 'value_json' || ref($ast->{path}) ne 'ARRAY'
		|| !@{ $ast->{path} };
	my @parts;

	for my $part (@{ $ast->{path} }) {

		# Arrayindizes folgen der einsbasierten json2nameValue-Namenskonvention;
		# sichere Objektfelder koennen unveraendert in den Reading-Key eingehen.
		if (defined($part) && !ref($part) && $part =~ /^\d+$/) {
			push @parts, 1 + $part;
		} elsif (defined($part) && !ref($part) && $part =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
			push @parts, $part;
		} else {
			return undef;
		}
	}

	return join('_', @parts);
}

# Liefert den fachlichen JSON-Hauptpfad auch hinter wertveraendernden Filtern.
sub source_json_key {
	return _json_key_with_filter_property($_[0], $_[1], 'source_path');
}

# Liefert nur JSON-Pfade, die ohne Werttransformation direkt gerendert werden duerfen.
sub simple_json_key {
	return _json_key_with_filter_property($_[0], $_[1], 'value_identity');
}

1;
