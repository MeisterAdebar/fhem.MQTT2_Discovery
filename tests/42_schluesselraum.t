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

my $zweiter_kanal = 0;

sub configuration {
	return {
		sys => { device => { name => $target } },
		mqtt => { topic_prefix => $id, rpc_ntf => JSON::PP::false, status_ntf => JSON::PP::true },
		'switch:0' => { id => 0 },
		($zweiter_kanal ? ('switch:1' => { id => 1 }) : ()),
	};
}

sub status {
	return {
		'switch:0' => { id => 0, output => JSON::PP::true, temperature => { tC => 42.5 } },
		($zweiter_kanal
			? ('switch:1' => { id => 1, output => JSON::PP::false, temperature => { tC => 40.0 } })
			: ()),
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

sub discover {
	my ($hash) = @_;
	@published = ();
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'discoverShelly', $id);

	for my $result ($info, configuration(), status()) {
		my $request = shift @published;
		return if !$request;
		my ($topic, $payload) = response($request, $result);
		dispatch_message('mqtt', 'shelly-client', $topic, $payload);
	}

	return $hash;
}

# Liefert den Registry-Datensatz des erkannten Geraets.
sub record {
	my ($hash) = @_;
	my $registry = FHEM::MQTT2_DISCOVERY::registry($hash);
	my ($identity) = sort keys %{ $registry->{devices} || {} };
	return $registry->{devices}{$identity};
}

subtest 'Schreibweise wird gegen den Schluesselraum geprueft' => sub {
	is(FHEM::MQTT2_DISCOVERY::check_keys('style=fhem sets=hook', 1), undef, 'bekannte Schluessel');
	is(FHEM::MQTT2_DISCOVERY::check_keys('shelly:sets=hook', 1), undef, 'Familie global erlaubt');
	is(FHEM::MQTT2_DISCOVERY::check_keys('hide=temperature,rssi', 1), undef, 'Listen bleiben ungeprueft');
	like(FHEM::MQTT2_DISCOVERY::check_keys('quatsch=1', 1), qr/Unbekannter Schluessel/, 'unbekannt');
	like(FHEM::MQTT2_DISCOVERY::check_keys('style=bunt', 1), qr/Ungueltiger Wert/, 'falscher Wert');
	like(FHEM::MQTT2_DISCOVERY::check_keys('style', 1), qr/Ungueltige Angabe/, 'keine Zuweisung');

	# Am Zielgeraet gilt nur die eigene Ebene, eine Familie waere dort sinnlos.
	like(FHEM::MQTT2_DISCOVERY::check_keys('shelly:sets=hook', 0),
		qr/Familie ist hier nicht erlaubt/, 'Familie nur am Discovery-Device');
};

subtest 'AttrFn prueft beide Attribute' => sub {
	my $hash = setup();
	is(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'keys', 'shelly:sets=hook'), undef,
		'das Attribut am Discovery-Device nimmt eine Familie an');
	like(FHEM::MQTT2_DISCOVERY::Attr('set', 'discovery', 'keys', 'style=bunt'),
		qr/Ungueltiger Wert/, 'ein falscher Wert wird abgewiesen');

	# Ueber addToDevAttrList mit Pruefinstanz landet auch das Attribut des
	# Zielgeraets in dieser AttrFn; $name ist dann das fremde Device.
	like(FHEM::MQTT2_DISCOVERY::Attr('set', $target, 'mqttDiscoveryKeys', 'shelly:readings=parse'),
		qr/Familie ist hier nicht erlaubt/, 'am Geraet ohne Familie');

	# Von Hand gesetzt wird das Attribut abgewiesen; der Anwender soll den
	# Set-Befehl nehmen, der die Schreibweise selbst erzeugt.
	like(FHEM::MQTT2_DISCOVERY::Attr('set', $target, 'mqttDiscoveryKeys', 'readings=parse'),
		qr/deviceKey/, 'ohne den Set-Befehl bleibt das Attribut zu');
	$hash->{helper}{own_device_attribute} = 1;
	is(FHEM::MQTT2_DISCOVERY::Attr('set', $target, 'mqttDiscoveryKeys', 'readings=parse'), undef,
		'mit dem Vermerk des Moduls geht es durch');
	delete $hash->{helper}{own_device_attribute};

	# Beim Laden der Konfiguration gibt es kein Kommando, das den Vermerk setzen
	# koennte; gespeicherte Werte muessen trotzdem zurueckkommen.
	local $main::init_done = 0;
	is(FHEM::MQTT2_DISCOVERY::Attr('set', $target, 'mqttDiscoveryKeys', 'readings=parse'), undef,
		'beim Start kommt der gespeicherte Wert zurueck');
	is(FHEM::MQTT2_DISCOVERY::Attr('del', $target, 'mqttDiscoveryKeys'), undef,
		'beim Loeschen wird nicht geprueft');
};

