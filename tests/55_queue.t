# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use JSON::PP qw(decode_json);
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery receive_client_message
	reading_value command_log);

our (@TIMERS, $MQTT2_DISCOVERY_QUEUE_DELAY);

# Liefert eine feste Zeitbasis fuer reproduzierbare Timertermine.
sub main::gettimeofday { return 1_700_000_000 }
# Speichert geplante FHEM-Timer, ohne einen echten Event-Loop zu starten.
sub main::InternalTimer {
	my ($when, $function, $argument, $wait_if_init_not_done) = @_;
	push @TIMERS, [$when, $function, $argument, $wait_if_init_not_done];
	return;
}
# Entfernt passende Timer aus der simulierten Timerwarteschlange.
sub main::RemoveInternalTimer {
	my ($argument, $function) = @_;
	@TIMERS = grep { $_->[2] != $argument || $_->[1] ne $function } @TIMERS;
	return;
}
my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

# Fuehrt den zeitlich naechsten gespeicherten Timer synchron im Test aus.
sub run_next_timer {
	my $timer = shift @TIMERS or die 'Kein Timer eingeplant';
	my $function = $timer->[1];
	no strict 'refs';
	&{ "main::$function" }($timer->[2]);
}

# Erstellt fuer jeden Queue-Test eine frische Discovery- und IODev-Umgebung.
sub setup {
	my ($io_type) = @_;
	@TIMERS = ();
	reset_env();
	my $io = add_iodev('mqtt', $io_type || 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_';
	return ($hash, $io);
}

# Verpackt Topic und Payload im von FHEMs MQTT-Dispatch verwendeten Nullbyteformat.
sub mqtt_message {
	my ($topic, $payload) = @_;
	return "autocreate=simple\0client\0$topic\0$payload";
}

subtest 'Parse legt Arbeit ab und konsumiert Discovery sofort' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';

	is(main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload)), '',
		'Discovery wird konsumiert');
	ok(!$main::defs{MQTT2_Node}, 'Device wird nicht im MQTT-Dispatch angelegt');
	is(scalar(@TIMERS), 1, 'genau ein Worker-Timer ist eingeplant');

	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'erster Timer bereitet die Discovery-Nachricht vor');
	ok(!$main::attr{MQTT2_Node}{readingList}, 'Device-Attribute warten auf einen eigenen Timer-Tick');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{client}, [$main::defs{MQTT2_Node}],
		'Define registriert das Ziel sofort in FHEMs CID-Index');
	is(scalar(@TIMERS), 1, 'Attributphase ist separat eingeplant');

	run_next_timer();
	like($main::attr{MQTT2_Node}{readingList}, qr/(?:\$DEVICETOPIC|node)\/temp/,
		'zweiter Timer schreibt die vorbereiteten Device-Attribute');
	my ($reading_regexp) = split /\s+/, $main::attr{MQTT2_Node}{readingList}, 2;
	$reading_regexp =~ s/\$DEVICETOPIC/node/g;
	ok("node/temp:{\"temperature\":21}" =~ m/^$reading_regexp$/s,
		'fertige readingList setzt FHEMs fnd vor dem Autocreate-Zweig');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'Zaehler ist nach Batch-Abschluss aktuell');
	is(scalar(@TIMERS), 0, 'leere Queue plant keinen weiteren Timer');
};

