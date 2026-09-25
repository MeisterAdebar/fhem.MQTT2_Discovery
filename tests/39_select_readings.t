# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(encode_json decode_json);
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::FHEMGateway ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $id = 'shelly1g4-aabbccddeeff';
my $target = 'Werkstatt_Switch_aabbccddeeff';
my $info = { id => $id, gen => 4, model => 'S4SW-001X16EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' };
my (@published, @timers);

# Ein Schalter mit Temperatur, WLAN und Laufzeit; die Meldewege sind je Test variabel.
sub configuration {
	my (%ntf) = @_;
	return {
		sys => { device => { name => $target } },
		mqtt => { topic_prefix => $id,
			rpc_ntf => ($ntf{rpc} ? JSON::PP::true : JSON::PP::false),
			status_ntf => ($ntf{status} ? JSON::PP::true : JSON::PP::false) },
		'switch:0' => { id => 0 },
	};
}

sub status {
	return {
		'switch:0' => { id => 0, output => JSON::PP::true, temperature => { tC => 42.5 } },
		wifi => { rssi => -57 }, sys => { uptime => 1234 },
	};
}

sub response {
	my ($request, $result) = @_;
	my $rpc = decode_json($request->{payload});
	return ("$rpc->{src}/rpc", encode_json({ id => $rpc->{id}, src => $id, result => $result }));
}

sub setup {
	reset_env();
	@published = ();
	@timers = ();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		publish_mqtt => sub {
			my (undef, $topic, $payload) = @_;
			push @published, { topic => $topic, payload => $payload };
			return undef;
		},
	);
	FHEM::MQTT2_DISCOVERY::activate($hash);
	@published = ();
	return $hash;
}

# Beantwortet die Discovery-Abfragen; liefert die erzeugte readingList zurueck.
sub discover {
	my ($hash, %ntf) = @_;

	# Die Statusabfrage nach dem Apply bleibt sonst als Rest in der Warteschlange.
	@published = ();
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'discoverShelly', $id);

	for my $result ($info, configuration(%ntf), status()) {
		my $request = shift @published;
		return if !$request;
		my ($topic, $payload) = response($request, $result);
		dispatch_message('mqtt', 'shelly-client', $topic, $payload);
	}

	return attr_value($target, 'readingList') // '';
}

# Wertet alle passenden readingList-Zeilen fuer ein konkretes Topic aus.
sub readings_for {
	my ($topic, $data) = @_;
	my $payload = ref($data) ? encode_json($data) : $data;
	my %updates;

	for my $line (split /\n/, attr_value($target, 'readingList') // '') {
		my ($pattern) = split /\s+/, $line, 2;
		my $prefix = attr_value($target, 'devicetopic');
		$pattern =~ s/\$DEVICETOPIC/\Q$prefix\E/g if defined $prefix;
		next if "$topic:$payload" !~ /^$pattern$/s;
		my ($reference) = $line =~ /'(r_[a-f0-9]+)'/;
		next if !defined($reference);
		my $values = FHEM::MQTT2_DISCOVERY::runtimeRef($target, $reference, $payload);
		%updates = (%updates, %$values) if ref($values) eq 'HASH';
	}

	return \%updates;
}

use Digest::SHA ();
subtest 'selectReadings filtert Entities und ueberlebt den Geraetedatensatz' => sub {
	my $hash = setup();
	discover($hash, status => 1);
	like(attr_value($target, 'readingList'), qr{\Qstatus/wifi\E}, 'die WLAN-Zeile entsteht zunaechst');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'selectReadings', $target,
		'switch_0=1', 'temperature=1', 'rssi=0', 'uptime=0'), undef,
		'die Auswahl wird uebernommen');
	my $reading_list = attr_value($target, 'readingList');
	unlike($reading_list, qr{\Qstatus/wifi\E}, 'die abgewaehlte WLAN-Zeile entfaellt');
	unlike($reading_list, qr{\Qstatus/sys\E}, 'die abgewaehlte Laufzeitzeile entfaellt');
	is(attr_value($target, 'autocreate'), '0', 'autocreate wird am Zielgeraet abgeschaltet');

	# Auch die gemeinsame Abfrageantwort darf die Werte nicht mehr liefern.
	my $values = readings_for('mqtt2_discovery/discovery/shelly/'
		. substr(Digest::SHA::sha1_hex($id), 0, 16) . '/state/rpc',
		{ src => $id, result => status() });
	ok(!exists($values->{rssi}), 'die Abfrageantwort liefert das abgewaehlte Reading nicht mehr');
	is($values->{switch_0}, 'true', 'die gewaehlten Readings bleiben erhalten');

	# Die Auswahl liegt neben den Geraetedatensaetzen und ueberdauert deren Verlust.
	my $registry = FHEM::MQTT2_DISCOVERY::registry($hash);
	is([sort @{ $registry->{selections}{$target} }], ['rssi', 'uptime'],
		'die Auswahl steht ausserhalb des Geraetedatensatzes');
	delete $registry->{devices}{$_} for keys %{ $registry->{devices} };
	$_->{started} -= 60 for values %{ $hash->{helper}{formats}{shelly}{devices} || {} };
	discover($hash, status => 1);
	unlike(attr_value($target, 'readingList'), qr{\Qstatus/wifi\E},
		'nach einer erneuten Erkennung bleibt die Auswahl wirksam');
};

