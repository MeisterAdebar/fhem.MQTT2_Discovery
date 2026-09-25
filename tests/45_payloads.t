# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use File::Temp ();
use MIME::Base64 ();
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::FHEMGateway ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $config_topic = 'tasmota/discovery/00005E005301/config';
my $sensors_topic = 'tasmota/discovery/00005E005301/sensors';
my $config = '{"dn":"Tasmota","fn":["Wasser"],"hn":"tasmota-005301-1234","ip":"192.168.0.42",'
	. '"mac":"00005E005301","md":"OBI Socket",'
	. '"state":["OFF","ON"],"t":"tasmota_005301","ft":"%prefix%/%topic%/",'
	. '"tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0},"ver":1}';
my $sensors = '{"sn":{"Time":"2026-09-22T11:00:00","ENERGY":{"Power":42}},"ver":1}';
my $device = 'Tasmota_Wasser';

sub setup {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	FHEM::MQTT2_DISCOVERY::activate($hash);
	return $hash;
}

subtest 'Geheimnisse werden ersetzt, alles andere bleibt' => sub {
	my $payload = '{"wifi":{"sta":{"ssid":"MeinWLAN","pass":"geheim"}},'
		. '"mqtt":{"user":"fhem","pass":"auchgeheim","topic_prefix":"shelly1"}}';
	my $redacted = FHEM::MQTT2_DISCOVERY::redact_payload($payload);
	like($redacted, qr/"pass":"xxx"/, 'das WLAN-Passwort ist ersetzt');
	unlike($redacted, qr/geheim/, 'kein Geheimnis bleibt uebrig');
	like($redacted, qr/"ssid":"WLAN"/, 'die SSID wird durch eine unverfaengliche ersetzt');
	like($redacted, qr/"topic_prefix":"shelly1"/, 'das Topic bleibt, es wird zum Nachstellen gebraucht');

	# Ein einfacher Wert ist kein JSON und bleibt unveraendert.
	is(FHEM::MQTT2_DISCOVERY::redact_payload('true'), 'true', 'ein einfacher Wert bleibt');
};

subtest 'get payloads liefert die Nachrichten des Geraets' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	ok($main::defs{$device}, 'das Geraet entsteht');
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);
	like($block, qr/^# MQTT2_DISCOVERY .*Adapter tasmota/m, 'der Kopf nennt Geraet und Adapter');
	like($block, qr{^tasmota/discovery/[0-9A-F]{12}/config \{"dn":"Tasmota"}m,
		'die Konfiguration steht drin');
	like($block, qr{^tasmota/discovery/[0-9A-F]{12}/sensors \{"sn":}m, 'die Sensoren stehen drin');

	# Die Kennung des Geraets wird ueberall durch dieselbe ersetzt, sonst passten
	# Topic und Inhalt nicht mehr zueinander.
	unlike($block, qr/00005E005301/, 'die echte MAC steht nirgends');
	unlike($block, qr/005301/, 'auch ihr Ende nicht');
	my ($aus_topic) = $block =~ m{^tasmota/discovery/([0-9A-F]{12})/config}m;
	my ($aus_inhalt) = $block =~ /"mac":"([0-9A-F]{12})"/;
	is($aus_inhalt, $aus_topic, 'Topic und Inhalt tragen dieselbe Ersatzkennung');
	my ($aus_prefix) = $block =~ /"t":"tasmota_([0-9A-F]{6})"/;
	is($aus_prefix, substr($aus_topic, -6), 'das eigene Topic folgt derselben Ersetzung');
	unlike($block, qr/192\.168\./, 'die Adresse aus dem Heimnetz steht nicht drin');
	like($block, qr/"hn":"host"/, 'der Hostname ist ersetzt');

	# Adressen und Hardwarekennungen erkennt die Ersetzung an ihrer Form; sie
	# heissen je nach Geraet ip, sta_ip, server oder bssid.
	my $frei = FHEM::MQTT2_DISCOVERY::redact_payload(
		'{"sta_ip":"192.168.0.43","server":"192.168.0.10:1883",'
			. '"bssid":"a0:b1:c2:da:fd:26","sta_ip6":["fe80::1234:5678"],"ver":"1.7.1"}');
	like($frei, qr/"sta_ip":"192\.0\.2\.10"/, 'eine Adresse wird ersetzt, egal wie ihr Schluessel heisst');
	like($frei, qr/"server":"192\.0\.2\.10:1883"/, 'auch mit Portangabe');
	like($frei, qr/"bssid":"de:ad:be:ef:00:01"/, 'die MAC des Accesspoints ebenso');
	like($frei, qr/"sta_ip6":\["2001:db8::1"\]/, 'und Adressen in Listen');
	like($frei, qr/"ver":"1\.7\.1"/, 'eine Versionsnummer bleibt, sie ist keine Adresse');

	# Ein unbekanntes Geraet wird benannt, nicht stillschweigend uebergangen.
	like(FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', 'gibtsnicht'),
		qr/kein von dieser Instanz verwaltetes Geraet/, 'ein fremder Name wird abgewiesen');
	like(FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', '?'), qr/payloads:\Q$device\E/,
		'die Auswahl nennt die verwalteten Geraete');
};

subtest 'aus FHEMWEB kommt ein Textfeld statt einer sehr langen Zeile' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);
	unlike($block, qr/textarea/, 'ohne Frontend bleibt es reiner Text');

	# FHEMWEB spannt den Dialog sonst auf die Laenge der Nutzdaten.
	local $hash->{CL} = { TYPE => 'FHEMWEB', NAME => 'WEB' };
	my $html = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);
	like($html, qr{\A<html><textarea readonly rows="\d+" cols="\d+"}, 'im Frontend ein Textfeld');
	like($html, qr{</textarea></html>\z}, 'und es ist geschlossen');
	like($html, qr/tasmota\/discovery/, 'die Nachrichten stehen darin');
	unlike($html, qr/<(?!\/?(?:html|textarea))/, 'sonst kommt kein Markup vor');
};