subtest 'retained Discovery wartet beim Neustart auf INITIALIZED' => sub {
	my ($running, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temperature/config';
	my $payload = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}",'
		. '"uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node"}}';

	# Der erste Lauf erzeugt den Besitzstand, den FHEM beim Neustart erst aus dem
	# statefile wiederherstellt.
	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	my $target = 'MQTT2_Node';
	my $stored_registry = reading_value('discovery', '.registry');
	my $reading_list = $main::attr{$target}{readingList};
	my $set_list = $main::attr{$target}{setList};
	my $device_topic = $main::attr{$target}{devicetopic};
	my $cid = $main::defs{$target}{DEF};

	# Beim Neustart sind Definitionen und Attribute bereits vorhanden, die
	# persistierte Registry fehlt jedoch bis zum Einlesen des statefile.
	@TIMERS = ();
	reset_env();
	my $restart_io = add_iodev('mqtt', 'MQTT2_SERVER');
	is(main::CommandDefine(undef, "$target MQTT2_DEVICE $cid mqtt"), undef,
		'vorhandenes Zieldevice wird aus der Konfiguration geladen');
	$main::attr{$target}{readingList} = $reading_list;
	$main::attr{$target}{setList} = $set_list if defined $set_list;
	$main::attr{$target}{devicetopic} = $device_topic if defined $device_topic;
	$main::init_done = 0;
	my ($restarted, $define_error) = define_discovery('discovery', 'mqtt');
	is($define_error, undef, 'Discovery wird vor INITIALIZED definiert');
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_';

	main::MQTT2_DISCOVERY_Parse($restart_io, mqtt_message($topic, $payload));
	is(scalar(@TIMERS), 0, 'vor INITIALIZED wird kein Polling-Timer eingeplant');
	ok($restarted->{helper}{queue}{waiting_for_init},
		'retained Discovery bleibt bis zum Lifecycle-Ereignis geparkt');
	main::MQTT2_DISCOVERY_process_queue($restarted);
	is($main::attr{$target}{readingList}, $reading_list,
		'defensiver Direktlauf vor INITIALIZED veraendert die readingList nicht');
	ok(!exists($restarted->{helper}{registry}),
		'leerer Vor-statefile-Stand wird weiterhin nicht gecacht');
	is(scalar(@TIMERS), 0, 'defensiver Direktlauf startet ebenfalls kein Polling');

	# Nach INITIALIZED muss dieselbe Nachricht gegen den restaurierten Besitzstand
	# idempotent verarbeitet werden.
	$restarted->{READINGS}{'.registry'} = {
		VAL => $stored_registry, TIME => '2026-08-22 12:00:00',
	};
	$main::init_done = 1;
	my ($reference) = $reading_list =~ /'(r_[a-f0-9]+)'/;
	is(main::MQTT2_DISCOVERY_runtimeRef(
			$target, $reference, '{"temperature":21}'),
		{ temperature => '21' },
		'die Referenz wird nach Neustart direkt aus dem restaurierten Registry-Reading aufgeloest');
	main::MQTT2_DISCOVERY_Notify($restarted, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(scalar(@TIMERS), 1, 'INITIALIZED startet die geparkte Queue genau einmal');
	main::MQTT2_DISCOVERY_Notify($restarted, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(scalar(@TIMERS), 1, 'wiederholtes INITIALIZED erzeugt keinen zweiten Timer');
	is($TIMERS[0][3], 0, 'Lifecycle-Timer blockiert den FHEM-Start nicht');
	run_next_timer() while @TIMERS;
	is($main::attr{$target}{readingList}, $reading_list,
		'retained Discovery dupliziert nach INITIALIZED keine eigene Zeile');
	is(scalar(() = $main::attr{$target}{readingList} =~ /runtimeRef/g), 1,
		'topicweite Referenz-readingList-Zeile bleibt genau einmal vorhanden');

	# REREADCFG wird von FHEM noch vor init_done=1 ausgeloest. Der geplante Timer
	# laeuft erst nach der Rueckkehr in den Eventloop und verarbeitet dann sicher.
	my $humidity_topic = 'homeassistant/sensor/node/humidity/config';
	my $humidity_payload = '{"stat_t":"node/data","val_tpl":"{{ value_json.humidity }}",'
		. '"uniq_id":"node_humidity","dev":{"ids":["node"],"name":"Node"}}';
	$main::init_done = 0;
	main::MQTT2_DISCOVERY_Parse(
		$restart_io, mqtt_message($humidity_topic, $humidity_payload),
	);
	is(scalar(@TIMERS), 0, 'auch vor REREADCFG bleibt neue Arbeit ohne Polling geparkt');
	main::MQTT2_DISCOVERY_Notify($restarted, {
		NAME => 'global', CHANGED => ['REREADCFG'],
	});
	is(scalar(@TIMERS), 1, 'REREADCFG plant die geparkte Queue fuer den Eventloop');
	$main::init_done = 1;
	run_next_timer() while @TIMERS;
	is(reading_value('discovery', 'discoveredEntities'), 2,
		'REREADCFG verarbeitet die zusaetzlich geparkte Entity');
};

subtest 'fehlendes Registry-Ziel wird nach Neustart neu aufgebaut' => sub {
	my ($running, $io) = setup();
	my @discoveries = (
		[
			'homeassistant/sensor/node/temperature/config',
			'{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}",'
				. '"uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node"}}',
		],
		[
			'homeassistant/sensor/node/humidity/config',
			'{"stat_t":"node/data","val_tpl":"{{ value_json.humidity }}",'
				. '"uniq_id":"node_humidity","dev":{"ids":["node"],"name":"Node"}}',
		],
	);
	my $target = 'MQTT2_Node';
	is(main::CommandDefine(undef, "$target MQTT2_DEVICE client mqtt"), undef,
		'Ausgangszustand besitzt ein vorhandenes, spaeter uebernommenes Zieldevice');

	# Die erste Verarbeitung erzeugt einen Registry-Eintrag fuer das bereits
	# vorhandene Device, ohne dessen manuelle Herkunft zu veraendern.
	for my $discovery (@discoveries) {
		main::MQTT2_DISCOVERY_Parse($io, mqtt_message(@$discovery));
	}
	run_next_timer() while @TIMERS;
	my $stored_registry = reading_value('discovery', '.registry');
	my ($stored_record) = values %{ decode_json($stored_registry)->{devices} };
	is($stored_record->{created}, 0, 'uebernommenes Device ist nicht als eigenerzeugt markiert');

	# Die neue Konfiguration enthaelt das Zieldevice nicht mehr, waehrend das
	# statefile weiterhin den bisherigen Discovery-Besitzstand wiederherstellt.
	@TIMERS = ();
	reset_env();
	my $restart_io = add_iodev('mqtt', 'MQTT2_SERVER');
	$main::init_done = 0;
	my ($restarted, $define_error) = define_discovery('discovery', 'mqtt');
	is($define_error, undef, 'Discovery wird aus der reduzierten Konfiguration geladen');
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_';
	$restarted->{READINGS}{'.registry'} = {
		VAL => $stored_registry, TIME => '2026-08-22 12:00:00',
	};
	$main::init_done = 1;

	for my $discovery (@discoveries) {
		main::MQTT2_DISCOVERY_Parse($restart_io, mqtt_message(@$discovery));
	}
	run_next_timer() while @TIMERS;

	ok($main::defs{$target}, 'fehlendes Zieldevice wird aus der Retained Discovery neu angelegt');
	like($main::attr{$target}{readingList}, qr/runtimeRef/,
		'neu aufgebautes Device erhaelt die kompakte Topic-Referenz');
	is(scalar(grep { /^define \Q$target\E MQTT2_DEVICE / } @{ command_log() }), 1,
		'der gesamte Burst legt das fehlende Ziel genau einmal neu an');
	is(reading_value('discovery', 'discoveredEntities'), 2,
		'bereinigte Registry enthaelt wieder beide Entities');
	my ($repaired_record) = values %{ decode_json(reading_value('discovery', '.registry'))->{devices} };
	my $entity_keys = join("\n", sort keys %{ $repaired_record->{entities} });
	like($entity_keys, qr{/temperature/config},
		'neu aufgebaute Registry enthaelt die erste Entity');
	like($entity_keys, qr{/humidity/config},
		'neu aufgebaute Registry enthaelt die zweite Entity desselben Bursts');
	is($repaired_record->{created}, 1,
		'neu angelegtes Ersatzdevice ist anschliessend als eigenerzeugt markiert');
};

subtest 'fehlendes Registry-Ziel respektiert autoCreate und bleibt wiederholbar' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temperature/config';
	my $payload = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}",'
		. '"uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node"}}';
	my $target = 'MQTT2_Node';

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	my $stored_registry = reading_value('discovery', '.registry');
	is(main::CommandDelete(undef, $target), undef, 'verwaltetes Zieldevice wird manuell geloescht');
	$main::attr{discovery}{autoCreate} = 0;

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	ok(!$main::defs{$target}, 'autoCreate=0 legt das fehlende Ziel nicht erneut an');
	like(reading_value('discovery', 'lastError'), qr/autoCreate ist deaktiviert/,
		'fehlende Neuanlage wird mit der bestehenden autoCreate-Meldung erklaert');
	is(reading_value('discovery', '.registry'), $stored_registry,
		'fehlgeschlagener Versuch behaelt den bisherigen Registry-Stand fuer einen Retry');

	$main::attr{discovery}{autoCreate} = 1;
	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	ok($main::defs{$target}, 'spaeter aktiviertes autoCreate baut dasselbe Ziel erfolgreich neu auf');
	is(reading_value('discovery', 'lastError'), 'none', 'erfolgreicher Retry bereinigt den Topic-Fehler');
};

