# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use lib 'lib/FHEM';
use MQTT2_Discovery::Parser::Shelly ();

my $id = 'shelly1g4-aabbccddeeff';
my $prefix = 'haus/licht';
my $reply = 'mqtt2_discovery/discovery/shelly/0123456789abcdef/state/rpc';

sub parse_switch {
	my ($rpc_ntf, $status_ntf) = @_;
	return MQTT2_Discovery::Parser::Shelly::parse(
		info => { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1' },
		config => {
			sys => { device => { name => 'Werkstatt' } },
			mqtt => {
				topic_prefix => $prefix,
				rpc_ntf => $rpc_ntf ? JSON::PP::true : JSON::PP::false,
				status_ntf => $status_ntf ? JSON::PP::true : JSON::PP::false,
			},
			'switch:0' => { id => 0 },
		},
		status => {
			sys => { uptime => 10 },
			'switch:0' => { id => 0, output => JSON::PP::true },
		},
		mqtt_prefix => $prefix,
		discovery_topic => "shelly/$id/config",
		state_topic => $reply,
		component_reply => 'mqtt2_discovery/discovery/shelly/0123456789abcdef/state',
	);
}

sub relay {
	my ($result) = @_;
	return (grep { ($_->{object_id} || '') eq 'switch_0' } @{ $result->{entities} })[0];
}

sub topics {
	my ($entity) = @_;
	return [$entity->{state_topic}, map { $_->{topic} } @{ $entity->{supplemental_signals} || [] }];
}

subtest 'Nur aktivierte Shelly-Pushwege werden gebunden' => sub {
	my $status_only = parse_switch(0, 1);
	is($status_only->{status}, 'ok', 'Snapshot mit status_ntf ist gueltig');
	is(topics(relay($status_only)), ["$prefix/status/switch:0", $reply],
		'status_ntf nutzt Komponentenstatus und behaelt die eigene Antwort als Initialquelle');

	my $rpc_only = parse_switch(1, 0);
	is(topics(relay($rpc_only)), [$reply, "$prefix/events/rpc"],
		'rpc_ntf nutzt Ereignisse und die eigene Antwort als primaere Initialquelle');

	my $both = parse_switch(1, 1);
	is(topics(relay($both)), ["$prefix/status/switch:0", "$prefix/events/rpc", $reply],
		'beide aktivierten Pushwege werden gemeinsam beruecksichtigt');
};

subtest 'Abgeschaltete Pushwege erzeugen keine toten readingList-Pfade' => sub {
	my $none = parse_switch(0, 0);
	is(topics(relay($none)), [$reply],
		'ohne Pushmeldungen bleibt nur die von Discovery angeforderte Antwort');
	like(join("\n", @{ $none->{warnings} }), qr/weder rpc_ntf noch status_ntf aktiv/,
		'fehlende laufende Aktualisierung wird sichtbar gemeldet');

	my $blu = MQTT2_Discovery::Parser::Shelly::parse(
		info => { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1' },
		config => {
			sys => { device => { name => 'Werkstatt' } },
			mqtt => { topic_prefix => $prefix,
				rpc_ntf => JSON::PP::false, status_ntf => JSON::PP::false },
		},
		status => {
			sys => { uptime => 10 },
			'bthomesensor:203' => { id => 203, value => JSON::PP::true },
		},
		mqtt_prefix => $prefix,
		discovery_topic => "shelly/$id/config",
		state_topic => $reply,
		component_reply => 'mqtt2_discovery/discovery/shelly/0123456789abcdef/state',
	);
	my @blu_topics = map { @{ topics($_) } }
		grep { ($_->{object_id} || '') =~ /\Abthomesensor_203/ } @{ $blu->{entities} };
	ok(!grep({ $_ eq "$prefix/events/rpc" } @blu_topics),
		'auch BLU-Ereignisfelder binden kein abgeschaltetes RPC-Topic');
};

done_testing();