subtest 'set deviceKey fuehrt den Anwender' => sub {
	my $hash = setup();
	discover($hash);
	like(FHEM::MQTT2_DISCOVERY::set_list($hash), qr/deviceKey:\Q$target\E/,
		'der Befehl bietet die verwalteten Geraete an');
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', $target, 'sets=quatsch'),
		qr/Ungueltiger Wert/, 'ein falscher Wert kommt nicht ins Attribut');
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', 'gibtsnicht', 'sets=hook'),
		qr/kein MQTT2_DEVICE/, 'ein fremdes Ziel wird abgewiesen');

	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', $target, 'sets=hook'), undef,
		'der Schluessel wird gesetzt');
	is(attr_value($target, 'mqttDiscoveryKeys'), 'sets=hook', 'er steht am Zielgeraet');

	# Ein zweiter Aufruf ergaenzt, statt den bestehenden Schluessel zu ersetzen.
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', $target, 'readings=parse'), undef,
		'ein weiterer Schluessel kommt hinzu');
	is(attr_value($target, 'mqttDiscoveryKeys'), 'readings=parse sets=hook', 'beide stehen dort');

	# Ein leerer Wert nimmt genau einen Schluessel zurueck.
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', $target, 'sets=');
	is(attr_value($target, 'mqttDiscoveryKeys'), 'readings=parse', 'der andere bleibt stehen');
	FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'deviceKey', $target, 'readings=');
	is(attr_value($target, 'mqttDiscoveryKeys'), undef, 'das leere Attribut entfaellt');
};

subtest 'Vorgabe, global, Familie und Geraet in dieser Reihenfolge' => sub {
	my $hash = setup();
	discover($hash);
	my $record = record($hash);
	is($record->{adapter}, 'shelly', 'der Datensatz kennt seine Familie');
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'list', 'ohne Angabe gilt die Vorgabe');

	$main::attr{discovery}{keys} = 'sets=hook';
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'hook', 'global schlaegt die Vorgabe');

	$main::attr{discovery}{keys} = 'sets=hook shelly:sets=list';
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'list', 'die Familie schlaegt global');

	$main::attr{$target}{mqttDiscoveryKeys} = 'sets=hook';
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'hook', 'das Geraet schlaegt die Familie');

	# Eine andere Familie darf das Geraet nicht betreffen.
	delete $main::attr{$target}{mqttDiscoveryKeys};
	$main::attr{discovery}{keys} = 'tasmota:sets=hook';
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'list', 'fremde Familie wirkt nicht');
};

subtest 'Die alten Einzelattribute bleiben gueltig' => sub {
	my $hash = setup();
	discover($hash);
	my $record = record($hash);

	$main::attr{discovery}{setsViaHook} = 1;
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'hook', 'das alte Attribut wirkt weiter');

	$main::attr{discovery}{keys} = 'sets=list';
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'sets'), 'list', 'der Schluessel hat Vorrang');

	# Das alte Attribut hat immer nur die Verdichtung unterdrueckt und die
	# Quellen stehen lassen; das heisst jetzt source.
	$main::attr{discovery}{availabilityReading} = 'none';
	delete $main::attr{discovery}{keys};
	is(FHEM::MQTT2_DISCOVERY::key($hash, $record, 'availability'), 'source',
		'availabilityReading none entspricht source');
};

subtest 'Die Schluessel wirken bis in die erzeugten Zeilen' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'shelly:sets=hook';
	discover($hash);
	is(attr_value($target, 'setList'), undef, 'mit sets=hook entsteht kein setList');
	ok(ref(record($hash)->{hook_sets}) eq 'ARRAY', 'die Befehle liegen in der Registry');

	$hash = setup();
	$main::attr{discovery}{keys} = 'readings=parse';
	discover($hash);
	is(attr_value($target, 'readingList'), undef, 'mit readings=parse entsteht kein readingList');

	$hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	discover($hash);
	like(attr_value($target, 'setList'), qr/^on:noArg /m, 'style=fhem benennt die Befehle um');
};