subtest 'MQTT2_CLIENT verarbeitet Retained erst nach dem Neustart' => sub {
	my ($running, $io) = setup('MQTT2_CLIENT');
	is(main::MQTT2_DISCOVERY_Set($running, 'discovery', 'activate'), undef,
		'Discovery wird in die Parserreihenfolge des Clients aufgenommen');
	my $client_order = $main::attr{mqtt}{clientOrder};
	my $device = '"dev":{"ids":["z2m_light"],"name":"WZ_LIGHTSTRIP_LICHT"}';
	my @discoveries = (
		[
			'homeassistant/light/z2m_light/light/config',
			'{"schema":"json","brightness":true,"brightness_scale":254,'
				. '"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT",'
				. '"cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set",'
				. '"avty":[{"t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/availability",'
				. '"val_tpl":"{{ value_json.state }}"},{"t":"zigbee2mqtt/bridge/state",'
				. '"val_tpl":"{{ value_json.state }}"}],"uniq_id":"z2m_light_light",'
				. $device . '}',
		],
		[
			'homeassistant/select/z2m_light/effect/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT",'
				. '"stat_val_tpl":"{{ value_json.effect }}",'
				. '"cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set/effect",'
				. '"ops":["blink","breathe"],"uniq_id":"z2m_light_effect",'
				. $device . '}',
		],
		[
			'homeassistant/number/z2m_light/effect_speed/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT",'
				. '"stat_val_tpl":"{{ value_json.effect_speed }}",'
				. '"cmd_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set/effect_speed",'
				. '"min":0,"max":1,"step":0.01,"uniq_id":"z2m_light_effect_speed",'
				. $device . '}',
		],
		[
			'homeassistant/sensor/z2m_light/linkquality/config',
			'{"stat_t":"zigbee2mqtt/WZ_LIGHTSTRIP_LICHT",'
				. '"stat_val_tpl":"{{ value_json.linkquality }}",'
				. '"uniq_id":"z2m_light_linkquality",' . $device . '}',
		],
	);

	# Der laufende Client empfaengt einen Retained-Burst. Alle Entities eines
	# Zieldevices werden erst nach dem vollstaendigen Burst gemeinsam geschrieben.
	for my $discovery (@discoveries) {
		is(receive_client_message('mqtt', 'z2m', @$discovery), ['MQTT2_DISCOVERY'],
			'MQTT2_CLIENT reicht das Discovery-Topic an den Parser weiter');
	}

	run_next_timer() while @TIMERS;
	my $target = 'MQTT2_WZ_LIGHTSTRIP_LICHT';
	my $stored_registry = reading_value('discovery', '.registry');
	my $reading_list = $main::attr{$target}{readingList};
	my $set_list = $main::attr{$target}{setList};
	my $device_topic = $main::attr{$target}{devicetopic};
	my $cid = $main::defs{$target}{DEF};
	ok($reading_list, 'erster Client-Lauf erzeugt die erwartete readingList');
	is(scalar(split /\n/, $reading_list), 3,
		'das reale WZ-Beispiel erzeugt drei eindeutige readingList-Zeilen');

	# Beim Neustart sind Device, Attribute und statefile bereits vorhanden. Der
	# MQTT2_CLIENT verbindet sich aber erst nach init_done und liefert dann die
	# Retained-Nachrichten des Brokers.
	@TIMERS = ();
	reset_env();
	my $restart_io = add_iodev('mqtt', 'MQTT2_CLIENT');
	is(main::CommandAttr(undef, "mqtt clientOrder $client_order"), undef,
		'gespeicherte Client-Reihenfolge wird beim Neustart wiederhergestellt');
	is(main::CommandDefine(undef, "$target MQTT2_DEVICE $cid mqtt"), undef,
		'vorhandenes Zieldevice wird aus der Konfiguration geladen');
	$main::attr{$target}{readingList} = join("\n", ($reading_list) x 8);
	is(scalar(split /\n/, $main::attr{$target}{readingList}), 24,
		'der gemeldete Fehlerstand aus acht Kopien enthaelt 24 Zeilen');
	$main::attr{$target}{setList} = $set_list;
	$main::attr{$target}{devicetopic} = $device_topic;
	$main::init_done = 0;
	my ($restarted, $define_error) = define_discovery('discovery', 'mqtt');
	is($define_error, undef, 'Discovery wird vor INITIALIZED definiert');
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_';
	$restarted->{READINGS}{'.registry'} = {
		VAL => $stored_registry, TIME => '2026-08-22 12:00:00',
	};
	$main::attr{mqtt}{ignoreRegexp} = 'homeassistant/[^:"]+/config';
	$main::init_done = 1;
	main::MQTT2_DISCOVERY_Notify($restarted, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(scalar(@TIMERS), 0,
		'INITIALIZED startet ohne vorzeitig empfangene Client-Nachricht keine Queue');

	# MQTT2_CLIENT verwirft passende Topics vor dem Dispatch. Dadurch kann die
	# Discovery vorhandene Duplikate weder erzeugen noch korrigieren.
	for my $discovery (@discoveries) {
		is(receive_client_message('mqtt', 'z2m', @$discovery), [],
			'ignoreRegexp filtert das Retained-Topic vor MQTT2_DISCOVERY');
	}

	is(scalar(@TIMERS), 0, 'gefilterte Retained-Nachrichten planen keinen Worker');
	is($main::attr{$target}{readingList}, join("\n", ($reading_list) x 8),
		'ohne Parser-Aufruf bleibt die vorhandene achtfache readingList unveraendert');

	# Ohne Filter verarbeitet die Queue denselben Retained-Burst. Der Generator
	# fuehrt alle Entities einmal zusammen und ersetzt den alten Besitzstand. Die
	# testweise Wartezeit von fuenf Sekunden veraendert nur den Timertermin.
	delete $main::attr{mqtt}{ignoreRegexp};
	local $MQTT2_DISCOVERY_QUEUE_DELAY = 5;
	my $commands_before_replay = scalar @{ command_log() };
	for my $discovery (@discoveries) {
		is(receive_client_message('mqtt', 'z2m', @$discovery), ['MQTT2_DISCOVERY'],
			'Retained-Topic erreicht MQTT2_DISCOVERY nach Entfernen des Filters');
	}

	is(scalar(@TIMERS), 1, 'der komplette Retained-Burst plant genau einen Worker');
	is($TIMERS[0][0], main::gettimeofday() + 5,
		'die Queue beginnt testweise erst fuenf Sekunden nach dem ersten Topic');
	run_next_timer() while @TIMERS;
	is($main::attr{$target}{readingList}, $reading_list,
		'die Verarbeitung reduziert acht alte Kopien auf genau einen Besitzstand');
	is(scalar(split /\n/, $main::attr{$target}{readingList}), 3,
		'der fertige Attributwert enthaelt wieder nur drei Zeilen');
	my @replay_commands = @{ command_log() }[
		$commands_before_replay .. $#{ command_log() }
	];
	is(scalar(grep { /^attr \Q$target\E readingList / } @replay_commands), 1,
		'der gesamte Erzeugungsweg schreibt readingList genau einmal');
};

subtest 'regulaeres Autocreate vor dem Discovery-Worker wird uebernommen' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';

	is(main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload)), '',
		'Discovery wird vor MQTT2_DEVICE konsumiert und eingeplant');
	is(main::CommandDefine(undef, 'client MQTT2_DEVICE client mqtt'), undef,
		'simuliertes State-Autocreate legt die Transport-CID vor dem Worker an');

	run_next_timer() while @TIMERS;
	ok(!$main::defs{MQTT2_Node}, 'Discovery legt kein zweites vorgeschlagenes Device an');
	like($main::attr{client}{readingList}, qr/(?:\$DEVICETOPIC|node)\/temp/,
		'Discovery uebernimmt und erweitert das zwischenzeitlich autocreated Device');
	is($hash->{helper}{registry}{devices}{'mqtt|id|node'}{name}, 'client',
		'Discovery-Registry zeigt auf das bereits vorhandene CID-Device');
};

