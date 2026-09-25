# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use File::Temp ();
use lib 'lib/FHEM', 'tests/lib';
use MQTT2_Discovery::FormatRegistry ();
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message reading_value);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined($loaded);

my $config_topic = 'tasmota/discovery/00005E005301/config';
my $sensors_topic = 'tasmota/discovery/00005E005301/sensors';
my $config = '{"dn":"Tasmota","fn":["Wasser"],"hn":"host","mac":"00005E005301","md":"OBI Socket",'
	. '"state":["OFF","ON"],"t":"tasmota_005301","ft":"%prefix%/%topic%/",'
	. '"tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0},"ver":1}';
my $sensors = '{"sn":{"Time":"2026-09-22T11:00:00","ENERGY":{"Power":42}},"ver":1}';
my $device = 'Tasmota_Wasser';

sub setup {
	reset_env();
	add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	main::MQTT2_DISCOVERY_activate($hash);
	return $hash;
}

subtest 'Geheimnisse werden ersetzt, alles andere bleibt' => sub {
	my $payload = '{"wifi":{"sta":{"ssid":"MeinWLAN","pass":"geheim"}},'
		. '"mqtt":{"user":"fhem","pass":"auchgeheim","topic_prefix":"shelly1"}}';
	my $redacted = main::MQTT2_DISCOVERY_redact_payload($payload);
	like($redacted, qr/"pass":"xxx"/, 'das WLAN-Passwort ist ersetzt');
	unlike($redacted, qr/geheim/, 'kein Geheimnis bleibt uebrig');
	like($redacted, qr/"ssid":"MeinWLAN"/, 'die SSID bleibt, sie ist kein Geheimnis');
	like($redacted, qr/"topic_prefix":"shelly1"/, 'das Topic bleibt, es wird zum Nachstellen gebraucht');

	# Ein einfacher Wert ist kein JSON und bleibt unveraendert.
	is(main::MQTT2_DISCOVERY_redact_payload('true'), 'true', 'ein einfacher Wert bleibt');
};

subtest 'get payloads liefert die Nachrichten des Geraets' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	ok($main::defs{$device}, 'das Geraet entsteht');
	my $block = main::MQTT2_DISCOVERY_Get($hash, 'discovery', 'payloads', $device);
	like($block, qr/^# MQTT2_DISCOVERY .*Adapter tasmota/m, 'der Kopf nennt Geraet und Adapter');
	like($block, qr{^\Q$config_topic\E \{"dn":"Tasmota"}m, 'die Konfiguration steht drin');
	like($block, qr{^\Q$sensors_topic\E \{"sn":}m, 'die Sensoren stehen drin');

	# Ein unbekanntes Geraet wird benannt, nicht stillschweigend uebergangen.
	like(main::MQTT2_DISCOVERY_Get($hash, 'discovery', 'payloads', 'gibtsnicht'),
		qr/kein von dieser Instanz verwaltetes Geraet/, 'ein fremder Name wird abgewiesen');
	like(main::MQTT2_DISCOVERY_Get($hash, 'discovery', '?'), qr/payloads:\Q$device\E/,
		'die Auswahl nennt die verwalteten Geraete');
};

subtest 'replayPayloads baut das Geraet ohne die Hardware nach' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	my $block = main::MQTT2_DISCOVERY_Get($hash, 'discovery', 'payloads', $device);
	my $file = File::Temp->new(SUFFIX => '.txt');
	print {$file} "$block\n" or die $!;
	close $file or die $!;

	# Eine frische Instanz kennt das Geraet nicht; der Block allein genuegt.
	$hash = setup();
	ok(!$main::defs{$device}, 'nach dem Neuaufbau gibt es das Geraet nicht mehr');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'replayPayloads', "$file"), undef,
		'der Block wird ohne Fehler eingespielt');
	ok($main::defs{$device}, 'das Geraet entsteht aus den Nachrichten');
	is(reading_value('discovery', 'lastReplay'), 'processed=2 failed=0', 'beide Nachrichten zaehlen');

	like(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'replayPayloads', '/tmp/../etc/passwd'),
		qr/nicht aus dem Verzeichnis herausfuehren/, 'ein Pfad mit .. wird abgewiesen');
};

done_testing();
