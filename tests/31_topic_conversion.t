# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Mapper::Renderer ();

sub render_reading {
	my ($topic, $device_topic, $conversion) = @_;
	local $MQTT2_Discovery::Mapper::Renderer::TOPIC_CONVERSION = $conversion;
	return MQTT2_Discovery::Mapper::Renderer::render_entry({
		kind => 'reading', topic => $topic, name => 'switch_0',
	}, $device_topic);
}

subtest 'Empfangstopics folgen der topicConversion des IODev' => sub {
	is(render_reading('haus/licht/status/switch:0', 'haus/licht', 1),
		'$DEVICETOPIC/status/switch_0:.* switch_0',
		'Doppelpunkt wird fuer den von FHEM umbenannten Empfangspfad ersetzt');
	is(render_reading('haus/licht/status/switch:0', 'haus/licht', 0),
		'$DEVICETOPIC/status/switch:0:.* switch_0',
		'abgeschaltete topicConversion behaelt den MQTT-Topicnamen');
};

subtest 'Ein Doppelpunkt im Geraetestamm veraendert kein Publish-Topic' => sub {
	is(render_reading('floor:1/device/status/switch:0', 'floor:1/device', 1),
		'floor_1/device/status/switch_0:.* switch_0',
		'Empfangsregel wird vollstaendig konvertiert statt mit rohem devicetopic gemischt');

	local $MQTT2_Discovery::Mapper::Renderer::TOPIC_CONVERSION = 1;
	is(MQTT2_Discovery::Mapper::Renderer::render_entry({
		kind => 'publish', name => 'switch_0', topic => 'floor:1/device/rpc', identity => 1,
	}, 'floor:1/device'), 'switch_0 $DEVICETOPIC/rpc',
		'ausgehendes Set verwendet weiterhin den unveraenderten MQTT-Geraetestamm');
};

done_testing();