subtest 'Burst wird portioniert und identische Topics werden zusammengefasst' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $first = '{"uniq_id":"node_temp","stat_t":"node/old","dev":{"ids":["node"],"name":"Node"}}';
	my $latest = '{"uniq_id":"node_temp","stat_t":"node/latest","dev":{"ids":["node"],"name":"Node"}}';
	my $other = '{"uniq_id":"other_temp","stat_t":"other/temp","dev":{"ids":["other"],"name":"Other"}}';

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $first));
	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $latest));
	main::MQTT2_DISCOVERY_Parse($io,
		mqtt_message('homeassistant/sensor/other/temp/config', $other));
	is(scalar(@TIMERS), 1, 'Burst plant nur einen Start-Timer');

	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'erstes Topic wurde vorbereitet');
	ok(!$main::attr{MQTT2_Node}{readingList}, 'erstes Topic schreibt noch keine Attribute');
	ok(!$main::defs{MQTT2_Other}, 'zweites Topic wartet auf den naechsten Tick');
	is(scalar(@TIMERS), 1, 'naechster Tick ist eingeplant');

	run_next_timer();
	ok($main::defs{MQTT2_Other}, 'zweites Topic wird im naechsten Tick vorbereitet');
	ok(!$main::attr{MQTT2_Node}{readingList} && !$main::attr{MQTT2_Other}{readingList},
		'nach der Topic-Phase sind noch keine Device-Attribute geschrieben');

	run_next_timer();
	is(scalar(grep { $main::attr{$_}{readingList} } qw(MQTT2_Node MQTT2_Other)), 1,
		'ein Timer-Tick aktualisiert hoechstens ein Zieldevice');
	is(scalar(@TIMERS), 1, 'zweites Zieldevice bleibt eingeplant');

	run_next_timer();
	like($main::attr{MQTT2_Node}{readingList}, qr/(?:\$DEVICETOPIC|node)\/latest/,
		'nur der neueste Stand des zusammengefassten Topics wird verwendet');
	ok($main::attr{MQTT2_Other}{readingList}, 'zweites Zieldevice wurde aktualisiert');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'beide Topic-Staende sind registriert');
};

