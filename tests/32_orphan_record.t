# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

reset_env();
add_iodev('mqtt');
my ($hash, $define_error) = define_discovery('discovery', 'mqtt');
is($define_error, undef, 'Discovery-Instanz ist definiert');
my $payload = '{"stat_t":"node/state","uniq_id":"node_state",'
	. '"dev":{"ids":["node"],"name":"Node"}}';
is(main::MQTT2_DISCOVERY_process(
	$hash, 'cid', 'homeassistant/sensor/node/state/config', $payload,
), 'consumed', 'erster Lauf erzeugt das verwaltete Zieldevice');
ok($main::defs{Node}, 'Zieldevice ist vorhanden');

my $registry = main::MQTT2_DISCOVERY_registry($hash);
my ($identity) = keys %{ $registry->{devices} };
ok(defined($identity), 'Registry enthaelt die Discovery-Identitaet');
main::CommandDelete(undef, 'Node');
ok(!$main::defs{Node}, 'Benutzerloeschung wurde simuliert');

my $batch_registry = main::MQTT2_DISCOVERY_clone_registry($registry);
my $batch = {
	registry => $batch_registry,
	delete_had_manual => {},
};
is(main::MQTT2_DISCOVERY_apply_batch_identity($hash, $batch, $identity), undef,
	'verwaister Batch-Eintrag verursacht keinen Apply-Fehler');
ok(!exists($batch_registry->{devices}{$identity}),
	'verwaister Eintrag wird aus dem Registry-Entwurf entfernt');

# Der reale Queue-Abschluss uebernimmt denselben bereinigten Entwurf als aktiven Stand.
$hash->{helper}{registry} = $batch_registry;
is(main::MQTT2_DISCOVERY_process(
	$hash, 'cid', 'homeassistant/sensor/node/state/config', $payload,
), 'consumed', 'erneute Ankuendigung wird nach der Bereinigung verarbeitet');
ok($main::defs{Node}, 'das Zieldevice kann regulaer neu angelegt werden');

done_testing();
