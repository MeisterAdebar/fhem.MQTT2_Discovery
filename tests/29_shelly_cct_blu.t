# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::Format::Shelly ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);
my $id = 'shellyduobulbg3-9070694a9e14';
my $prefix = 'haus/lampe';
my $target = 'ShellyTest';
my $info = { id => $id, gen => 3, model => 'S3BL-DUO', ver => '2.0.0' };
my @published;

# Baut die dokumentierten CCT-Felder mit einem individuell konfigurierten Kelvinbereich.
sub config {
	return {
		sys => { device => { name => $target } },
		mqtt => { topic_prefix => $prefix, rpc_ntf => JSON::PP::true },
		'cct:0' => { id => 0, ct_range => [2200, 7000] },
	};
}

# Entspricht den im Forum gezeigten Messwerten einschliesslich optionaler Leistungsmessung.
sub status {
	return {
		sys => { uptime => 30 }, wifi => { rssi => -54 },
		'cct:0' => { id => 0, output => JSON::PP::true, brightness => 50, ct => 4600,
			apower => 4.5, aenergy => { total => 12 } },
	};
}

# Simuliert FHEM und MQTT ausschliesslich im Prozess, ohne Dateien oder Netzwerkzugriffe.
sub setup {
	my ($type) = @_;
	reset_env();
	add_iodev('mqtt', $type || 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		publish_mqtt => sub {
			my (undef, $topic, $payload) = @_;
			push @published, { topic => $topic, payload => $payload };
			return undef;
		},
	);
	main::MQTT2_DISCOVERY_activate($hash);
	@published = ();
	return $hash;
}

# Beantwortet genau die naechste Anfrage mit ihrer eigenen Request-ID und Rueckadresse.
sub reply {
	my ($result, $method) = @_;
	my $request = shift @published;
	die 'Erwartete MQTT-Abfrage fehlt' if !$request;
	my $rpc = decode_json($request->{payload});
	is($rpc->{method}, $method, 'erwartete lesende RPC-Methode');
	dispatch_message('mqtt', 'shelly-client', "$rpc->{src}/rpc",
		encode_json({ id => $rpc->{id}, src => $id, result => $result }));
	return $rpc;
}

# Liefert den statischen Snapshot; bei BTHome bleibt die Komponentenabfrage noch offen.
sub discover {
	my ($hash, $config, $status) = @_;
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'discoverShelly', $prefix), undef, 'Discovery gestartet');
	reply($info, 'Shelly.GetDeviceInfo');
	reply($config || config(), 'Shelly.GetConfig');
	reply($status || status(), 'Shelly.GetStatus');
}

# Wertet die generierten Runtime-Bindings fuer Komponentenstatus, RPC und Ereignisse aus.
sub readings {
	my ($topic, $data) = @_;
	my $payload = encode_json($data);
	my %updates;

	for my $line (split /\n/, attr_value($target, 'readingList')) {
		my ($pattern) = split /\s+/, $line, 2;
		my $device_topic = attr_value($target, 'devicetopic');
		$pattern =~ s/\$DEVICETOPIC/\Q$device_topic\E/g;
		next if "$topic:$payload" !~ /^$pattern$/s;
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
		next if !defined($reference);
		my $values = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, $payload);
		@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
	}

	return \%updates;
}

# Prueft den tatsaechlichen MQTT-Payload, den MQTT2_DEVICE aus dem Set erzeugen wuerde.
sub command {
	my ($name, $value) = @_;
	my ($line) = grep { /^\Q$name\E:/ } split /\n/, attr_value($target, 'setList');
	my ($reference) = ($line || '') =~ /'(r_[a-f0-9]+)'/;
	return undef if !defined($reference);
	my $message = main::MQTT2_DISCOVERY_runtimeRef($target, $reference, "$name $value");
	return undef if !defined($message);
	my ($topic, $payload) = split / /, $message, 2;
	is($topic, "$prefix/rpc", 'Befehl erreicht den individuellen Shelly-Prefix');
	return decode_json($payload);
}

# Stellt eine dokumentierte Seite der dynamischen Komponenten zusammen.
sub page {
	my ($offset, $total, @components) = @_;
	return { offset => $offset, total => $total, cfg_rev => 42, components => \@components };
}

