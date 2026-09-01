# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::FHEMGateway ();

my (%attributes, @commands, @readings, @deleted_readings, @timers, @integrations,
	@cid_lookups, @iodev_lookups);
my $gateway = MQTT2_Discovery::FHEMGateway->new(
	attr_value => sub {
		my ($device, $attribute, $default) = @_;
		return exists($attributes{$device}{$attribute}) ? $attributes{$device}{$attribute} : $default;
	},
	attribute_state => sub {
		my ($device, $attribute) = @_;
		return exists($attributes{$device}{$attribute})
			? (1, $attributes{$device}{$attribute}) : (0, undef);
	},
	command_attr => sub {
		my ($definition) = @_;
		push @commands, "attr $definition";
		my ($device, $attribute, $value) = split /\s+/, $definition, 3;
		$attributes{$device}{$attribute} = $value;
		return undef;
	},
	command_delete_attr => sub {
		my ($definition) = @_;
		push @commands, "deleteattr $definition";
		my ($device, $attribute) = split /\s+/, $definition, 2;
		delete $attributes{$device}{$attribute};
		return undef;
	},
	update_reading => sub { push @readings, [@_]; return undef; },
	delete_reading => sub { push @deleted_readings, [@_]; return undef; },
	schedule => sub { push @timers, [@_]; return undef; },
	semantic_integration_end => sub { push @integrations, ['end', @_]; return 1; },
	mqtt2_devices_for_cid => sub {
		push @cid_lookups, $_[0];
		return [{ NAME => 'UmbenanntesDevice', TYPE => 'MQTT2_DEVICE', CID => $_[0] }];
	},
	mqtt2_devices_for_iodev => sub {
		push @iodev_lookups, $_[0];
		return [{ NAME => 'BrokerDevice', TYPE => 'MQTT2_DEVICE', IODev => $_[0] }];
	},
);

is($gateway->attr_value('device', 'missing', 'fallback'), 'fallback',
	'Lesezugriff ist injizierbar');
is($gateway->mqtt2_devices_for_cid('client-id')->[0]{NAME}, 'UmbenanntesDevice',
	'FHEM-CID-Zuordnung ist ueber das Gateway injizierbar');
is(\@cid_lookups, ['client-id'], 'CID wird unveraendert an die Zielaufloesung uebergeben');
my $lookup_iodev = { NAME => 'server', TYPE => 'MQTT2_SERVER' };
is($gateway->mqtt2_devices_for_iodev($lookup_iodev)->[0]{NAME}, 'BrokerDevice',
	'FHEM-IODev-Zuordnung ist ueber das Gateway injizierbar');
is(\@iodev_lookups, [$lookup_iodev],
	'IODev wird unveraendert an die Zielaufloesung uebergeben');
is($gateway->set_attribute('device', 'mode', 'auto'), undef, 'Attribut wird geschrieben');
is($gateway->set_attribute('device', 'mode', 'auto'), undef, 'identischer Wert ist ein No-op');
is($gateway->set_attribute('device', 'mode', ''), undef, 'Attribut wird geloescht');
is(\@commands, ['attr device mode auto', 'deleteattr device mode'],
	'Gateway dedupliziert und kapselt konkrete FHEM-Kommandos');

$gateway->update_reading({ NAME => 'discovery' }, 'state', 'active', 1);
$gateway->delete_reading({ NAME => 'target' }, 'OldAvailability');
$gateway->schedule(0.01, { NAME => 'discovery' }, 'callback');
is($readings[0][1], 'state', 'Reading-Callback erhaelt den Reading-Namen');
is($deleted_readings[0][1], 'OldAvailability',
	'Loesch-Callback erhaelt genau den zuvor geprueften Reading-Namen');
is($timers[0][2], 'callback', 'Timer-Callback erhaelt die Zielfunktion');
ok($gateway->can_schedule, 'injizierter Scheduler ist erkennbar');
$gateway->semantic_integration_end('NeuesDevice');
is(\@integrations, [
	['end', 'NeuesDevice'],
], 'optionales Fertig-Signal ist injizierbar');