subtest 'ein Burst persistiert die Registry nur einmal' => sub {
	my ($hash, $io) = setup();
	my $original = \&main::readingsSingleUpdate;
	my $registry_writes = 0;

	{
		no warnings qw(redefine);
		local *main::readingsSingleUpdate = sub($$$$) {
			++$registry_writes if $_[1] eq '.registry';
			return $original->(@_);
		};
		for my $index (1 .. 20) {
			my $payload = qq({"uniq_id":"node_$index","stat_t":"node/$index",)
				. qq("dev":{"ids":["node"],"name":"Node"}});
			main::MQTT2_DISCOVERY_Parse($io,
				mqtt_message("homeassistant/sensor/node/value_$index/config", $payload));
		}
		run_next_timer() while @TIMERS;
	}

	is($registry_writes, 1, 'Registry wird nicht mehr fuer jedes einzelne Topic serialisiert');
	is(reading_value('discovery', 'discoveredEntities'), 20, 'der gesamte Burst wurde uebernommen');
};

subtest 'retained Delete wird ebenfalls portioniert' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';
	$main::attr{discovery}{autoDelete} = 1;

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	ok($main::defs{MQTT2_Node}, 'Ausgangsdevice wurde angelegt');

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, ''));
	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'Topic-Tick entfernt das Device noch nicht im selben Event-Loop-Lauf');
	is(scalar(@TIMERS), 1, 'Device-Aktualisierung des Deletes ist separat eingeplant');

	run_next_timer();
	ok(!$main::defs{MQTT2_Node}, 'Device-Tick fuehrt autoDelete kontrolliert aus');
	is(reading_value('discovery', 'discoveredEntities'), 0, 'Registry ist nach Delete leer');
};

