# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env);

my $foreign_calls = 0;

# Simuliert einen fremden JSON-Import mit Prototyp im gemeinsamen FHEM-Namensraum.
sub decode_json($) {
	$foreign_calls++;
	die "Discovery darf den fremden JSON-Decoder nicht verwenden\n";
}

my $foreign_decoder = \&decode_json;
my @load_warnings;
my $loaded;
{
	# Erfasst Importwarnungen unmittelbar beim Laden wie waehrend eines FHEM-Neustarts.
	local $SIG{__WARN__} = sub { push @load_warnings, @_ };
	$loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
	die $@ if $@;
	die $! if !defined $loaded;
}

ok($loaded, 'Hauptmodul laedt neben einem fremden JSON-Decoder');
is(\@load_warnings, [], 'Laden erzeugt keine Import- oder Prototypwarnung');
is(\&main::decode_json, $foreign_decoder, 'Fremder JSON-Decoder bleibt unveraendert');
is(prototype('main::decode_json'), '$', 'Fremder Funktionsprototyp bleibt erhalten');

is(main::MQTT2_DISCOVERY_log_payload('{"value":42,"password":"secret"}'),
	'{"password":"[REDACTED]","value":42}', 'Payload-Logging verwendet den eigenen JSON-Decoder');

# Ein noch laufender FHEM-Start haelt Nachrichten in der Queue und vermeidet Timeraktionen.
reset_env();
$main::init_done = 0;
my $hash = $main::defs{json_isolation} = {
	NAME => 'json_isolation',
	READINGS => {
		'.registry' => { VAL => '{"version":1,"devices":{"node":{"entities":{}}}}' },
	},
};
is(main::MQTT2_DISCOVERY_registry($hash),
	{ version => 1, devices => { node => { entities => {} } } },
	'Registry wird trotz fremdem JSON-Decoder vollstaendig geladen');

main::MQTT2_DISCOVERY_enqueue($hash, 'first', 'shellies/announce',
	'{"id":"shelly1g4-112233445566","gen":4,"model":"S4SW-001X16EU"}');
main::MQTT2_DISCOVERY_enqueue($hash, 'second', 'shellies/announce',
	'{"id":"shelly1g4-aabbccddeeff","gen":4,"model":"S4SW-001X16EU"}');
is(scalar(keys %{ $hash->{helper}{queue}{messages} }), 2,
	'Shelly-Announcements behalten trotz fremdem JSON-Decoder getrennte Queue-Eintraege');
is($foreign_calls, 0, 'Discovery hat den fremden JSON-Decoder nie aufgerufen');

done_testing;
