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
is(value_of("{{ value_json.temperature if value_json.temperature is defined else 0 }}", '{"temperature":21.5}')->{value},
	'21.5', 'is defined waehlt bei vorhandenem Pfad den Wert');
is(value_of("{{ value_json.temperature if value_json.temperature is defined else 0 }}", '{}')->{value},
	'0', 'is defined waehlt bei fehlendem Pfad den Fallback');
is(value_of("{{ 'missing' if value_json.temperature is not defined else 'present' }}", '{}')->{value},
	'missing', 'is not defined erkennt einen fehlenden Pfad');
is(value_of('{% if value_json.active %}on{% else %}off{% endif %}', '{"active":true}')->{value}, 'on', 'If-Block');
is(value_of('{% if value_json.active is defined %}present{% else %}missing{% endif %}', '{"active":false}')->{value},
	'present', 'is defined funktioniert auch in einem If-Block');

subtest 'EMS-ESP optionale Werte und Klimamodus' => sub {
	# EMS-ESP verwendet dieselbe optionale Ausdrucksform fuer alle drei im Log
	# beanstandeten Analogwerte.
	for my $key (qw(core_voltage led supply_voltage)) {
		my $optional = "{{value_json['$key'] if value_json['$key'] is defined}}";
		is(value_of($optional, qq({"$key":3.3}))->{value}, '3.3',
			"ein Inline-if ohne else liefert $key bei vorhandenem Wert");
		ok(!value_of($optional, '{}')->{ok},
			"ein Inline-if ohne else unterdrueckt den fehlenden Wert $key");
	}

	my $availability = "{{'offline' if value_json.mode is undefined else 'online'}}";
	is(value_of($availability, '{}')->{value}, 'offline',
		'is undefined erkennt einen fehlenden EMS-Modus');
	is(value_of($availability, '{"mode":"Auto"}')->{value}, 'online',
		'is undefined bleibt bei vorhandenem EMS-Modus falsch');

	my $mode = q!{%if value_json.mode is undefined%}off{%elif value_json.mode=='Manuell'%}heat{%elif value_json.mode=='Tag'%}heat{%elif value_json.mode=='Nacht'%}off{%elif value_json.mode=='aus'%}off{%else%}auto{%endif%}!;
	is(value_of($mode, '{}')->{value}, 'off',
		'der erste EMS-Klimazweig behandelt einen fehlenden Modus');
	is(value_of($mode, '{"mode":"Manuell"}')->{value}, 'heat',
		'der erste elif-Zweig bildet Manuell auf heat ab');
	is(value_of($mode, '{"mode":"Nacht"}')->{value}, 'off',
		'ein spaeter elif-Zweig bildet Nacht auf off ab');
	is(value_of($mode, '{"mode":"Urlaub"}')->{value}, 'auto',
		'der else-Zweig bildet unbekannte EMS-Modi auf auto ab');
};

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
	for my $key (qw(zero false null empty)) {
		is(value_of("{{ 'yes' if value_json.$key is defined else 'no' }}",
			'{"zero":0,"false":false,"null":null,"empty":""}')->{value}, 'yes',
			"is defined behandelt $key als vorhandenen Wert");
	}
};

subtest 'Zigbee2MQTT-Update-Template' => sub {
	my $template = q!{"latest_version":"{{ value_json['update']['latest_version'] }}","installed_version":"{{ value_json['update']['installed_version'] }}","update_percentage":{{ value_json['update'].get('progress', 'null') }},"in_progress":{{ (value_json['update']['state'] == 'updating')|lower }}}!;
	my $updating = '{"update":{"latest_version":"1.164.0","installed_version":"1.163.1","progress":42,"state":"updating"}}';
	is(value_of($template, $updating)->{value},
		'{"latest_version":"1.164.0","installed_version":"1.163.1","update_percentage":42,"in_progress":true}',
		'mehrere Ausdruecke, get-Default und geklammerter Boolean werden gemeinsam gerendert');
	my $idle = '{"update":{"latest_version":"1.163.1","installed_version":"1.163.1","state":"idle"}}';
	is(value_of($template, $idle)->{value},
		'{"latest_version":"1.163.1","installed_version":"1.163.1","update_percentage":null,"in_progress":false}',
		'fehlender Fortschritt und falscher Vergleich ergeben gueltige JSON-Tokens');
};
for my $unsafe (
	"{{ states('sensor.example') }}",
	"{{ state_attr('light.example', 'brightness') }}",
	"{{ is_state('switch.example', 'on') }}",
	'{{ value.__class__ }}',
	'{{ value_json.get(dynamic_key) }}',
	'{{ value_json.x is callable }}',
	'{{ value_json.x is not undefined }}',
	'{{ (value_json.x == 1) is defined }}',
	"{{ value_json.get('safe').system('calc') }}",
	'{{ value; system("calc") }}',
	'{% if value %}{{ value }}{% else %}off{% endif %}',
	"{% if value %}on{% elif states('sensor.example') %}bad{% else %}off{% endif %}",
	'{% for x in items %}{{ x }}{% endfor %}',
) {
	ok(!MQTT2_Discovery::Template::compile($unsafe)->{ok}, "unsicheres Template abgelehnt: $unsafe");
}
ok(!value_of('{{ value_json.x }}', 'kein json')->{ok}, 'ungueltiges JSON liefert strukturierten Fehler');

done_testing;