# Die Konfiguration enthaelt absichtlich nicht zu persistierende Zusatzdaten.
sub dynamic {
	my ($key, $values) = @_;
	my ($channel) = $key =~ /:(\d+)$/;
	return { key => $key, status => { id => 0 + $channel, %$values },
		config => { id => 0 + $channel, key => 'darf-nicht-in-den-cache', meta => { private => 'verwerfen' } } };
}

subtest 'CCT ist ueber SERVER und CLIENT vollstaendig steuerbar' => sub {

	for my $type (qw(MQTT2_SERVER MQTT2_CLIENT)) {
		my $hash = setup($type);
		discover($hash);
		ok($main::defs{$target}, 'Duo Bulb wurde angelegt');
		is(reading_value('discovery', 'warningCount'), 0, 'keine Warnung fuer CCT');
		like(attr_value($target, 'setList'), qr/^cct_0_brightness:slider,0,1,100 /m, 'Helligkeit verwendet Prozent');
		like(attr_value($target, 'setList'), qr/^cct_0_ct:slider,2200,1,7000 /m, 'konfigurierter Kelvinbereich wurde uebernommen');
		is(command('cct_0', 'on')->{params}, { id => 0, on => JSON::PP::true }, 'on sendet echtes JSON-Boolean');
		is(command('cct_0', 'off')->{method}, 'CCT.Set', 'CCT verwendet den eigenen RPC-Namensraum');
		is(command('cct_0_brightness', 0)->{params}, { id => 0, brightness => 0 }, 'Null ist ein gueltiger Helligkeitswert');
		is(command('cct_0_ct', 4600)->{params}, { id => 0, ct => 4600 }, 'Kelvin bleiben unveraendert');

		# Weder ungueltige Zahlen noch angehaengtes JSON duerfen einen MQTT-Befehl erzeugen.
		for my $bad (-1, 101, 'kaputt', '50,"on":true', 'NaN', 'Inf') {
			is(command('cct_0_brightness', $bad), undef, "ungueltige Helligkeit abgefangen: $bad");
		}

		is(command('cct_0_ct', 7001), undef, 'Farbtemperatur ausserhalb des Bereichs abgefangen');
		my $initial = decode_json($published[0]{payload});
		my $values = readings("$initial->{src}/rpc", { src => $id, result => status() });
		is([@{$values}{qw(cct_0 cct_0_brightness cct_0_ct cct_0_power cct_0_energy)}],
			['true', 50, 4600, 4.5, 12], 'Initialwerte und Messwerte werden gelesen');
		$values = readings("$prefix/events/rpc", { method => 'NotifyStatus', params => { 'cct:0' => { ct => 3000 } } });
		is($values, { cct_0_ct => 3000 }, 'Teilstatus ueberschreibt keine fehlenden Werte');
		$values = readings("$prefix/status/cct:0", { output => JSON::PP::false, brightness => 25 });
		is($values, { cct_0 => 'false', cct_0_brightness => 25 }, 'Komponentenstatus verwendet dieselben Namen');
	}

};

subtest 'CCT-Standardbereich und unvollstaendige Snapshots' => sub {
	my $hash = setup();
	my $config = config();
	delete $config->{'cct:0'}{ct_range};
	discover($hash, $config);
	like(attr_value($target, 'setList'), qr/^cct_0_ct:slider,2700,1,6500 /m, 'dokumentierter Duo-Bulb-Standard');

	# Fehlerhafte Aktoren duerfen keine unvollstaendige Definition erzeugen.
	for my $field (qw(output brightness ct)) {
		$hash = setup();
		my $status = status();
		delete $status->{'cct:0'}{$field};
		discover($hash, config(), $status);
		ok(!$main::defs{$target}, "fehlendes $field verhindert Teilgeraet");
		is(reading_value('discovery', 'errorCount'), 1, 'Fehler bleibt sichtbar');
	}

	$hash = setup();
	$config = config();
	$config->{'cct:0'}{ct_range} = [7000, 2200];
	discover($hash, $config);
	ok(!$main::defs{$target}, 'absteigender Bereich wird abgelehnt');
};

