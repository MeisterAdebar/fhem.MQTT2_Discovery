# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::DevicePlanner ();

my $internal = 'mqtt2_discovery/discovery/shelly/0123456789abcdef/state/rpc';
my $component = 'mqtt2_discovery/discovery/shelly/0123456789abcdef/state/bthomesensor:203/rpc';

ok(MQTT2_Discovery::DevicePlanner::is_internal_topic($internal),
	'eigene Shelly-Statusantwort wird als internes Topic erkannt');
ok(MQTT2_Discovery::DevicePlanner::is_internal_topic($component),
	'eigene Komponenten-Antwort wird als internes Topic erkannt');
ok(!MQTT2_Discovery::DevicePlanner::is_internal_topic('mqtt2_discovery/user/device/status'),
	'aehnlich benanntes reales Geraet bleibt ein normales Nutzdatentopic');

my $record = { entities => { relay => { device_topic => 'haus/licht' } } };
is(MQTT2_Discovery::DevicePlanner::device_topic($record, [
	{ topic => $internal },
	{ topic => 'haus/licht/status/switch:0' },
	{ topic => 'haus/licht/rpc' },
]), 'haus/licht',
	'interne Antwort vergroessert das gemeinsame Shelly-devicetopic nicht');

is(MQTT2_Discovery::DevicePlanner::device_topic({ entities => {} }, [
	{ topic => $internal }, { topic => $component },
]), undef, 'ausschliesslich interne Antworttopics erzeugen kein devicetopic');

is(MQTT2_Discovery::DevicePlanner::device_topic({ entities => {} }, [
	{ topic => 'mqtt2_discovery/user/device/status' },
	{ topic => 'mqtt2_discovery/user/device/set' },
]), 'mqtt2_discovery/user/device',
	'der reserviert wirkende Root wird fuer echte Geraetetopics nicht pauschal ausgeschlossen');

done_testing();