subtest 'readings=parse stellt den Match weit' => sub {
	my $hash = setup();
	discover($hash);
	my $eng = $main::modules{MQTT2_DISCOVERY}{Match};
	isnt($eng, '.*', 'ohne den Schluessel bleibt der enge Match');

	# Ohne weiten Match sieht ParseFn die Nutzdatentopics des Geraets nie, und
	# die selbst geschriebenen Readings blieben aus.
	$main::attr{discovery}{keys} = 'readings=parse';
	FHEM::MQTT2_DISCOVERY::update_match();
	is($main::modules{MQTT2_DISCOVERY}{Match}, '.*', 'mit dem Schluessel sieht das Modul alles');

	delete $main::attr{discovery}{keys};
	FHEM::MQTT2_DISCOVERY::update_match();
	is($main::modules{MQTT2_DISCOVERY}{Match}, $eng, 'danach wieder eng');

	# Nach einem Neustart rendert niemand neu; der Match muss trotzdem stehen,
	# sonst sieht ParseFn die Nutzdatentopics erst nach dem naechsten Rendern.
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	$main::attr{discovery}{keys} = 'readings=parse';
	is($main::modules{MQTT2_DISCOVERY}{Match}, $eng, 'frisch geladen ist der Match eng');
	define_discovery('discovery', 'mqtt');
	is($main::modules{MQTT2_DISCOVERY}{Match}, '.*', 'die Definition stellt ihn wieder her');

	# Ein reload ruft Initialize erneut auf und setzt den Match zurueck; die
	# bestehende Instanz braucht ihn weiterhin weit.
	# CommandReload fuellt ein neues Modulhash und haengt es erst danach ein;
	# der Match muss deshalb in genau dieses Hash geschrieben werden.
	my %neu = (LOADED => 1);
	FHEM::MQTT2_DISCOVERY::Initialize(\%neu);
	is($neu{Match}, '.*', 'auch nach einem reload bleibt er weit');
};