subtest 'replayPayloads baut das Geraet ohne die Hardware nach' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);
	my $file = File::Temp->new(SUFFIX => '.txt');
	print {$file} "$block\n" or die $!;
	close $file or die $!;

	# Eine frische Instanz kennt das Geraet nicht; der Block allein genuegt.
	$hash = setup();
	ok(!$main::defs{$device}, 'nach dem Neuaufbau gibt es das Geraet nicht mehr');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', "$file"), undef,
		'der Block wird ohne Fehler eingespielt');
	ok($main::defs{$device}, 'das Geraet entsteht aus den Nachrichten');
	is(reading_value('discovery', 'lastReplay'), 'processed=2 failed=0', 'beide Nachrichten zaehlen');

	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', '/tmp/../etc/passwd'),
		qr/nicht aus dem Verzeichnis herausfuehren/, 'ein Pfad mit .. wird abgewiesen');

	# Ein FileLog sieht zeilenweise aehnlich aus, ist aber keines: Die erste
	# Spalte ist ein Zeitstempel, kein Topic.
	my $log = File::Temp->new(SUFFIX => '.log');
	print {$log} "2026-09-17_15:18:20 shelly1minig3_aabbccddeeff online: true\n" or die $!;
	print {$log} "2026-09-17_15:37:03 shelly1minig3_aabbccddeeff bthc_rev: 2\n" or die $!;
	close $log or die $!;
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', "$log"),
		qr/keine Zeile aus Topic und Nutzdaten/, 'ein FileLog wird als solches erkannt');
};

subtest 'auch die Antworten einer Shelly-Abfrage lassen sich einspielen' => sub {
	my $hash = setup();

	# Der Replay eroeffnet eine eigene Abfrage und veroeffentlicht sie; in der
	# Testumgebung genuegt ein Gateway, das das Senden bestaetigt.
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		publish_mqtt => sub { return undef },
	);
	my $id = 'shelly1minig3-aabbccddeeff';
	my $reply = "mqtt2_discovery/discovery/shelly/1234567890abcdef";

	# Ein Block, wie ihn get payloads fuer einen Shelly liefert: vier Antworten
	# auf eine Abfrage, die es hier nie gab.
	my %antwort = (
		info => { id => 9, src => $id, result => {
			id => $id, gen => 3, model => 'S3SW-001X8EU', ver => '1.7.1', mac => 'AABBCCDDEEFF' } },
		config => { id => 9, src => $id, result => {
			sys => { device => { name => 'Keller' } },
			mqtt => { topic_prefix => $id, status_ntf => JSON::PP::true },
			'switch:0' => { id => 0 } } },
		status => { id => 9, src => $id, result => {
			'switch:0' => { id => 0, output => JSON::PP::false }, sys => { uptime => 1 } } },
		components => { id => 9, src => $id, result => { components => [], total => 0, offset => 0 } },
	);
	my $file = File::Temp->new(SUFFIX => '.txt');
	print {$file} "# Block aus dem Forum\n" or die $!;
	print {$file} "$reply/$_/rpc " . JSON::PP->new->canonical(1)->encode($antwort{$_}) . "\n"
		for sort keys %antwort;
	close $file or die $!;

	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', "$file"), undef,
		'der Block wird ohne Fehler eingespielt');
	is([sort grep { ($main::defs{$_}{TYPE} // '') eq 'MQTT2_DEVICE' } keys %main::defs],
		['Keller_Switch_aabbccddeeff'], 'das Geraet entsteht aus den Antworten');

	# Ohne gekoppelte Komponenten endet die Abfrage nach dem Status; die vierte
	# Antwort wird dann nicht mehr gebraucht.
	is(reading_value('discovery', 'lastReplay'), 'processed=3 failed=0',
		'die Antworten der Abfrage zaehlen');
};

subtest 'der Block laesst sich auch einfuegen statt abspeichern' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);

	# Ohne Angabe fragt das Frontend den Block ab.
	local $hash->{CL} = { TYPE => 'FHEMWEB', NAME => 'WEB' };
	my $dialog = FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads');
	like($dialog, qr/<textarea id="m2dReplayText"/, 'es erscheint ein Eingabefeld');
	like($dialog, qr/replayPayloads base64:/, 'der Knopf schickt den Block als ein Stueck');

	# Eingefuegt wird er als ein Stueck, damit Leerzeichen und Umbrueche die
	# Befehlszeile nicht zerlegen.
	$hash = setup();
	my $base64 = MIME::Base64::encode_base64($block, '');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', "base64:$base64"), undef,
		'der eingefuegte Block wird verarbeitet');
	ok($main::defs{$device}, 'das Geraet entsteht daraus');
	is(reading_value('discovery', 'lastReplay'), 'processed=2 failed=0', 'beide Nachrichten zaehlen');

	# Ein leeres Feld ist kein Fehlerfall, aber auch keine Eingabe.
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads',
		'base64:' . MIME::Base64::encode_base64("\n\n", '')), qr/leer/, 'ein leerer Block wird benannt');
};

done_testing();