subtest 'auch Felder einer Sammelzeile lassen sich abwaehlen' => sub {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	FHEM::MQTT2_DISCOVERY::activate($hash);
	dispatch_message('mqtt', 'client1', 'tasmota/discovery/AABBCCDDEEFF/config',
		'{"dn":"Keller","fn":["Pumpe",null],"mac":"AABBCCDDEEFF","md":"Generic",'
			. '"state":["OFF","ON"],"t":"tasmota_DDEEFF","ft":"%prefix%/%topic%/",'
			. '"tp":["cmnd","stat","tele"],"rl":[1,0],"so":{"4":0},"ver":1}');
	my $device = 'Keller_Pumpe';
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $device
	} values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };

	# Vor der ersten Nachricht kennt niemand die Felder: Eine Sammelzeile kuendigt
	# keine an, sie flacht ab, was ankommt.
	ok(!grep({ $_ eq 'Heap' } FHEM::MQTT2_DISCOVERY::selectable_readings($hash, $record)),
		'vor der ersten Nachricht steht das Feld in keiner Liste');

	# Mit der eigenen Auswertung merkt sich das Modul, was eine Sammelzeile
	# erzeugt hat.
	$main::attr{discovery}{keys} = 'readings=parse';
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'rebuildDevice', $device);
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE',
		'{"Heap":24,"LoadAvg":19}');
	is($main::defs{$device}{READINGS}{Heap}{VAL}, 24, 'das Feld entsteht');
	ok(grep({ $_ eq 'Heap' } FHEM::MQTT2_DISCOVERY::selectable_readings($hash, $record)),
		'danach bietet selectReadings es an');

	# Abgewaehlt wird es ueber die Umbenennungsliste, die den Schluessel verwirft.
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'selectReadings', $device,
		'Heap=0', 'LoadAvg=1'), undef, 'die Auswahl wird angenommen');
	ok(!exists($main::defs{$device}{READINGS}{Heap}), 'der alte Wert bleibt nicht stehen');
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE',
		'{"Heap":25,"LoadAvg":20}');
	ok(!exists($main::defs{$device}{READINGS}{Heap}), 'und es entsteht auch nicht neu');
	is($main::defs{$device}{READINGS}{LoadAvg}{VAL}, 20, 'das andere Feld laeuft weiter');

	# Ein eigenes jsonMap am Zielgeraet benennt vor der Auswahl um. Der Dialog
	# zeigt dann den fertigen Namen, verworfen werden muss aber der Schluessel
	# aus der Nachricht.
	$main::defs{$device}{JSONMAP} = { LoadAvg => 'last' };
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'rebuildDevice', $device);
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"LoadAvg":21}');
	is($main::defs{$device}{READINGS}{last}{VAL}, 21, 'die eigene Umbenennung wirkt weiter');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'selectReadings', $device, 'last=0'), undef,
		'der umbenannte Name laesst sich abwaehlen');
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"LoadAvg":22}');
	ok(!exists($main::defs{$device}{READINGS}{last}), 'und das Feld bleibt weg');

	# Umgekehrte Reihenfolge: erst abwaehlen, dann umbenennen. Ohne Neuaufbau
	# darf der Name trotzdem nicht wieder auftauchen, sonst muesste der Anwender
	# nach jeder Aenderung an jsonMap an den Neuaufbau denken.
	delete $main::defs{$device}{JSONMAP};
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'rebuildDevice', $device);
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'selectReadings', $device, 'last=0'), undef,
		'der Name wird abgewaehlt, bevor es ihn gibt');
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"LoadAvg":23}');
	is($main::defs{$device}{READINGS}{LoadAvg}{VAL}, 23, 'unter seinem alten Namen laeuft das Feld');
	$main::defs{$device}{JSONMAP} = { LoadAvg => 'last' };
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"LoadAvg":24}');
	ok(!exists($main::defs{$device}{READINGS}{last}),
		'das geaenderte jsonMap greift ohne Neuaufbau');
};

subtest 'eine Aenderung an jsonMap raeumt das alte Reading ab' => sub {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	FHEM::MQTT2_DISCOVERY::activate($hash);
	$main::attr{discovery}{keys} = 'readings=parse';
	dispatch_message('mqtt', 'client1', 'tasmota/discovery/AABBCCDDEEFF/config',
		'{"dn":"Keller","fn":["Pumpe",null],"mac":"AABBCCDDEEFF","md":"Generic",'
			. '"state":["OFF","ON"],"t":"tasmota_DDEEFF","ft":"%prefix%/%topic%/",'
			. '"tp":["cmnd","stat","tele"],"rl":[1,0],"so":{"4":0},"ver":1}');
	my $device = 'Keller_Pumpe';
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"Heap":24}');
	is($main::defs{$device}{READINGS}{Heap}{VAL}, 24, 'das Feld steht unter seinem Namen');

	# So meldet FHEM eine Attributaenderung; MQTT2_DEVICE hat JSONMAP da bereits
	# aus dem Attribut gebaut.
	$main::defs{$device}{JSONMAP} = { Heap => 'speicher' };
	$main::defs{global} = { NAME => 'global',
		CHANGED => ["ATTR $device jsonMap Heap:speicher"] };
	FHEM::MQTT2_DISCOVERY::Notify($hash, $main::defs{global});
	ok(!exists($main::defs{$device}{READINGS}{Heap}),
		'das Reading unter dem alten Namen ist weg');
	dispatch_message('mqtt', 'client1', 'tele/tasmota_DDEEFF/STATE', '{"Heap":25}');
	is($main::defs{$device}{READINGS}{speicher}{VAL}, 25, 'der neue Name laeuft weiter');

	# Ein abgewaehlter Name bleibt in der Auswahl, ein ueberholter verschwindet.
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $device
	} values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	ok(!grep({ $_ eq 'Heap' } FHEM::MQTT2_DISCOVERY::selectable_readings($hash, $record)),
		'der ueberholte Name wird nicht mehr angeboten');
};

done_testing();