{
	my $iodev = { NAME => 'server', TYPE => 'MQTT2_SERVER' };
	my $other_iodev = { NAME => 'otherServer', TYPE => 'MQTT2_SERVER' };
	no warnings 'once';
	local %main::defs = (
		server => $iodev,
		otherServer => $other_iodev,
		Alpha => { NAME => 'Alpha', TYPE => 'MQTT2_DEVICE', IODev => $iodev },
		Zulu => { NAME => 'Zulu', TYPE => 'MQTT2_DEVICE', IODev => $iodev },
		Other => { NAME => 'Other', TYPE => 'MQTT2_DEVICE', IODev => $other_iodev },
		Dummy => { NAME => 'Dummy', TYPE => 'dummy', IODev => $iodev },
	);
	my $native_gateway = MQTT2_Discovery::FHEMGateway->new();
	my $devices = $native_gateway->mqtt2_devices_for_iodev($iodev);

	# Der Vergleich der Namen prueft zugleich Filterung und stabile alphabetische Reihenfolge.
	is([ map { $_->{NAME} } @$devices ], [qw(Alpha Zulu)],
		'nativer IODev-Scan liefert nur passende lebende MQTT2_DEVICEs');
	is($native_gateway->mqtt2_devices_for_iodev({ NAME => 'server' }), [],
		'eine veraltete IODev-Referenz liefert keine Devices');
}

{
	my $target = {
		NAME => 'target', READINGS => { RetainedReading => { VAL => 'alt' } },
	};
	my $definition;
	no warnings qw(once redefine);
	local *main::CommandDeleteReading = sub {
		(undef, $definition) = @_;
		delete $target->{READINGS}{RetainedReading};
		return 'Deleted reading RetainedReading for device target';
	};
	my $native_gateway = MQTT2_Discovery::FHEMGateway->new();
	is($native_gateway->delete_reading($target, 'RetainedReading'), undef,
		'FHEM-Erfolgstext beim Loeschen wird als Erfolg normalisiert');
	is($definition, 'target ^RetainedReading$',
		'das native deletereading erhaelt ein exakt begrenztes Readingmuster');
	ok(!exists($target->{READINGS}{RetainedReading}),
		'der Regressionstest bildet den tatsaechlich geloeschten FHEM-Zustand ab');
}

{
	my $target = {
		NAME => 'target', READINGS => { RetainedReading => { VAL => 'alt' } },
	};
	no warnings qw(once redefine);
	local *main::CommandDeleteReading = sub {
		return 'deletereading konnte nicht ausgefuehrt werden';
	};
	my $native_gateway = MQTT2_Discovery::FHEMGateway->new();
	like($native_gateway->delete_reading($target, 'RetainedReading'),
		qr/konnte nicht ausgefuehrt/, 'ein weiterhin vorhandenes Reading bleibt ein Fehler');
	ok(exists($target->{READINGS}{RetainedReading}),
		'der Fehlerfall laesst den unveraenderten Readingzustand sichtbar');
}

{
	my @packets;
	my $client = {
		NAME => 'mqtt', TYPE => 'MQTT2_CLIENT', STATE => 'opened', FD => 7,
	};
	no warnings qw(once redefine);
	local *main::MQTT2_CLIENT_send = sub {
		my ($iodev, $packet, $immediate, $do_send) = @_;
		push @packets, [$iodev, $packet, $immediate, $do_send];
		return;
	};
	is($gateway->refresh_retained_topic($client, 'zigbee2mqtt/node/availability'), undef,
		'gezielter Retained-Abruf wird als MQTT-SUBSCRIBE gesendet');
	is(scalar(@packets), 1, 'genau ein MQTT-Paket wird erzeugt');
	my $packet = $packets[0][1];
	is(ord(substr($packet, 0, 1)), 0x82, 'Paket besitzt den SUBSCRIBE-Fixed-Header');
	my $payload = substr($packet, 2);
	my $topic_length = unpack('n', substr($payload, 2, 2));
	is(substr($payload, 4, $topic_length), 'zigbee2mqtt/node/availability',
		'das Paket abonniert ausschliesslich das angeforderte Topic');
	is(ord(substr($payload, 4 + $topic_length, 1)), 0,
		'SUBSCRIBE fordert QoS 0 an');
	is($packets[0][3], 1, 'vollstaendig verbundener Client sendet das Paket unmittelbar frei');
	like($gateway->refresh_retained_topic($client, 'invalid/#'), qr/ungueltige Zeichen/,
		'MQTT-Wildcards werden nicht als exaktes Availability-Topic akzeptiert');
}

done_testing;
