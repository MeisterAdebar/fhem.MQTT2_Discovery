# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Template ();

# Rendert ein Testtemplate und liefert direkt dessen Ergebniswert zurueck.
sub value_of {
	my ($template, $value, $vars) = @_;
	return MQTT2_Discovery::Template::render($template, value => $value, vars => $vars || {});
}

is(value_of('{{ value }}', ' AbC ')->{value}, ' AbC ', 'value bleibt unveraendert');
is(value_of('{{ value_json.temperature }}', '{"temperature":21.5}')->{value}, '21.5', 'JSON-Key');
is(value_of("{{ value_json.get('temperature') }}", '{"temperature":21.5}')->{value}, '21.5',
	'Jinja-dict.get mit literalem Schluessel');
is(value_of('{{ value_json.nested.value }}', '{"nested":{"value":"ok"}}')->{value}, 'ok', 'verschachtelter JSON-Pfad');
is(value_of('{{ items[0] }}', '', { items => ['first'] })->{value}, 'first', 'Arrayzugriff');
is(value_of('{{ value | lower }}', ' AbC ')->{value}, ' abc ', 'lower');
is(value_of('{{ value | upper | trim }}', ' abc ')->{value}, 'ABC', 'Filterkette');
is(value_of('{{ value | int }}', '12.9')->{value}, '12', 'int');
is(value_of('{{ value | float }}', '12.5')->{value}, '12.5', 'float');
is(value_of('{{ value | int(7) }}', 'ungueltig')->{value}, '7',
	'int verwendet den von HA vorgesehenen Fehler-Fallback');
is(value_of('{{ value | float(2.5) }}', 'ungueltig')->{value}, '2.5',
	'float verwendet den von HA vorgesehenen Fehler-Fallback');
is(value_of('{{ value_json.temperature | float | round(1) }}', '{"temperature":12.56}')->{value}, '12.6', 'round');
is(value_of('{{ value_json.temperature | is_defined }}', '{"temperature":21.5}')->{value}, '21.5',
	'is_defined reicht einen vorhandenen JSON-Wert unveraendert weiter');
ok(!value_of('{{ value_json.temperature | is_defined }}', '{}')->{ok},
	'is_defined unterdrueckt einen fehlenden JSON-Wert');
ok(!MQTT2_Discovery::Template::compile('{{ value | is_defined(1) }}')->{ok},
	'is_defined akzeptiert keine Argumente');
is(value_of('{{ value | default(7) }}', '0')->{value}, '0', 'default ersetzt gueltige Null nicht');
is(value_of('{{ missing | default(7) }}', '')->{value}, '7', 'default ersetzt fehlenden Wert');
is(value_of("{{ 'on' if value == 'ON' else 'off' }}", 'ON')->{value}, 'on', 'Ternary wahr');
is(value_of("{{ 'on' if value == 'ON' else 'off' }}", 'OFF')->{value}, 'off', 'Ternary falsch');
is(value_of('{% if value_json.active %}on{% else %}off{% endif %}', '{"active":true}')->{value}, 'on', 'If-Block');

subtest 'Filtermetadaten trennen Quellpfad und direkte Wertidentitaet' => sub {
	my $lower_template = '{{ value_json.permit_join | lower }}';
	my $lower = MQTT2_Discovery::Template::compile($lower_template);
	is(MQTT2_Discovery::Template::source_json_key($lower_template, $lower), 'permit_join',
		'lower behaelt permit_join als fachlichen Quellpfad');
	is(MQTT2_Discovery::Template::simple_json_key($lower_template, $lower), undef,
		'lower bleibt eine auszufuehrende Werttransformation');

	my $chain_template = '{{ value_json.log_level | upper | trim }}';
	my $chain = MQTT2_Discovery::Template::compile($chain_template);
	is(MQTT2_Discovery::Template::source_json_key($chain_template, $chain), 'log_level',
		'eine Kette pfaderhaltender Filter behaelt denselben Hauptpfad');
	is(MQTT2_Discovery::Template::simple_json_key($chain_template, $chain), undef,
		'wertveraendernde Filterketten werden nicht direkt als JSON-Identitaet behandelt');

	my $defined_template = '{{ value_json.temperature | is_defined }}';
	my $defined = MQTT2_Discovery::Template::compile($defined_template);
	is(MQTT2_Discovery::Template::simple_json_key($defined_template, $defined), 'temperature',
		'is_defined bleibt als unveraenderte Durchleitung direkt abbildbar');

	my $default_template = '{{ value_json.temperature | default(0) }}';
	my $default = MQTT2_Discovery::Template::compile($default_template);
	is(MQTT2_Discovery::Template::source_json_key($default_template, $default), undef,
		'default besitzt wegen seines alternativen Ergebniszweigs keinen eindeutigen Quellpfad');
	ok(!MQTT2_Discovery::Template::compile('{{ value | lower(1) }}')->{ok},
		'nicht von HA vorgesehene lower-Argumente werden zentral abgelehnt');
};

subtest 'fehlend, false, null und leer bleiben unterscheidbar' => sub {
	is(value_of('{{ value_json.zero | default(9) }}', '{"zero":0}')->{value}, '0', 'Null bleibt');
	is(value_of('{{ value_json.false | default(9) }}', '{"false":false}')->{value}, 'false', 'False bleibt');
	is(value_of('{{ value_json.null | default(9) }}', '{"null":null}')->{value}, '9', 'Null verwendet Default');
	is(value_of('{{ value_json.empty | default(9) }}', '{"empty":""}')->{value}, '', 'leerer String bleibt');
	is(value_of('{{ value_json.missing | default(9) }}', '{}')->{value}, '9', 'fehlender Key verwendet Default');
};

for my $unsafe (
	"{{ states('sensor.example') }}",
	"{{ state_attr('light.example', 'brightness') }}",
	"{{ is_state('switch.example', 'on') }}",
	'{{ value.__class__ }}',
	'{{ value_json.get(dynamic_key) }}',
	"{{ value_json.get('safe').system('calc') }}",
	'{{ value; system("calc") }}',
	'{% for x in items %}{{ x }}{% endfor %}',
) {
	ok(!MQTT2_Discovery::Template::compile($unsafe)->{ok}, "unsicheres Template abgelehnt: $unsafe");
}
ok(!value_of('{{ value_json.x }}', 'kein json')->{ok}, 'ungueltiges JSON liefert strukturierten Fehler');

done_testing;
