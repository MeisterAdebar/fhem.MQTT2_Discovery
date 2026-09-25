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

	# Topics und Kennungen bleiben, wie sie sind: Ersetzt man sie, beschreibt der
	# Block ein anderes Geraet, und sein Zwilling sendet auf einen Zweig, auf dem
	# keine Hardware antwortet.
	like($block, qr{^tasmota/discovery/00005E005301/config}m, 'das echte Topic steht drin');
	like($block, qr/"mac":"00005E005301"/, 'die echte Kennung ebenfalls');
	like($block, qr/"t":"tasmota_005301"/, 'und das eigene Topic des Geraets');

	# Was das Netz des Anwenders verraet, wird trotzdem ersetzt.
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
	is(reading_value('discovery', 'replayPayloads'), 'processed=2 failed=0', 'beide Nachrichten zaehlen');

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

subtest 'der eigene Block stellt sein Geraet wieder her' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);

	# Das Modul tauscht beim Anwenden den ganzen Registry-Hash aus. Wer sich eine
	# Referenz merkt, prueft danach den alten Stand; geholt wird deshalb frisch.
	my $records = sub { FHEM::MQTT2_DISCOVERY::registry($hash)->{devices} };
	my $spielen = sub {
		return FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads',
			'base64:' . MIME::Base64::encode_base64($_[0], ''));
	};
	is(scalar keys %{ $records->() }, 1, 'ein Geraet, ein Datensatz');
	my ($identity) = keys %{ $records->() };
	my $cid = $records->()->{$identity}{cid};
	is($cid, 'client1', 'der Datensatz traegt die Client-ID des Geraets');

	# Weil Topics und Kennungen im Block stehen, trifft er dieselbe Identitaet
	# wie das echte Geraet. Zweimal einspielen legt deshalb nichts Neues an.
	is($spielen->($block), undef, 'der Block wird eingespielt');
	is([ sort keys %{ $records->() } ], [$identity], 'es bleibt bei der einen Identitaet');
	is($records->()->{$identity}{cid}, $cid, 'und bei ihrer Client-ID');

	# Und er stellt sein Geraet wieder her, wenn es fehlt. Die Client-ID steht in
	# keiner Nachricht; ohne die aus dem Datensatz kaeme das Geraet mit der
	# Ersatz-ID replay zurueck und verlaere seine Zuordnung am IODev.
	delete $main::defs{$device};
	is($spielen->($block), undef, 'noch einmal eingespielt');
	ok($main::defs{$device}, 'das Geraet ist wieder da');
	is([ sort keys %{ $records->() } ], [$identity], 'ohne einen zweiten Datensatz');
	is($records->()->{$identity}{cid}, $cid, 'mit seiner eigenen Client-ID, nicht mit replay');
	like($main::attr{$device}{setList} // '', qr{cmnd/tasmota_005301/POWER},
		'und es sendet weiter auf seinem cmnd-Zweig');
	is($main::attr{$device}{comment}, undef, 'ein wiederhergestelltes Geraet ist kein Papiergeraet');
};