subtest 'Lifecycle gleicht den bisherigen Availability-Default aus der Registry ab' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/state",'
		. '"val_tpl":"{{ value_json.temperature }}","avty_t":"node/status",'
		. '"dev":{"ids":["node"],"name":"Node"}}';
	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	my ($record) = values %{ $hash->{helper}{registry}{devices} };
	$record->{availability_reading} = 'deviceAvailability';
	$record->{owned_availability_reading} = 'deviceAvailability';
	$main::defs{MQTT2_Node}{READINGS}{deviceAvailability} = { VAL => 'unknown' };
	delete $main::defs{MQTT2_Node}{READINGS}{availability};
	ok(main::MQTT2_DISCOVERY_registry_rendering_outdated($hash),
		'der gespeicherte bisherige Default wird als veraltet erkannt');
	$main::attr{MQTT2_Node}{readingList} .= "\nmanual/default:.* availability";

	main::MQTT2_DISCOVERY_Notify($hash, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(scalar(@TIMERS), 0,
		'eine manuelle Belegung blockiert auch den automatischen Lifecycle-Abgleich');
	like(reading_value('discovery', 'lastWarning'), qr/MQTT2_Node/,
		'die Lifecycle-Warnung nennt das blockierende Zieldevice');
	$main::attr{MQTT2_Node}{readingList} = join("\n", grep {
		$_ ne 'manual/default:.* availability'
	} split /\n/, $main::attr{MQTT2_Node}{readingList});
	main::MQTT2_DISCOVERY_Notify($hash, {
		NAME => 'global', CHANGED => ['INITIALIZED'],
	});
	is(scalar(@TIMERS), 1,
		'das Lifecycle-Ereignis plant genau eine registry-basierte Neuerzeugung');
	run_next_timer() while @TIMERS;
	is(reading_value('MQTT2_Node', 'availability'), 'unknown',
		'der aktuelle Zustand steht nach dem Abgleich unter dem neuen Default');
	ok(!exists($main::defs{MQTT2_Node}{READINGS}{deviceAvailability}),
		'das nachweislich modulverwaltete alte Defaultreading wurde entfernt');
	ok(!main::MQTT2_DISCOVERY_registry_rendering_outdated($hash),
		'der aktualisierte Registry-Stand entspricht dem neuen Default');
};