subtest 'mehrere Kanaele werden in eigene Geraete aufgeteilt' => sub {
	my $hash = setup();
	discover($hash);
	is([sort grep { ($main::defs{$_}{TYPE} // '') eq 'MQTT2_DEVICE' } keys %main::defs],
		[$target], 'ein Kanal bleibt ein Geraet');

	$zweiter_kanal = 1;
	$hash = setup();
	discover($hash);
	my @alle = sort grep { ($main::defs{$_}{TYPE} // '') eq 'MQTT2_DEVICE' } keys %main::defs;
	$zweiter_kanal = 0;

	# Drei Geraete: das Hauptgeraet mit WLAN, Laufzeit und Erreichbarkeit, dazu
	# je Kanal eines.
	is(scalar(@alle), 3, 'zwei Kanaele ergeben ein Haupt- und zwei Kanalgeraete');
	ok($main::defs{$target}, 'das Hauptgeraet behaelt seinen Namen');
	my @geraete = grep { $_ ne $target } @alle;
	like($geraete[0], qr/\Q$target\E_1\z/, 'das erste Kanalgeraet traegt seine Nummer');
	like($geraete[1], qr/\Q$target\E_2\z/, 'das zweite ebenso');

	# Jeder Kanal hat sein eigenes Geraet und damit seinen eigenen Namensraum;
	# die Temperatur heisst in beiden schlicht temperature.
	for my $geraet (@geraete) {
		my ($record) = grep {
			ref($_) eq 'HASH' && ($_->{name} // '') eq $geraet
		} values %{ FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} || {} };
		my %namen;

		for my $descriptor (values %{ $record->{runtime_refs} || {} }) {
			next if ref($descriptor) ne 'HASH';
			$namen{ $descriptor->{name} } = 1 if defined($descriptor->{name});

			for my $reading (@{ $descriptor->{configuration}{readings} || [] }) {
				$namen{ $reading->{name} } = 1 if ref($reading) eq 'HASH' && defined($reading->{name});
			}
		}
		ok($namen{temperature}, "$geraet hat seine eigene Temperatur");
		ok(!$namen{switch_0_temperature} && !$namen{switch_1_temperature},
			"$geraet braucht keinen Kanal im Readingnamen");
	}
};

subtest 'hide blendet Readings aus' => sub {
	my $hash = setup();
	discover($hash);
	like(attr_value($target, 'readingList'), qr{\Qstatus/wifi\E}, 'ohne hide ist alles da');

	# hide nennt dieselben Readingnamen wie der Dialog selectReadings; bleibt von
	# einem Topic nichts uebrig, entfaellt die ganze Zeile.
	$hash = setup();
	$main::attr{discovery}{keys} = 'hide=rssi,uptime';
	discover($hash);
	my $reading_list = attr_value($target, 'readingList');
	unlike($reading_list, qr{\Qstatus/wifi\E}, 'die ausgeblendete WLAN-Zeile entfaellt');
	unlike($reading_list, qr{\Qstatus/sys\E}, 'die ausgeblendete Laufzeitzeile entfaellt');
	like($reading_list, qr{\Qstatus/switch_0\E}, 'der Schalter bleibt');
};

subtest 'availability kennt drei Stufen' => sub {

	# combined: Quelle und Verdichtung.
	my $hash = setup();
	discover($hash);
	is(record($hash)->{availability_reading}, 'availability', 'combined benennt die Verdichtung');
	is(reading_value($target, 'availability'), 'unknown', 'und schreibt sie ans Geraet');
	like(attr_value($target, 'readingList'), qr{/online:}, 'die Quelle wird ausgewertet');

	# source: nur die Quelle. Der Schluessel muss nicht nur die gerenderte Zeile
	# unterdruecken, sondern auch den Namen, sonst schreibt das Anwenden die
	# Verdichtung trotzdem und sie bleibt mit ihrem letzten Wert stehen.
	$hash = setup();
	$main::attr{discovery}{keys} = 'availability=source';
	discover($hash);
	is(record($hash)->{availability_reading}, '', 'source benennt keine Verdichtung');
	is(reading_value($target, 'availability'), undef, 'und schreibt sie nicht');
	like(attr_value($target, 'readingList'), qr{/online:}, 'die Quelle bleibt');

	# none: gar nichts davon.
	$hash = setup();
	$main::attr{discovery}{keys} = 'availability=none';
	discover($hash);
	is(reading_value($target, 'availability'), undef, 'none schreibt keine Verdichtung');
	unlike(attr_value($target, 'readingList'), qr{/online:},
		'und wertet auch die Quelle nicht mehr aus');
	is(reading_value($target, '.availability_io'), undef, 'der IO-Zustand entfaellt ebenfalls');
};

subtest 'forceNEXT gibt auch konsumierte Nachrichten weiter' => sub {
	my $hash = setup();
	$main::attr{discovery}{disable} = 1;
	my $message = join("\0", 'client', 'homeassistant/switch/haus/config', '{}');

	# Ohne den Schluessel verschluckt das Modul die Discovery-Nachricht, damit
	# MQTT2_DEVICE daraus kein Fremd-Device anlegt.
	is([FHEM::MQTT2_DISCOVERY::Parse($main::defs{mqtt}, $message)], [''],
		'die Nachricht endet hier');

	$main::attr{discovery}{keys} = 'forceNEXT=1';
	is([FHEM::MQTT2_DISCOVERY::Parse($main::defs{mqtt}, $message)], ['[NEXT]'],
		'mit forceNEXT laeuft die Parserkette weiter');
};

subtest 'Die Konvention haengt am Datensatz, nicht am Attribut' => sub {
	my $hash = setup();
	$main::attr{discovery}{keys} = 'style=fhem';
	discover($hash);
	is(record($hash)->{style}, 'fhem', 'der Datensatz haelt die Konvention seiner Anlage fest');

	# Wird der Schluessel spaeter zurueckgenommen, behaelt das bestehende Geraet
	# sein Verhalten; sonst kippten laufende Readingnamen.
	delete $main::attr{discovery}{keys};
	is(FHEM::MQTT2_DISCOVERY::key($hash, record($hash), 'style'), 'fhem',
		'ein bestehendes Geraet bleibt bei seiner Konvention');

	$hash = setup();
	discover($hash);
	is(record($hash)->{style}, 'raw', 'ohne Schluessel entsteht ein Datensatz nach alter Art');
};

done_testing();