subtest 'ein fremder Block nimmt keinem Geraet den Namen weg' => sub {
	my $hash = setup();
	dispatch_message('mqtt', 'client1', $config_topic, $config);
	dispatch_message('mqtt', 'client1', $sensors_topic, $sensors);
	my $block = FHEM::MQTT2_DISCOVERY::Get($hash, 'discovery', 'payloads', $device);

	# Ein Block aus einer fremden Anlage: anderes Geraet, aber derselbe
	# Anwendername, und damit derselbe Vorschlag fuer den Geraetenamen.
	my $fremd = $block;
	$fremd =~ s/00005E005301/AABBCCDDEEFF/g;
	$fremd =~ s/tasmota_005301/tasmota_DDEEFF/g;
	$fremd =~ s/-005301-/-DDEEFF-/g;

	# Fehlt das eigene Geraet gerade - von Hand geloescht, umbenannt, aus der
	# Sicherung noch nicht zurueck -, war sein Name frei. Der fremde Block legte
	# dann ein Geraet unter diesem Namen an, und von da an sendeten zwei
	# Datensaetze unter einem Namen auf verschiedene Topics.
	delete $main::defs{$device};
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads',
		'base64:' . MIME::Base64::encode_base64($fremd, '')), undef, 'der fremde Block wird eingespielt');

	my $records = FHEM::MQTT2_DISCOVERY::registry($hash)->{devices};
	my %names;
	$names{ $_->{name} }++ for grep { ref($_) eq 'HASH' && defined($_->{name}) } values %$records;
	is([ sort grep { $names{$_} > 1 } keys %names ], [],
		'kein Name gehoert zwei Datensaetzen');

	my ($live) = grep { ($_->{cid} // '') ne 'replay' } values %$records;
	is($live->{name}, $device, 'der eigene Datensatz behaelt seinen Namen');
	my ($fremder) = grep { ($_->{cid} // '') eq 'replay' } values %$records;
	isnt($fremder->{name}, $device, 'der fremde bekommt einen eigenen');

	# Der Fehler war unsichtbar: Die Befehle standen weiter am Geraet, sie
	# veroeffentlichten nur auf dem Topic des fremden.
	like($main::attr{ $fremder->{name} }{setList} // '', qr{cmnd/tasmota_DDEEFF/POWER},
		'der fremde sendet auf seinem eigenen cmnd-Zweig');

	# Hinter einem fremden Geraet steht hier keine Hardware. Es sendet richtig,
	# es antwortet nur niemand, und sein state bleibt auf set_<befehl>.
	like($main::attr{ $fremder->{name} }{comment} // '', qr/Ohne die zugehoerige Hardware/,
		'es sagt am Geraet, dass ihm die Hardware fehlt');
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
	is(reading_value('discovery', 'replayPayloads'), 'processed=3 failed=0',
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
	like($dialog, qr/id='m2dReplayCmd' value='set discovery replayPayloads'/,
		'der Befehl steht wie im Schluesseldialog in einem verborgenen Feld');
	like($dialog, qr/\Q+" base64:"+block\E/, 'OK schickt den Block als ein Stueck');
	like($dialog, qr/ui-dialog-buttonpane button/, 'uebernommen wird mit dem OK des Fensters');
	unlike($dialog, qr/value="Einspielen"/, 'einen eigenen Knopf gibt es nicht mehr');

	# FHEMWEB fuehrt das Merkmal als FW_csrfToken und haengt es mit addcsrf an.
	# Ein FW_csrf gibt es dort nicht; es hatte das Abschicken zerlegt.
	like($dialog, qr/addcsrf|FW_csrfToken/, 'das Merkmal wird so geholt, wie FHEMWEB es fuehrt');
	unlike($dialog, qr/FW_csrf\b/, 'und nicht unter einem Namen, den es nicht gibt');

	# Eingefuegt wird er als ein Stueck, damit Leerzeichen und Umbrueche die
	# Befehlszeile nicht zerlegen.
	$hash = setup();
	my $base64 = MIME::Base64::encode_base64($block, '');
	is(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', "base64:$base64"), undef,
		'der eingefuegte Block wird verarbeitet');
	ok($main::defs{$device}, 'das Geraet entsteht daraus');
	is(reading_value('discovery', 'replayPayloads'), 'processed=2 failed=0', 'beide Nachrichten zaehlen');

	# Ein leeres Feld ist kein Fehlerfall, aber auch keine Eingabe.
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads',
		'base64:' . MIME::Base64::encode_base64("\n\n", '')), qr/leer/, 'ein leerer Block wird benannt');
};

subtest 'ein in die Befehlszeile eingefuegter Block wird erklaert' => sub {
	my $hash = setup();

	# FHEM zerlegt die Befehlszeile in Woerter; der Block verliert dabei seine
	# Zeilenumbrueche und ist danach nicht mehr lesbar. Erkennbar ist das an
	# mehreren Topics in einer Zeile.
	my $antwort = FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads',
		'tasmota/discovery/AABBCCDDEEFF/config', '{"dn":"X"}',
		'tasmota/discovery/AABBCCDDEEFF/sensors', '{"sn":{}}');
	like($antwort, qr/Zeilenumbrueche verloren/, 'der Grund wird genannt');
	like($antwort, qr/replayPayloads ohne Angabe/, 'und der Weg, der funktioniert');

	# Ein einzelner Dateiname bleibt ein Dateiname.
	like(FHEM::MQTT2_DISCOVERY::Set($hash, 'discovery', 'replayPayloads', 'gibtsnicht.txt'),
		qr/nicht lesen/, 'ein Dateiname wird weiterhin als solcher behandelt');
};

done_testing();