subtest 'Renderattribute werden registryweit und ohne neue Discovery angewendet' => sub {
	my ($hash, $io) = setup();
	my @discoveries = (
		[
			'homeassistant/sensor/node/temp/config',
			'{"uniq_id":"node_temp","stat_t":"node/state",'
				. '"val_tpl":"{{ value_json.temperature }}","avty_t":"node/status",'
				. '"dev":{"ids":["node"],"name":"Node"}}',
		],
		[
			'homeassistant/sensor/other/temp/config',
			'{"uniq_id":"other_temp","stat_t":"other/state",'
				. '"val_tpl":"{{ value_json.temperature }}","avty_t":"other/status",'
				. '"dev":{"ids":["other"],"name":"Other"}}',
		],
	);

	# Beide Ziele werden einmalig aus Discovery aufgebaut; alle folgenden
	# Umbenennungen muessen ausschliesslich aus der Registry erfolgen.
	for my $discovery (@discoveries) {
		main::MQTT2_DISCOVERY_Parse($io, mqtt_message(@$discovery));
	}

	run_next_timer() while @TIMERS;
	my @targets = qw(MQTT2_Node MQTT2_Other);
	is([map { reading_value($_, 'availability') } @targets], ['unknown', 'unknown'],
		'der Ausgangszustand verwendet auf beiden Zielen das Standardreading');

	is(main::MQTT2_DISCOVERY_Attr(
			'set', 'discovery', 'availabilityReading', 'MQTT2DiscoveryAvailability',
		), undef, 'ein sicherer globaler Availability-Name wird akzeptiert');
	$main::attr{discovery}{availabilityReading} = 'MQTT2DiscoveryAvailability';
	is(scalar(@TIMERS), 1, 'die Attributaenderung plant genau einen Queue-Worker');
	run_next_timer() while @TIMERS;

	for my $target (@targets) {
		is(reading_value($target, 'MQTT2DiscoveryAvailability'), 'unknown',
			"$target verwendet den global festgelegten Availability-Namen");
		ok(!exists($main::defs{$target}{READINGS}{availability}),
			"$target enthaelt das alte modulverwaltete Reading nicht mehr");
	}

	my $registry = decode_json(reading_value('discovery', '.registry'));

	for my $record (values %{ $registry->{devices} }) {
		is($record->{availability_reading}, 'MQTT2DiscoveryAvailability',
			"Registry-Stand fuer $record->{name} kennt den wirksamen Namen");
		my @availability_descriptors = grep {
			($_->{operation} || '') eq 'availability'
				|| ref($_->{configuration}{availability}) eq 'HASH'
		} values %{ $record->{runtime_refs} || {} };
		ok(@availability_descriptors, "$record->{name} besitzt eine Availability-Runtime");
		is([map {
			($_->{operation} || '') eq 'availability'
				? $_->{configuration}{reading}
				: $_->{configuration}{availability}{reading}
		} @availability_descriptors],
			[('MQTT2DiscoveryAvailability') x scalar(@availability_descriptors)],
			"$record->{name} transportiert den Namen in allen Runtime-Referenzen");
	}

	# Ein manueller Anspruch auf einem einzigen Ziel verhindert die globale
	# Umstellung, bevor irgendein Device teilweise geaendert werden kann.
	$main::attr{MQTT2_Other}{readingList} .= "\nmanual/topic:.* ReservedAvailability";
	like(main::MQTT2_DISCOVERY_Attr(
			'set', 'discovery', 'availabilityReading', 'ReservedAvailability',
		), qr/MQTT2_Other/, 'manueller Konflikt nennt das blockierende Zieldevice');
	is(scalar(@TIMERS), 0, 'abgelehnte globale Umstellung plant keine Teilaktualisierung');

	is(main::MQTT2_DISCOVERY_Attr(
			'set', 'discovery', 'availabilityReading', 'RenamedAvailability',
		), undef, 'der Availability-Name kann spaeter erneut geaendert werden');
	$main::attr{discovery}{availabilityReading} = 'RenamedAvailability';
	run_next_timer() while @TIMERS;

	for my $target (@targets) {
		is(reading_value($target, 'RenamedAvailability'), 'unknown',
			"$target verwendet den erneut geaenderten Namen");
		ok(!exists($main::defs{$target}{READINGS}{MQTT2DiscoveryAvailability}),
			"$target hat auch den ersten benutzerdefinierten Namen entfernt");
	}

	$main::attr{MQTT2_Other}{readingList} .= "\nmanual/default:.* availability";
	like(main::MQTT2_DISCOVERY_Attr(
			'del', 'discovery', 'availabilityReading',
		), qr/MQTT2_Other/,
		'auch die Rueckkehr zum Default wird bei manueller Belegung global abgelehnt');
	is(scalar(@TIMERS), 0, 'abgelehntes Loeschen plant keine Teilaktualisierung');
	$main::attr{MQTT2_Other}{readingList} = join("\n", grep {
		$_ ne 'manual/default:.* availability'
	} split /\n/, $main::attr{MQTT2_Other}{readingList});

	is(main::MQTT2_DISCOVERY_Attr(
			'del', 'discovery', 'availabilityReading',
		), undef, 'Loeschen des Attributes wird akzeptiert');
	delete $main::attr{discovery}{availabilityReading};
	run_next_timer() while @TIMERS;

	for my $target (@targets) {
		is(reading_value($target, 'availability'), 'unknown',
			"$target kehrt zum Standardnamen zurueck");
		ok(!exists($main::defs{$target}{READINGS}{RenamedAvailability}),
			"$target entfernt den zuletzt modulverwalteten Namen");
	}
};

subtest 'deactivate verwirft noch nicht verarbeitete Arbeit' => sub {
	my ($hash, $io) = setup();
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';
	main::MQTT2_DISCOVERY_Parse($io,
		mqtt_message('homeassistant/sensor/node/temp/config', $payload));

	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'deactivate'), undef,
		'deactivate ist erfolgreich');
	is(scalar(@TIMERS), 0, 'Queue-Timer wurde entfernt');
	ok(!$main::defs{MQTT2_Node}, 'verworfene Arbeit hat keine Nebenwirkung');
};

done_testing;