subtest 'BLU-Seiten, schlafende Sensoren, Initialwerte und Ereignisarrays' => sub {
	my $hash = setup();
	my $status = status();
	$status->{bthome} = {};
	discover($hash, config(), $status);
	ok(!$main::defs{$target}, 'statischer Snapshot wartet auf dynamische Komponenten');
	my $request = reply(page(0, 4,
		dynamic('bthomedevice:200', { battery => 95, rssi => -58, packet_id => 10, last_update_ts => 100 }),
		dynamic('bthomesensor:201', { value => undef, last_update_ts => 0 })), 'Shelly.GetComponents');
	is($request->{params}, { offset => 0, include => ['config', 'status'], dynamic_only => JSON::PP::true }, 'nur dynamische Komponenten mit Config und Status angefordert');
	ok(!$main::defs{$target}, 'erste Seite erzeugt noch kein Teilgeraet');
	$request = reply(page(2, 4,
		dynamic('bthomedevice:202', { battery => undef, rssi => undef }),
		dynamic('bthomesensor:203', { value => JSON::PP::false, last_updated_ts => 100 })), 'Shelly.GetComponents');
	is($request->{params}{offset}, 2, 'zweite Seite beginnt nach der ersten');
	ok($main::defs{$target}, 'vollstaendiger Snapshot erzeugt genau ein Gateway-Device');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'BLU-Readings gehoeren zum Shelly-Gateway');
	is(reading_value('discovery', 'warningCount'), 0, 'BTHome wird ohne Warnung abgebildet');
	is(scalar(@published), 5, 'statischer Status und vier dynamische Initialabfragen erst nach dem Apply');
	my ($initial) = map { decode_json($_->{payload}) }
		grep { decode_json($_->{payload})->{src} =~ m{/bthomesensor:203$} } @published;
	is($initial->{method}, 'BTHomeSensor.GetStatus', 'passende Initialabfrage fuer den BLU-Sensor');
	my $values = readings("$initial->{src}/rpc", { src => $id, result => { id => 203, value => JSON::PP::false, last_updated_ts => 100 } });
	is($values, { bthomesensor_203 => 'false', bthomesensor_203_last_update => 100 }, 'Boolean und Zeitstempel aus Einzelabfrage');
	$values = readings("$prefix/events/rpc", { method => 'NotifyStatus', params => {
		'bthomesensor:201' => { value => 21.5, last_updated_ts => 200 },
		'bthomedevice:200' => { battery => 94, rssi => -60 },
	} });
	is([@{$values}{qw(bthomesensor_201 bthomesensor_201_last_update bthomedevice_200_battery bthomedevice_200_rssi)}],
		[21.5, 200, 94, -60], 'spaeterer Sensorwert und alternative Zeitstempelschreibweise');
	ok(!exists($values->{bthomesensor_203}), 'fremder Sensor wird nicht veraendert');
	$values = readings("$prefix/events/rpc", { method => 'NotifyEvent', params => { events => [
		{ component => 'input:0', event => 'single_push', idx => 99 },
		{ component => 'bthomedevice:202', event => 'double_push', idx => 1, channel => -1, ts => 201 },
		{ component => 'bthomedevice:200', event => 'single_push', idx => 0, channel => 0, ts => 202 },
		{ component => 'bthomedevice:200', event => 'long_push', idx => 0, channel => 0, ts => 203 },
	] } });
	is([@{$values}{qw(bthomedevice_200_event bthomedevice_200_idx bthomedevice_200_channel bthomedevice_200_ts bthomedevice_202_event)}],
		['long_push', 0, 0, 203, 'double_push'], 'Arrayposition ist beliebig, letzter passender Event gewinnt');
	is(readings("$prefix/events/rpc", { method => 'NotifyEvent', params => { events => [{}] } }), {}, 'fehlende Ereignisfelder erzeugen keine leeren Ueberschreibungen');
	unlike(reading_value('discovery', '.registry'), qr/darf-nicht-in-den-cache|verwerfen/, 'Registry enthaelt keine unbenoetigten Konfigurationswerte');
	unlike(encode_json($hash->{helper}{formats}{shelly}), qr/darf-nicht-in-den-cache|verwerfen/, 'Adaptercache enthaelt keine unbenoetigten Konfigurationswerte');
	$main::attr{discovery}{extraJsonReadings} = 'ignore';
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'rebuildDevice', $target), undef, 'Neuaufbau im restriktiven JSON-Modus');
	$values = readings("$prefix/events/rpc", { params => { events => [{ component => 'bthomedevice:200', event => 'single_push' }] } });
	is($values->{bthomedevice_200_event}, 'single_push', 'explizite BLU-Ereignisse bleiben bei extraJsonReadings ignore erhalten');
};

