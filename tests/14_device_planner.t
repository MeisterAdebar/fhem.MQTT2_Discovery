# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::DevicePlanner ();

{
	package Local::PlannerGateway;
	# Protokolliert Attributaenderungen, damit ihre Ausfuehrungsreihenfolge sichtbar wird.
	sub new { return bless { calls => [] }, $_[0]; }
	sub set_attribute {
		my ($self, $device, $attribute, $value) = @_;
		push @{ $self->{calls} }, [$device, $attribute, $value];
		return undef;
	}
}

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => { one => { device_topic => 'node' } } },
	[{ topic => 'node/state' }, { topic => 'node/command' }],
), 'node', 'gemeinsames Devicetopic wird ohne FHEM-Zustand bestimmt');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} }, [{ topic => 'home/+/RTL_433toMQTT/model/42' }],
), 'home', 'Devicetopic endet vor einer MQTT-Wildcard');
is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} }, [{ topic => '+/+/RTL_433toMQTT/model/42' }],
), undef, 'fuehrende MQTT-Wildcards werden nicht als Devicetopic verwendet');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => { light => { device_topic => 'zigbee2mqtt' } } },
	[
		{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT' },
		{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set' },
		{ topic => 'zigbee2mqtt/bridge/state', role => 'availability' },
	],
), 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT',
	'tiefer gemeinsamer Nutzdatenstamm gewinnt gegen einen allgemeineren Parser-Vorschlag');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} },
	[
		{ topic => 'zigbee2mqtt/TK_TUER_BAD' },
		{ topic => 'zigbee2mqtt/TK_TUER_BAD/availability', role => 'availability' },
		{ topic => 'zigbee2mqtt/bridge/state', role => 'availability' },
	],
), 'zigbee2mqtt/TK_TUER_BAD',
	'geraeteeigene Availability belegt ein einzelnes Nutzdaten-Topic als Geraetestamm');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} },
	[
		{ topic => 'tele/plug/STATE' },
		{ topic => 'stat/plug/RESULT' },
		{ topic => 'cmnd/plug/POWER' },
	],
), undef, 'Tasmota-Standardtopics erhalten kein kuenstliches gemeinsames Prefix');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} },
	[
		{ topic => 'plug/tele/STATE' },
		{ topic => 'plug/stat/RESULT' },
		{ topic => 'plug/cmnd/POWER' },
	],
), 'plug', 'ein device-first Tasmota-FullTopic kann den sicheren gemeinsamen Stamm nutzen');

my @conflicts;
my ($prepared, $current) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', 'manual/topic:.* temperature', [],
	[{ kind => 'json_reading', name => 'temperature', topic => 'node/state' }],
	\@conflicts,
);
is($prepared, [], 'manuelle JSON-Kollision gewinnt im konservativen Modus');
is($current, 'manual/topic:.* temperature', 'manuelle Konfiguration bleibt unveraendert');
is(\@conflicts, ['temperature'], 'Konflikt wird deklarativ gemeldet');

my $manual_json = q!$DEVICETOPIC/state:.* { json2nameValue($EVENT,'',$JSONMAP) }!;
my @topic_conflicts;
my ($topic_prepared, $topic_current) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', $manual_json, [],
	[
		{ kind => 'json_autocreate', name => 'state', topic => 'node/state' },
		{ kind => 'json_reading', name => 'temperature', topic => 'node/state' },
		{ kind => 'availability', role => 'availability', name => 'availability', topic => 'node/state' },
		{ kind => 'json_autocreate', name => 'other', topic => 'node/other' },
	],
	\@topic_conflicts, 'node', 'client',
);
is($topic_prepared, [
	{ kind => 'availability', role => 'availability', name => 'availability', topic => 'node/state' },
	{ kind => 'json_autocreate', name => 'other', topic => 'node/other' },
], 'manueller Sammelhandler verdraengt nur JSON-Auswertungen desselben Topics');
is($topic_current, $manual_json, 'manueller JSON-Sammelhandler bleibt unveraendert');
is(\@topic_conflicts, [qw(state temperature)],
	'alle vom manuellen Sammelhandler verdraengten Namen werden als Konflikt gemeldet');

my @sequence_conflicts;
my ($sequence_prepared) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', q!tele/node/INFO.:.* { json2nameValue($EVENT,'',$JSONMAP) }!, [],
	[{
		kind => 'json_sequence', name => 'INFO', topic => 'tele/node/INFO',
		parts => [1, 2, 3],
	}],
	\@sequence_conflicts,
);
is($sequence_prepared, [], 'breiter manueller INFO-Handler deckt die gesamte Sequenz ab');
is(\@sequence_conflicts, ['INFO'], 'abgedeckte JSON-Sequenz wird als Konflikt gemeldet');

my @partial_sequence_conflicts;
my ($partial_sequence) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', q!tele/node/INFO1:.* { json2nameValue($EVENT,'',$JSONMAP) }!, [],
	[{
		kind => 'json_sequence', name => 'INFO', topic => 'tele/node/INFO',
		parts => [1, 2, 3],
	}],
	\@partial_sequence_conflicts,
);
is(scalar(@$partial_sequence), 1,
	'ein manueller Handler fuer nur INFO1 verdraengt die vollstaendige Sequenz nicht');
is(\@partial_sequence_conflicts, [], 'Teilabdeckung wird nicht als Topickonflikt gemeldet');

my @prefixed_conflicts;
my ($prefixed_json) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', q!node/state:.* { json2nameValue($EVENT,'state_',$JSONMAP) }!, [],
	[{ kind => 'json_autocreate', name => 'state', topic => 'node/state' }],
	\@prefixed_conflicts,
);
is(scalar(@$prefixed_json), 1,
	'ein praefixierter manueller JSON-Handler ersetzt keine unpraefixierte Discovery-Auswertung');
is(\@prefixed_conflicts, [], 'abweichender JSON-Namensraum wird nicht als Topickonflikt gemeldet');

my $plan = MQTT2_Discovery::DevicePlanner::attribute_plan(
	device => 'node', manage_device_topic => 1, device_topic => 'node',
	previous_device_topic_exists => 0,
	reading_list => 'state', previous_reading_list_exists => 1,
	previous_reading_list => 'old-state',
	set_list => 'power', previous_set_list_exists => 0,
);
my $gateway = Local::PlannerGateway->new;
is($plan->execute($gateway), undef, 'Device-Plan ist ausfuehrbar');
is([map { $_->[1] } @{ $gateway->{calls} }],
	[qw(devicetopic readingList setList)],
	'Device-Plan verwendet die atomare Schreibreihenfolge');

done_testing;
