# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::Parser::Tasmota ();
use MQTT2_Discovery::Parser::Shelly ();
use MQTT2_Discovery::Format::Shelly ();
use MQTT2_Discovery::FormatRegistry ();
use JSON::PP qw(encode_json decode_json);
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

# Baut eine Tasmota-Discovery mit den Feldern, die den Namen bestimmen.
sub tasmota_config {
	my (%args) = @_;
	my $relays = $args{rl} || [1, 0];
	my $friendly = $args{fn} // ['Wasser'];
	return sprintf(
		'{"dn":"%s","fn":[%s],"hn":"host","mac":"%s","md":"%s","state":["OFF","ON"],'
			. '"t":"%s","ft":"%%prefix%%/%%topic%%/","tp":["cmnd","stat","tele"],"rl":[%s],'
			. '"so":{"4":0},%s"ver":1}',
		$args{dn} // 'Tasmota', join(',', map { "\"$_\"" } @$friendly),
		$args{mac} // '00005E005301', $args{md} // 'Generic',
		$args{t} // 'tasmota_005301', join(',', @$relays),
		defined($args{lt_st}) ? "\"lt_st\":$args{lt_st}," : '',
	);
}

# Liefert den Zielnamen, den der Mapper fuer die erste Entity vorschlaegt.
sub proposed_name {
	my ($entities) = @_;

	for my $entity (@{ $entities || [] }) {
		next if ($entity->{operation} // 'upsert') ne 'upsert';

		# Ein Adapter liefert entweder rohe Entities oder bereits kanonische
		# Modelle; beide Wege fuehren zu demselben Namensvorschlag.
		my $model = ref($entity->{entity}) eq 'HASH' ? $entity
			: MQTT2_Discovery::Model::from_entity(adapter => 'test', entity => $entity);
		my $mapping = MQTT2_Discovery::Mapper::map_model(model => $model, io_name => 'mqtt');
		return $mapping->{proposed_name} if $mapping->{ok};
	}

	return undef;
}

sub tasmota_name {
	my (%args) = @_;
	my $result = MQTT2_Discovery::Parser::Tasmota::parse(
		state => {}, topic => 'tasmota/discovery/00005E005301/config',
		payload => tasmota_config(%args), prefixes => ['tasmota/discovery'],
	);
	return proposed_name($result->{entities});
}

subtest 'ohne Kanalnamen gilt Name, Art und Kennung' => sub {
	is(tasmota_name(fn => []), 'Tasmota_Switch_005301',
		'aus Tasmota wird Tasmota_Switch_005301');
	is(tasmota_name(fn => [], rl => [2, 0]), 'Tasmota_Light_005301', 'ein Lichtkanal ergibt Light');
	is(tasmota_name(fn => [], rl => [1, 0], lt_st => 2), 'Tasmota_Light_005301',
		'auch der Lichttyp macht ein Licht daraus');
	is(tasmota_name(fn => [], rl => [3, 3]), 'Tasmota_Cover_005301', 'ein Rollladenpaar ergibt Cover');

	# Ohne Kennung im Topic bleibt das Ende der MAC.
	is(tasmota_name(fn => [], t => 'wasser'), 'Tasmota_Switch_005301',
		'ohne Kennung im Topic zaehlt das Ende der MAC');

	# Ein eigener Geraetename ersetzt den Vorgabenamen des Herstellers, mehr nicht.
	is(tasmota_name(fn => [], dn => 'Wasserpumpe'), 'Wasserpumpe_Switch_005301',
		'der eigene Geraetename steht vorn');
	is(tasmota_name(fn => [], dn => 'tasmota'), 'Tasmota_Switch_005301',
		'auch klein geschrieben ist es der Vorgabename');
};

subtest 'ein Kanalname ersetzt Art und Kennung' => sub {
	is(tasmota_name(), 'Tasmota_Wasser', 'aus dem Kanalnamen wird Tasmota_Wasser');
	is(tasmota_name(dn => 'Keller'), 'Keller_Wasser', 'mit eigenem Geraetenamen Keller_Wasser');

	# Bei mehreren Kanaelen beschreibt der Kanalname nicht mehr das Geraet.
	is(tasmota_name(rl => [1, 1], fn => ['Wasser', 'Licht']), 'Tasmota_Switch_005301',
		'mehrere Kanaele fallen auf Art und Kennung zurueck');
};

subtest 'Shelly ohne eigenen Namen traegt Hersteller, Art und Kennung' => sub {
	my $id = 'shelly1minig3-00005e005302';
	my $state = {};
	my %common = (state => $state, reply_prefix => 'mqtt2_discovery/test/shelly', now => 100);
	my $step = MQTT2_Discovery::Format::Shelly::begin(%common, mqtt_prefix => $id);
	my $info = { id => $id, gen => 3, model => 'S3SW-001X8EU', ver => '1.7.1', mac => '00005E005302' };

	# Ohne sys.device.name meldet das Geraet keinen eigenen Namen.
	my $config = {
		sys => { device => {} },
		mqtt => { topic_prefix => $id, status_ntf => JSON::PP::true },
		'switch:0' => { id => 0 },
	};
	my $status = {
		'switch:0' => { id => 0, output => JSON::PP::false },
		sys => { uptime => 1 },
	};

	for my $part ($info, $config, $status) {
		my $request = $step->{requests}[0] or last;
		my $rpc = decode_json($request->{payload});
		$step = MQTT2_Discovery::FormatRegistry::consume(
			%common, states => { shelly => $state },
			topic => "$rpc->{src}/rpc",
			payload => encode_json({ id => $rpc->{id}, src => $id, result => $part }),
		);
		last if $step->{status} ne 'ok';
	}
	is($step->{status}, 'ok', 'der Snapshot ist vollstaendig');
	is(proposed_name($step->{events}), 'Shelly_Switch_00005e005302',
		'ohne Geraetenamen entsteht Hersteller, Art und Kennung');
};

subtest 'ein belegter Name faellt auf Art und Kennung zurueck' => sub {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	main::MQTT2_DISCOVERY_activate($hash);

	# Ein fremdes Geraet belegt den Namen, den der Kanalname ergeben wuerde.
	$main::defs{Tasmota_Wasser} = { NAME => 'Tasmota_Wasser', TYPE => 'dummy', READINGS => {} };
	dispatch_message('mqtt', 'client1', 'tasmota/discovery/00005E005301/config', tasmota_config());
	ok($main::defs{Tasmota_Switch_005301}, 'das Geraet entsteht unter Art und Kennung');
	is($main::defs{Tasmota_Wasser}{TYPE}, 'dummy', 'das fremde Geraet bleibt unberuehrt');
};

done_testing();