subtest 'Inkonsistente Komponentenseiten ersetzen keine bestehende Definition' => sub {
	my $hash = setup();
	discover($hash);
	my $before = attr_value($target, 'readingList');
	@published = ();
	my $status = status();
	$status->{bthome} = {};
	discover($hash, config(), $status);
	reply(page(0, 2, dynamic('bthomesensor:200', { value => 1 })), 'Shelly.GetComponents');
	my $bad = page(1, 2, dynamic('bthomesensor:201', { value => 2 }));
	$bad->{cfg_rev} = 43;
	reply($bad, 'Shelly.GetComponents');
	is(attr_value($target, 'readingList'), $before, 'Revisionswechsel laesst vorhandene Bindings unveraendert');
	is(reading_value('discovery', 'errorCount'), 1, 'Revisionswechsel wird sichtbar gemeldet');
	is(\@published, [], 'fehlerhafter Snapshot startet keine Initialabfragen');
};

subtest 'Manuelle BLU-Auswertung bleibt konservativ erhalten, Rebuild ist explizit' => sub {
	my $hash = setup();
	is(main::CommandDefine(undef, "$target MQTT2_DEVICE shelly-client mqtt"), undef, 'Bestandsgeraet im lokalen Test angelegt');
	$main::attr{$target}{IODev} = 'mqtt';
	my $manual = "$prefix/events/rpc:.* { json2nameValue(\$EVENT) }";
	$main::attr{$target}{readingList} = $manual;
	$main::attr{$target}{userReadings} = 'blu_alt:.* { 1 }';
	$main::defs{$target}{READINGS}{blu_alt} = { VAL => 42, TIME => 'vorher' };
	my $status = status();
	$status->{bthome} = {};
	discover($hash, config(), $status);
	reply(page(0, 1, dynamic('bthomedevice:200', { battery => 99 })), 'Shelly.GetComponents');
	like(attr_value($target, 'readingList'), qr/\Q$manual\E/, 'manuelle JSON-Sammelregel bleibt erhalten');
	is(reading_value($target, 'blu_alt'), 42, 'bestehender BLU-Wert bleibt erhalten');
	is(attr_value($target, 'userReadings'), 'blu_alt:.* { 1 }', 'manuelle userReadings bleiben erhalten');
	is(readings("$prefix/events/rpc", { params => { events => [{ component => 'bthomedevice:200', event => 'single_push' }] } }),
		{}, 'kein zweiter generierter Event-Handler neben der manuellen Sammelregel');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'rebuildDevice', $target), undef, 'expliziter Neuaufbau ersetzt Listen');
	unlike(attr_value($target, 'readingList'), qr/\Q$manual\E/, 'manuelle Listenregel wird nur beim expliziten Rebuild verworfen');
	is(reading_value($target, 'blu_alt'), 42, 'Rebuild ohne clearReadings behaelt vorhandene Werte');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'rebuildDevice', $target, 'clearReadings'), undef, 'explizites Loeschen der Readings');
	ok(!exists($main::defs{$target}{READINGS}{blu_alt}), 'clearReadings loescht den manuellen Wert');
	is(main::CommandDefine(undef, 'Unmanaged MQTT2_DEVICE other-client mqtt'), undef, 'zweites lokales Bestandsgeraet');
	like(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'rebuildDevice', 'Unmanaged'), qr/nicht verwaltet/, 'rebuildDevice bleibt auf verwaltete Geraete beschraenkt');
};

done_testing;
