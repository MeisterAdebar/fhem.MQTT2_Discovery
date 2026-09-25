# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

##############################################
# Native Home-Assistant-MQTT-Discovery fuer FHEM
package FHEM::MQTT2_DISCOVERY;

use strict;
use warnings;
use lib './lib/FHEM';
use Encode ();
# Vermeidet JSON-Funktionsimporte in den mit anderen FHEM-Modulen geteilten Namensraum.
use JSON::PP ();
use Scalar::Util ();
use MIME::Base64 ();
use MQTT2_Discovery::Helper qw(stable_unique stable_suffix split_lines line_key merge_generated_lines);
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Semantics ();
use MQTT2_Discovery::Template ();
use MQTT2_Discovery::FHEMGateway ();
use MQTT2_Discovery::DevicePlanner ();
use GPUtils qw(GP_Import GP_Export);

# FHEMs Funktionen und Variablen stehen in main. GP_Import legt Aliase an, damit
# dieses Paket sie unveraendert verwenden kann.
BEGIN {
	GP_Import(qw(
		defs attr modules data init_done readingFnAttributes
		AttrVal ReadingsVal CommandAttr json2nameValue deviceEvents
	));
}

# Nur vier Namen muessen in main stehen: fhem.pl sucht dort
# MQTT2_DISCOVERY_Initialize, der Hook in 10_MQTT2_DEVICE.pm den eingetragenen
# Namen, und die erzeugten Zeilen von readingList und setList werden von FHEM in
# main ausgewertet. Alles andere bleibt in diesem Paket.
GP_Export(qw(Initialize SetExtensions runtimeRef jsonReadings));

our $VERSION = '0.9.11';
our $QUEUE_DELAY = 0.01;
our $AVAILABILITY_REFRESH_DELAY = 60;
our $AVAILABILITY_RETRY_DELAY = 10;
our $DEFAULT_AVAILABILITY_READING = 'availability';

# --- FHEM-Zugriffe und Logging ------------------------------------------------

# Pro Modulinstanz wird genau ein Gateway erzeugt und fuer alle FHEM-Zugriffe
# wiederverwendet. Tests koennen vorab ein eigenes Gateway einsetzen.
sub gateway {
	my ($hash) = @_;
	return $hash->{helper}{gateway} ||= MQTT2_Discovery::FHEMGateway->new();
}

# Das normale FHEM-Attribut verbose steuert alle Meldungen dieses Devices.
sub log_enabled {
	my ($hash, $level) = @_;
	return 0 if ref($hash) ne 'HASH' || !defined($hash->{NAME});
	my $gateway = gateway($hash);
	my $verbose = $gateway->attr_value(
		$hash->{NAME}, 'verbose', $gateway->attr_value('global', 'verbose', 3),
	);
	$verbose = 3 if !defined($verbose) || $verbose !~ /^\d+$/;
	return $verbose >= $level ? 1 : 0;
}

# Schreibt begrenzte einzeilige Diagnosemeldungen nur ab der aktiven Verbose-Stufe.
sub log_message {
	my ($hash, $level, $message) = @_;
	return if !log_enabled($hash, $level);
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	$message = substr($message, 0, 4096) . '... <truncated>' if length($message) > 4096;
	gateway($hash)->log_message(
		$hash->{NAME}, $level, "MQTT2_DISCOVERY $hash->{NAME}: $message",
	);
	return;
}

# Vorwaertsdeklaration fuer die rekursive Schwaerzung verschachtelter Logdaten.

# Schwaerzt Geheimnisse rekursiv, bevor strukturierte Payloaddaten protokolliert werden.
sub log_redacted {
	my ($value) = @_;

	# Hashes werden schluesselweise kopiert, damit vertrauliche Felder maskiert
	# werden koennen, ohne die fuer die Diagnose wichtige Struktur zu verlieren.
	if (ref($value) eq 'HASH') {
		my %safe;

		# Schluesselnamen werden bewusst breit erkannt; ein zu stark geschwaerzter
		# Diagnosewert ist sicherer als ein versehentlich protokolliertes Geheimnis.
		for my $key (keys %$value) {
			$safe{$key} = $key =~ /(?:pass(?:word)?|passwd|secret|token|auth(?:orization)?|credential|api[_-]?key|private[_-]?key|client[_-]?id|user(?:name)?|email)/i
				? '[REDACTED]' : log_redacted($value->{$key});
		}

		return \%safe;
	}
	return [ map { log_redacted($_) } @$value ] if ref($value) eq 'ARRAY';
	return $value if !ref($value);
	return '<unsupported value>';
}

# Payloads erscheinen nur auf Stufe 5, kanonisch, begrenzt und mit geschwaerzten Geheimnissen.
sub log_payload {
	my ($payload) = @_;
	$payload = '' if !defined $payload;
	return '<empty payload>' if $payload eq '';
	my ($decoded, $safe);
	my $ok = eval {
		$decoded = JSON::PP::decode_json($payload);
		$safe = JSON::PP->new->canonical(1)->encode(log_redacted($decoded));
		1;
	};
	return '<invalid or unloggable JSON; length=' . length($payload) . '>' if !$ok;
	return length($safe) <= 4096 ? $safe : substr($safe, 0, 4096) . '... <truncated>';
}

# --- FHEM-Lebenszyklus und Benutzerbefehle -----------------------------------

# Registriert FHEMs Lebenszyklus-, Parser- und Attributschnittstellen fuer den Modultyp.

sub Initialize {
	my ($hash) = @_;
	register_set_extensions();
	$hash->{DefFn} = \&Define;
	$hash->{UndefFn} = \&Undef;
	$hash->{GetFn} = \&Get;
	$hash->{SetFn} = \&Set;
	$hash->{AttrFn} = \&Attr;
	$hash->{ParseFn} = \&Parse;
	$hash->{NotifyFn} = \&Notify;
	# Kontextbezogene FHEMWEB-Hilfe fuer Get, Set und Attr aktivieren. Die
	# zugehoerigen Commandref-Anker stehen in der eingebetteten HTML-Dokumentation.
	$hash->{FW_deviceOverview} = 1;
	# Match bleibt absichtlich prefixunabhaengig, da Prefixe je IODev konfiguriert sind.
	$hash->{Match} = '\\x00(?:[^\\x00]+/(?:config|sensors|announce|online|events/rpc)|mqtt2_discovery/[^/\\x00]+/shelly/[a-f0-9]{16}/(?:info|config|status|components)/rpc|[^\\x00]+/discovery/[^/\\x00]+/[^/\\x00]+)\\x00';
	$hash->{AttrList} = 'discoveryPrefixes keys:textField-long shellyDiscovery:0,1 deviceNamePrefix existingDevice:conservative,ignore,replace extraJsonReadings:include,ignore autoCreate:0,1 autoDelete:0,1 createReadings:0,1 disable:0,1 ' . $readingFnAttributes;
	$modules{MQTT2_DISCOVERY}{defptr} ||= {};

	# Ein reload ruft Initialize erneut auf und setzt den Match damit auf den
	# engen Ausgangswert zurueck. Bestehende Instanzen mit readings=parse
	# brauchen ihn aber weit, sonst sieht ParseFn die Nutzdaten nicht mehr.
	# CommandReload fuellt dabei ein neues Modulhash und haengt es erst danach
	# in %modules ein (fhem.pl: $modules{$m} = \%hash); der Match muss deshalb in
	# genau dieses Hash geschrieben werden und nicht in das noch eingehaengte.
	update_match($hash);
	return;
}

# Validiert die Definition und bindet genau eine Discovery-Instanz an ein MQTT2-IODev.
sub Define {
	my ($hash, $definition) = @_;
	my @parts = split /[ \t]+/, $definition;

	# Eine unvollstaendige Definition darf weder ein IODev binden noch einen
	# halb initialisierten Eintrag in der globalen Discovery-Registry hinterlassen.
	if (@parts != 3) {
		my $error = 'Usage: define <name> MQTT2_DISCOVERY <MQTT2_SERVER|MQTT2_CLIENT>';
		log_message($hash, 1, "define failed: $error");
		return $error;
	}
	my ($name, undef, $io_name) = @parts;
	my $iodev = $defs{$io_name};

	# Ohne vorhandenes IODev gibt es weder einen MQTT-Dispatch noch eine sichere
	# Stelle, an der die Discovery-Instanz registriert werden koennte.
	if (!$iodev) {
		my $error = "MQTT2_DISCOVERY: IODev $io_name existiert nicht";
		log_message($hash, 1, "define failed: $error");
		return $error;
	}

	# Nur MQTT2_SERVER und MQTT2_CLIENT stellen den Parser-Dispatch bereit, den
	# dieses Modul fuer Discovery-Nachrichten benoetigt.
	if (($iodev->{TYPE} || '') !~ /^MQTT2_(?:SERVER|CLIENT)$/) {
		my $error = "MQTT2_DISCOVERY: $io_name ist weder MQTT2_SERVER noch MQTT2_CLIENT";
		log_message($hash, 1, "define failed: $error");
		return $error;
	}
	my $registered = $modules{MQTT2_DISCOVERY}{defptr}{$io_name};

	# Pro IODev darf genau eine Instanz Nachrichten konsumieren; zwei Instanzen
	# wuerden dieselbe Config doppelt verarbeiten und konkurrierende Devices pflegen.
	if ($registered && $registered != $hash) {
		my $error = "MQTT2_DISCOVERY: Fuer $io_name ist bereits $registered->{NAME} definiert";
		log_message($hash, 1, "define failed: $error");
		return $error;
	}

	# FHEM ruft die DefFn bei modify/defmod mit gesetztem OLDDEF erneut auf.
	# Erst nach erfolgreicher Validierung des neuen IODev die bisherige
	# Registrierung und eventuell noch geplante Arbeit entfernen. Schlaegt die
	# Validierung fehl, bleibt die alte Definition dadurch voll funktionsfaehig.
	Undef($hash, undef) if defined $hash->{OLDDEF};

	$hash->{IODev} = $iodev;
	$hash->{IODevName} = $io_name;
	$hash->{DEF} = $io_name;
	set_notify_devices($hash);
	$modules{MQTT2_DISCOVERY}{defptr}{$io_name} = $hash;
	registry($hash);

	# Der weite Match steht sonst erst nach dem naechsten Rendern wieder; bis
	# dahin saehe ParseFn die Nutzdatentopics nach einem Neustart nicht.
	update_match();
	reconcile_registry_rendering($hash) if $main::init_done;
	reading($hash, 'state', state_value($hash));
	update_selection_reading($hash, undef)
		if !defined(ReadingsVal($hash->{NAME}, 'selectReadings', undef));
	reading($hash, 'deviceKey', '-')
		if !defined(ReadingsVal($hash->{NAME}, 'deviceKey', undef));
	reading($hash, 'replayPayloads', '-')
		if !defined(ReadingsVal($hash->{NAME}, 'replayPayloads', undef));
	update_counts($hash);
	sync_io_availability($hash) if $main::init_done;
	log_message($hash, 2, "defined for $iodev->{TYPE} $io_name; version=$VERSION");
	check_ignore_regexp($hash);
	start_shelly($hash);
	return undef;
}

# Loest Timer und IODev-Registrierung einer entfernten oder geaenderten Instanz.
sub Undef {
	my ($hash, undef) = @_;
	my $io_name = $hash->{IODevName};
	clear_queue($hash);
	clear_availability_refreshes($hash);
	log_message($hash, 2, 'undefined' . ($io_name ? "; IODev=$io_name" : ''));
	delete $modules{MQTT2_DISCOVERY}{defptr}{$io_name}
		if $io_name && $modules{MQTT2_DISCOVERY}{defptr}{$io_name} == $hash;
	return undef;
}

# Validiert Modulattribute und setzt disable-Aenderungen unmittelbar im Laufzeitstatus um.
sub Attr {
	my ($operation, $name, $attribute, @values) = @_;
	my $hash = $defs{$name};

	# Ueber addToDevAttrList mit Pruefinstanz ruft FHEM diese Funktion auch fuer
	# Attribute an fremden Devices auf; $name ist dann das Zielgeraet.
	# Das Attribut laesst sich auch von Hand setzen; geprueft wird dabei
	# dieselbe Schreibweise wie im Dialog. Eine Familie ist hier nicht erlaubt,
	# die des Geraets steht ja fest. Den Neuaufbau loest das globale Ereignis
	# aus, weil fhem.pl beim Loeschen die AttrFn des Zielgeraets ruft.
	if ($attribute eq 'mqttDiscoveryKeys') {
		return undef if $operation ne 'set';
		return check_keys(join(' ', @values), 0);
	}

	if ($attribute eq 'keys') {
		my $error = $operation eq 'set'
			? check_keys(join(' ', @values), 1) : undef;
		return $error if $error;

		# FHEM setzt den Attributwert erst nach dieser Funktion; der Match wird
		# deshalb im naechsten Durchlauf der Ereignisschleife nachgezogen.
		forget_parse_index($hash) if $hash;
		gateway($hash)->schedule(
			0, $hash, sub { update_match() },
		) if $hash && gateway($hash)->can_schedule();

		# Jeder Schluessel aendert das erzeugte Ergebnis: style die Readingnamen,
		# sets und readings die Attribute selbst, availability und hide den
		# Umfang. Ohne Neuaufbau bliebe der zuletzt gerenderte Stand stehen und
		# die Einstellung waere nur an neuen Geraeten zu sehen.
		enqueue_rerender($hash) if $hash;
		return undef;
	}

	# disable wirkt unmittelbar auf Laufzeitstatus und Warteschlange und wird
	# deshalb getrennt von den rein deklarativen Attributen behandelt.
	if ($attribute eq 'disable') {
		my $value = join(' ', @values);
		return 'disable muss 0 oder 1 sein'
			if $operation eq 'set' && $value !~ /^(?:0|1)$/;
		# AttrFn kann auch waehrend des Loeschens aufgerufen werden; nur ein noch
		# vorhandenes Device darf Readings oder geplante Arbeit aktualisieren.
		if ($hash) {
			# Das Reading wird sofort aktualisiert; beim Deaktivieren darf keine
			# bereits geplante Discovery-Arbeit spaeter weiterlaufen.
			my $disabled = $operation eq 'set' && $value eq '1';
			if ($disabled) {
				clear_queue($hash);
				clear_availability_refreshes($hash);
			}
			reading($hash, 'state', $disabled ? 'disabled' : state_value($hash, 1));
			log_message($hash, 2, $disabled ? 'disabled by attribute' : 'enabled by attribute');
			enqueue_rerender($hash)
				if !$disabled && $hash->{helper}{rerender_pending};
		}
		return undef;
	}
	my $value = join(' ', @values);

	# Set-Operationen werden vor der Ablage des neuen Attributwertes validiert.
	if ($operation eq 'set') {
		if ($attribute eq 'discoveryPrefixes') {
			my ($prefixes, $error) = prefixes_from_value($value);
			return $error if $error;
			return 'discoveryPrefixes darf nicht leer sein' if !@$prefixes;
		} elsif ($attribute eq 'existingDevice') {
			return 'existingDevice muss conservative, ignore oder replace sein'
				if $value !~ /^(?:conservative|ignore|replace)$/;
		} elsif ($attribute eq 'extraJsonReadings') {
			return 'extraJsonReadings muss include oder ignore sein'
				if $value !~ /^(?:include|ignore)$/;
		} elsif ($attribute eq 'shellyDiscovery' || $attribute eq 'autoCreate' || $attribute eq 'autoDelete'
				|| $attribute eq 'createReadings') {
			return "$attribute muss 0 oder 1 sein" if $value !~ /^(?:0|1)$/;
		} elsif ($attribute eq 'deviceNamePrefix') {
			return 'deviceNamePrefix muss mit einem Buchstaben oder Unterstrich beginnen und darf nur Buchstaben, Ziffern, Unterstriche und Punkte enthalten'
				if $value !~ /^[A-Za-z_][A-Za-z0-9_.]*$/;
		}
	}

	# Diese Attribute veraendern die erzeugte readingList aller verwalteten Devices.
	if ($operation =~ /^(?:set|del)$/
			&& $attribute eq 'extraJsonReadings') {
		enqueue_rerender($hash) if $hash;
	}
	return undef;
}

# Liefert den einzigen lesenden Benutzerbefehl als FHEMWEB-faehige Device-Uebersicht.
sub Get {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	# Die Fragezeichenabfrage ist kein Befehl des Anwenders, sondern FHEMWEB, das
	# die Auswahlliste holt - und zwar bei jedem Seitenaufbau und je Geraet. Sie
	# gehoert deshalb nicht in das Log der ausgefuehrten Befehle.
	log_message($hash, defined($command) && $command eq '?' ? 5 : 3,
		'get ' . (defined($command) ? $command : '<missing>'));
	log_message($hash, 4, 'get arguments=[' . join(', ', @arguments) . ']') if @arguments;

	# Ohne Kommandonamen liefert FHEM die verfuegbare Get-Auswahl.
	return 'Unknown argument ?, choose one of ' . get_list($hash)
		if !defined $command;
	return payloads($hash, $arguments[0])
		if $command eq 'payloads' && @arguments == 1;


	# devices akzeptiert bewusst keine Zusatzargumente und erzeugt keine Seiteneffekte.
	return devices_html($hash)
		if $command eq 'devices' && !@arguments;

	# Auch fehlerhafte Aufrufe nennen die vollstaendige Get-Auswahl.
	return "Unknown argument $command, choose one of " . get_list($hash);
}

# Die verwalteten Geraete stehen als Auswahl hinter payloads.
sub get_list {
	my ($hash) = @_;
	my $registry = registry($hash);
	my @targets = sort grep { defined($_) && !ref($_) && $defs{$_} } map {
		ref($_) eq 'HASH' ? $_->{name} : undef
	} values %{ $registry->{devices} || {} };
	return 'devices:noArg payloads' . (@targets ? ':' . join(',', @targets) : '');
}

# Escaped dynamische Texte, bevor sie in die bewusst rohe FHEMWEB-HTML-Antwort gelangen.
sub html_escape {
	my ($value) = @_;
	$value = '' if !defined($value) || ref($value);
	$value =~ s/&/&amp;/g;
	$value =~ s/</&lt;/g;
	$value =~ s/>/&gt;/g;
	$value =~ s/"/&quot;/g;
	$value =~ s/'/&#39;/g;
	return $value;
}

# Codiert Zeichenketten als UTF-8-Querywert und erhaelt bereits codierte Bytestreams.
sub url_encode {
	my ($value) = @_;
	$value = '' if !defined($value) || ref($value);
	my $encoded = utf8::is_utf8($value)
		? Encode::encode('UTF-8', $value) : $value;
	$encoded =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
	return $encoded;
}

# Erzeugt einen themen- und Unterpfad-kompatiblen Link zur FHEMWEB-Detailansicht.
sub device_link {
	my ($name) = @_;
	my $label = html_escape($name);
	my $target = 'detail=' . url_encode($name);

	# Im FHEMWEB-Kontext uebernimmt der Kern Root-Pfad und Small-Screen-Verhalten.
	if (defined(&main::FW_pH)) {
		return &main::FW_pH($target, $label, 0, undef, 1, 1);
	}

	# Telnet und isolierte Tests erhalten einen gueltigen relativen Detail-Link.
	return qq{<a href="?$target">$label</a>};
}

# Ordnet alle lebenden MQTT2_DEVICEs am gebundenen IODev der Registry oder dem Rest zu.
sub device_groups {
	my ($hash) = @_;
	my $devices = gateway($hash)->mqtt2_devices_for_iodev(
		$hash->{IODev},
	);
	my %by_name;

	# Der Gateway-Rueckgabewert wird defensiv validiert und zugleich nach Namen dedupliziert.
	for my $device (@{ ref($devices) eq 'ARRAY' ? $devices : [] }) {
		next if ref($device) ne 'HASH' || !defined($device->{NAME})
			|| ref($device->{NAME}) || $device->{NAME} eq '';
		$by_name{ $device->{NAME} } = $device;
	}

	my %managed;
	my $registry = registry($hash);
	my $io_name = $hash->{IODevName} || '';
	my @records;

	# Die erste Phase validiert und begrenzt alle Registry-Records auf dieses IODev.
	for my $identity (sort keys %{ $registry->{devices} || {} }) {
		my $record = $registry->{devices}{$identity};
		next if ref($record) ne 'HASH';
		next if defined($record->{io})
			&& (ref($record->{io}) || $record->{io} ne $io_name);
		my $name = $record->{name};
		next if !defined($name) || ref($name) || $name eq '';
		push @records, $record;
	}

	# Direkte Namen werden zuerst vollstaendig reserviert und gelten unabhaengig
	# vom created-Marker als verwaltet.
	for my $record (@records) {
		my $name = $record->{name};
		$managed{$name} = 1 if exists($by_name{$name});
	}

	# Erst danach darf ein fehlender Registry-Name unter den noch freien Devices
	# per CID gesucht werden, damit die Identity-Sortierung das Ergebnis nicht beeinflusst.
	for my $record (@records) {
		my $name = $record->{name};
		next if exists($by_name{$name});

		my $cid = $record->{cid};
		next if !defined($cid) || ref($cid) || $cid eq '';
		my @candidates = grep {
			my $device = $by_name{$_};
			my $device_cid = defined($device->{CID}) ? $device->{CID} : $device->{DEF};
			!$managed{$_} && defined($device_cid) && !ref($device_cid)
				&& $device_cid eq $cid;
		} sort keys %by_name;

		# Ein umbenanntes Ziel wird nur bei genau einer eindeutigen CID-Entsprechung erkannt.
		$managed{ $candidates[0] } = 1 if @candidates == 1;
	}

	my @managed = sort keys %managed;
	my @unmanaged = sort grep { !$managed{$_} } keys %by_name;
	return (\@managed, \@unmanaged);
}

# Rendert eine der beiden Device-Gruppen als FHEMWEB-Tabelle mit stabiler Sortierung.
sub devices_table {
	my ($heading, $devices, $empty_text) = @_;
	my $html = '<table class="block wide"><tr class="odd"><td><b>'
		. html_escape($heading) . ' (' . scalar(@$devices)
		. ')</b></td></tr>';

	# Vorhandene Devices erhalten jeweils eine eigene, abwechselnd formatierte Linkzeile.
	if (@$devices) {
		my $row = 0;

		for my $device (@$devices) {
			my $class = $row++ % 2 ? 'odd' : 'even';
			$html .= qq{<tr class="$class"><td>}
				. device_link($device) . '</td></tr>';
		}

	} else {
		# Eine leere Gruppe bleibt explizit sichtbar statt scheinbar zu verschwinden.
		$html .= '<tr class="even"><td>'
			. html_escape($empty_text) . '</td></tr>';
	}

	return $html . '</table>';
}

# Baut die rohe HTML-Antwort, die FHEMWEB bei Get-Aufrufen automatisch im Popup zeigt.
sub devices_html {
	my ($hash) = @_;
	my ($managed, $unmanaged) = device_groups($hash);
	my $language = uc(gateway($hash)->attr_value(
		'global', 'language', 'EN',
	));
	my $german = $language eq 'DE';
	my $io_name = html_escape($hash->{IODevName} || '');
	my $title = $german ? "MQTT2-Devices an $io_name" : "MQTT2 devices on $io_name";
	my $managed_heading = $german ? 'Verwaltet' : 'Managed';
	my $unmanaged_heading = $german ? 'Nicht verwaltet' : 'Unmanaged';
	my $empty_text = $german ? 'Keine Devices' : 'No devices';

	return '<html><div class="makeTable wide"><span class="mkTitle">'
		. $title . '</span>'
		. devices_table($managed_heading, $managed, $empty_text)
		. '<br>'
		. devices_table($unmanaged_heading, $unmanaged, $empty_text)
		. '</div></html>';
}

# Die abgewaehlten Readings liegen bewusst neben den Geraetedatensaetzen: Wird ein
# MQTT2_DEVICE geloescht, verwirft die Registry seinen Datensatz und legt ihn bei

# Was ein Kanal aus einem Sammelpayload liest, und was er von einem eigenen
# skalaren Topic liest. Beides wird unterschiedlich behandelt, deshalb getrennt.
# Nur Kanaele zaehlen; ein Sensor ohne Kanal gehoert dem Geraet.
sub channel_keys {
	my ($record) = @_;
	my (%collective, %scalar);

	for my $mapping (values %{ $record->{entities} || {} }) {
		next if ref($mapping) ne 'HASH' || !defined($mapping->{channel});

		for my $line (@{ $mapping->{reading_lines} || [] }) {
			next if ref($line) ne 'HASH';
			my $key = $line->{json_key};
			$collective{$key} = 1 if defined($key) && !ref($key) && $key ne '';
			my ($name, $topic) = ($line->{name}, $line->{topic});
			next if !defined($name) || ref($name) || $name eq ''
				|| !defined($topic) || ref($topic);

			# Steht der Name als letztes Segment im Topic, liest der Kanal dort
			# einen einzelnen Wert - und genau unter diesem Schluessel nennt ihn
			# der Sammelpayload noch einmal.
			$scalar{$name} = 1 if $topic =~ m{(?:\A|/)\Q$name\E\z};
		}

	}

	return (\%collective, \%scalar);
}

# Welche Schluessel aus den Sammelzeilen eines Datensatzes verschwinden.
# Zweierlei gehoert nicht hinein: was ein Kanal von seinem eigenen Topic liest -
# es stuende sonst roh neben seinem state, so wie es die attrTemplates mit
# jsonMap POWER1:0 wegwerfen -, und was einem anderen Kanal gehoert, denn der
# Sammelpayload beschreibt das ganze Geraet. Was dieser Datensatz selbst aus dem
# Sammelpayload liest, bleibt.
sub channel_json_keys {
	my ($hash, $record, $registry) = @_;

	# Beim Anwenden eines Stapels ist der sichtbare Registry-Stand noch der alte;
	# die Geschwister stehen in der Kopie, auf der gerade gearbeitet wird.
	$registry = registry($hash) if ref($registry) ne 'HASH';
	my $devices = $registry->{devices} || {};
	my $name = $record->{name};
	return {} if !defined($name) || $name eq '';
	my ($identity) = grep {
		ref($devices->{$_}) eq 'HASH' && ($devices->{$_}{name} // '') eq $name
	} sort keys %$devices;
	return {} if !defined($identity);
	my $base = $identity;
	$base =~ s/\|ch[^|]*\z//;
	my @siblings = grep { $_ eq $base || index($_, "$base|ch") == 0 } sort keys %$devices;

	# Ohne Kanalgeschwister ist nichts aufgeteilt, und der Sammelpayload gehoert
	# dem einen Geraet ganz.
	return {} if !grep { /\|ch/ } @siblings;
	my ($own_collective) = channel_keys($record);
	my %hidden;

	for my $sibling (@siblings) {
		my ($collective, $scalar) = channel_keys($devices->{$sibling});
		$hidden{$_} = 1 for keys %$scalar;
		next if $sibling eq $identity;
		$hidden{$_} = 1 for keys %$collective;
	}

	delete @hidden{ keys %$own_collective };
	return \%hidden;
}

# Ein Sammelpayload beschreibt das ganze Geraet und nennt damit die Schluessel
# aller Kanaele. In den Sammelzeilen eines aufgeteilten Geraets haben sie nichts
# zu suchen: Jeder Kanal liest seinen Zustand von seinem eigenen Topic, und roh
# stuende er ein zweites Mal daneben. Die attrTemplates loesen es genauso, dort
# mit jsonMap POWER1:0 POWER2:0 am Kanalgeraet.

# Die im Dialog abgewaehlten Readings eines Geraets. Sie liegen in der Registry
# und nicht am Geraet: Ein von Hand geloeschtes Device legt die naechste
# Erkennung neu an, die Auswahl soll das ueberleben.
sub ignored_entities {
	my ($hash, $record) = @_;
	return () if ref($record) ne 'HASH' || !defined($record->{name});
	my $selections = registry($hash)->{selections};
	return () if ref($selections) ne 'HASH'
		|| ref($selections->{ $record->{name} }) ne 'ARRAY';
	return grep { defined($_) && !ref($_) && $_ ne '' } @{ $selections->{ $record->{name} } };
}

# Alle Readingnamen, die der Dialog zur Auswahl stellt.
sub selectable_readings {
	my ($hash, $record) = @_;
	my %names;
	my $references = ref($record->{runtime_refs}) eq 'HASH' ? $record->{runtime_refs} : {};

	for my $descriptor (values %$references) {
		next if ref($descriptor) ne 'HASH';
		my $operation = $descriptor->{operation} // '';
		if ($operation eq 'reading' && defined($descriptor->{name})) {
			$names{ $descriptor->{name} } = 1;
		} elsif ($operation eq 'topic' && ref($descriptor->{configuration}) eq 'HASH') {

			for my $reading (@{ $descriptor->{configuration}{readings} || [] }) {
				$names{ $reading->{name} } = 1
					if ref($reading) eq 'HASH' && defined($reading->{name});
			}

		}
	}

	# Felder einer Sammelzeile kuendigt die Discovery nicht an; angeboten wird,
	# was am Geraet schon einmal ankam. Ein Name, der weder als Reading steht
	# noch abgewaehlt ist, stammt aus einer ueberholten Zuordnung und faellt weg.
	my $device = $defs{ $record->{name} // '' };
	my %ignored = map { ($_ => 1) } ignored_entities($hash, $record);

	for my $name (keys %{ ref($record->{json_seen}) eq 'HASH' ? $record->{json_seen} : {} }) {
		next if !defined($name) || ref($name);

		if (!$ignored{$name}
				&& (!$device || ref($device->{READINGS}) ne 'HASH'
					|| !exists($device->{READINGS}{$name}))) {
			delete $record->{json_seen}{$name};
			next;
		}
		$names{$name} = 1;
	}
	my @sorted = sort keys %names;
	return @sorted;
}


# FHEMWEB-Formular mit eigenem Knopf: Das Muster aus AttrTemplate.pm verlaesst sich
# auf den Knopf von FW_okDialog; bei einem abgeschickten Set-Formular rendert
# FHEMWEB die Antwort aber als ganze Seite, in der es diesen Knopf nicht gibt.
# FHEMWEB holt die Antwort eines Setters nur dann per XHR und zeigt sie im
# Fenster, wenn am Geraet ein Reading gleichen Namens steht; sonst laedt es die
# ganze Seite neu (fhemweb.js: $(".dval[informid="+ifid+"]").length == 0). Das
# Reading zeigt deshalb die zuletzt gesetzte Auswahl und macht zugleich den
# Dialog moeglich.
sub update_selection_reading {
	my ($hash, $target_name) = @_;
	my $selections = registry($hash)->{selections};
	my @ignore = ref($selections) eq 'HASH'
		&& ref($selections->{ $target_name // '' }) eq 'ARRAY'
			? @{ $selections->{$target_name} } : ();
	reading($hash, 'selectReadings', !defined($target_name) || $target_name eq ''
		? '-' : "$target_name: " . (@ignore ? join(',', @ignore) : '-'));
	return;
}

sub select_readings_dialog {
	my ($hash, $target_name, $selectable, $ignored) = @_;
	my $command = html_escape("set $hash->{NAME} selectReadings $target_name");
	my $detail = html_escape($target_name);
	my $rows = join('', map {
		my $name = html_escape($_);
		my $checked = $ignored->{$_} ? '' : " checked='checked'";
		"<tr><td><input type='checkbox' class='m2dSelect' name='$name'$checked></td><td>$name</td></tr>";
	} @$selectable);
	return '<html>'
		. "<input type='hidden' id='m2dSelectCmd' value='$command'>"
		. "<p>Welche Readings soll $detail behalten?</p>"
		. "<table class='block wide'>$rows</table>"
		. qq{<script>
			(function(){
				var apply = function(){
					var cmd = document.getElementById("m2dSelectCmd").value;
					var boxes = document.getElementsByClassName("m2dSelect");
					for(var i=0; i<boxes.length; i++)
						cmd += " "+boxes[i].getAttribute("name")+"="+(boxes[i].checked ? 1 : 0);
					if(typeof FW_cmd == "function") {
						FW_cmd(FW_root+"?cmd="+encodeURIComponent(cmd)+"&XHR=1", function(){
							location.href = FW_root+"?detail=$detail";
						});
					} else {
						location.href = "?cmd="+encodeURIComponent(cmd)+"&detail=$detail";
					}
				};
				// FW_okDialog fuellt sein div, bevor es im Dokument haengt und
				// bevor es den Knopf OK gibt (fhemweb.js: \$(div).html(txt) vor
				// append und dialog). Zu diesem Zeitpunkt findet das Skript
				// weder seine Felder noch den Knopf; es wartet deshalb.
				var bind = function(){
				if(typeof \$ == "function" && \$("#FW_okDialog").length) {
					\$("#FW_okDialog").parent().find("button").css("display","block");
					\$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button")
						.unbind("click").click(function(){ apply(); \$("#FW_okDialog").remove(); });
				} else {
					var button = document.createElement("input");
					button.type = "button";
					button.value = "OK";
					button.onclick = apply;
					document.getElementById("m2dSelectCmd").parentNode.appendChild(button);
				}
				};

				// Gewartet wird auf den Knopf, nicht auf die Felder: FW_okDialog
				// haengt sein div ein und macht erst danach einen Dialog daraus.
				var wait = function(tries){
					var ready = typeof \$ == "function"
						&& \$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button").length;
					if(!ready && tries > 0)
						return setTimeout(function(){ wait(tries-1);; }, 50);
					bind();
				};
				wait(40);
			})();
		</script>}
		. '</html>';
}

# Zeigt die Auswahl an oder uebernimmt sie und baut die Listen neu auf.
sub select_readings {
	my ($hash, $target_name, @pairs) = @_;
	return 'Usage: set <name> selectReadings <MQTT2_DEVICE> [<reading>=0|1 ...]'
		if !defined($target_name) || $target_name eq '';
	my $registry = registry($hash);
	my @records = grep {
		ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $target_name
	} values %{ $registry->{devices} || {} };
	return "$target_name wird von $hash->{NAME} nicht verwaltet" if @records != 1;
	my $record = $records[0];
	my @selectable = selectable_readings($hash, $record);
	my %ignored = map { ($_ => 1) } ignored_entities($hash, $record);

	# Bereits abgewaehlte Namen entstehen nicht mehr und fehlen deshalb in den
	# Runtime-Referenzen; fuer den Dialog gehoeren sie wieder in die Liste.
	my %offered = map { ($_ => 1) } (@selectable, keys %ignored);
	@selectable = sort keys %offered;
	return "$target_name hat noch keine erkannten Readings" if !@selectable;

	if (!@pairs) {
		return select_readings_dialog($hash, $target_name, \@selectable, \%ignored)
			if $hash->{CL} && ($hash->{CL}{TYPE} // '') eq 'FHEMWEB';
		return "Usage: set $hash->{NAME} selectReadings $target_name "
			. join(' ', map { "$_=" . ($ignored{$_} ? 0 : 1) } @selectable);
	}
	my %selection = map { ($_ => $ignored{$_} ? 0 : 1) } @selectable;

	for my $pair (@pairs) {
		my ($name, $value) = $pair =~ /^([A-Za-z0-9_.-]+)=([01])$/;
		return "Ungueltige Angabe: $pair" if !defined($name);
		return "Unbekanntes Reading: $name" if !exists($selection{$name});
		$selection{$name} = $value;
	}
	my @ignore = sort grep { !$selection{$_} } keys %selection;

	if (@ignore) {
		$registry->{selections}{$target_name} = \@ignore;
	} else {
		delete $registry->{selections}{$target_name};
	}
	my $error = apply_device_lines($hash, $record, { rebuild_lists => 1 });
	return $error if $error;
	persist_registry($hash);

	# Ein abgewaehltes Reading wird nicht mehr beschrieben; es stehen zu lassen
	# wuerde einen veralteten Wert dauerhaft sichtbar machen.
	for my $reading (@ignore) {
		next if $reading =~ /^\./;
		next if ref($defs{$target_name}{READINGS}) ne 'HASH'
			|| !exists($defs{$target_name}{READINGS}{$reading});
		gateway($hash)->delete_reading($defs{$target_name}, $reading);
	}

	update_selection_reading($hash, $target_name);
	log_message($hash, 2,
		"selectReadings $target_name ignoriert: " . (@ignore ? join(',', @ignore) : '-'));
	return undef;
}

# Die verwalteten Zieldevices erscheinen als Auswahlliste hinter selectReadings,
# damit FHEMWEB ein Klappmenue statt eines Textfelds anbietet.
sub set_list {
	my ($hash) = @_;
	my $registry = registry($hash);
	my @targets = sort grep { defined($_) && !ref($_) && $defs{$_} } map {
		ref($_) eq 'HASH' ? $_->{name} : undef
	} values %{ $registry->{devices} || {} };
	my $select = @targets ? 'selectReadings:' . join(',', @targets) : 'selectReadings';
	my $device_key = @targets ? 'deviceKey:' . join(',', @targets) : 'deviceKey';
	return "activate:noArg deactivate:noArg rebuildDevice $select $device_key"
		. ' replayPayloads:noArg rescan:noArg discoverShelly';
}
# Bedient die Set-Kommandos eines verwalteten MQTT2_DEVICE, ohne dass dort ein
# setList-Attribut noetig ist: bei "?" ergaenzt die Funktion die Befehle in der
# Auswahl, sonst fuehrt sie den gewaehlten Befehl aus. Fremde Devices reicht sie
# unveraendert an SetExtensions weiter.
sub SetExtensions {
	my ($hash, $list, $name, $cmd, @a) = @_;
	my ($discovery, $record) = runtimeRegistryRecord($name);

	# Als Glied der Kette gibt diese Funktion die Auswahl unveraendert weiter,
	# wenn sie nichts beizutragen hat. Ein Aufruf von SetExtensions waere hier
	# eine Schleife, denn von dort kommt sie gerade.
	return unknown_argument($cmd, $list)
		if ref($record) ne 'HASH' || ref($record->{hook_sets}) ne 'ARRAY';
	my %sets = map { (($_->{name} // '') => $_) } @{ $record->{hook_sets} };
	my $entry = defined($cmd) ? $sets{$cmd} : undef;

	# Ohne passenden Befehl werden die eigenen Kommandos nur angeboten; ueber
	# alles Weitere entscheidet das naechste Glied der Kette.
	if (!$entry) {
		my $offered = join(' ', map {
			$_->{name} . (defined($_->{spec}) && $_->{spec} ne '' ? ":$_->{spec}" : '')
		} sort { ($a->{name} // '') cmp ($b->{name} // '') } @{ $record->{hook_sets} });
		$list .= ($list eq '' ? '' : ' ') . $offered if $offered ne '';
		return unknown_argument($cmd, $list);
	}
	my $payload = $entry->{kind} eq 'button' ? $entry->{payload}
		: ref($entry->{mapping}) eq 'HASH' && defined($a[0]) ? $entry->{mapping}{ $a[0] } : undef;
	return "Unbekannter Wert fuer $cmd" if !defined($payload);
	my $error = gateway($discovery)->publish_mqtt(
		$discovery->{IODev}, $entry->{topic}, $payload,
	);
	return $error if defined($error) && $error ne '';

	# MQTT2_DEVICE setzt state nur fuer Befehle aus seiner eigenen setList; auf
	# diesem Weg uebernimmt das Modul denselben Schritt. Nach FHEM-Konvention
	# steht dabei bis zur Rueckmeldung des Geraets ein set_<befehl> im Reading;
	# roh bleibt es beim bisherigen Verhalten.
	my $state = $cmd . (@a ? ' ' . join(' ', @a) : '');
	$state = "set_$state" if key($discovery, $record, 'style') eq 'fhem';
	gateway($discovery)->update_reading($defs{$name}, 'state', $state, 1)
		if $defs{$name};
	log_message($discovery, 3, "set $name $cmd ueber den Hook ausgefuehrt");
	return undef;
}
# Mit readings=parse wertet das Modul die Nutzdaten selbst aus. Dafuer muss es
# alle Nachrichten sehen, deshalb wird der Match des Moduls weit gestellt, solange
# mindestens eine Instanz das Attribut gesetzt hat. Ohne das Attribut bleibt der
# enge Match erhalten und nichts am bisherigen Ablauf aendert sich.
our $NARROW_MATCH;
sub update_match {
	my ($module) = @_;
	$module ||= $modules{MQTT2_DISCOVERY};
	$NARROW_MATCH = $module->{Match} if !defined($NARROW_MATCH);
	my $wide = 0;

	for my $instance (values %{ $modules{MQTT2_DISCOVERY}{defptr} || {} }) {
		next if ref($instance) ne 'HASH' || !defined($instance->{NAME});
		$wide = 1 if key($instance, undef, 'readings') eq 'parse'
			|| parse_readings_wanted($instance);
	}

	$module->{Match} = $wide ? '.*' : $NARROW_MATCH;
	return $wide;
}

# Raeumt nach einer Aenderung am Attribut jsonMap auf. Die Umbenennung wirkt
# sofort, das bisher geschriebene Reading bliebe aber unter seinem alten Namen
# stehen, als kaeme es weiterhin vom Geraet.
sub sync_json_map {
	my ($hash, $device_name) = @_;
	my $target = $defs{$device_name};
	return if !$target;
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $device_name
	} values %{ registry($hash)->{devices} || {} };
	return if ref($record) ne 'HASH';
	my $previous = ref($target->{helper}{mqtt2_discovery_json_map}) eq 'HASH'
		? $target->{helper}{mqtt2_discovery_json_map} : {};
	my $current = ref($target->{JSONMAP}) eq 'HASH' ? $target->{JSONMAP} : {};
	my %sources = map { ($_ => 1) } (keys %$previous, keys %$current);

	for my $source (sort keys %sources) {
		my $before = defined($previous->{$source}) && !ref($previous->{$source})
			&& $previous->{$source} ne '' ? $previous->{$source} : $source;
		my $after = defined($current->{$source}) && !ref($current->{$source})
			&& $current->{$source} ne '' ? $current->{$source} : $source;
		next if $before eq $after;

		# Entfernt wird nur, was das Modul selbst geschrieben hat.
		next if !$record->{json_seen}{$before};
		delete $record->{json_seen}{$before};
		next if ref($target->{READINGS}) ne 'HASH' || !exists($target->{READINGS}{$before});
		next if record_has_manual_reading($hash, $record, $before);
		gateway($hash)->delete_reading($target, $before);
		log_message($hash, 3, "jsonMap an $device_name: Reading $before entfernt");
	}
	$target->{helper}{mqtt2_discovery_json_map} = { %$current };
	return;
}

# Liefert die vom Modul selbst auszuwertenden Zeilen eines Zielgeraets.
sub parse_readings {
	my ($hash, $record) = @_;
	return () if ref($record) ne 'HASH' || ref($record->{parse_readings}) ne 'ARRAY';
	return @{ $record->{parse_readings} };
}

# Wertet eine Nutzdatennachricht fuer alle verwalteten Zieldevices aus und schreibt
# deren Readings direkt, ohne den Umweg ueber ein readingList-Attribut.
# Ordnet die gespeicherten Muster ihrem Topic zu. Ohne diesen Index kostet jede
# fremde Nachricht einen Vergleich je Muster und Geraet; mit ihm einen
# Hash-Zugriff. Muster mit Sonderzeichen im Topic (etwa INFO(?:1|2|3)) lassen
# sich nicht als Text nachschlagen und bleiben eine kurze Restliste.
sub parse_index {
	my ($hash) = @_;
	return $hash->{helper}{parse_index} if ref($hash->{helper}{parse_index}) eq 'HASH';
	my (%exact, @other);
	my $registry = registry($hash);

	for my $record (values %{ $registry->{devices} || {} }) {
		next if ref($record) ne 'HASH' || !defined($record->{name});
		next if key($hash, $record, 'readings') ne 'parse';

		# Das eigene Antworttopic wird erst beim Auswerten zusammengesetzt und
		# haengt am Namen dieser Instanz.
		push @{ $exact{"mqtt2_discovery/$hash->{NAME}/shelly/$record->{reply_key}/state/rpc"} },
			{ record => $record, reference => $record->{reply_reference} }
			if defined($record->{reply_key}) && defined($record->{reply_reference});

		for my $entry (parse_readings($hash, $record)) {
			next if ref($entry) ne 'HASH' || !defined($entry->{regexp});
			next if !defined($entry->{reference}) && ref($entry->{json}) ne 'HASH';
			my $candidate = { record => $record, reference => $entry->{reference},
				json => $entry->{json}, regexp => $entry->{regexp} };

			# Ein Muster ohne Sonderzeichen und mit beliebigem Payload ist ein
			# fester Topicname und damit nachschlagbar.
			my ($literal) = $entry->{regexp} =~ m{\A([^\\^\$.*+?()\[\]{}|]+):[.]\*\z};

			if (defined($literal) && $literal !~ /\$DEVICETOPIC/) {
				push @{ $exact{$literal} }, $candidate;
				next;
			}
			push @other, $candidate;
		}
	}

	return $hash->{helper}{parse_index} = { exact => \%exact, other => \@other };
}

# Verwirft den Index; er entsteht beim naechsten Zugriff neu.
sub forget_parse_index {
	my ($hash) = @_;
	delete $hash->{helper}{parse_index};
	return;
}

# Tasmota verpackt INFO1 bis INFO3 in einen Umschlag, der denselben Namen traegt
# wie das Topic. Ohne Auspacken stuende er in jedem Readingnamen (Info1_Module).
# Dieselbe Form erzeugt der Renderer fuer die Zeile im Attribut.
sub unwrap_sequence_payload {
	my ($payload, $unwrap) = @_;
	return $payload if ref($unwrap) ne 'HASH' || !defined($payload) || ref($payload);
	my $prefix = $unwrap->{key_prefix};
	my @parts = grep { defined($_) && !ref($_) } @{ $unwrap->{parts} || [] };
	return $payload if !defined($prefix) || ref($prefix) || !@parts;
	my $alternatives = join '|', map { quotemeta("$_") } @parts;
	return $1 if $payload =~ /\A..\Q$prefix\E(?:$alternatives)..(.+).\z/s;
	return $payload;
}

sub apply_parsed_readings {
	my ($hash, $topic, $payload) = @_;
	my $index = parse_index($hash);
	my @candidates = (@{ $index->{exact}{$topic} || [] }, @{ $index->{other} || [] });
	return () if !@candidates;

	# Die Sammelzeilen laufen zuerst: Sie flachen den ganzen Payload ab, waehrend
	# eine Laufzeitreferenz denselben Wert ausdruecklich abbildet, etwa ON auf on.
	# Die angekuendigte Zuordnung muss deshalb die rohe ueberschreiben.
	@candidates = ((grep { ref($_->{json}) eq 'HASH' } @candidates),
		(grep { ref($_->{json}) ne 'HASH' } @candidates));
	my (%updates, %targets, %seen);

	for my $candidate (@candidates) {
		my $record = $candidate->{record};
		my $target = $defs{ $record->{name} };
		next if !$target;

		# Nur die Restliste muss noch vergleichen; ein nachgeschlagenes Muster
		# passt bereits.
		if (defined($candidate->{regexp})) {
			my $pattern = $candidate->{regexp};
			my $device_topic = AttrVal($record->{name}, 'devicetopic', '');
			$pattern =~ s/\$DEVICETOPIC/\Q$device_topic\E/g if $device_topic ne '';
			next if "$topic:$payload" !~ /^$pattern$/s;
		}
		my $values = ref($candidate->{json}) eq 'HASH'
			? jsonReadings($record->{name}, $candidate->{json}{path},
				unwrap_sequence_payload($payload, $candidate->{json}{unwrap}),
				$candidate->{json}{renames})
			: runtimeRef($record->{name}, $candidate->{reference}, $payload);
		next if ref($values) ne 'HASH';

		# Eine Sammelzeile kuendigt ihre Felder nicht an; welche es gibt, zeigt
		# erst die Nachricht. Gemerkt werden sie, damit selectReadings sie
		# anbieten kann.
		$seen{ $record->{name} } = $record if ref($candidate->{json}) eq 'HASH'
			&& grep { !$record->{json_seen}{$_} } keys %$values;
		$record->{json_seen}{$_} = 1 for ref($candidate->{json}) eq 'HASH'
			? keys %$values : ();
		@{ $updates{ $record->{name} } }{ keys %$values } = values %$values;
		$targets{ $record->{name} } = $target;
	}
	my @written;

	persist_registry($hash) if %seen;

	for my $name (sort keys %updates) {
		gateway($hash)->update_readings($targets{$name}, $updates{$name});
		log_message($hash, 4,
			"readings aus $topic fuer $name: " . join(',', sort keys %{ $updates{$name} }));
		push @written, $name;
	}

	return @written;
}
# Beantwortet, ob ueberhaupt ein Geraet dieser Instanz seine Readings in ParseFn
# erwartet. Nur dann lohnt der Durchlauf durch die Registry je Nachricht.
sub parse_readings_wanted {
	my ($hash) = @_;

	# Der Index enthaelt genau die Muster der Geraete mit readings=parse; ist er
	# leer, gibt es nichts selbst auszuwerten.
	my $index = parse_index($hash);
	return keys %{ $index->{exact} || {} } || @{ $index->{other} || [] } ? 1 : 0;
}

# --- Nutzdaten zum Nachstellen ------------------------------------------------
# Damit ein Helfer ein Geraet ohne die Hardware nachbauen kann, hebt das Modul
# die Nachrichten auf, aus denen es entstanden ist. Sie liegen im Speicher, denn
# in der Registry wuerden sie den Statefile aufblaehen; nach einem Neustart
# fuellt die naechste Erkennung sie wieder.
our $PAYLOAD_LIMIT = 32768;

# Die eigenen Antworttopics tragen den Geraeteschluessel; daran haengen die
# Teilantworten einer Abfrage zusammen. Nur die letzte von ihnen erzeugt
# Entities, die uebrigen gehoeren aber genauso zum Bild.
sub payload_session {
	my ($topic) = @_;
	return $1 if defined($topic)
		&& $topic =~ m{\Amqtt2_discovery/[^/]+/shelly/([a-f0-9]{16})/};
	return undef;
}

# Haelt eine Nachricht fest, deren Geraet noch nicht feststeht.
sub buffer_payload {
	my ($hash, $topic, $payload) = @_;
	my $session = payload_session($topic);
	return if !defined($session) || !defined($payload);
	$hash->{helper}{pending_payloads}{$session}{$topic} = $payload;
	return;
}

sub remember_payload {
	my ($hash, $name) = @_;
	my $message = $hash->{helper}{process_message};
	return if ref($message) ne 'HASH' || !defined($name) || $name eq '';
	return if !defined($message->{topic}) || !defined($message->{payload});
	my $store = ($hash->{helper}{payloads}{$name} ||= {});

	# Die uebrigen Teilantworten derselben Abfrage gehoeren zu diesem Geraet.
	my $session = payload_session($message->{topic});

	if (defined($session) && ref($hash->{helper}{pending_payloads}{$session}) eq 'HASH') {
		my $pending = delete $hash->{helper}{pending_payloads}{$session};
		@$store{ keys %$pending } = values %$pending;
		delete $hash->{helper}{pending_payloads} if !keys %{ $hash->{helper}{pending_payloads} };
	}

	# Dieselbe Nachricht ersetzt ihre Vorgaengerin; der Platz ist begrenzt, damit
	# ein geschwaetziges Geraet den Speicher nicht fuellt.
	$store->{ $message->{topic} } = $message->{payload};
	my $size = 0;
	$size += length($_) + length($store->{$_}) for keys %$store;
	return if $size <= $PAYLOAD_LIMIT;

	for my $topic (sort { length($store->{$b}) <=> length($store->{$a}) } keys %$store) {
		next if $topic eq $message->{topic};
		$size -= length($topic) + length(delete $store->{$topic});
		last if $size <= $PAYLOAD_LIMIT;
	}

	return;
}

# Schluesselnamen, hinter denen ein Geheimnis stehen kann. Die Adapter halten
# zwar nur, was sie brauchen, aber die rohe Nachricht geht hier unveraendert
# durch, und ein Shelly liefert auf Shelly.GetConfig auch sein WLAN-Passwort.
our $SECRET_KEYS = qr/(?:pass|pwd|psk|secret|token|api_?key|auth|user)/i;

# Die Client-ID, unter der ein eingespielter Block verarbeitet wird. Ein daraus
# entstandenes Geraet traegt sie in seinem Datensatz und ist damit als
# eingespielt erkennbar.
our $REPLAY_CID = 'replay';

# Werte, die das Netz des Anwenders beschreiben. Sie werden nicht geschwaerzt,
# sondern durch unverfaengliche ersetzt, damit die Nachricht auswertbar bleibt.
our %ANONYMOUS_KEYS = (
	hn => 'host', hostname => 'host', ssid => 'WLAN', ip => '192.0.2.10',
	ipv6 => '2001:db8::1', gw => '192.0.2.1', ntp => 'ntp.example',
);

# Ersetzt Geheimnisse durch einen Platzhalter und Netzangaben durch feste
# Beispielwerte. Was sich nicht als JSON lesen laesst, bleibt unveraendert; es ist dann
# ein einfacher Wert wie true oder online.
sub redact_payload {
	my ($payload) = @_;
	return $payload if !defined($payload) || $payload !~ /^\s*[\[{]/;
	my $data = eval { JSON::PP->new->decode($payload) };
	return $payload if !defined($data) || $@;
	redact_value($data);
	return eval { JSON::PP->new->canonical(1)->encode($data) } // $payload;
}

sub redact_value {
	my ($value) = @_;

	if (ref($value) eq 'HASH') {

		for my $key (keys %$value) {

			if ($key =~ $SECRET_KEYS && !ref($value->{$key})) {
				$value->{$key} = 'xxx';
				next;
			}

			if (exists($ANONYMOUS_KEYS{ lc $key }) && !ref($value->{$key})
					&& defined($value->{$key}) && $value->{$key} ne '') {
				$value->{$key} = $ANONYMOUS_KEYS{ lc $key };
				next;
			}

			if (!ref($value->{$key})) {
				$value->{$key} = anonymous_value($value->{$key});
				next;
			}
			redact_value($value->{$key});
		}

	} elsif (ref($value) eq 'ARRAY') {
		$_ = anonymous_value($_) for grep { !ref($_) } @$value;
		redact_value($_) for grep { ref($_) } @$value;
	}

	return;
}

# Adressen und Hardwarekennungen erkennt man an ihrer Form, nicht am Namen ihres
# Schluessels: Dasselbe Geraet nennt sie ip, sta_ip, server oder bssid. Ersetzt
# wird durch die fuer Beispiele vorgesehenen Bereiche.
sub anonymous_value {
	my ($value) = @_;
	return $value if !defined($value) || ref($value) || $value eq '';
	return $value =~ s/\d{1,3}(?:\.\d{1,3}){3}/192.0.2.10/gr
		if $value =~ /\A\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\z/;
	# Eine MAC sieht wie eine kurze IPv6 aus und muss deshalb zuerst geprueft werden.
	return 'de:ad:be:ef:00:01' if $value =~ /\A(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\z/;
	return '2001:db8::1' if $value =~ /\A[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}\z/;
	return $value;
}

# FHEMWEB zeigt die Antwort eines get in einem Dialog, dessen Breite der
# laengsten Zeile folgt; eine einzelne Nutzdatenzeile sprengt damit den
# Bildschirm. In einem Textfeld steht sie in fester Groesse und laesst sich
# trotzdem im Ganzen markieren und kopieren. Andere Aufrufer, etwa ein Skript
# oder telnet, bekommen den Block unveraendert.
sub payload_answer {
	my ($hash, $block) = @_;
	my $client = $hash->{CL};
	return $block if ref($client) ne 'HASH' || ($client->{TYPE} // '') ne 'FHEMWEB';
	my $rows = () = $block =~ /\n/g;
	$rows = 25 if $rows > 25;
	$rows = 8 if $rows < 8;
	return '<html><textarea readonly rows="' . $rows . '" cols="100" '
		. 'style="width:98%;white-space:pre;overflow:auto;font-family:monospace">'
		. html_escape($block) . '</textarea></html>';
}

# Stellt die Nachrichten eines Geraets als Textblock zum Einfuegen bereit.
sub payloads {
	my ($hash, $name) = @_;
	my $registry = registry($hash);
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq ($name // '')
	} values %{ $registry->{devices} || {} };
	return "$name ist kein von dieser Instanz verwaltetes Geraet" if !$record;
	my $store = $hash->{helper}{payloads}{$name};

	# Nach einem Neustart ist der Speicher leer. Ein nativ abgefragter Adapter
	# kann die Nachrichten selbst neu anfordern.
	if (ref($store) ne 'HASH' || !%$store) {
		my $error = ($record->{adapter} // '') eq 'shelly'
			? discover_shelly($hash, $record->{cid}) : undef;
		return 'Noch keine Nachrichten gespeichert; die Abfrage laeuft, bitte gleich erneut aufrufen.'
			if ($record->{adapter} // '') eq 'shelly' && !$error;
		return 'Noch keine Nachrichten gespeichert. Sie entstehen bei der naechsten Erkennung;'
			. ' bei einem Adapter ohne Abfrage hilft nur, auf die naechste Ankuendigung zu warten.';
	}
	my $entities = scalar keys %{ $record->{entities} || {} };

	# Topics und Geraetekennungen bleiben, wie sie sind. Ersetzt man sie, passt
	# der Block nicht mehr zu dem Geraet, das er beschreibt: Sein Zwilling sendet
	# dann auf einen Zweig, auf dem keine Hardware antwortet. Geschwaerzt wird
	# deshalb nur, was das Netz des Anwenders verraet.
	my @lines = (
		'# MQTT2_DISCOVERY ' . $VERSION . ", Geraet $name"
			. ', Adapter ' . ($record->{adapter} // 'unbekannt') . ", Entities $entities",
		'# Geheimnisse stehen als xxx, Adressen und Netznamen als Beispielwerte.',
		'# Topics und Kennungen der Geraete bleiben unveraendert, sonst waere der',
		'# Block nicht der dieses Geraets.',
		'# Einspielen: set <MQTT2_DISCOVERY> replayPayloads ohne Angabe aufrufen',
		'# und diesen Block in das Eingabefeld einfuegen, dann OK.',
	);
	push @lines, "$_ " . redact_payload($store->{$_}) for sort keys %$store;
	return payload_answer($hash, join("\n", @lines));
}

# Fragt den Block im Frontend ab. Ein eingefuegter Text enthaelt Leerzeichen und
# Zeilenumbrueche und wuerde die Befehlszeile zerlegen; er geht deshalb als ein
# Stueck in base64 zurueck. Gesendet wird per POST, ein Block sprengt sonst die
# Laenge einer Adresse.
sub replay_dialog {
	my ($hash) = @_;
	my $client = $hash->{CL};
	return 'Aufruf: set <name> replayPayloads <datei>'
		if ref($client) ne 'HASH' || ($client->{TYPE} // '') ne 'FHEMWEB';
	my $name = html_escape($hash->{NAME});
	return '<html>'
		. "<input type='hidden' id='m2dReplayCmd' value='set $name replayPayloads'>"
		. "<p>Block aus <code>get $name payloads &lt;device&gt;</code> einfuegen:</p>"
		. '<textarea id="m2dReplayText" rows="12" cols="100" '
			. 'style="width:98%;white-space:pre;overflow:auto;font-family:monospace"></textarea>'
		. qq{<script>
			(function(){
				var apply = function(){
					var text = document.getElementById("m2dReplayText").value;
					if(!text.replace(/\\s/g, "")) return;
					var block = btoa(unescape(encodeURIComponent(text)));
					var cmd = document.getElementById("m2dReplayCmd").value+" base64:"+block;

					// Der Block gehoert in den Koerper der Anfrage, nicht in die
					// Adresse. Das Merkmal heisst in FHEMWEB FW_csrfToken und
					// wird ueber addcsrf angehaengt; eine kuerzere Schreibweise
					// des Namens gibt es dort nicht.
					var url = FW_root+"?XHR=1";
					if(typeof addcsrf == "function") {
						url = addcsrf(url);
					} else if(typeof FW_csrfToken != "undefined") {
						url += "&fwcsrf="+encodeURIComponent(FW_csrfToken);
					}
					var xhr = new XMLHttpRequest();
					xhr.open("POST", url, true);
					xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
					xhr.onload = function(){
						// Eine Antwort ist hier immer eine Meldung; ein Neuladen
						// wuerde sie verschlucken.
						var answer = (xhr.responseText || "").replace(/^\\s+|\\s+\$/g, "");
						if(answer && typeof FW_errmsg == "function")
							return FW_errmsg(answer, 7000);
						location.href = FW_root+"?detail=$name";
					};
					xhr.send("cmd="+encodeURIComponent(cmd));
				};
				// Wie beim Schluesseldialog: Das OK des Fensters uebernimmt, und
				// das Binden wartet, bis das Fenster im Dokument steht.
				var bind = function(){
				if(typeof \$ == "function" && \$("#FW_okDialog").length) {
					\$("#FW_okDialog").parent().find("button").css("display","block");
					\$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button")
						.unbind("click").click(function(){ apply(); \$("#FW_okDialog").remove(); });
				} else {
					var button = document.createElement("input");
					button.type = "button";
					button.value = "OK";
					button.onclick = apply;
					document.getElementById("m2dReplayCmd").parentNode.appendChild(button);
				}
				};

				// Gewartet wird auf den Knopf, nicht auf das Feld: FW_okDialog
				// haengt sein div ein und macht erst danach einen Dialog daraus.
				var wait = function(tries){
					var ready = typeof \$ == "function"
						&& \$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button").length;
					if(!ready && tries > 0)
						return setTimeout(function(){ wait(tries-1); }, 50);
					bind();
				};
				wait(40);
			})();
		</script>}
		. '</html>';
}

# Spielt die Antworten einer Shelly-Abfrage ein. Sie ergeben nur im Ablauf einer
# Abfrage einen Sinn: Der Adapter nimmt eine Antwort nur zu der Anfrage an, die
# gerade offen ist, und erkennt sie an deren ID. Der Replay eroeffnet deshalb
# eine eigene Abfrage und schreibt jede gespeicherte Antwort auf die jeweils
# offene um.
sub replay_shelly {
	my ($hash, $parts) = @_;
	my $json = JSON::PP->new;
	my $info = eval { $json->decode($parts->{info} // '') };
	return (0, 1) if ref($info) ne 'HASH' || ref($info->{result}) ne 'HASH'
		|| !defined($info->{result}{id});
	my $config = eval { $json->decode($parts->{config} // '') };

	# Ohne eigenen Prefix meldet sich ein Shelly unter seiner Kennung.
	my $prefix = ref($config) eq 'HASH' && ref($config->{result}) eq 'HASH'
		&& ref($config->{result}{mqtt}) eq 'HASH'
		&& defined($config->{result}{mqtt}{topic_prefix})
		? $config->{result}{mqtt}{topic_prefix} : $info->{result}{id};
	my $error = discover_shelly($hash, $prefix);
	return (0, 1) if defined($error) && $error ne '';
	my ($processed, $failed) = (0, 0);
	my $guard = 0;

	while (my $open = MQTT2_Discovery::Format::Shelly::pending(
			$hash->{helper}{formats}{shelly}, $prefix)) {
		last if ++$guard > 10;
		my $payload = $parts->{ $open->{part} };
		last if !defined($payload);
		my $data = eval { $json->decode($payload) };
		last if ref($data) ne 'HASH';

		# Die gespeicherte Antwort traegt die ID der damaligen Abfrage.
		$data->{id} = $open->{id};
		my $status = process($hash, $REPLAY_CID, "$open->{reply}/$open->{part}/rpc",
			$json->canonical(1)->encode($data));
		$status eq 'error' ? $failed++ : $processed++;
		last if $status eq 'error';
	}

	return ($processed, $failed);
}

# Spielt einen mit get payloads erzeugten Block wieder ein. Damit entsteht ein
# Geraet ohne die zugehoerige Hardware, etwa um einer fremden Meldung aus dem
# Forum nachzugehen.
sub replay_payloads {
	my ($hash, $file) = @_;

	# Ohne Angabe fragt das Frontend den Block ab; einen Umweg ueber eine Datei
	# braucht es dafuer nicht.
	return replay_dialog($hash) if !defined($file) || $file eq '';
	my @lines;
	my $source = $file;

	# Aus dem Eingabefeld kommt der Block als ein Stueck, damit Leerzeichen und
	# Zeilenumbrueche die Befehlszeile nicht zerlegen.
	if ($file =~ /\Abase64:(.*)\z/s) {
		my $text = MIME::Base64::decode_base64($1);
		return 'Der eingefuegte Block ist leer' if !defined($text) || $text !~ /\S/;
		@lines = split /\r?\n/, $text;
		$source = 'dem eingefuegten Block';
	} elsif ($file =~ m{(?:\A|\s)\S+/\S+\s}) {

		# Ein in die Befehlszeile eingefuegter Block verliert seine Zeilenumbrueche
		# und ist danach nicht mehr lesbar. Erkennbar ist das an mehreren Topics
		# in einer Zeile; der Dialog nimmt denselben Block als ein Stueck.
		my @topics = $file =~ m{(?:\A|\s)(\S+/\S+)(?=\s)}g;
		return 'Der Block hat seine Zeilenumbrueche verloren. Bitte '
			. "set $hash->{NAME} replayPayloads ohne Angabe aufrufen und ihn "
			. 'dort in das Eingabefeld einfuegen.' if @topics > 1;
		return "Kann $file nicht lesen: keine Datei dieses Namens";
	} else {
		return 'Der Dateiname darf nicht aus dem Verzeichnis herausfuehren' if $file =~ m{\.\.};
		open my $input, '<', $file or return "Kann $file nicht lesen: $!";
		@lines = <$input>;
		close $input or return "Kann $file nicht schliessen: $!";
	}
	my (@messages, $ignored);

	for my $line (@lines) {
		chomp $line;
		next if $line =~ /^\s*(?:#|$)/;
		my ($topic, $payload) = split /\s+/, $line, 2;

		# Eine Nachrichtenzeile besteht aus Topic und Nutzdaten. Ein Topic ohne
		# Schraegstrich ist keines, ebenso wenig eines mit Platzhaltern. So
		# bleibt etwa ein FileLog draussen, dessen erste Spalte ein Zeitstempel
		# ist; sonst wuerde er stillschweigend als verarbeitet gezaehlt.
		if (!defined($topic) || !defined($payload) || $topic !~ m{/} || $topic =~ /[+#]/) {
			$ignored++;
			next;
		}

		# Das eigene Antworttopic traegt den Namen der Instanz, die gefragt hat.
		# Beim Einspielen ist das diese hier.
		$topic =~ s{^mqtt2_discovery/[^/]+/}{mqtt2_discovery/$hash->{NAME}/};
		push @messages, [$topic, $payload];
	}
	return "In $source steht keine Zeile aus Topic und Nutzdaten;"
		. ' erwartet wird die Ausgabe von get <MQTT2_DISCOVERY> payloads <device>'
		if !@messages;
	my ($processed, $failed) = (0, 0);

	# Antworten auf eigene Abfragen gelten nur innerhalb einer laufenden
	# Abfrage; sie werden deshalb getrennt behandelt.
	my (@plain, %sessions);

	for my $message (@messages) {
		my ($topic, $payload) = @$message;

		if ($topic =~ m{\Amqtt2_discovery/[^/]+/shelly/([a-f0-9]{16})/([a-z]+)/rpc\z}) {
			$sessions{$1}{$2} = $payload;
			next;
		}
		push @plain, $message;
	}

	for my $message (@plain) {
		my $status = process($hash, $REPLAY_CID, @$message);
		$status eq 'error' ? $failed++ : $processed++;
	}

	for my $key (sort keys %sessions) {
		my ($done, $error) = replay_shelly($hash, $sessions{$key});
		$processed += $done;
		$failed += $error;
	}
	my $result = "processed=$processed failed=$failed"
		. ($ignored ? " ignored=$ignored" : '');
	# Das Reading traegt den Namen des Set-Befehls, weil FHEMWEB die Antwort nur
	# dann im Fenster zeigt; der Wert ist das Ergebnis des letzten Einspielens.
	reading($hash, 'replayPayloads', $result);
	log_message($hash, 2, "replayPayloads aus $source: $result");
	return $failed ? "Nicht alle Nachrichten konnten verarbeitet werden: $result" : undef;
}

# --- Schluessel ---------------------------------------------------------------
# Statt je Schalter ein Attribut gibt es einen Schluesselraum mit vier Ebenen:
# Vorgabe im Code, global, Familie (die Adapterkennung) und Geraet. Gesucht wird
# von unten nach oben. Global und Familie stehen in einem Attribut am
# Discovery-Device, die Geraeteebene in einem Attribut am Zielgeraet.
our %KEYS = (
	style        => { values => [qw(fhem raw)],                default => 'fhem' },
	sets         => { values => [qw(list hook)],               default => 'hook' },
	readings     => { values => [qw(list parse)],              default => 'parse' },
	reachability => { values => [qw(full sources none)],        default => 'sources' },
	forceNEXT    => { values => [qw(0 1)],                     default => '0' },
	hide         => { list => 1,                               default => '' },
);

# Liest eine Zuweisungsliste in der Schreibweise von parseParams, erlaubt eine
# Familie als Praefix: "style=fhem shelly:sets=hook".
sub parse_keys {
	my ($value) = @_;
	my %keys;
	return \%keys if !defined($value);

	for my $token (split /\s+/, $value) {
		next if $token eq '';
		my ($family, $key, $setting) = $token =~ /^(?:([A-Za-z0-9_]+):)?([A-Za-z0-9_]+)=(.*)$/;
		next if !defined($key);
		$keys{ $family // '' }{$key} = $setting;
	}

	return \%keys;
}

# Prueft eine Zuweisungsliste gegen den bekannten Schluesselraum.
sub check_keys {
	my ($value, $allow_family) = @_;

	for my $token (split /\s+/, ($value // '')) {
		next if $token eq '';
		my ($family, $key, $setting) = $token =~ /^(?:([A-Za-z0-9_]+):)?([A-Za-z0-9_]+)=(.*)$/;
		return "Ungueltige Angabe: $token" if !defined($key);
		return "Eine Familie ist hier nicht erlaubt: $token" if defined($family) && !$allow_family;
		my $definition = $KEYS{$key};
		return "Unbekannter Schluessel: $key" if !$definition;

		# Ein leerer Wert nimmt den Schluessel zurueck und faellt damit auf die
		# naechsthoehere Ebene.
		next if $setting eq '' || $definition->{list};
		return "Ungueltiger Wert fuer $key: $setting"
			if !grep { $_ eq $setting } @{ $definition->{values} };
	}

	return undef;
}

# Loest einen Schluessel fuer ein Zielgeraet auf.
sub key {
	my ($hash, $record, $key, $skip_device) = @_;
	my $definition = $KEYS{$key} or return undef;
	my $gateway = gateway($hash);
	my $family = ref($record) eq 'HASH' ? ($record->{adapter} // '') : '';
	my $name = ref($record) eq 'HASH' ? ($record->{name} // '') : '';

	# Geraeteebene; der Dialog laesst sie aus, um den Wert ohne eigenen Eintrag
	# zu bestimmen.
	if (!$skip_device && $name ne '' && $defs{$name}) {
		my $device = parse_keys(
			$gateway->attr_value($name, 'mqttDiscoveryKeys', ''),
		);
		return $device->{''}{$key}
			if defined($device->{''}{$key}) && $device->{''}{$key} ne '';
	}
	my $global = parse_keys($gateway->attr_value($hash->{NAME}, 'keys', ''));

	# Familienebene, dann global; ein leerer Wert zaehlt auch hier als "nicht gesetzt"
	return $global->{$family}{$key}
		if $family ne '' && defined($global->{$family}{$key}) && $global->{$family}{$key} ne '';
	return $global->{''}{$key}
		if defined($global->{''}{$key}) && $global->{''}{$key} ne '';

	# Ein Datensatz, der unter der FHEM-Konvention entstanden ist, behaelt sie;
	# aeltere Datensaetze bleiben unveraendert, damit keine Readingwerte kippen.
	return 'fhem' if $key eq 'style' && ref($record) eq 'HASH' && ($record->{style} // '') eq 'fhem';
	return $definition->{default};
}

# Setzt einen Schluessel am Zielgeraet. Das Modul fuehrt den Anwender hier,
# statt ihn die Schreibweise im Attribut raten zu lassen: Der Befehl prueft,
# mischt mit den bestehenden Angaben und traegt erst dann ein. Das Attribut
# selbst nimmt nur an, was aus diesem Befehl kommt.
# Zeigt die Schluessel eines Geraets als Dialog. Die Set-Syntax von FHEM kennt
# nur ein Argument mit Widget; das ist hier das Geraet, sodass fuer den
# Schluessel kein Feld bliebe (fhemweb.js: vArr = argAndPar[1].split(",")).
sub device_key_dialog {
	my ($hash, $device) = @_;
	my ($record) = grep {
		ref($_) eq 'HASH' && ($_->{name} // '') eq $device
	} values %{ registry($hash)->{devices} || {} };
	my $own = parse_keys(gateway($hash)->attr_value($device, 'mqttDiscoveryKeys', ''));
	my $command = html_escape("set $hash->{NAME} deviceKey $device");
	my $detail = html_escape($device);
	my $rows = '';

	# hide bleibt aussen vor: Ein einzelnes Geraet waehlt seine Readings im
	# Dialog von selectReadings ab; als Schluessel ist hide fuer die oberen
	# Ebenen gedacht, wo er alle Geraete einer Familie trifft.
	for my $key (grep { !$KEYS{$_}{list} } sort keys %KEYS) {
		my $definition = $KEYS{$key};
		my $set = $own->{''}{$key};
		my $name = html_escape($key);

		# Was ohne eigenen Wert gilt, steht als eigene Spalte daneben; die
		# Auswahl selbst nennt nur, was waehlbar ist.
		my $fallback = ref($record) eq 'HASH'
			? (key($hash, $record, $key, 1) // '') : ($definition->{default} // '');
		my $inherited = html_escape($fallback);
		# Der leere Eintrag traegt den Wert, der ohne eigenen Eintrag gilt; die
		# uebrigen Eintraege sind nur die davon abweichenden, sonst stuende
		# derselbe Wert zweimal in der Liste.
		my $field = "<select class='m2dKey' name='$name'>" . join('', map {
			my $option = html_escape($_);
			my $label = $_ eq ''
				? ($inherited ne '' ? "$inherited (default)" : '(keiner)') : $option;
			my $selected = defined($set) && $set eq $_ ? " selected='selected'" : '';
			$selected = " selected='selected'" if !defined($set) && $_ eq '';
			"<option value='$option'$selected>$label</option>";
		} ('', grep { $_ ne $fallback } @{ $definition->{values} || [] })) . '</select>';
		$rows .= "<tr><td>$name</td><td>$field</td></tr>";
	}
	return '<html>'
		. "<input type='hidden' id='m2dKeyCmd' value='$command'>"
		. "<p>Welche Schluessel gelten fuer $detail?</p>"

		# Die Auswahlfelder sind unterschiedlich lang, weil ihre Werte es sind;
		# eine feste Breite stellt sie untereinander auf dieselbe Kante.
		. "<style>select.m2dKey { width: 9em }</style>"
		. "<table class='block wide'>$rows</table>"
		. qq{<script>
			(function(){
				var apply = function(){
					var cmd = document.getElementById("m2dKeyCmd").value;
					var fields = document.getElementsByClassName("m2dKey");
					for(var i=0; i<fields.length; i++)
						cmd += " "+fields[i].getAttribute("name")+"="+fields[i].value;
					if(typeof FW_cmd == "function") {
						FW_cmd(FW_root+"?cmd="+encodeURIComponent(cmd)+"&XHR=1", function(){
							location.href = FW_root+"?detail=$detail";
						});
					} else {
						location.href = "?cmd="+encodeURIComponent(cmd)+"&detail=$detail";
					}
				};
				// Wie beim Readingdialog: Das OK des Fensters uebernimmt, und
				// das Binden wartet, bis das Fenster im Dokument steht.
				var bind = function(){
				if(typeof \$ == "function" && \$("#FW_okDialog").length) {
					\$("#FW_okDialog").parent().find("button").css("display","block");
					\$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button")
						.unbind("click").click(function(){ apply();; \$("#FW_okDialog").remove(); });
				} else {
					var button = document.createElement("input");;
					button.type = "button";;
					button.value = "OK";;
					button.onclick = apply;;
					document.getElementById("m2dKeyCmd").parentNode.appendChild(button);;
				}
				};

				// Gewartet wird auf den Knopf, nicht auf die Felder: FW_okDialog
				// haengt sein div ein und macht erst danach einen Dialog daraus.
				var wait = function(tries){
					var ready = typeof \$ == "function"
						&& \$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button").length;;
					if(!ready && tries > 0)
						return setTimeout(function(){ wait(tries-1);; }, 50);;
					bind();;
				};;
				wait(40);;
			})();
		</script>}
		. '</html>';
}

sub device_key {
	my ($hash, $device, @assignments) = @_;
	return 'Aufruf: set <name> deviceKey <device> <schluessel>=<wert> ...'
		if !defined($device);
	return "$device ist kein MQTT2_DEVICE"
		if !$defs{$device} || ($defs{$device}{TYPE} // '') ne 'MQTT2_DEVICE';

	# Ohne Zuweisung fragt der Dialog die Schluessel ab; ein Skript bekommt die
	# Schreibweise genannt.
	if (!@assignments) {
		return device_key_dialog($hash, $device)
			if $hash->{CL} && ($hash->{CL}{TYPE} // '') eq 'FHEMWEB';
		return 'Aufruf: set <name> deviceKey <device> <schluessel>=<wert> ...';
	}
	my $assignment = join(' ', @assignments);
	my $error = check_keys($assignment, 0);
	return $error if $error;
	my $gateway = gateway($hash);

	# Bereits gesetzte Schluessel bleiben stehen; ein leerer Wert entfernt einen
	# einzelnen Schluessel, das leere Attribut wird ganz geloescht.
	my $current = parse_keys($gateway->attr_value($device, 'mqttDiscoveryKeys', ''));
	my $wanted = parse_keys($assignment);
	my %merged = (%{ $current->{''} || {} }, %{ $wanted->{''} || {} });
	delete $merged{$_} for grep { $merged{$_} eq '' } keys %merged;
	my $line = join(' ', map { "$_=$merged{$_}" } sort keys %merged);

	my $command_error = $gateway->set_attribute($device, 'mqttDiscoveryKeys', $line);
	return $command_error if defined($command_error) && $command_error ne '';
	reading($hash, 'deviceKey', "$device: " . ($line ne '' ? $line : '-'));
	log_message($hash, 3, "deviceKey $device: " . ($line ne '' ? $line : '<leer>'));

	# Der Schluessel wirkt auf das erzeugte Ergebnis; ohne Neuaufbau bliebe das
	# Geraet auf dem Stand, den es vor der Aenderung hatte.
	forget_parse_index($hash);
	my $rebuild_error = rebuild_device($hash, $device);
	log_message($hash, 2, "deviceKey $device: Neuaufbau fehlgeschlagen: $rebuild_error")
		if defined($rebuild_error) && $rebuild_error ne '';
	return undef;
}

# Meldet das Geraeteattribut samt Pruefinstanz an. FHEM ruft danach beim Setzen
# die AttrFn dieses Moduls auf, nicht die des Zielgeraets (fhem.pl, attrSource).
sub announce_device_keys {
	my ($hash, $name) = @_;
	return if !defined($name) || !$defs{$name} || !defined(&main::addToDevAttrList);
	main::addToDevAttrList($name, 'mqttDiscoveryKeys:textField-long',
		'MQTT2_DISCOVERY', $hash->{NAME});
	return;
}

# Formuliert die Antwort so, dass die Kette sie weiterreicht. SE_Next erkennt
# ein weiterzureichendes Ergebnis an m/^Unknown argument $cmd, choose one of/,
# wobei der Befehl ungeschuetzt in das Muster geraet. Bei "?" trifft das Muster
# den eigenen Text nicht mehr; ohne den Befehl im Text passt es wieder, und das
# naechste Glied ergaenzt seine Befehle.
sub unknown_argument {
	my ($cmd, $list) = @_;
	$cmd = '' if !defined($cmd);
	return "Unknown argument $cmd, choose one of $list" if $cmd !~ /[\\^\$.|?*+()\[\]{}]/;
	return "Unknown argument, choose one of $list";
}

# Reiht die eigene Funktion in die Kette von SetExtensions ein. Seit
# SetExtensions.pm r31666 ruft SE_Next alle Namen auf, die unter
# $modules{<Zieltyp>}{SetExtensionsFn} als Liste stehen; dieselbe Liste benutzt
# FHEM fuer AttrTemplate_Set. Ein reload des Zielmoduls setzt sie zurueck,
# deshalb wird beim Start und bei jedem Rendern erneut eingereiht.
sub register_set_extensions {
	my $module = $modules{MQTT2_DEVICE};

	# Ohne geladenes MQTT2_DEVICE entstuende hier ein Modulhash ohne Match und
	# ParseFn, an dem Dispatch spaeter stirbt.
	return if ref($module) ne 'HASH' || !$module->{LOADED};
	my $name = 'MQTT2_DISCOVERY_SetExtensions';
	$module->{SetExtensionsFn} = [] if ref($module->{SetExtensionsFn}) ne 'ARRAY';
	return if ($module->{SetExtensionsFn}[0] // '') eq $name;

	# Ein frueherer Eintrag kann inzwischen hinter einem anderen stehen, etwa
	# weil SetExtensions sein AttrTemplate_Set davor gesetzt hat.
	@{ $module->{SetExtensionsFn} } = grep { $_ ne $name } @{ $module->{SetExtensionsFn} };

	# Vorn statt hinten: SE_Next setzt den Befehl ungeschuetzt in einen
	# regulaeren Ausdruck ein (m/^Unknown argument $cmd, .../), sodass die
	# Abfrage "?" ihn nicht trifft und die Kette nach dem ersten Glied endet.
	# Wer dort zuletzt steht, kommt bei genau der Abfrage nie zum Zug, mit der
	# FHEMWEB seine Auswahl aufbaut.
	unshift @{ $module->{SetExtensionsFn} }, $name;
	return;
}

# Verteilt die erlaubten Set-Kommandos auf Aktivierung, Deaktivierung oder Neuaufbau.
sub Set {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	log_message($hash, defined($command) && $command eq '?' ? 5 : 3,
		'set ' . (defined($command) ? $command : '<missing>'));
	log_message($hash, 4, 'set arguments=[' . join(', ', @arguments) . ']') if @arguments;
	return 'Unknown argument ?, choose one of ' . set_list($hash)
		if !defined $command;
	return activate($hash) if $command eq 'activate' && !@arguments;
	return deactivate($hash) if $command eq 'deactivate' && !@arguments;
	return rebuild_device(
		$hash, $arguments[0], @arguments == 2 ? 1 : 0,
	) if $command eq 'rebuildDevice'
		&& (@arguments == 1
			|| (@arguments == 2 && $arguments[1] eq 'clearReadings'));
	return rescan($hash) if $command eq 'rescan' && !@arguments;
	return discover_shelly($hash, $arguments[0])
		if $command eq 'discoverShelly' && @arguments <= 1;
	return select_readings($hash, @arguments) if $command eq 'selectReadings';
	return device_key($hash, @arguments) if $command eq 'deviceKey';
	return replay_payloads($hash, join(' ', @arguments))
		if $command eq 'replayPayloads';
	return "Unknown argument $command, choose one of " . set_list($hash);
}

# Liefert den instanzlokalen Antwortpfad und die getrennt schaltbare native Erkennung.
sub shelly_args {
	my ($hash) = @_;
	return (
		shelly_enabled => gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1),
		reply_prefix => "mqtt2_discovery/$hash->{NAME}/shelly",
	);
}

# Fuehrt deklarierte MQTT-Abfragen aus; Konfigurations- und Geraetebefehle entstehen hier nicht.
sub send_requests {
	my ($hash, $requests) = @_;
	return undef if ref($requests) ne 'ARRAY' || !@$requests;
	return 'MQTT2_DISCOVERY ist deaktiviert' if gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	return 'Shelly-Discovery ist deaktiviert' if !gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	return 'MQTT-IODev ist nicht verbunden' if !iodev_available($hash);

	for my $request (@$requests) {
		my $error = gateway($hash)->publish_mqtt(
			$hash->{IODev}, $request->{topic}, $request->{payload},
		);
		return $error if defined($error) && $error ne '';
	}

	return undef;
}

# Fordert native Announcements oder einen gezielten Snapshot fuer einen individuellen Prefix an.
sub discover_shelly {
	my ($hash, $prefix) = @_;
	return 'MQTT2_DISCOVERY muss aktiv sein' if state_value($hash) ne 'active';
	return 'Shelly-Discovery ist deaktiviert' if !gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	my $requests = [{ topic => 'shellies/command', payload => 'announce' }];

	# Ein expliziter Prefix wird direkt abgefragt und benoetigt MQTT Control nicht.
	if (defined($prefix)) {
		my $result = MQTT2_Discovery::Format::Shelly::begin(
			shelly_args($hash), mqtt_prefix => $prefix, force => 1,
			state => ($hash->{helper}{formats}{shelly} ||= {}),
		);
		return $result->{error} if $result->{status} ne 'ok';
		$requests = $result->{requests};
	}
	my $error = send_requests($hash, $requests);
	reading($hash, 'lastShellyDiscovery', $error || 'requested');
	return $error;
}

# Startet native Erkennung einmal pro aktiver Brokerverbindung, auch nach einem FHEM-Neustart.
sub start_shelly {
	my ($hash) = @_;
	return if !$main::init_done;
	# Ein Verbindungsabbruch gibt den naechsten Start wieder frei.
	if (state_value($hash) ne 'active' || !iodev_available($hash)) {
		delete $hash->{helper}{shelly_started};
		return;
	}
	return if $hash->{helper}{shelly_started}
		|| !gateway($hash)->can_publish_mqtt()
		|| !gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	my $error = discover_shelly($hash);
	$hash->{helper}{shelly_started} = 1 if !$error;
	log_message($hash, 2, "Shelly discovery failed: $error") if $error;
	return;
}

# Ersetzt devicetopic, readingList und setList eines verwalteten Zieldevices vollstaendig.
sub rebuild_device {
	my ($hash, $target_name, $clear_readings) = @_;

	# Ein expliziter Neuaufbau darf die kontrollierte Moduldeaktivierung nicht umgehen.
	if (gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		return 'MQTT2_DISCOVERY ist durch disable=1 deaktiviert';
	}
	my $registry = registry($hash);
	my @records = grep {
		ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $target_name
	} values %{ $registry->{devices} || {} };

	# Nur ein bereits eindeutig von dieser Discovery-Instanz verwaltetes Device ist zulaessig.
	return "$target_name wird von $hash->{NAME} nicht verwaltet" if !@records;
	return "$target_name ist in der Discovery-Registry nicht eindeutig" if @records > 1;
	return "$target_name ist kein MQTT2_DEVICE"
		if !$defs{$target_name} || ($defs{$target_name}{TYPE} || '') ne 'MQTT2_DEVICE';
	my $error = apply_device_lines(
		$hash, $records[0], {
			rebuild_lists => 1,
			clear_readings => $clear_readings ? 1 : 0,
		},
	);

	# Ein fehlgeschlagener ActionPlan hat die Attribute bereits zurueckgerollt.
	if ($error) {
		reading($hash, 'lastError', $error);
		log_message($hash, 1, "rebuildDevice failed for target=$target_name: $error");
		return $error;
	}
	persist_registry($hash);
	log_message($hash, 2, "rebuildDevice completed for target=$target_name");
	return undef;
}

# Parst und validiert die kommagetrennte Liste erlaubter Discovery-Topic-Prefixe.
sub prefixes_from_value {
	my ($value) = @_;
	my @prefixes = map {
		my $prefix = $_;
		$prefix =~ s/^\s+|\s+$//g;
		$prefix;
	} split /,/, defined($value) ? $value : '';

	for my $prefix (@prefixes) {
		return (undef, 'Discovery-Prefixe duerfen nicht leer sein') if $prefix eq '';
		return (undef, "Ungueltiger Discovery-Prefix: $prefix")
			if $prefix !~ m{^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$};
	}

	return ([ stable_unique(@prefixes) ], undef);
}

# Liest die wirksamen Discovery-Prefixe und liefert bei Altstaenden sichere Standards.
sub prefixes {
	my ($hash) = @_;
	my $value = gateway($hash)->attr_value(
		$hash->{NAME}, 'discoveryPrefixes', 'homeassistant,tasmota/discovery,sonos2mqtt',
	);
	my ($prefixes, undef) = prefixes_from_value($value);
	return $prefixes || ['homeassistant', 'tasmota/discovery', 'sonos2mqtt'];
}

# Ermittelt die aktuelle MQTT-Parserreihenfolge aus Attribut oder IODev-Standard.
sub client_order {
	my ($hash) = @_;
	my $iodev = $hash->{IODev};
	my $configured = gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientOrder', '',
	);
	my @order = $configured ne '' ? split(/\s+/, $configured) : grep { $_ ne '' } split(/:/, $iodev->{Clients} || '');
	@order = qw(MQTT2_DEVICE MQTT_GENERIC_BRIDGE) if !@order;
	return @order;
}

# Discovery muss vor MQTT2_DEVICE laufen, damit Discovery-Nachrichten nicht als
# normale Geraetetelemetrie autocreated werden.
sub is_active {
	my ($hash) = @_;
	my @order = client_order($hash);
	my %position;
	$position{$order[$_]} = $_ for 0 .. $#order;
	return 0 if !exists $position{MQTT2_DISCOVERY};
	return 0 if exists($position{MQTT2_DEVICE}) && $position{MQTT2_DISCOVERY} > $position{MQTT2_DEVICE};
	return 1;
}

# Leitet den sichtbaren Modulstatus aus disable und der tatsaechlichen Parserposition ab.
sub state_value {
	my ($hash, $ignore_disable) = @_;
	return 'disabled' if !$ignore_disable
		&& gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	my $io_name = $hash->{IODevName} || '';
	return 'inactive' if !$io_name || !$defs{$io_name}
		|| $defs{$io_name} != $hash->{IODev};
	return is_active($hash) ? 'active' : 'inactive';
}

# Ordnet Discovery vor den Device-Parsern ein und aktualisiert den Laufzeitstatus.
sub activate {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } client_order($hash);
	my $index = 0;

	# Vor den ersten Device-Parser einsortieren, andere Client-Reihenfolge aber
	# unveraendert lassen.
	++$index while $index < @order && $order[$index] ne 'MQTT2_DEVICE' && $order[$index] ne 'MQTT_GENERIC_BRIDGE';
	splice @order, $index, 0, 'MQTT2_DISCOVERY';
	my $error = gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', join(' ', @order),
	);

	# Bei einem FHEM-Fehler ist die neue Parserposition nicht verlaesslich aktiv;
	# Status und Erfolgsmeldung duerfen dann nicht vorgetaeuscht werden.
	if ($error) {
		log_message($hash, 1, "activation failed: $error");
		return $error;
	}
	reading($hash, 'state', state_value($hash));
	check_ignore_regexp($hash);
	log_message($hash, 2, 'activated; clientOrder=' . join(' ', @order));
	start_shelly($hash);
	return undef;
}

# Entfernt Discovery aus clientOrder und verwirft danach noch geplante Verarbeitung.
sub deactivate {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } client_order($hash);
	my $error = gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', @order ? join(' ', @order) : '',
	);

	# Schlaegt das Entfernen aus clientOrder fehl, kann der Parser weiterhin aktiv
	# sein; seine Warteschlange bleibt deshalb bis zu einer erfolgreichen Aenderung erhalten.
	if ($error) {
		log_message($hash, 1, "deactivation failed: $error");
		return $error;
	}
	clear_queue($hash);
	reading($hash, 'state', state_value($hash));
	log_message($hash, 2, 'deactivated; clientOrder=' . join(' ', @order));
	return undef;
}

# Warnt einmalig, wenn das IODev-ignoreRegexp ein typisches Discovery-Topic
# bereits vor dem Parser-Dispatch ausfiltern wuerde.
sub check_ignore_regexp {
	my ($hash) = @_;
	my $io_name = $hash->{IODevName};
	my $regexp = gateway($hash)->attr_value(
		$io_name, 'ignoreRegexp', '',
	);

	# Ein entferntes oder nicht passendes Filter darf bei einer spaeter erneut
	# passenden Konfiguration wieder genau eine neue Warnung ausloesen.
	if ($regexp eq '') {
		delete $hash->{helper}{ignore_regexp_warning};
		return;
	}

	# Beispieltopics pruefen die haeufigen Discovery-Layouts, ohne reale
	# Nachrichten oder Devices zu erzeugen.
	for my $prefix (@{ prefixes($hash) }) {
		my @topics = (
			"$prefix/sensor/example/config",
			"$prefix/001122AABBCC/sensors",
			"$prefix/discovery/sonos/RINCON_00112233445501400",
		);

		for my $topic (@topics) {
			my $matches = eval { "$topic:{}" =~ /$regexp/ };
			next if !$matches;
			my $signature = join("\0", $io_name, $regexp, $topic);

			# Define, activate und Lifecycle-Notify koennen dieselbe Konfiguration
			# pruefen; im Log soll sie trotzdem nur einmal pro Lauf erscheinen.
			return if ($hash->{helper}{ignore_regexp_warning} || '') eq $signature;
			$hash->{helper}{ignore_regexp_warning} = $signature;
			my $warning = "ignoreRegexp am IODev $io_name blockiert Discovery-Topic $topic";
			reading($hash, 'lastWarning', $warning);
			log_message($hash, 2, "warning: $warning; regexp=$regexp");
			return;
		}

	}

	delete $hash->{helper}{ignore_regexp_warning};
	return;
}

# Spielt den lokalen MQTT2_SERVER-Retain-Cache als gemeinsamen Discovery-Batch erneut ein.
sub rescan {
	my ($hash) = @_;

	# Ein manueller Rescan darf die ausdrueckliche Deaktivierung nicht umgehen
	# und dadurch trotz disable=1 wieder Devices oder Attribute veraendern.
	if (gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		my $message = 'MQTT2_DISCOVERY ist durch disable=1 deaktiviert';
		reading($hash, 'lastRescan', $message);
		log_message($hash, 2, "rescan skipped: $message");
		return $message;
	}
	my $iodev = $hash->{IODev};
	log_message($hash, 3, "rescan started; IODev=$hash->{IODevName}");

	# MQTT2_CLIENT verwaltet keinen lokalen Retain-Cache; dort kann nur der Broker
	# die Configs nach Reconnect oder erneuter Subscription wieder ausliefern.
	if (($iodev->{TYPE} || '') eq 'MQTT2_CLIENT') {
		my $message = 'MQTT2_CLIENT besitzt keinen lokalen Retain-Cache; Broker-Replay oder Reconnect erforderlich';
		reading($hash, 'lastRescan', $message);
		log_message($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $retain = $iodev->{retain};

	# Ohne den erwarteten Hash ist keine vertrauenswuerdige Liste retained Topics
	# vorhanden, aus der ein lokaler Wiederholungslauf aufgebaut werden koennte.
	if (ref($retain) ne 'HASH') {
		my $message = 'Kein Retain-Cache vorhanden; respectRetain und retained Discovery pruefen';
		reading($hash, 'lastRescan', $message);
		log_message($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $cid = gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientId', $iodev->{NAME},
	);
	my ($processed, $failed) = (0, 0);

	# Alle retained Topics teilen eine Registry-Kopie und werden erst nach dem
	# vollstaendigen Scan pro Device angewendet.
	my $batch = { pending_identities => {}, created_identities => {} };

	for my $topic (sort keys %$retain) {
		my $entry = $retain->{$topic};
		my $payload = ref($entry) eq 'HASH' ? $entry->{val} : $entry;
		my $status = process($hash, $cid, $topic, $payload, $batch);
		++$processed if $status eq 'consumed';
		++$failed if $status eq 'error';
	}

	my $apply_error = finish_batch($hash, $batch);

	# Ein Fehler beim abschliessenden Device-Apply gehoert zur Rescan-Bilanz, auch
	# wenn alle einzelnen retained Nachrichten zuvor erfolgreich geparst wurden.
	if ($apply_error) {
		++$failed;
		reading($hash, 'lastError', $apply_error);
		log_message($hash, 1, "rescan apply failed: $apply_error");
	}
	my $message = "processed=$processed failed=$failed";
	reading($hash, 'lastRescan', $message);
	log_message($hash, $failed ? 2 : 3, "rescan finished; $message");
	return undef;
}

# Konsumiert passende MQTT-Dispatchnachrichten und plant oder startet deren Verarbeitung.
sub Parse {
	my ($iodev, $message) = @_;
	my $config = $modules{MQTT2_DISCOVERY}{defptr}{ $iodev->{NAME} };
	return '[NEXT]' if !$config;
	$message =~ s/^autocreate=[^\0]+\0//s;
	my ($cid, $topic, $payload) = split /\0/, $message, 3;
	return '[NEXT]' if !defined($topic) || !defined($payload);

	# Mit readings=parse schreibt das Modul die Readings selbst und gibt die
	# Nachricht danach weiter, damit manuelle Zeilen am Geraet erhalten bleiben.
	# Welche Geraete das betrifft, entscheidet sich je Datensatz; hier genuegt,
	# dass ueberhaupt eines so eingestellt ist.
	# Dispatch loest die Ereignisse der Geraete aus, die eine ParseFn zurueckgibt;
	# waehrend ihres Laufs unterbleibt der Trigger von readingsEndUpdate
	# (fhem.pl: $readingsUpdateDelayTrigger). Ohne die Namen bliebe die
	# Aenderung deshalb ohne Ereignis, und FHEMWEB zeigte sie erst nach einem
	# Neuladen der Seite. Vor [NEXT] duerfen sie stehen (fhem.pl 4207).
	my @updated = parse_readings_wanted($config)
		? apply_parsed_readings($config, $topic, $payload) : ();

	# forceNEXT gibt jede Nachricht weiter, auch die selbst beantworteten
	# RPC-Antworten. Das ist fuer Fehlersuche gedacht und legt ohne readingList
	# keine Fremd-Devices an.
	my $force_next = key($config, undef, 'forceNEXT') ? 1 : 0;
	my @shelly = MQTT2_Discovery::Format::Shelly::route(
		shelly_args($config), topic => $topic, payload => $payload,
		state => $config->{helper}{formats}{shelly} || {},
	);
	my $native_topic = $topic =~ m{/(?:announce|online|events/rpc|(?:info|config|status|components)/rpc)$};
	return ('[NEXT]', @updated) if $native_topic && !@shelly;

	# Auch deaktivierte Discovery-Nachrichten werden konsumiert, damit
	# MQTT2_DEVICE daraus keine unerwuenschten Fremd-Devices autocreated.
	if (gateway($config)->attr_value($config->{NAME}, 'disable', 0)) {
		log_message($config, 4, 'disabled; consuming discovery message without processing');
		return $force_next || (@shelly && $shelly[0] ne 'reply')
			? ('[NEXT]', @updated) : (@updated ? @updated : '');
	}
	return ('[NEXT]', @updated) if !@shelly && !grep { MQTT2_Discovery::DevicePlanner::topic_has_prefix($topic, $_) }
		@{ prefixes($config) };

	# MQTT2_SERVER kann beim Start viele retained Configs in einem einzigen
	# Dispatch-Schub liefern. Die teure Parser-/Mapping-/Attributarbeit darf
	# dabei FHEMs Event-Loop nicht fuer den gesamten Schub blockieren.
	if (gateway($config)->can_schedule()) {
		enqueue($config, $cid, $topic, $payload);
		return $force_next || (@shelly && $shelly[0] ne 'reply')
			? ('[NEXT]', @updated) : (@updated ? @updated : '');
	}

	# Isolierte Testumgebungen ohne FHEM-Timer bleiben synchron nutzbar.
	my $status = process($config, $cid, $topic, $payload);
	return ('[NEXT]', @updated) if $force_next;
	return ('[NEXT]', @updated) if @shelly && $shelly[0] ne 'reply';
	return ('[NEXT]', @updated) if $status eq 'next';
	# Ein definierter Leerstring stoppt im aktuellen Dispatch die Parserkette ohne
	# Device-Event; geschriebene Geraete brauchen ihr Ereignis trotzdem.
	return @updated ? @updated : '';
}

# --- Asynchrone Verarbeitung -------------------------------------------------

# Plant genau einen Queue-Worker; weitere Nachrichten werden bis zu dessen Lauf
# nur im bereits vorhandenen Queue-Zustand zusammengefuehrt.
sub schedule_queue {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return if ref($queue) ne 'HASH' || $queue->{scheduled};

	delete $queue->{waiting_for_init};
	$queue->{scheduled} = 1;
	gateway($hash)->schedule(
		$QUEUE_DELAY, $hash, \&process_queue,
	);
	return;
}

# Begrenzt FHEMs Notify-Auswertung auf Lebenszyklus und gebundenes MQTT-IODev.
sub set_notify_devices {
	my ($hash) = @_;
	my $notify_devices = 'global,' . ($hash->{IODevName} || '');
	$notify_devices =~ s/,$//;

	# setNotifyDev invalidiert zusaetzlich FHEMs internen Notify-Cache. Die direkte
	# Zuweisung haelt isolierte Testumgebungen ohne diese Hilfsfunktion nutzbar.
	if (defined(&main::setNotifyDev)) {
		&main::setNotifyDev($hash, $notify_devices);
	} else {
		$hash->{NOTIFYDEV} = $notify_devices;
	}
	return;
}

# Liefert den Brokerzugang des gebundenen MQTT2-IODev als normierten Zustand.
sub iodev_available {
	my ($hash) = @_;
	return 0 if ref($hash) ne 'HASH';
	my $iodev = $hash->{IODev};
	return 0 if ref($iodev) ne 'HASH';
	my $name = $iodev->{NAME} || '';

	# Eine im Hash verbliebene Perl-Referenz bedeutet nicht, dass das IODev noch
	# in FHEM definiert ist. Nur das aktuelle Objekt unter demselben Namen gilt.
	return 0 if $name eq '' || !$defs{$name} || $defs{$name} != $iodev;
	my $gateway = gateway($hash);
	my $disabled = $gateway->attr_value($name, 'disable', 0);

	# IsDisabled beruecksichtigt neben disable auch zeitgesteuerte Sperren. Ein
	# Fehler der optionalen FHEM-Hilfe darf die einfache Attributpruefung nicht
	# verdecken.
	if (defined(&main::IsDisabled)) {
		my $value = eval { &main::IsDisabled($name) };
		$disabled = 1 if !$@ && $value;
	}
	return 0 if $disabled;
	my $state = $iodev->{STATE};
	$state = $gateway->reading_value($name, 'state', '')
		if !defined($state) || $state eq '';
	$state = lc($state || '');

	# MQTT2_CLIENT bezeichnet nur eine vollstaendig aufgebaute Brokerverbindung
	# als opened. Alle Zwischen- und Fehlerzustaende bleiben offline.
	return $state eq 'opened' ? 1 : 0
		if ($iodev->{TYPE} || '') eq 'MQTT2_CLIENT';

	# MQTT2_SERVER besitzt keine einzelne Upstream-Verbindung. Er gilt als
	# verfuegbar, solange sein eigener Laufzeitstatus nicht explizit beendet ist.
	return $state =~ /^(?:closed|disconnected|disabled|inactive)$/ ? 0 : 1;
}

# Liefert den global reservierten sichtbaren Availability-Readingnamen.
sub availability_reading {
	my ($hash, $record, $entries) = @_;

	# source und none unterdruecken beide das verdichtete Reading; sie
	# entscheiden vor dem Namen, sonst entstuende er trotzdem und das Reading
	# bliebe mit seinem letzten Wert stehen.
	return '' if key($hash, $record, 'reachability') ne 'full';

	# Der Name folgt der Art der Quellen: Ein beim Broker angemeldeter letzter
	# Wille heisst lwt, eine von einer Bruecke errechnete Erreichbarkeit
	# availability. Ausserhalb des Renderns steht die Entscheidung im Datensatz.
	return defined($entries)
		? (availability_from_last_will($entries) ? 'lwt' : $DEFAULT_AVAILABILITY_READING)
		: (($record->{availability_reading} // '') eq 'lwt'
			? 'lwt' : $DEFAULT_AVAILABILITY_READING);
}

# Beantwortet, ob die Erreichbarkeit eines Geraets auf seinem eigenen letzten
# Willen beruht. Nur der Adapter kennt die Art seiner Quellen und kennzeichnet
# sie; alles andere ist die Aussage eines Dritten ueber das Geraet.
sub availability_from_last_will {
	my ($entries) = @_;
	return scalar(grep {
		ref($_) eq 'HASH' && ($_->{kind} // '') eq 'availability'
			&& ($_->{source_reading} // '') eq 'lwt'
	} @{ ref($entries) eq 'ARRAY' ? $entries : [] });
}

# Sammelt die Readingnamen, die eine Referenztabelle fuer Availability fuehrt:
# die Quellen je Topic und die Regeln, die daraus den sichtbaren Zustand bilden.
sub availability_reading_names {
	my ($references) = @_;
	my %names;

	for my $descriptor (values %{ ref($references) eq 'HASH' ? $references : {} }) {
		next if ref($descriptor) ne 'HASH' || ref($descriptor->{configuration}) ne 'HASH';

		# Eine reine Availability-Zeile traegt die Kette unmittelbar, eine
		# gemeinsame Topic-Zeile fuehrt sie als eigenen Abschnitt.
		my $availability = ($descriptor->{operation} // '') eq 'availability'
			? $descriptor->{configuration} : $descriptor->{configuration}{availability};
		next if ref($availability) ne 'HASH';

		for my $entry (@{ $availability->{sources} || [] }, @{ $availability->{policies} || [] }) {
			next if ref($entry) ne 'HASH' || !defined($entry->{reading})
				|| ref($entry->{reading}) || $entry->{reading} eq '';
			$names{ $entry->{reading} } = 1;
		}
	}

	return \%names;
}

# Liefert die Readingnamen einfacher Zeilen der Form "muster name". Zeilen mit
# Perl-Ausdruck tragen ihre Namen dagegen im Deskriptor.
sub plain_reading_names {
	my ($lines) = @_;
	my %names;

	for my $line (@{ ref($lines) eq 'ARRAY' ? $lines : [] }) {
		next if ref($line) || !defined($line);
		my (undef, $name) = split /\s+/, $line, 2;
		next if !defined($name) || $name !~ /^[A-Za-z_][A-Za-z0-9_.-]*\z/;
		$names{$name} = 1;
	}

	return \%names;
}

# Sammelt alle Readingnamen, die ein Datensatz nach dem Rendern erzeugt: aus den
# einfachen Zeilen, aus den Deskriptoren und aus den Umbenennungen der
# Sammelzeilen. Was hier fehlt, schreibt niemand mehr fort.
sub generated_reading_names {
	my ($record, $lines) = @_;
	my $names = plain_reading_names($lines);

	for my $descriptor (values %{ ref($record->{runtime_refs}) eq 'HASH' ? $record->{runtime_refs} : {} }) {
		next if ref($descriptor) ne 'HASH' || ref($descriptor->{configuration}) ne 'HASH';

		for my $entry (@{ $descriptor->{configuration}{readings} || [] }) {
			$names->{ $entry->{name} } = 1
				if ref($entry) eq 'HASH' && defined($entry->{name}) && !ref($entry->{name});
		}
		my $reading = $descriptor->{configuration}{reading};
		$names->{$reading} = 1 if defined($reading) && !ref($reading) && $reading ne '';
	}

	# Eine Sammelzeile benennt nur um; welche Readings sie sonst erzeugt, haengt
	# am Payload und laesst sich vorher nicht wissen.
	for my $entry (@{ ref($record->{parse_readings}) eq 'ARRAY' ? $record->{parse_readings} : [] }) {
		next if ref($entry) ne 'HASH' || ref($entry->{json}) ne 'HASH';
		$names->{$_} = 1 for grep { defined($_) && !ref($_) }
			values %{ $entry->{json}{renames} || {} };
	}
	%$names = (%$names, %{ availability_reading_names($record->{runtime_refs}) });
	return $names;
}

# Erkennt Registry-Staende, deren zuletzt gerenderter Availability-Name nicht
# mehr dem aktuellen Attribut beziehungsweise Moduldefault entspricht.
sub registry_rendering_outdated {
	my ($hash) = @_;
	return 0 if ref($hash) ne 'HASH';
	my $registry = registry($hash);

	# Fehlende Felder kennzeichnen Registry-Staende vor der konfigurierbaren
	# Benennung und verwenden deshalb fuer den Vergleich den bisherigen Namen.
	# Der erwartete Name wird je Datensatz bestimmt, weil ein Schluessel am
	# Geraet haengen kann.
	for my $record (values %{ $registry->{devices} || {} }) {
		my $rendered = $record->{availability_reading} // 'availability';
		return 1 if $rendered ne availability_reading($hash, $record);

		# source und none ergeben beide einen leeren Namen. Ohne die mitgefuehrte
		# Stufe bliebe der Wechsel zwischen ihnen unbemerkt, und der Datensatz
		# wertete weiter nach der alten Regel aus. Aeltere Staende fuehren sie
		# nicht und werden erst beim naechsten Rendern nachgezogen.
		next if !defined($record->{reachability});
		return 1 if $record->{reachability} ne key($hash, $record, 'reachability');
	}

	return 0;
}

# Erkennt eine explizite manuelle readingList-Belegung ausserhalb der zuletzt
# von dieser Discovery-Instanz erzeugten Zeilen.
sub record_has_manual_reading {
	my ($hash, $record, $reading) = @_;
	return 0 if ref($record) ne 'HASH' || !defined($record->{name});
	my %owned = map { ($_ => 1) } @{ $record->{owned_reading} || [] };
	my $current = gateway($hash)->attr_value(
		$record->{name}, 'readingList', '',
	);

	# Nur explizit bestimmbare Reading-Namen koennen vorab sicher als Konflikt
	# erkannt werden; offene JSON-Parser werden spaeter durch die Reservierung umbenannt.
	for my $line (split_lines($current)) {
		next if $owned{$line};
		return 1 if line_key('reading', $line) eq $reading;
	}

	return 0;
}


# Gleicht einen veralteten Registry-Renderstand ab.
sub reconcile_registry_rendering {
	my ($hash) = @_;
	return if !registry_rendering_outdated($hash);
	enqueue_rerender($hash);
	return;
}

# Sammelt die verborgenen Entity-Regeln, die den sichtbaren Zustand bestimmen.
sub availability_policies {
	my ($record) = @_;
	my %policies;

	for my $mapping (values %{ $record->{entities} || {} }) {

		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || ($entry->{role} || '') ne 'availability';
			my $policy = $entry->{policy};
			next if ref($policy) ne 'HASH' || !defined($policy->{reading})
				|| ref($policy->{reading}) || $policy->{reading} eq '';
			$policies{ $policy->{reading} } = 1;
		}

	}

	return [ sort keys %policies ];
}

# Verdichtet die bereits nach HA-Semantik ausgewerteten Entity-Regeln zu einem
# Devicezustand, ohne eine einzelne optionale Funktion zum Deviceausfall zu machen.
sub device_availability_status {
	my ($states) = @_;
	$states = [] if ref($states) ne 'ARRAY';

	# Mindestens eine verfuegbare Entity belegt, dass das zusammengefasste Device online ist.
	return 'online' if grep { defined($_) && $_ eq 'online' } @$states;

	# Offline ist erst sicher, wenn jede vorhandene Entity-Regel ausdruecklich offline meldet.
	return 'offline' if @$states
		&& !(grep { !defined($_) || $_ ne 'offline' } @$states);

	return 'unknown';
}

# Sammelt alle exakten Availability-Topics eines fertig aufgeloesten Registry-Ziels.
sub availability_topics {
	my ($record) = @_;
	my %topics;

	for my $mapping (values %{ $record->{entities} || {} }) {

		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			next if ref($entry) ne 'HASH' || ($entry->{role} || '') ne 'availability';
			my $topic = $entry->{topic};
			next if !defined($topic) || ref($topic) || $topic eq '';
			$topics{$topic} = 1;
		}

	}

	return [ sort keys %topics ];
}

# Prueft gegen die aktive Registry, ob mindestens ein Ziel das Topic noch verwendet.
sub availability_topic_used {
	my ($hash, $topic) = @_;
	my $registry = registry($hash);

	for my $record (values %{ $registry->{devices} || {} }) {
		return 1 if grep { $_ eq $topic } @{ availability_topics($record) };
	}

	return 0;
}

# Erkennt, ob ein Discovery-Batch noch Nachrichten vorbereitet oder Devices anwendet.
sub queue_busy {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return 0 if ref($queue) ne 'HASH';
	return 1 if $queue->{scheduled} || $queue->{waiting_for_init};
	return 1 if @{ $queue->{order} || [] } || keys %{ $queue->{messages} || {} };
	return 1 if ref($queue->{batch}) eq 'HASH'
		&& keys %{ $queue->{batch}{pending_identities} || {} };
	return 0;
}

# Plant pro Topic hoechstens einen Retained-Abruf; bestehende Topic-Timer werden wiederverwendet.
sub schedule_availability_refresh {
	my ($hash, $topic, $delay) = @_;
	return if ref($hash) ne 'HASH' || !defined($topic) || ref($topic) || $topic eq '';
	return if ref($hash->{IODev}) ne 'HASH'
		|| ($hash->{IODev}{TYPE} || '') ne 'MQTT2_CLIENT';
	my $gateway = gateway($hash);
	return if !$gateway->can_schedule();
	my $refreshes = $hash->{helper}{availability_refreshes} ||= {};
	my $timer = $refreshes->{$topic} ||= {
		discovery => $hash, topic => $topic, scheduled => 0,
	};
	return if $timer->{scheduled};
	delete $timer->{waiting_for_io};
	$timer->{scheduled} = 1;
	$gateway->schedule(
		defined($delay) ? $delay : $AVAILABILITY_REFRESH_DELAY,
		$timer, \&refresh_availability_topic,
	);
	return;
}

# Entfernt alle noch ausstehenden Topic-Timer einer Discovery-Instanz.
sub clear_availability_refreshes {
	my ($hash) = @_;
	my $refreshes = $hash->{helper}{availability_refreshes};
	return if ref($refreshes) ne 'HASH';

	for my $timer (values %$refreshes) {
		gateway($hash)->cancel_timer(
			$timer, \&refresh_availability_topic,
		) if ref($timer) eq 'HASH' && $timer->{scheduled};
	}

	delete $hash->{helper}{availability_refreshes};
	return;
}

# Setzt bei wieder geoeffnetem IODev zuvor verbindungslos geparkte Abrufe fort.
sub resume_availability_refreshes {
	my ($hash) = @_;
	return if !iodev_available($hash);
	my $refreshes = $hash->{helper}{availability_refreshes};
	return if ref($refreshes) ne 'HASH';

	for my $topic (sort keys %$refreshes) {
		my $timer = $refreshes->{$topic};
		next if ref($timer) ne 'HASH' || !$timer->{waiting_for_io};
		schedule_availability_refresh(
			$hash, $topic, $AVAILABILITY_RETRY_DELAY,
		);
	}

	return;
}

# Fordert nach allen Sicherheitspruefungen genau das Retained Availability-Topic an.
sub refresh_availability_topic {
	my ($timer) = @_;
	return if ref($timer) ne 'HASH';
	my $hash = $timer->{discovery};
	my $topic = $timer->{topic};
	return if ref($hash) ne 'HASH' || !defined($topic);
	$timer->{scheduled} = 0;
	my $refreshes = $hash->{helper}{availability_refreshes};
	return if ref($refreshes) ne 'HASH' || !$refreshes->{$topic}
		|| $refreshes->{$topic} != $timer;

	# Entfernte, ersetzte oder deaktivierte Discovery-Instanzen duerfen keine
	# spaeten Brokeraktionen mehr ausloesen.
	if (!$defs{ $hash->{NAME} } || $defs{ $hash->{NAME} } != $hash
			|| gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		delete $refreshes->{$topic};
		delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
		return;
	}

	# Der aktive Registry-Stand ist erst nach Abschluss des Queue-Batches sicher.
	# Solange der Worker laeuft, wird derselbe Topic-Timer kurz zurueckgestellt.
	if (queue_busy($hash)) {
		schedule_availability_refresh(
			$hash, $topic, $AVAILABILITY_RETRY_DELAY,
		);
		return;
	}

	# Eine inzwischen entfernte oder geaenderte Entity darf kein veraltetes Topic
	# mehr abonnieren. Die aktuelle Registry ist dafuer die einzige Quelle.
	if (!availability_topic_used($hash, $topic)) {
		delete $refreshes->{$topic};
		delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
		return;
	}

	# Ohne Brokerverbindung bleibt der Abruf ereignisbasiert geparkt. Notify setzt
	# ihn nach dem naechsten opened-Zustand fort, ohne dauerhaft zu pollen.
	if (!iodev_available($hash)) {
		$timer->{waiting_for_io} = 1;
		return;
	}

	my $error = gateway($hash)->refresh_retained_topic(
		$hash->{IODev}, $topic,
	);
	log_message($hash, $error ? 2 : 4, $error
		? "retained availability refresh failed for topic=$topic: $error"
		: "retained availability refresh requested for topic=$topic");
	delete $refreshes->{$topic};
	delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
	return;
}

# Verknuepft den IO-Zustand mit den erhaltenen Entity-Availability-Regeln.
sub sync_target_availability {
	my ($hash, $record, $io_available) = @_;
	return if ref($record) ne 'HASH' || !keys %{ $record->{entities} || {} };
	my $name = $record->{name};
	my $target = $defs{$name};
	return if !$target || ($target->{TYPE} || '') ne 'MQTT2_DEVICE';
	return if key($hash, $record, 'reachability') eq 'none';
	my $gateway = gateway($hash);
	my $io_status = $io_available ? 'online' : 'offline';
	my $availability_reading = $record->{availability_reading}
		// availability_reading($hash, $record);

	# Das interne Reading verhindert, dass eine bereits zugestellte MQTT-Nachricht
	# einen inzwischen getrennten Brokerzugang wieder sichtbar online setzt.
	if ($gateway->reading_value($name, '.availability_io', '') ne $io_status) {
		$gateway->update_reading($target, '.availability_io', $io_status, 0);
	}
	my $policies = availability_policies($record);
	my $status = $io_available ? 'online' : 'offline';

	# Ohne erhaltenen Retained-Wert bleibt eine vorhandene HA-Regel unbekannt.
	# Mindestens eine verfuegbare Entity macht das Device online; offline erfordert
	# dagegen den sicheren Ausfall aller darin zusammengefassten Entity-Regeln.
	if ($io_available && @$policies) {
		my @states = map {
			$gateway->reading_value($name, $_, 'unknown')
		} @$policies;
		$status = device_availability_status(\@states);
	}
	$gateway->update_reading($target, $availability_reading, $status, 1)
		if $availability_reading ne ''
			&& $gateway->reading_value($name, $availability_reading, '') ne $status;
	return;
}

# Uebertraegt eine IO-Zustandsaenderung genau einmal auf alle Registry-Ziele.
sub sync_io_availability {
	my ($hash, $force, $override) = @_;
	my $available = defined($override)
		? ($override ? 1 : 0)
		: iodev_available($hash);
	return if !$force && defined($hash->{helper}{io_available})
		&& $hash->{helper}{io_available} == $available;
	$hash->{helper}{io_available} = $available;
	my $registry = registry($hash);

	for my $record (values %{ $registry->{devices} || {} }) {
		sync_target_availability($hash, $record, $available);
	}

	log_message($hash, 3, 'IODev availability=' . ($available ? 'online' : 'offline')
		. '; targets=' . scalar(keys %{ $registry->{devices} || {} }));
	return;
}

# Startet vor INITIALIZED gesammelte Arbeit und uebernimmt IO-Zustandsereignisse.
sub Notify {
	my ($hash, $device) = @_;
	return undef if ref($device) ne 'HASH';
	my $device_name = $device->{NAME} || '';
	my $io_name = $hash->{IODevName} || '';
	return undef if $device_name ne 'global' && $device_name ne $io_name;
	my $events = deviceEvents($device, 1);
	return undef if ref($events) ne 'ARRAY';

	# Das gebundene IODev kann viele Ereignisse erzeugen. Der Helperzustand sorgt
	# dafuer, dass nur ein wirklicher Online-/Offline-Wechsel alle Ziele anfasst.
	if ($device_name eq $io_name) {
		sync_io_availability($hash);
		resume_availability_refreshes($hash);
		start_shelly($hash);
		return undef;
	}
	my $lifecycle = grep { $_ eq 'INITIALIZED' || $_ eq 'REREADCFG' } @$events;
	my $ignore_regexp_changed = grep {
		/^(?:ATTR|DELETEATTR)\s+\Q$io_name\E\s+ignoreRegexp(?:\s|$)/
	} @$events;
	my $io_availability_changed = grep {
		/^(?:ATTR|DELETEATTR)\s+\Q$io_name\E\s+
			(?:disable|disabledForIntervals)(?:\s|$)/x
	} @$events;
	my $io_deleted = grep {
		/^DELETED\s+\Q$io_name\E(?:\s|$)/
	} @$events;

	# Ein eigenes jsonMap am Zielgeraet benennt Readings um. Die Umbenennung
	# wirkt sofort; das Reading unter dem alten Namen muss deshalb weg.
	for my $event (@$events) {
		next if $event !~ /^(?:ATTR|DELETEATTR)\s+(\S+)\s+jsonMap(?:\s|$)/;
		sync_json_map($hash, $1);
	}

	# Ein von Hand gesetzter Geraeteschluessel wirkt auf das erzeugte Ergebnis.
	# Ueber das Ereignis statt ueber die AttrFn, weil fhem.pl beim Loeschen die
	# AttrFn des Zielgeraets ruft und nicht die angemeldete Pruefinstanz
	# (CommandDeleteAttr: CallFn($sdev, "AttrFn", "del", ...)).
	for my $event (@$events) {
		next if $event !~ /^(?:ATTR|DELETEATTR)\s+(\S+)\s+mqttDiscoveryKeys(?:\s|$)/;
		my $target = $1;
		next if !$defs{$target};
		forget_parse_index($hash);
		my $error = rebuild_device($hash, $target);
		log_message($hash, 2, "mqttDiscoveryKeys an $target: $error")
			if defined($error) && $error ne '';

		# Das Reading gehoert zum Set-Befehl, muss aber auch ein von Hand
		# gesetztes Attribut zeigen; sonst nennt es einen ueberholten Stand.
		my $line = gateway($hash)->attr_value($target, 'mqttDiscoveryKeys', '');
		reading($hash, 'deviceKey', "$target: " . ($line ne '' ? $line : '-'));
	}

	# Beim Loeschen des IODev darf weder eine vorgemerkte Config noch dessen
	# letzte Perl-Referenz einen scheinbar verfuegbaren Zustand erhalten.
	if ($io_deleted) {
		clear_queue($hash);
		clear_availability_refreshes($hash);
		sync_io_availability($hash, 1, 0);
		reading($hash, 'state', state_value($hash));
		log_message($hash, 2, "bound IODev $io_name was deleted; targets offline");
	}

	# Beim Start sind IODev-Attribute und clientOrder vollstaendig geladen. Die
	# erneute, deduplizierte Pruefung erfasst deshalb auch gespeicherte Filter.
	# Globale Attributereignisse machen spaetere Aenderungen sofort sichtbar.
	check_ignore_regexp($hash)
		if $lifecycle || $ignore_regexp_changed;
	sync_io_availability($hash, 1)
		if !$io_deleted && ($lifecycle || $io_availability_changed);
	resume_availability_refreshes($hash)
		if !$io_deleted && ($lifecycle || $io_availability_changed);
	reconcile_registry_rendering($hash)
		if !$io_deleted && $lifecycle;

	# Die Readings gehoeren zu den Set-Befehlen mit Dialog und muessen auch an
	# einer Instanz stehen, die vor dieser Fassung definiert wurde; sonst laedt
	# FHEMWEB beim Aufruf des Dialogs die ganze Seite neu.
	update_selection_reading($hash, undef)
		if $lifecycle && !defined(ReadingsVal($hash->{NAME}, 'selectReadings', undef));
	reading($hash, 'deviceKey', '-')
		if $lifecycle && !defined(ReadingsVal($hash->{NAME}, 'deviceKey', undef));
	reading($hash, 'replayPayloads', '-')
		if $lifecycle && !defined(ReadingsVal($hash->{NAME}, 'replayPayloads', undef));

	# INITIALIZED folgt beim Start auf das statefile; REREADCFG wird unmittelbar
	# vor der Rueckkehr in den Eventloop ausgeloest und darf denselben Start planen.
	return undef if !$lifecycle;
	start_shelly($hash);
	my $queue = $hash->{helper}{queue};
	return undef if ref($queue) ne 'HASH' || !$queue->{waiting_for_init};

	schedule_queue($hash);
	return undef;
}

# Koalesziert Config-Nachrichten pro Topic und plant genau einen kurzen Queue-Timer.
sub enqueue {
	my ($hash, $cid, $topic, $payload) = @_;
	my $queue = $hash->{helper}{queue} ||= { order => [], messages => {}, scheduled => 0 };
	my $queue_key = $topic;
	# Das gemeinsame Announce-Topic traegt mehrere Geraete und darf sie nicht gegenseitig ersetzen.
	if ($topic eq 'shellies/announce') {
		my $info = eval { JSON::PP::decode_json($payload) };
		$queue_key .= "\0$info->{id}" if MQTT2_Discovery::Parser::Shelly::valid_info($info);
	}

	# Fuer ein Config-Topic ist nur der zuletzt empfangene Stand relevant. Das
	# begrenzt zugleich die Arbeit bei schnellen Wiederholungen/Reconnects.
	push @{ $queue->{order} }, $queue_key if !exists $queue->{messages}{$queue_key};
	$queue->{messages}{$queue_key} = [$cid, $topic, $payload];
	return if $queue->{scheduled};

	# Vor dem Einlesen des statefile bleibt die Arbeit ausschliesslich gespeichert;
	# global:INITIALIZED beziehungsweise global:REREADCFG startet sie spaeter.
	if (defined($main::init_done) && !$main::init_done) {
		$queue->{waiting_for_init} = 1;
		return;
	}

	schedule_queue($hash);
	return;
}

# Merkt eine vollstaendige Neuerzeugung aus der Registry vor. Dadurch muessen
# bereits empfangene Discovery-Nachrichten nicht erneut vom Broker kommen.
sub enqueue_rerender {
	my ($hash) = @_;
	return if ref($hash) ne 'HASH';
	$hash->{helper}{rerender_pending} = 1;
	my $queue = $hash->{helper}{queue} ||= { order => [], messages => {}, scheduled => 0 };
	return if $queue->{scheduled};

	# Vor INITIALIZED bleibt auch die Attribut-Neuerzeugung geparkt, bis das
	# statefile und damit die vollstaendige Registry geladen worden sind.
	if (defined($main::init_done) && !$main::init_done) {
		$queue->{waiting_for_init} = 1;
		return;
	}
	return if !gateway($hash)->can_schedule();

	schedule_queue($hash);
	return;
}

# Verarbeitet pro Timerlauf eine Nachricht oder ein vorbereitetes Zieldevice atomar.
sub process_queue {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return if ref($queue) ne 'HASH';

	# Nach Loeschen, Ersetzen oder Deaktivieren des Devices darf ein alter Timer
	# keine bereits ueberholten Discovery-Nachrichten mehr anwenden.
	if (!$defs{ $hash->{NAME} } || $defs{ $hash->{NAME} } != $hash
			|| gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		clear_queue($hash);
		return;
	}

	# Der Worker darf selbst bei einem unerwartet fruehen Timerlauf keine Daten
	# verarbeiten. Das naechste Lifecycle-Ereignis startet die geparkte Queue.
	if (defined($main::init_done) && !$main::init_done) {
		$queue->{scheduled} = 0;
		$queue->{waiting_for_init} = 1;
		return;
	}

	my $batch = $queue->{batch} ||= {
		pending_identities => {}, created_identities => {}, delete_had_manual => {},
	};

	# Eine Attributaenderung rendert jedes aktuell verwaltete Ziel aus demselben
	# Registry-Entwurf neu; noch wartende MQTT-Nachrichten fliessen danach hinein.
	if ($hash->{helper}{rerender_pending}) {
		$batch->{registry} ||= clone_registry(
			registry($hash),
		);
		$batch->{rerender_all} = 1;

		for my $identity (keys %{ $batch->{registry}{devices} || {} }) {
			$batch->{pending_identities}{$identity} = 1;
		}

		delete $hash->{helper}{rerender_pending};
	}
	my $message;

	# Pro Timerlauf wird hoechstens eine MQTT-Nachricht verarbeitet. Wenn keine
	# mehr wartet, folgt hoechstens ein bereits zusammengefuehrtes Zieldevice.
	while (@{ $queue->{order} || [] }) {
		my $topic = shift @{ $queue->{order} };
		$message = delete $queue->{messages}{$topic};
		last if $message;
	}

	# Die Argumente werden einzeln uebergeben: Der Prototyp der Funktion legt jedem
	# Parameter skalaren Kontext auf, ein aufgeloestes Array zaehlte als ein Argument.
	process($hash, $message->[0], $message->[1], $message->[2], $batch)
		if $message;

	my $error;

	# Sind keine MQTT-Nachrichten mehr offen, wird pro Timerlauf genau ein bereits
	# zusammengefuehrtes Zieldevice angewendet, damit FHEMs Event-Loop responsiv bleibt.
	if (!$message && keys %{ $batch->{pending_identities} || {} }) {
		my ($identity) = sort keys %{ $batch->{pending_identities} };
		$error = apply_batch_identity($hash, $batch, $identity);
		delete $batch->{pending_identities}{$identity} if !$error;
	}

	# Ein fehlgeschlagener Apply beendet den gesamten Queue-Batch; nur in diesem
	# Lauf erzeugte Devices werden dabei als Teil der Transaktion zurueckgerollt.
	if ($error) {
		# Neu angelegte Devices gehoeren zur fehlgeschlagenen Transaktion und
		# werden entfernt; bestehende Devices bleiben durch den ActionPlan intakt.
		cleanup_created_devices($hash, $batch->{registry}, $batch->{created_identities});
		$hash->{helper}{registry} = $batch->{registry};
		persist_registry($hash);
		update_counts($hash);
		reading($hash, 'lastError', $error);
		log_message($hash, 1, "queue apply failed: $error");
		$hash->{helper}{rerender_pending} = 1 if $batch->{rerender_all};
		clear_queue($hash);
	} elsif (@{ $queue->{order} || [] } || keys %{ $batch->{pending_identities} || {} }) {
		gateway($hash)->schedule(
			$QUEUE_DELAY, $hash, \&process_queue,
		);
	} else {
		$hash->{helper}{registry} = $batch->{registry} if ref($batch->{registry}) eq 'HASH';
		persist_registry($hash);
		update_counts($hash);
		$queue->{scheduled} = 0;
		# Initialwerte werden erst angefordert, wenn alle Reading-Bindings des Batches vorhanden sind.
		my $request_error = send_requests($hash, $batch->{after_apply});
		reading($hash, 'lastError', $request_error) if $request_error;
		delete $queue->{batch};
	}
	return;
}

# Bricht geplante Queue-Arbeit ab und entfernt den vollstaendigen Batchzustand.
sub clear_queue {
	my ($hash) = @_;
	gateway($hash)->cancel_timer($hash, \&process_queue);
	delete $hash->{helper}{queue} if ref($hash->{helper}) eq 'HASH';
	delete $hash->{helper}{shelly_started};
	# Antworten abgebrochener Abfragen duerfen nach einer Reaktivierung keinen alten Snapshot anwenden.
	if (ref($hash->{helper}{formats}{shelly}) eq 'HASH') {
		$hash->{helper}{formats}{shelly} = { sequence => $hash->{helper}{formats}{shelly}{sequence} || 0 };
	}
	return;
}

# Vorwaertsdeklaration der inneren Verarbeitung fuer den davor definierten Fehlerwrapper.

# Issues werden pro Topic gespeichert. Ein spaeter erfolgreich verarbeitetes
# Topic kann dadurch genau seinen vorherigen Fehler oder seine Warnung loeschen.
# Synchronisiert Fehler- und Warnungszaehler mit den Topic-bezogenen Issue-Tabellen.
sub update_issue_readings {
	my ($hash) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	reading($hash, 'errorCount', scalar keys %{ $issues->{error} || {} });
	reading($hash, 'warningCount', scalar keys %{ $issues->{warning} || {} });
	return;
}

# Speichert einen Fehler oder eine Warnung samt Topic und Adapter in Readings und Speicher.
sub record_issue {
	my ($hash, $level, $topic, $adapter, $reason) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	$issues->{$level}{$topic} = {
		adapter => $adapter || 'unknown', reason => $reason || 'Unbekannter Fehler',
	};
	my $prefix = $level eq 'error' ? 'lastError' : 'lastWarning';
	reading($hash, $prefix, $reason || 'Unbekannter Fehler');
	reading($hash, $prefix . 'Adapter', $adapter || 'unknown');
	reading($hash, $prefix . 'Topic', $topic);
	update_issue_readings($hash);
	return;
}

# Entfernt ein geloestes Topic-Issue und aktualisiert die zugehoerigen Zaehler.
sub clear_issue {
	my ($hash, $level, $topic) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	delete $issues->{$level}{$topic};
	reading($hash, 'lastWarning', 'none')
		if $level eq 'warning' && !keys %{ $issues->{warning} || {} };
	update_issue_readings($hash);
	return;
}

# Kapselt die gesamte Topic-Verarbeitung in einer Exception-Grenze und pflegt Issues.
sub process {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	delete $hash->{helper}{process_adapter};
	delete $hash->{helper}{process_warning};
	my $status;

	# Diese Exception-Grenze verhindert, dass fehlerhafte Fremddaten FHEMs
	# gesamten MQTT-Dispatch abbrechen.
	my $ok = eval {
		$status = process_inner($hash, $cid, $topic, $payload, $batch);
		1;
	};

	# Nur ein expliziter Status aus einer fehlerfrei verlassenen Prozessgrenze ist
	# geeignet, die Topic-bezogenen Fehler- und Warnungsreadings fortzuschreiben.
	if ($ok && defined $status) {

		# Parser- oder Apply-Fehler bleiben ihrem Topic und Adapter zugeordnet, damit
		# eine spaetere erfolgreiche Wiederholung genau diesen Eintrag loeschen kann.
		if ($status eq 'error') {
			# Ein fehlgeschlagener Apply darf die native Wiedererkennung nicht dauerhaft sperren.
			if (($hash->{helper}{process_adapter} || '') eq 'shelly') {
				delete $_->{complete} for values %{ $hash->{helper}{formats}{shelly}{devices} || {} };
			}
			record_issue(
				$hash, 'error', $topic,
				$hash->{helper}{process_adapter}
					|| gateway($hash)->reading_value($hash->{NAME}, 'lastErrorAdapter', 'unknown'),
				gateway($hash)->reading_value($hash->{NAME}, 'lastError', 'Unbekannter Fehler'),
			);
		} elsif ($status eq 'consumed') {
			clear_issue($hash, 'error', $topic);
			my $warning = delete $hash->{helper}{process_warning};

			# Ein erfolgreich konsumiertes Topic kann dennoch degradierte oder nicht
			# unterstuetzte Bestandteile enthalten, die als Warnung sichtbar bleiben sollen.
			if (defined($warning) && $warning ne '') {
				record_issue(
					$hash, 'warning', $topic,
					gateway($hash)->reading_value($hash->{NAME}, 'lastAdapter', 'unknown'), $warning,
				);
			} else {
				clear_issue($hash, 'warning', $topic);
			}
			reading($hash, 'lastError', 'none')
				if !keys %{ $hash->{helper}{issues}{error} || {} };
		}
		return $status;
	}

	my $detail = $ok ? 'Verarbeitung lieferte keinen Status' : ($@ || 'unbekannter Fehler');
	$detail =~ s/[\r\n]+/ /g;
	$detail = substr($detail, 0, 1000) . '... <truncated>' if length($detail) > 1000;
	my $error = "Unerwarteter Fehler in der MQTT-Verarbeitung: $detail";
	eval { reading($hash, 'lastError', $error) };
	eval { record_issue(
		$hash, 'error', $topic, $hash->{helper}{process_adapter} || 'unknown', $error,
	) };
	eval { log_message($hash, 1, $error) };
	return 'error';
}

# Fuehrt Formatwahl, Modellierung, Mapping und transaktionales Device-Apply fuer ein Topic aus.
sub process_inner {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	log_message($hash, 4, "processing topic=$topic");
	log_message($hash, 4, 'message cid=' . (defined($cid) ? $cid : '') . '; payloadLength=' . length(defined($payload) ? $payload : ''));
	log_message($hash, 5, 'discovery payload=' . log_payload($payload))
		if log_enabled($hash, 5);
	my $prefixes = prefixes($hash);
	my $parsed = MQTT2_Discovery::FormatRegistry::consume(
		topic => $topic, payload => $payload, prefixes => $prefixes,
		shelly_args($hash), cid => $cid,
		states => ($hash->{helper}{formats} ||= {}),
		(ref($hash->{helper}{format_adapters}) eq 'ARRAY'
			? (adapters => $hash->{helper}{format_adapters}) : ()),
	);
	$hash->{helper}{process_adapter} = $parsed->{adapter} if $parsed->{adapter};
	$hash->{helper}{process_message} = { topic => $topic, payload => $payload };
	buffer_payload($hash, $topic, $payload);

	# Kein Adapter beansprucht das Topic; es muss fuer nachfolgende MQTT-Parser
	# freigegeben werden und darf keine Discovery-Readings veraendern.
	if ($parsed->{status} eq 'next') {
		log_message($hash, 4, "topic does not match configured prefixes; passing to next parser: $topic");
		return 'next';
	}
	reading($hash, 'lastTopic', $topic);

	# Parserfehler liefern kein belastbares kanonisches Modell und duerfen daher
	# weder Registry noch Zieldevices teilweise veraendern.
	if ($parsed->{status} ne 'ok') {
		my $error = $parsed->{error} || 'Unbekannter Parserfehler';
		reading($hash, 'lastError', $error);
		reading($hash, 'lastErrorAdapter', $parsed->{adapter} || 'unknown');
		reading($hash, 'lastErrorTopic', $topic);
		reading($hash, 'unsupportedCount', scalar @{ $parsed->{warnings} || [] }) if $parsed->{warnings};
		log_message($hash, 1, "parser error for topic=$topic: $error");
		return 'error';
	}
	my $request_error = send_requests($hash, $parsed->{requests});
	# Netzwerkfehler bleiben sichtbar; ohne vollstaendigen Snapshot wird keine Registry kopiert.
	if ($request_error) {
		reading($hash, 'lastError', $request_error);
		return 'error';
	}
	return 'consumed' if ($parsed->{adapter} || '') eq 'shelly' && !@{ $parsed->{events} || [] };
	$cid = $parsed->{cid} if defined($parsed->{cid});

	# Die Registry wird als Transaktionsentwurf kopiert. Erst nach erfolgreichem
	# Mapping und Attribut-Apply ersetzt sie den bisher sichtbaren Stand.
	my $registry;
	my $clone_ok = eval {

		# Ein Batch teilt genau einen Registry-Entwurf ueber alle Nachrichten;
		# Einzelverarbeitung erhaelt dagegen eine nur fuer dieses Topic gueltige Kopie.
		if ($batch) {
			$batch->{registry} ||= clone_registry(registry($hash));
			$registry = $batch->{registry};
		} else {
			$registry = clone_registry(registry($hash));
		}
		1;
	};

	# Ohne vollstaendige Registry-Kopie fehlt die Rollback-Grenze; die Verarbeitung
	# muss abbrechen, bevor irgendein Device den neuen Stand sieht.
	if (!$clone_ok) {
		my $detail = $@ || 'unbekannter JSON-Fehler';
		$detail =~ s/[\r\n]+/ /g;
		my $error = "Registry konnte nicht kopiert werden: $detail";
		reading($hash, 'lastError', $error);
		log_message($hash, 1, $error);
		return 'error';
	}
	my @warnings = @{ $parsed->{warnings} || [] };
	my %pending_identities;
	my %created_identities;

	# Parser koennen aus einer Nachricht mehrere Upserts und Deletes liefern.
	# Zunaechst werden alle davon nur in der Registry-Kopie gesammelt.
	# Ein Geraet mit mehreren Kanaelen wird in ein Geraet je Kanal aufgeteilt.
	# Das steht erst fest, wenn alle Entities einer Nachricht bekannt sind; sie
	# kommen gemeinsam an, deshalb genuegt ein Blick vor der Schleife.
	my (%channels, %channel_names);

	for my $event (grep {
		ref($_) eq 'HASH' && ($_->{operation} // '') eq 'upsert'
			&& ref($_->{entity}) eq 'HASH' && defined($_->{entity}{channel})
	} @{ $parsed->{events} || [] }) {
		my $number = $event->{entity}{channel};
		$channels{$number} = 1;
		my $channel_name = $event->{entity}{channel_name};
		$channel_names{$number} = $channel_name
			if defined($channel_name) && !ref($channel_name) && $channel_name ne '';
	}
	my $split_channels = keys(%channels) > 1 ? 1 : 0;
	my ($first_channel) = sort { $a <=> $b } keys %channels;

	# Der erste Kanal ist das Geraet. Sein Name gilt deshalb als Geraetename,
	# auf dem die weiteren Kanaele aufbauen.
	my $first_channel_name = defined($first_channel) ? $channel_names{$first_channel} : undef;

	for my $event (@{ $parsed->{events} || [] }) {
		my $operation = $event->{operation} || 'upsert';
		log_message($hash, 4, 'entity operation=' . $operation
			. '; component=' . ($event->{entity}{kind} || '') . '; key=' . ($event->{source}{key} || ''));

		# Loeschereignisse entfernen bestehende Registry-Eintraege und durchlaufen
		# deshalb nicht das fuer Upserts bestimmte Mapping und Rendering.
		if ($operation eq 'delete' || $operation eq 'delete_device') {
			my ($entity, $model_error) = MQTT2_Discovery::Model::to_entity($event);

			# Eine nicht kanonisierbare Loeschung koennte die falsche Entity treffen;
			# in diesem Fall bleibt der bisherige Registry-Stand unveraendert.
			if ($model_error) {
				reading($hash, 'lastError', $model_error);
				log_message($hash, 1, "canonical delete failed for topic=$topic: $model_error");
				return 'error';
			}
			my $error = delete_entity($hash, $registry, $entity, $batch);

			# Fehler beim Neurendern oder automatischen Loeschen machen die gesamte
			# Delete-Operation unvollstaendig und werden als Topic-Fehler zurueckgegeben.
			if ($error) {
				reading($hash, 'lastError', $error);
				log_message($hash, 1, "delete failed for topic=$topic: $error");
				return 'error';
			}
			next;
		}
		# Die Adapterkennung ist die Familie dieses Geraets und damit die mittlere
		# Ebene des Schluesselraums.
		my $family = ref($event->{source}) eq 'HASH' ? ($event->{source}{adapter} // '') : '';
		my @mapper_arguments = (
			model => $event, io_name => $hash->{IODevName},
			name_prefix => gateway($hash)->attr_value(
				$hash->{NAME}, 'deviceNamePrefix', '',
			),
		);
		my $mapping;
		{
			# Die Wertabbildung entsteht bereits beim Mapping, die Konvention muss
			# deshalb hier schon feststehen. Das Zielgeraet ist noch unbekannt, es
			# zaehlen also zunaechst nur Familie und globale Ebene.
			local $MQTT2_Discovery::Mapper::FHEM_CONVENTIONS =
				key($hash, { adapter => $family }, 'style') eq 'fhem' ? 1 : 0;
			$mapping = MQTT2_Discovery::Mapper::map_model(@mapper_arguments);

			# Erst die Identitaet aus dem Mapping findet einen bestehenden
			# Datensatz. Behaelt er eine andere Konvention, entsteht die Abbildung
			# noch einmal mit seiner; sonst kippten laufende Readingnamen.
			my $record = $mapping->{ok} ? $registry->{devices}{ $mapping->{identity} } : undef;

			if (ref($record) eq 'HASH') {
				my $wanted = key($hash, $record, 'style') eq 'fhem' ? 1 : 0;

				if ($wanted != $MQTT2_Discovery::Mapper::FHEM_CONVENTIONS) {
					local $MQTT2_Discovery::Mapper::FHEM_CONVENTIONS = $wanted;
					$mapping = MQTT2_Discovery::Mapper::map_model(@mapper_arguments);
				}
			}
		}
		$mapping->{adapter} = $family if ref($mapping) eq 'HASH';

		# Nicht abbildbare Komponenten werden isoliert uebersprungen, damit andere
		# Entities derselben Discovery-Nachricht weiterhin nutzbar bleiben.
		if (!$mapping->{ok}) {
			push @warnings, $mapping->{error};
			log_message($hash, 2, 'mapping warning: ' . ($mapping->{error} || 'unknown mapping error'));
			next;
		}
		log_message($hash, 4, 'mapped component=' . ($mapping->{metadata}{component} || '')
			. '; target=' . ($mapping->{proposed_name} || '') . '; readings=' . scalar(@{ $mapping->{reading_lines} || [] })
			. '; sets=' . scalar(@{ $mapping->{set_lines} || [] }));
		push @warnings, @{ $mapping->{warnings} || [] };
		my $created_now = 0;

		# Beim Aufteilen liegt der Datensatz unter einer anderen Identitaet als
		# der des Mappings; das Anwenden muss die tatsaechliche kennen.
		my $staged_identity = $mapping->{identity};
		my $error = stage_mapping(
			$hash, $registry, $mapping, $cid, \$created_now, $split_channels,
			\$staged_identity, $first_channel, $first_channel_name,
		);

		# Ein Staging-Fehler kann bereits ein neues Device angelegt haben; solche
		# Seiteneffekte dieses Laufs werden entfernt, bevor der Fehler weitergereicht wird.
		if ($error) {
			cleanup_created_devices($hash, $registry, \%created_identities);
			reading($hash, 'lastError', $error);
			log_message($hash, 1, "apply failed for topic=$topic: $error");
			return 'error';
		}
		$pending_identities{$staged_identity} = 1;
		$created_identities{$staged_identity} = 1 if $created_now;
	}

	# Im Batch werden nur betroffene Identitaeten vorgemerkt; ohne Batch koennen
	# die vollstaendig gesammelten Mappings sofort pro Zieldevice angewendet werden.
	if ($batch) {
		$batch->{pending_identities}{$_} = 1 for keys %pending_identities;
		$batch->{created_identities}{$_} = 1 for keys %created_identities;
	} else {
		# Erst die vollstaendige Nachricht sammeln, damit jedes Zieldevice nur einmal
		# neue Attribute erhaelt und Device-Discovery atomar sichtbar wird.
		for my $identity (sort keys %pending_identities) {
			my $record = $registry->{devices}{$identity};
			my $error = apply_device_lines($hash, $record, { registry => $registry });

			# Scheitert ein Zieldevice, gehoeren alle in dieser Nachricht neu erzeugten
			# Devices zum fehlgeschlagenen Apply und werden gemeinsam bereinigt.
			if ($error) {
				cleanup_created_devices($hash, $registry, \%created_identities);
				reading($hash, 'lastError', $error);
				log_message($hash, 1, "apply failed for topic=$topic: $error");
				return 'error';
			}
		}

	}

	# Bei Einzelverarbeitung ist der neue Entwurf jetzt vollstaendig angewendet und
	# darf den sichtbaren Registry-Stand ersetzen; ein Batch tut das erst am Ende.
	if (!$batch) {
		$hash->{helper}{registry} = $registry;
		persist_registry($hash);
		update_counts($hash);
		my $error = send_requests($hash, $parsed->{after_apply});
		if ($error) {
			reading($hash, 'lastError', $error);
			return 'error';
		}
	} else {
		push @{ $batch->{after_apply} ||= [] }, @{ $parsed->{after_apply} || [] };
	}

	# Parser- und Mapping-Warnungen degradieren das Ergebnis, verhindern aber nicht
	# die erfolgreichen Entities und werden deshalb getrennt von Fehlern gespeichert.
	if (@warnings) {
		my $warning = join('; ', @warnings);
		$hash->{helper}{process_warning} = $warning;
		reading($hash, 'lastWarning', $warning);
		log_message($hash, 2, "warning: $warning");
	}
	reading($hash, 'lastAdapter', $parsed->{adapter} || 'unknown');
	log_message($hash, 4, 'processing finished; topic=' . $topic
		. '; entities=' . scalar(@{ $parsed->{events} || [] }));
	return 'consumed';
}

# Prueft, ob eine geladene Registry die fuer sichere Weiterverarbeitung erwartete Struktur hat.
sub registry_valid {
	my ($registry) = @_;
	return 0 if ref($registry) ne 'HASH' || ref($registry->{devices}) ne 'HASH';

	for my $record (values %{ $registry->{devices} }) {
		return 0 if ref($record) ne 'HASH' || ref($record->{entities}) ne 'HASH';
		return 0 if exists($record->{owned_reading}) && ref($record->{owned_reading}) ne 'ARRAY';
		return 0 if exists($record->{owned_set}) && ref($record->{owned_set}) ne 'ARRAY';
		return 0 if exists($record->{availability_topics})
			&& ref($record->{availability_topics}) ne 'ARRAY';
		return 0 if exists($record->{runtime_refs}) && ref($record->{runtime_refs}) ne 'HASH';
		return 0 if exists($record->{availability_reading})
			&& (ref($record->{availability_reading})
				|| ($record->{availability_reading} ne ''
					&& $record->{availability_reading} !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/));
		return 0 if exists($record->{owned_availability_reading})
			&& (ref($record->{owned_availability_reading})
				|| ($record->{owned_availability_reading} ne ''
					&& $record->{owned_availability_reading} !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/));

		# Runtime-Referenzen duerfen nur die vom Renderer erzeugte kurze SHA-1-Form
		# und rein deklarative Hash-Beschreibungen aus dem internen Reading laden.
		if (ref($record->{runtime_refs}) eq 'HASH') {
			return 0 if grep {
				$_ !~ /^r_[a-f0-9]{16,40}$/ || ref($record->{runtime_refs}{$_}) ne 'HASH'
			} keys %{ $record->{runtime_refs} };
		}
		return 0 if grep { ref($_) ne 'HASH' } values %{ $record->{entities} };
	}

	return 1;
}

# Die versteckte .registry-Reading ueberlebt einen FHEM-Neustart, ohne eine
# Konfigurationsdatei zu veraendern. Ungueltige Altstaende werden verworfen.
sub registry {
	my ($hash) = @_;
	return $hash->{helper}{registry} if ref($hash->{helper}{registry}) eq 'HASH';
	my $may_cache = $main::init_done ? 1 : 0;
	my $stored = gateway($hash)->reading_value($hash->{NAME}, '.registry', '');
	my $registry;
	eval {
		# Unicode-Strings werden als Zeichen dekodiert. Bei ungeflaggten Strings
		# zuerst UTF-8 versuchen und fuer FHEMs bytestream-Statefile auf die dort
		# uebliche Ein-Byte-Zeichenkodierung zurueckfallen.
		if (utf8::is_utf8($stored)) {
			$registry = JSON::PP->new->decode($stored);
		} else {
			eval { $registry = JSON::PP::decode_json($stored); 1 }
				or $registry = JSON::PP->new->decode($stored);
		}
	} if $stored ne '';

	# Ein fehlender oder strukturell veralteter Persistenzstand wird durch eine
	# leere Registry ersetzt, statt spaetere Mapping-Schritte mit Fremddaten zu speisen.
	if (!registry_valid($registry)) {
		log_message($hash, 2, 'stored registry is empty or invalid; starting with an empty registry') if $stored ne '';
		$registry = { version => 1, devices => {} };
	}
	# Vor INITIALIZED ist das statefile noch nicht geladen. Der leere Zwischenstand
	# darf deshalb nicht den kurz darauf restaurierten Registry-Stand verdecken.
	$hash->{helper}{registry} = $registry if $may_cache;
	return $registry;
}

# Erstellt ueber kanonisches JSON eine tiefe Kopie des reinen Registry-Datenmodells.
sub clone_registry {
	my ($registry) = @_;
	my $json = JSON::PP->new->canonical(1);
	return $json->decode($json->encode($registry));
}

# Persistiert den kanonischen Registry-Stand in einer internen, nicht ausloesenden Reading.
sub persist_registry {
	my ($hash) = @_;
	my $json = JSON::PP->new->canonical(1)->encode(registry($hash));
	gateway($hash)->update_reading($hash, '.registry', $json, 0);
	forget_parse_index($hash);
	return;
}

# Ein Kanalgeraet traegt den Namen seines Kanals, wenn der Anwender einen
# vergeben hat, sonst die Nummer. Der allgemeine Name aus Geraetename, Art und
# Kennung bleibt der Rueckfall bei Namensgleichheit.
sub channel_mapping {
	my ($mapping, $channel) = @_;
	my $named = defined($mapping->{channel_name}) && !ref($mapping->{channel_name})
		&& $mapping->{channel_name} ne '';
	my $suffix = $named ? $mapping->{channel_name} : $channel;
	$suffix =~ s/[^A-Za-z0-9]+/_/g;
	$suffix =~ s/\A_+|_+\z//g;
	$suffix = $channel if $suffix eq '';
	my $base = $named && defined($mapping->{device_base}) && $mapping->{device_base} ne ''
		? $mapping->{device_base} : $mapping->{proposed_name};
	return {
		%$mapping,
		proposed_name => "${base}_$suffix",
		alternate_name => ($mapping->{alternate_name} // $mapping->{proposed_name}) . "_$channel",
	};
}

# Waehlt bei Namenskonflikten einen stabilen, reproduzierbaren Zieldevicenamen.
# Sammelt die Namen, die andere Discovery-Identitaeten bereits fuer sich halten.
# Ein solcher Name ist belegt, auch wenn sein Geraet gerade fehlt: Sonst nimmt
# eine zweite Identitaet denselben Namen, beide Datensaetze senden auf
# verschiedene Topics, und welcher gewinnt, entscheidet die Reihenfolge des
# Hashes. Sichtbar wird das erst beim Schalten.
sub claimed_target_names {
	my ($registry, $identity) = @_;
	my $devices = ref($registry) eq 'HASH' ? $registry->{devices} : undef;
	return {} if ref($devices) ne 'HASH';
	my %claimed;

	for my $key (keys %$devices) {
		next if defined($identity) && $key eq $identity;
		my $record = $devices->{$key};
		next if ref($record) ne 'HASH' || !defined($record->{name}) || $record->{name} eq '';
		$claimed{ $record->{name} } = $key;
	}

	return \%claimed;
}

sub target_name {
	my ($mapping, $registry, $allow_existing, $hash, $identity) = @_;
	my $base = $mapping->{proposed_name};
	$identity = $mapping->{identity} if !defined($identity);
	my $claimed = claimed_target_names($registry, $identity);
	return $base if !$defs{$base} && !$claimed->{$base};

	# Ein fremder Datensatz gibt seinen Namen auch im replace-Modus nicht her;
	# der Modus richtet sich auf Geraete des Anwenders, nicht auf verwaltete.
	if ($allow_existing && !$claimed->{$base}) {
		return $base;
	}
	log_message($hash, 3, "Zielname $base gehoert schon zu $claimed->{$base}")
		if ref($hash) eq 'HASH' && $claimed->{$base};

	# Der bevorzugte Name kann durch ein fremdes Geraet belegt sein, etwa weil
	# zwei Geraete denselben Anwendernamen tragen. Dann gilt der allgemeine
	# Vorschlag aus Name, Art und Kennung, der sich je Geraet unterscheidet.
	my $alternate = $mapping->{alternate_name};

	if (defined($alternate) && $alternate ne '' && !$defs{$alternate}
			&& !$claimed->{$alternate}) {
		log_message($hash, 3, "Zielname $base ist belegt; verwende $alternate")
			if ref($hash) eq 'HASH';
		return $alternate;
	}
	$base = $alternate if defined($alternate) && $alternate ne '';

	# Der Hash bleibt ueber Neustarts stabil; ein Zaehler ist nur der seltene
	# Fallback, wenn sogar dieser Name bereits belegt ist.
	my $suffix = stable_suffix($mapping->{identity});
	my $candidate = "${base}_$suffix";
	my $counter = 2;
	$candidate = "${base}_${suffix}_" . $counter++
		while $defs{$candidate} || $claimed->{$candidate};
	return $candidate;
}

# Erzeugt fuer Transporte ohne Publisher-CID einen stabilen lokalen Routing-Schluessel.
sub virtual_cid {
	my ($mapping) = @_;
	return undef if !defined($mapping->{identity}) || $mapping->{identity} eq '';
	return 'mqtt2_discovery_' . stable_suffix($mapping->{identity}, 16);
}

# Leitet aus Bridge-Regeln oder fehlender Publisher-Identitaet die Ziel-CID ab.
sub autocreate_cid {
	my ($mapping, $cid, $io_type) = @_;
	my $transport_cid = defined($cid) ? $cid : '';
	my $bridge = $modules{MQTT2_DEVICE}{defptr}{bridge};

	my @topics = stable_unique(map { $_->{topic} }
		grep { ref($_) eq 'HASH' && defined($_->{topic}) && $_->{topic} ne '' }
			@{ $mapping->{reading_lines} || [] });
	my %resolved;

	# MQTT_GENERIC_BRIDGE kann aus Topic und Transport-CID eine logischere CID
	# ableiten. Der fremde Ausdruck stammt aus lokaler FHEM-Konfiguration, nicht
	# aus dem Discovery-Payload, und wird in einer Fehlergrenze ausgewertet.
	for my $topic (@topics) {

		for my $regexp (sort keys %{ ref($bridge) eq 'HASH' ? $bridge : {} }) {
			my $rule = $bridge->{$regexp};
			next if ref($rule) ne 'HASH' || !defined($rule->{name});
			my ($matched, $new_cid);
			my $ok = eval {

				# Nur eine zur Topic- oder CID/Topic-Form passende Bridge-Regel darf die
				# Transport-CID durch ihre logisch abgeleitete Client-ID ersetzen.
				if ("$topic:" =~ m/^$regexp$/s || "$transport_cid:$topic:" =~ m/^$regexp$/s) {
					$matched = 1;
					$new_cid = eval $rule->{name};  ## no critic (BuiltinFunctions::ProhibitStringyEval)
					die $@ if $@;
				}
				1;
			};
			return (undef, "bridgeRegexp fuer $topic konnte nicht ausgewertet werden: " . ($@ || 'unbekannter Fehler'))
				if !$ok;
			next if !$matched;
			return (undef, "bridgeRegexp fuer $topic liefert keine Client-ID")
				if !defined($new_cid) || ref($new_cid) || $new_cid eq '';
			$resolved{$new_cid} = 1;
		}

	}

	return (undef, 'Discovery-Topics ergeben mehrere bridgeRegexp-Client-IDs: ' . join(', ', sort keys %resolved))
		if keys(%resolved) > 1;
	my ($resolved_cid) = keys %resolved;
	return ($resolved_cid, undef) if defined($resolved_cid);

	# MQTT2_CLIENT kennt nur die Client-ID seiner eigenen Brokerverbindung und
	# nicht die des urspruenglichen Publishers. Eine fehlende Transport-CID hat
	# dieselbe Grenze und erhaelt deshalb ebenfalls eine logische Discovery-CID.
	if (($io_type || '') eq 'MQTT2_CLIENT' || $transport_cid eq '') {
		my $virtual_cid = virtual_cid($mapping);
		return (undef, 'Discovery-Geraeteidentitaet kann keine virtuelle Client-ID bilden')
			if !defined($virtual_cid);
		return ($virtual_cid, undef);
	}
	return ($transport_cid, undef);
}

# Findet unter Beruecksichtigung fremder Registry-Besitzer ein eindeutiges CID-Zieldevice.
sub existing_cid_target {
	my ($hash, $registry, $identity, $mapping, $cid) = @_;
	my $devices = gateway($hash)->mqtt2_devices_for_cid($cid);
	return (undef, undef) if ref($devices) ne 'ARRAY' || !@$devices;

	# Eine Transport-CID kann bei Bridges fuer mehrere logische Discovery-Geraete
	# stehen. Bereits einer anderen Discovery-Identitaet zugeordnete Targets sind
	# deshalb keine Kandidaten fuer die aktuelle Identitaet.
	my %owned_elsewhere = map {
		my $record = $registry->{devices}{$_};
		defined($record->{name}) ? ($record->{name} => 1) : ()
	} grep { $_ ne $identity && ref($registry->{devices}{$_}) eq 'HASH' }
		keys %{ $registry->{devices} || {} };
	my @available = grep { !$owned_elsewhere{ $_->{NAME} || '' } } @$devices;
	return (undef, undef) if !@available;
	return ($available[0], undef) if @available == 1;

	my @named = grep { ($_->{NAME} || '') eq $mapping->{proposed_name} } @available;
	return ($named[0], undef) if @named == 1;
	return (undef, "Mehrere MQTT2_DEVICE-Devices verwenden Client-ID $cid: "
		. join(', ', sort map { $_->{NAME} || '<ohne Name>' } @available));
}

# Ordnet ein Mapping einem bestehenden oder neu angelegten Registry-Zieldevice zu.
sub stage_mapping {
	my ($hash, $registry, $mapping, $cid, $created_now_ref, $split_channels,
		$staged_identity_ref, $first_channel, $first_channel_name) = @_;

	# Ein Geraet mit mehreren Kanaelen wird in ein Geraet je Kanal aufgeteilt,
	# nicht in ein technisches Hauptgeraet und dazu die Kanaele: Ein Kanal ein
	# Geraet, zwei Kanaele zwei Geraete, n Kanaele n Geraete. Der niedrigste
	# Kanal ist das Geraet selbst und traegt dessen Telemetrie; so machen es auch
	# die attrTemplates, deren zweites Geraet nur den zweiten Kanal fuehrt.
	my $channel = $split_channels ? $mapping->{channel} : undef;
	my $is_first = defined($channel) && defined($first_channel) && $channel eq $first_channel;
	undef $channel if $is_first;

	# Traegt dieser erste Kanal einen eigenen Namen, benennt er damit auch das
	# Geraet - genauso wie bei einem einkanaligen Geraet. Die Identitaet bleibt
	# die des Geraets, nur der Name kommt vom Kanal.
	$mapping = channel_mapping($mapping, $first_channel)
		if $is_first && defined($mapping->{channel_name}) && $mapping->{channel_name} ne '';

	# Ein weiterer Kanal haengt seinen Namen an den des Geraets. Benennt der
	# erste Kanal das Geraet, ist das sein Name und nicht mehr der aus Art und
	# Kennung.
	if (defined($channel) && defined($first_channel_name)
			&& defined($mapping->{device_base}) && $mapping->{device_base} ne '') {
		$mapping = { %$mapping,
			proposed_name => "$mapping->{device_base}_$first_channel_name" };
	}
	my $identity = $mapping->{identity} . (defined($channel) ? "|ch$channel" : '');
	$mapping = channel_mapping($mapping, $channel) if defined($channel);
	$$staged_identity_ref = $identity if ref($staged_identity_ref) eq 'SCALAR';
	my $record = $registry->{devices}{$identity};
	my $created_now = 0;
	my ($target_cid, $cid_error);
	$$created_now_ref = 0 if ref($created_now_ref) eq 'SCALAR';

	# Die Registry haelt die dauerhafte Zielzuordnung. Nur eine erstmals
	# auftretende Discovery-Identitaet benoetigt eine neue CID-Aufloesung.
	if ($record) {
		$target_cid = $record->{cid};
	} else {
		my $io_type = $defs{ $hash->{IODevName} }{TYPE} || '';
		($target_cid, $cid_error) = autocreate_cid($mapping, $cid, $io_type);
	}
	return $cid_error if $cid_error;

	# Alle Kanaele eines Geraets teilen sich eine CID. Ein Kanalgeraet darf
	# deshalb kein Bestandsgeraet darueber uebernehmen, es traefe das
	# Hauptgeraet oder einen anderen Kanal.
	my ($cid_target, $target_error) = defined($channel) ? (undef, undef)
		: existing_cid_target($hash, $registry, $identity, $mapping, $target_cid);
	return $target_error if $target_error;

	# Ein Registry-Eintrag besitzt Vorrang vor neuer Namensfindung, solange sein
	# Ziel noch existiert oder anhand der gespeicherten CID wiedergefunden wird.
	if ($record) {
		my $registered = $defs{ $record->{name} };

		# Wurde das Ziel ausserhalb der Discovery umbenannt, kann seine eindeutige
		# Client-ID die Registry-Zuordnung wiederherstellen, ohne ein Duplikat anzulegen.
		if (!$registered || ($registered->{TYPE} || '') ne 'MQTT2_DEVICE') {

			# Ohne CID-Ziel ist der Registry-Eintrag veraltet. Das aktuelle Mapping
			# durchlaeuft deshalb erneut die regulaere Uebernahme und autoCreate-Pruefung.
			if (!$cid_target) {
				my $stale_name = $record->{name};
				my $known_cid = $record->{cid};
				log_message($hash, 2,
					"stale registry target $stale_name is missing; reprocessing identity=$identity");
				$record = undef;
				my $io_type = $defs{ $hash->{IODevName} }{TYPE} || '';
				($target_cid, $cid_error) = autocreate_cid($mapping, $cid, $io_type);
				return $cid_error if $cid_error;

				# Ein eingespielter Block kennt die Client-ID des Geraets nicht,
				# sie steht in keiner seiner Nachrichten. Fehlt das Geraet gerade,
				# kaeme es mit der Ersatz-ID replay zurueck und verlaere seine
				# Zuordnung am IODev. Die bekannte ID des Datensatzes gilt deshalb
				# weiter; nur so stellt ein eigener Block sein Geraet wieder her.
				$target_cid = $known_cid
					if ($cid // '') eq $REPLAY_CID && defined($known_cid)
						&& $known_cid ne '' && $known_cid ne $REPLAY_CID;
				($cid_target, $target_error) = defined($channel) ? (undef, undef)
					: existing_cid_target($hash, $registry, $identity, $mapping, $target_cid);
				return $target_error if $target_error;
			} else {
				log_message($hash, 2,
					"recovered renamed target device $record->{name} as $cid_target->{NAME} by cid=$target_cid");
				$record->{name} = $cid_target->{NAME};
			}
		}
		$record->{cid} = $target_cid if $record;
	}

	# Nur bisher unbekannte Identitaeten durchlaufen Uebernahme, Namenskonflikt
	# und gegebenenfalls die automatische Anlage eines MQTT2_DEVICE.
	if (!$record) {
		my $mode = gateway($hash)->attr_value(
			$hash->{NAME}, 'existingDevice', 'conservative',
		);

		# ignore lehnt vorhandene Targets ab, replace darf ein gleichnamiges
		# MQTT2_DEVICE uebernehmen, conservative weicht auf einen stabilen Namen aus.
		if ($cid_target && $mode eq 'ignore') {
			return "Bestehendes Device $cid_target->{NAME} wird im ignore-Modus nicht veraendert";
		}
		my $base_exists = $defs{ $mapping->{proposed_name} } ? 1 : 0;

		# ignore schuetzt auch gleichnamige Devices ohne eindeutige CID-Zuordnung;
		# die Discovery darf sie weder uebernehmen noch unter diesem Namen veraendern.
		if (!$cid_target && $base_exists && $mode eq 'ignore') {
			return "Bestehendes Device $mapping->{proposed_name} wird im ignore-Modus nicht veraendert";
		}
		my $adopt_by_name = !$cid_target && $base_exists && $mode eq 'replace'
			&& ($defs{ $mapping->{proposed_name} }{TYPE} || '') eq 'MQTT2_DEVICE';
		my $name = $cid_target ? $cid_target->{NAME}
			: target_name($mapping, $registry, $adopt_by_name, $hash, $identity);

		# Erst wenn weder CID-Aufloesung noch Bestandsdevice ein Ziel liefern, ist
		# eine Neuanlage erforderlich und dabei die autoCreate-Vorgabe massgeblich.
		if (!$defs{$name}) {
			return "autoCreate ist deaktiviert; $name wurde nicht angelegt"
				if !gateway($hash)->attr_value($hash->{NAME}, 'autoCreate', 1);
			my $error = gateway($hash)->define_mqtt2_device(
				$name, $target_cid, $hash->{IODevName},
			);
			return $error if $error;
			$created_now = 1;

			# Hinter einem aus einem Block entstandenen Geraet steht keine
			# Hardware. Es sendet richtig, aber niemand antwortet, und sein state
			# bleibt darum auf set_<befehl> stehen. Der Vermerk sagt das auf der
			# Detailseite, sonst sieht es wie ein haengendes Geraet aus.
			gateway($hash)->set_attribute($name, 'comment',
				'Aus einem mit get payloads erzeugten Block eingespielt.'
					. ' Ohne die zugehoerige Hardware bleibt state auf set_<befehl>.')
				if ($target_cid // '') eq $REPLAY_CID;
		}
		return "$name ist kein MQTT2_DEVICE" if ($defs{$name}{TYPE} || '') ne 'MQTT2_DEVICE';
		$record = {
			name => $name, created => $created_now ? 1 : 0, io => $hash->{IODevName},
			cid => $target_cid,

			# Der Vermerk haelt fest, welche Konvention bei der Anlage galt. Wird
			# der Schluessel spaeter global umgestellt, behalten bestehende
			# Geraete ihr Verhalten, damit keine Readingwerte kippen.
			style => key($hash, undef, 'style'),
			entities => {}, owned_reading => [], owned_set => [], owned_devicetopic => undef,
		};
		$registry->{devices}{$identity} = $record;
		log_message($hash, 2, ($created_now ? 'created and registered' : 'adopted') . " target device $name");
	}
	# Die Familie wandert in den Datensatz, damit sie auch ohne neues Mapping
	# zur Verfuegung steht (shelly:sets=hook).
	$record->{adapter} = $mapping->{adapter}
		if defined($mapping->{adapter}) && $mapping->{adapter} ne '';
	$record->{entities}{ $mapping->{entity_key} } = $mapping;
	remember_payload($hash, $record->{name});
	log_message($hash, 4, "staged target=$record->{name}; entity=$mapping->{entity_key}");
	$$created_now_ref = $created_now if ref($created_now_ref) eq 'SCALAR';
	return undef;
}

# Entfernt nach Fehlern ausschliesslich Devices, die in der aktuellen Transaktion entstanden.
sub cleanup_created_devices {
	my ($hash, $registry, $created_identities) = @_;

	# Ausschliesslich in diesem Lauf neu angelegte Devices duerfen bei einem
	# Fehler wieder entfernt werden; uebernommene Devices sind tabu.
	for my $identity (sort keys %{ $created_identities || {} }) {
		my $record = $registry->{devices}{$identity};
		gateway($hash)->delete_device($record->{name})
			if $record && $defs{ $record->{name} };
		delete $registry->{devices}{$identity};
	}

	return;
}

# Loescht einen leeren, vollstaendig automatisch verwalteten Registry-Datensatz optional mit Device.
sub MQTT2_Discovery_autoDeleteRecord {
	my ($hash, $registry, $identity, $record, $hadManual) = @_;
	return undef if keys %{ $record->{entities} };
	return undef if !gateway($hash)->attr_value($hash->{NAME}, 'autoDelete', 0);
	return undef if !$record->{created} || $hadManual;
	return undef if record_has_manual_lines($hash, $record);

	# autoDelete gilt nur fuer vollstaendig von Discovery erzeugte Devices ohne
	# verbliebene manuelle Attribute oder Zeilen.
	my $error = gateway($hash)->delete_device($record->{name});
	return $error if $error;
	log_message($hash, 2, "deleted automatically managed MQTT2_DEVICE $record->{name}");
	delete $registry->{devices}{$identity};
	return undef;
}

# Wendet alle vorgemerkten Batch-Identitaeten an und veroeffentlicht den Registry-Stand.
sub finish_batch {
	my ($hash, $batch) = @_;
	return undef if ref($batch) ne 'HASH';
	my $registry = ref($batch->{registry}) eq 'HASH'
		? $batch->{registry} : registry($hash);

	for my $identity (sort keys %{ $batch->{pending_identities} || {} }) {
		my $error = apply_batch_identity($hash, $batch, $identity);

		# Ein einziges fehlgeschlagenes Zieldevice macht den gemeinsamen Registry-
		# Entwurf unvollstaendig; neu erzeugte Devices werden vor dem Abbruch bereinigt.
		if ($error) {
			cleanup_created_devices($hash, $registry, $batch->{created_identities});
			$hash->{helper}{registry} = $registry;
			persist_registry($hash);
			update_counts($hash);
			return $error;
		}
	}

	$hash->{helper}{registry} = $registry;
	persist_registry($hash);
	update_counts($hash);
	return send_requests($hash, delete $batch->{after_apply});
}

# Rendert ein einzelnes Batch-Ziel und fuehrt danach die geschuetzte autoDelete-Entscheidung aus.
sub apply_batch_identity {
	my ($hash, $batch, $identity) = @_;
	my $registry = $batch->{registry};
	return undef if ref($registry) ne 'HASH';
	my $record = $registry->{devices}{$identity};
	return undef if !$record;
	my $error = apply_device_lines($hash, $record);
	return $error if $error;

	my $hadManual = delete $batch->{delete_had_manual}{$identity};
	return MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
}

# Ermittelt die aus Discovery sicher bekannten sichtbaren Reading-Namen.
sub expected_reading_names {
	my ($entries) = @_;
	my @names;

	# Nur explizite State-Bindings liefern bereits ohne Nutzdaten einen sicheren
	# Reading-Namen. Freie JSON-Felder und Sequenzen entstehen erst aus Payloads.
	for my $entry (@{ $entries || [] }) {
		next if ref($entry) ne 'HASH' || ($entry->{role} || '') eq 'availability';
		my $kind = $entry->{kind} || '';
		next if $kind eq 'json_sequence';
		next if $kind eq 'json_autocreate'
			&& (!defined($entry->{json_key}) || ref($entry->{json_key}) || $entry->{json_key} eq '');
		next if $kind !~ /^(?:reading|json_reading|json_autocreate|device_automation_group)$/;
		my $name = $entry->{name};
		next if !defined($name) || ref($name) || $name eq '' || $name =~ /^\./;
		push @names, $name;
	}

	return [ sort(stable_unique(@names)) ];
}

# Legt optional fehlende, sicher angekuendigte Zielreadings mit leerem Wert an.
sub initialize_device_readings {
	my ($hash, $record, $names, $conflicts) = @_;
	my $enabled = gateway($hash)->attr_value(
		$hash->{NAME}, 'createReadings', 0,
	);
	return if !$enabled;
	my $target = $defs{ $record->{name} };
	return if !$target || ($target->{TYPE} || '') ne 'MQTT2_DEVICE';
	my %conflict = map { ($_ => 1) } @{ $conflicts || [] };
	my @created;

	# Vorhandene Readings behalten Wert und Zeitstempel; ebenso werden Namen
	# ausgelassen, bei denen eine manuelle readingList-Zeile Vorrang erhalten hat.
	for my $name (@{ $names || [] }) {
		next if $conflict{$name};
		next if ref($target->{READINGS}) eq 'HASH'
			&& exists($target->{READINGS}{$name});
		gateway($hash)->update_reading(
			$target, $name, '', 1,
		);
		push @created, $name;
	}

	log_message($hash, 4, 'initialized target readings='
		. join(',', @created) . "; target=$record->{name}") if @created;
	return;
}

# Entfernt nach erfolgreichem Listenplan alle sichtbaren Readings eines Zieldevices.
sub clear_device_readings {
	my ($hash, $record) = @_;
	my $target = $defs{ $record->{name} };
	return if !$target || ref($target->{READINGS}) ne 'HASH';
	my @readings = grep { $_ !~ /^\./ } sort keys %{ $target->{READINGS} };
	my ($deleted, $failed) = (0, 0);

	# Versteckte technische Readings bleiben erhalten; alle sichtbaren Werte sind explizit freigegeben.
	for my $reading (@readings) {
		my $error = gateway($hash)->delete_reading(
			$target, $reading,
		);

		# Einzelne FHEM-Fehler verhindern nicht die anschliessende Neuinitialisierung.
		if ($error) {
			++$failed;
			log_message(
				$hash, 2,
				"clearReadings failed for target=$record->{name}; reading=$reading; error=$error",
			);
			next;
		}
		++$deleted;
	}

	# Teilfehler bleiben sichtbar; der bereits erfolgreiche Attributplan bleibt gueltig.
	if ($failed) {
		my $message = "clearReadings konnte $failed von "
			. scalar(@readings) . " Readings an $record->{name} nicht loeschen";
		reading($hash, 'lastWarning', $message);
	}
	log_message(
		$hash, 3,
		"clearReadings completed for target=$record->{name}; deleted=$deleted failed=$failed",
	);
	return;
}

# Erstellt eine renderbare Kopie der Registry-Mappings fuer den aktuellen
# Reading-Modus und den global reservierten Availability-Namen.
sub prepare_device_mappings {
	my ($mappings, $availability_reading, $include_extra_json) = @_;
	my $json = JSON::PP->new;
	my $prepared = $json->decode($json->encode(
		ref($mappings) eq 'ARRAY' ? $mappings : [],
	));

	# Die Registry bleibt als vollstaendige Discovery-Quelle unveraendert, damit
	# ein spaeterer Attributwechsel daraus ohne erneuten Brokerabruf rendern kann.
	# Der gesamte Device-Satz wird einmal kopiert und gehoert danach der Renderpipeline.
	for my $mapping (@$prepared) {
		my @reading_lines;

		for my $entry (@{ $mapping->{reading_lines} || [] }) {
			if (($entry->{role} || '') eq 'availability') {
				$entry->{name} = $availability_reading;

				# Traegt die Verdichtung den Namen lwt, gehoert er ihr: Sie sagt
				# dasselbe wie die Quelle und dazu, ob FHEM den Broker hat. Die
				# Quelle bleibt dann versteckt, sonst stuende der Name zweimal.
				# Die Regel nennt ihre Quellen beim Namen; sie liegt nach dem
				# Kopieren je Eintrag vor und wird deshalb in jedem umgestellt.
				if ($availability_reading eq 'lwt') {
					$entry->{source_reading} = '.availability_lwt'
						if ($entry->{source_reading} // '') eq 'lwt';
					$_ = '.availability_lwt' for grep { $_ eq 'lwt' }
						@{ ref($entry->{policy}) eq 'HASH'
							? $entry->{policy}{sources} || [] : [] };
				}
				push @reading_lines, $entry;
				next;
			}

			# Im restriktiven Modus bleiben nur JSON-Felder mit einem durch Discovery
			# explizit bekannten Schluessel; offene Payload-Parser entfallen.
			if (!$include_extra_json && ($entry->{kind} || '') eq 'json_autocreate') {
				next if !defined($entry->{json_key}) || ref($entry->{json_key})
					|| $entry->{json_key} eq '';
				$entry->{kind} = 'json_reading';
			} elsif (!$include_extra_json && ($entry->{kind} || '') eq 'json_sequence') {
				next;
			}

			push @reading_lines, $entry;
		}

		$mapping->{reading_lines} = \@reading_lines;
	}

	return $prepared;
}

# Erkennt atomare Home-Assistant-Device-Discovery auch in aelteren Registry-Eintraegen.
sub is_device_discovery_mapping {
	my ($mapping) = @_;
	return 0 if ref($mapping) ne 'HASH';
	return 1 if ($mapping->{source_layout} || '') eq 'device';
	my $topic = $mapping->{discovery_topic};
	return defined($topic) && !ref($topic)
		&& $topic =~ m{(?:^|/)device/[^/]+/config\z} ? 1 : 0;
}

# Beschreibt nur die funktionalen MQTT-Bindings eines Mappings, nicht dessen Anzeigenamen.
sub mapping_function_signature {
	my ($mapping) = @_;
	return undef if ref($mapping) ne 'HASH';
	my @readings;
	my @sets;

	# Availability ist geraeteweit und darf eine sonst identische Funktion nicht unterscheiden.
	for my $entry (@{ $mapping->{reading_lines} || [] }) {
		next if ref($entry) ne 'HASH' || ($entry->{role} || '') eq 'availability';
		my %binding = map { exists($entry->{$_}) ? ($_ => $entry->{$_}) : () }
			qw(kind topic template payload json_key key_prefix parts unwrap_single_property);
		push @readings, \%binding;
	}

	# Set-Namen und Optionslisten duerfen sich bei einer Publisher-Migration aendern;
	# Topic, Operation und feste Payloadstruktur identifizieren die Funktion weiterhin.
	for my $entry (@{ $mapping->{set_lines} || [] }) {
		next if ref($entry) ne 'HASH';
		my %binding = map { exists($entry->{$_}) ? ($_ => $entry->{$_}) : () }
			qw(kind topic template payload key constants);
		push @sets, \%binding;
	}
	return undef if !@readings && !@sets;
	my $json = JSON::PP->new->canonical(1);
	my @reading_signatures = sort map { $json->encode($_) } @readings;
	my @set_signatures = sort map { $json->encode($_) } @sets;
	return $json->encode({
		component => $mapping->{metadata}{component} || '',
		readings => \@reading_signatures,
		sets => \@set_signatures,
	});
}

# Bevorzugt bei paralleler alter und neuer HA-Ankuendigung die atomare Device-Komponente.
sub prefer_device_discovery_mappings {
	my ($mappings) = @_;
	my @source = grep { ref($_) eq 'HASH' } @{ $mappings || [] };
	my %device_signatures;

	# Zuerst werden alle von Device-Discovery bereits vollstaendig beschriebenen Funktionen erfasst.
	for my $mapping (@source) {
		next if !is_device_discovery_mapping($mapping);
		my $signature = mapping_function_signature($mapping);
		$device_signatures{$signature} = 1 if defined($signature);
	}
	return \@source if !keys %device_signatures;
	my @preferred;

	# Klassische Einzel-Entities bleiben erhalten, sofern keine funktional gleiche
	# atomare Komponente fuer dasselbe Registry-Device vorliegt.
	for my $mapping (@source) {
		my $signature = mapping_function_signature($mapping);
		next if !is_device_discovery_mapping($mapping)
			&& defined($signature) && $device_signatures{$signature};
		push @preferred, $mapping;
	}
	return \@preferred;
}

# Rendert und setzt alle verwalteten Attribute eines Zieldevices als atomaren Plan.
# Ein Geraet mit genau einem schaltbaren Kanal folgt der FHEM-Konvention: Der
# Zustand gehoert nach state, geschaltet wird mit on und off. Damit schreibt auch
# MQTT2_DEVICE_Set beim Setzen denselben Wert, den die Rueckmeldung liefert.
# Schaltet die beim Mapping mitgefuehrte Wertabbildung scharf.
sub enable_boolean_maps {
	my ($readings) = @_;
	my $count = 0;

	for my $reading (@$readings) {
		next if ref($reading) ne 'HASH' || ref($reading->{boolean_map}) ne 'HASH';
		$reading->{value_map} = { %{ $reading->{boolean_map} } };

		# Mit Abbildung ist die kompakte json2nameValue-Form nicht mehr moeglich.
		# Der Quellschluessel bleibt vermerkt: Eine Sammelzeile desselben Topics
		# muss ihn weiterhin auf dieses Reading umbenennen koennen.
		if (($reading->{kind} // '') ne 'reading') {
			$reading->{kind} = 'reading';
			$reading->{json_source_key} = delete $reading->{json_key}
				if defined($reading->{json_key});
		}
		$count++;
	}

	return $count;
}

# Namen, die FHEM fuer eine bekannte Rolle vorsieht. Quellen: das Wiki
# DevelopmentGuidelinesReadings und der Forumsthread 117933.
our %FHEM_READING_NAMES = (
	target_temperature  => 'desired-temp',
	current_temperature => 'temperature',
	temperature_target  => 'desired-temp',
);

# Setzt die FHEM-Namenskonvention auf den bereits aufgeloesten Namen um: Erst
# faellt der Komponentenpraefix weg, wenn die Komponente nur einmal vorkommt,
# dann greifen die Namen fuer bekannte Rollen und die Batterieregeln. Umbenannt
# wird nur, wenn der Zielname im Geraet frei bleibt.
sub fhem_reading_names {
	my ($readings, $sets, $context, $reserved) = @_;
	my %taken = map { ($_ => 1) } keys %{ ref($reserved) eq 'HASH' ? $reserved : {} };
	$taken{ $_->{name} } = 1 for grep {
		ref($_) eq 'HASH' && defined($_->{name})
	} (@$readings, @$sets);
	my %wanted;

	for my $entry (@$readings, @$sets) {
		next if ref($entry) ne 'HASH' || !defined($entry->{name}) || $entry->{name} eq '';
		my $meta = $context->{ Scalar::Util::refaddr($entry) };
		next if ref($meta) ne 'HASH';
		my $candidate = $entry->{name};

		# Der Praefix ist der Blattname des Mappings, also die Komponente selbst
		# (thermostat_target_temperature, cct_0_ct).
		my $leaf = $meta->{leaf};
		$candidate = $1
			if defined($leaf) && $leaf ne '' && $candidate =~ /^\Q$leaf\E_(.+)\z/;
		$candidate = $FHEM_READING_NAMES{$candidate}
			if exists($FHEM_READING_NAMES{$candidate});
		my $battery = battery_reading($candidate, $meta);
		$candidate = $battery if defined($battery);
		next if $candidate eq $entry->{name};
		push @{ $wanted{$candidate} }, $entry;
	}

	my $renamed = 0;

	for my $candidate (sort keys %wanted) {
		my $entries = $wanted{$candidate};

		# Ein Reading und der zugehoerige Setter duerfen denselben Namen tragen
		# (desired-temp); zwei Readings duerfen es nicht, und ein Name, den ein
		# anderes Reading des Geraets schon fuehrt, bleibt tabu.
		my %by_group;
		push @{ $by_group{ entry_group($_) } }, $_ for @$entries;
		next if $taken{$candidate} || grep { @{ $by_group{$_} } != 1 } keys %by_group;

		for my $entry (@$entries) {
			delete $taken{ $entry->{name} };
			$entry->{semantic_name} = $entry->{name} if !defined($entry->{semantic_name});
			$entry->{name} = $candidate;

			# batteryState meldet nach FHEM ok oder low, nicht on oder off.
			if ($candidate eq 'batteryState' && ref($entry->{value_map}) eq 'HASH') {
				my %map = %{ $entry->{value_map} };
				$map{$_} = { on => 'low', off => 'ok' }->{ $map{$_} } // $map{$_} for keys %map;
				$entry->{value_map} = \%map;
			}
			$renamed++;
		}
		$taken{$candidate} = 1;
	}

	return $renamed;
}

# Macht Reading-Eintraege in ParseFn auswertbar: Ohne Template schreibt eine
# Zeile den ganzen Payload, das leistet die Identitaet genauso; ein einzelnes
# JSON-Feld bekommt sein Template. Beides erzeugt beim Rendern eine
# Laufzeitreferenz, die ParseFn spaeter aufloesen kann.
sub runtime_readable {
	my ($entries) = @_;
	my $changed = 0;

	for my $entry (@{ $entries || [] }) {
		next if ref($entry) ne 'HASH';
		my $kind = $entry->{kind} // '';

		# Ein einzelnes JSON-Feld traegt sein Template weiterhin bei sich; der
		# json_key ist nur der verkuerzte Readingname und kein JSON-Pfad.
		if ($kind eq 'json_reading'
				&& defined($entry->{template}) && $entry->{template} ne '') {
			$entry->{kind} = 'reading';
			$entry->{json_source_key} = delete $entry->{json_key}
				if defined($entry->{json_key});
			$changed++;
			next;
		}
		next if $kind ne 'reading' || exists($entry->{items});
		next if defined($entry->{template}) && $entry->{template} ne '';
		$entry->{template} = '{{ value }}';
		$changed++;
	}

	return $changed;
}

# Unterscheidet die beiden Namensraeume eines Geraets: Readings und Befehle.
sub entry_group {
	my ($entry) = @_;
	return ($entry->{kind} // '') =~ /^(?:button|choice|slider|textfield|colorpicker)\z/
		|| defined($entry->{spec}) ? 'set' : 'reading';
}

# Die drei Batterienamen der Richtlinie unterscheiden sich nur in Einheit und
# Art der Quelle.
sub battery_reading {
	my ($candidate, $meta) = @_;
	my $class = $meta->{device_class} // '';
	my $unit = $meta->{unit} // '';
	return 'batteryVoltage' if $candidate =~ /^battery_?voltage\z/i;
	return undef if $class ne 'battery';
	return 'batteryState' if ($meta->{component} // '') eq 'binary_sensor';
	return 'batteryVoltage' if $unit =~ /^m?V\z/;
	return 'batteryPercent' if $unit eq '%' || $unit eq '';
	return undef;
}

sub single_channel_state {
	my ($readings, $sets) = @_;
	my @switches = grep {
		ref($_) eq 'HASH' && $_->{primary_switch}
			&& ($_->{kind} // '') eq 'choice' && ($_->{spec} // '') eq 'on,off'
			&& ref($_->{mapping}) eq 'HASH'
			&& defined($_->{mapping}{on}) && defined($_->{mapping}{off})
	} @$sets;
	return 0 if @switches != 1;
	my $switch = $switches[0];
	my $switch_name = $switch->{name};
	return 0 if !defined($switch_name) || $switch_name eq '' || $switch_name eq 'state';

	# Ein bereits vergebenes state bleibt unangetastet, ebenso ein vorhandener
	# Befehl on oder off eines anderen Kanals.
	return 0 if grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'state' } @$readings;
	return 0 if grep {
		ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} =~ /^(?:on|off)$/
	} @$sets;
	my $renamed = 0;

	for my $reading (@$readings) {
		next if ref($reading) ne 'HASH' || ($reading->{name} // '') ne $switch_name;
		$reading->{semantic_name} = $switch_name if !defined($reading->{semantic_name});
		$reading->{name} = 'state';
		$renamed++;
	}
	return 0 if !$renamed;

	# Aus der Auswahl werden die beiden einzelnen Befehle mit festem Payload.
	@$sets = grep { $_ != $switch } @$sets;
	push @$sets, {
		kind => 'button', name => $_, spec => 'noArg',
		topic => $switch->{topic}, payload => $switch->{mapping}{$_},
	} for qw(on off);
	return 1;
}

sub apply_device_lines {
	my ($hash, $record, $options) = @_;
	$options = {} if ref($options) ne 'HASH';
	my $rebuild_lists = $options->{rebuild_lists} ? 1 : 0;
	my $name = $record->{name};

	# Ein von Hand geloeschtes Zieldevice darf die Erkennung nicht dauerhaft
	# blockieren: Der verwaiste Datensatz wird verworfen, die naechste Erkennung
	# legt Device und Datensatz neu an.
	if (!$defs{$name}) {
		my $registry = registry($hash);

		for my $identity (keys %{ $registry->{devices} || {} }) {
			next if ($registry->{devices}{$identity} // 0) != $record;
			delete $registry->{devices}{$identity};
		}

		persist_registry($hash);
		log_message($hash, 2, "verwaisten Registry-Eintrag fuer $name verworfen");
		return undef;
	}

	# Erst jetzt steht fest, dass das Zieldevice existiert: Das Geraeteattribut
	# wird mit dieser Instanz als Pruefinstanz angemeldet.
	announce_device_keys($hash, $name);
	register_set_extensions();
	my %previous_availability_topics = map { ($_ => 1) }
		grep { defined($_) && !ref($_) && $_ ne '' }
		@{ $record->{availability_topics} || [] };
	# Der Name der Verdichtung haengt von der Art der Quellen ab und steht
	# deshalb erst fest, wenn die Mappings des Geraets vorliegen.
	my @availability_entries = grep {
		ref($_) eq 'HASH' && ($_->{role} // '') eq 'availability'
	} map { @{ $_->{reading_lines} || [] } } values %{ $record->{entities} || {} };
	my $availability_reading = availability_reading($hash, $record, \@availability_entries);
	my $previous_availability_reading = $record->{availability_reading} // 'availability';

	# Die Quellreadings der bisherigen Kette werden vor dem Rendern festgehalten.
	# Faellt die Kette weg, blieben sie sonst mit ihrem letzten Wert stehen.
	my $previous_availability_names = availability_reading_names($record->{runtime_refs});

	# Dasselbe gilt fuer einfache Zeilen: Wird aus dem rohen Reading eines Topics
	# spaeter eine Quelle unter anderem Namen, bliebe der alte Name stehen.
	my $previous_plain_names = plain_reading_names($record->{owned_reading});
	my $previous_availability_owned = exists($record->{owned_availability_reading})
		? $record->{owned_availability_reading} eq $previous_availability_reading
		: !exists($record->{availability_reading})
			&& $previous_availability_reading eq 'availability';
	my $include_extra_json = gateway($hash)->attr_value(
		$hash->{NAME}, 'extraJsonReadings', 'include',
	) eq 'include';

	# Namen werden ueber alle Entities des Devices gemeinsam aufgeloest, bevor
	# eine einzige readingList- oder setList-Zeile gerendert wird.
	my $reserved_readings = { $availability_reading => 1 };
	my $all_mappings = [
		map { $record->{entities}{$_} } sort keys %{ $record->{entities} }
	];
	my $preferred_mappings = prefer_device_discovery_mappings(
		$all_mappings,
	);
	log_message($hash, 3, 'suppressed equivalent legacy mappings='
		. (scalar(@$all_mappings) - scalar(@$preferred_mappings)) . "; target=$name")
		if @$preferred_mappings < @$all_mappings;
	my $prepared_mappings = prepare_device_mappings(
		$preferred_mappings, $availability_reading, $include_extra_json,
	);
	my $resolved_mappings = MQTT2_Discovery::Mapper::resolve_owned_mapping_names(
		$prepared_mappings, $reserved_readings,
	);
	$resolved_mappings = MQTT2_Discovery::Mapper::collapse_device_automation_readings(
		$resolved_mappings, $reserved_readings,
	);
	my %resolved_by_key = map { (($_->{entity_key} // '') => $_) } @$resolved_mappings;
	my (@reading_entries, @set_entries, %entry_context);
	my %runtime_references;

	for my $mapping (@$resolved_mappings) {
		push @reading_entries, @{ $mapping->{reading_lines} || [] };
		push @set_entries, @{ $mapping->{set_lines} || [] };

		# Einheit, Geraeteklasse und Blattname des Mappings gehoeren zum Eintrag,
		# stehen aber nur hier zur Verfuegung.
		my $meta = {
			leaf => $mapping->{reading_name},
			unit => $mapping->{metadata}{unit},
			device_class => $mapping->{metadata}{device_class},
			component => $mapping->{metadata}{component},
		};
		$entry_context{ Scalar::Util::refaddr($_) } = $meta
			for grep { ref($_) eq 'HASH' }
				(@{ $mapping->{reading_lines} || [] }, @{ $mapping->{set_lines} || [] });
	}

	# none laesst die Availability-Kette ganz weg: kein Quellreading, keine
	# Regel, keine Verdichtung. source behaelt die Quellen und laesst nur die
	# Verdichtung aus, das entscheidet der Readingname weiter unten.
	if (key($hash, $record, 'reachability') eq 'none') {
		@reading_entries = grep {
			ref($_) ne 'HASH' || ($_->{kind} // '') ne 'availability'
		} @reading_entries;
	}

	# Die Konventionen aendern bestehende Readingnamen und -werte und sind deshalb
	# abschaltbar; ohne das Attribut bleibt alles wie bisher.
	my $fhem_conventions = key($hash, $record, 'style') eq 'fhem' ? 1 : 0;
	if ($fhem_conventions) {
		enable_boolean_maps(\@reading_entries);
		fhem_reading_names(
			\@reading_entries, \@set_entries, \%entry_context, $reserved_readings,
		);
		my $renamed = single_channel_state(\@reading_entries, \@set_entries);

		# Der alte Readingname wird nicht mehr beschrieben und bliebe sonst mit
		# seinem letzten Wert sichtbar stehen.
		if ($renamed && ref($defs{$name}{READINGS}) eq 'HASH') {

			for my $reading (@reading_entries) {
				next if ref($reading) ne 'HASH' || ($reading->{semantic_name} // '') eq '';
				my $old = $reading->{semantic_name};
				next if $old eq ($reading->{name} // '') || !exists($defs{$name}{READINGS}{$old});
				gateway($hash)->delete_reading($defs{$name}, $old);
			}

		}
	}
	# Im Dialog abgewaehlte Readings entstehen gar nicht erst, weder als eigene
	# Zeile noch in den Sammelzeilen fuer die Abfrageantwort und die Ereignisse.
	# Der Schluessel hide nennt dieselben Namen wie das Attribut ignoreEntities;
	# beide Wege ergaenzen sich.
	my %ignored_entities = map { ($_ => 1) } (
		ignored_entities($hash, $record),
		grep { $_ ne '' } split(/\s*,\s*/, key($hash, $record, 'hide')),
	);

	# Die Kanalschluessel verschwinden nur aus den Sammelzeilen, nicht als
	# Eintrag: Das eigene skalare Topic tragt denselben Namen und ist die Quelle
	# des Zustands.
	my %hidden_json = (%ignored_entities,
		%{ channel_json_keys($hash, $record, $options->{registry}) });
	if (%hidden_json) {

		# Ohne abgeschaltetes Autocreate haengt MQTT2_DEVICE die abgewaehlten Topics
		# beim naechsten Eintreffen selbst wieder an; das gilt auch nach einer Neuanlage.
		CommandAttr(undef, "$name autocreate 0")
			if AttrVal($name, 'autocreate', '') ne '0';
		@reading_entries = grep {
			ref($_) ne 'HASH' || !$ignored_entities{ $_->{name} // '' }
		} @reading_entries;
		@set_entries = grep {
			ref($_) ne 'HASH' || !$ignored_entities{ $_->{name} // '' }
		} @set_entries;
	}
	my @availability_topics = sort stable_unique(map { $_->{topic} }
		grep {
			ref($_) eq 'HASH' && ($_->{role} || '') eq 'availability'
				&& defined($_->{topic}) && !ref($_->{topic}) && $_->{topic} ne ''
		} @reading_entries);

	my @all_entries = (@reading_entries, @set_entries);
	my $generated_device_topic = MQTT2_Discovery::DevicePlanner::device_topic($record, \@all_entries);
	my @device_topic_entries = grep {
		ref($_) eq 'HASH' && ($_->{role} // '') ne 'availability' && defined($_->{topic})
			&& $_->{topic} !~ m{^mqtt2_discovery/}
	} @all_entries;
	my $old_device_topic_exists = exists($attr{$name}) && exists($attr{$name}{devicetopic});
	my $old_device_topic = $old_device_topic_exists ? $attr{$name}{devicetopic} : undef;
	my $previous_owned_device_topic = $record->{owned_devicetopic};
	my $render_device_topic;
	my $manage_device_topic = 0;

	# Ein manuell geaendertes devicetopic bleibt erhalten, sofern alle erzeugten
	# Topics weiterhin darunter liegen. Nur eigene Werte werden automatisch ersetzt.
	if ($record->{created}) {

		# Fehlende oder weiterhin von Discovery besessene Werte duerfen dem neu
		# berechneten gemeinsamen Topic-Prefix folgen; manuelle Werte bleiben erhalten.
		if (!$old_device_topic_exists
				|| (defined($previous_owned_device_topic) && $old_device_topic eq $previous_owned_device_topic)) {
			$render_device_topic = $generated_device_topic;
			$manage_device_topic = 1;
		} elsif (defined($old_device_topic)
				&& !grep { !MQTT2_Discovery::DevicePlanner::topic_has_prefix($_->{topic}, $old_device_topic) }
					@device_topic_entries) {
			$render_device_topic = $old_device_topic;
		}
	} elsif ($old_device_topic_exists
			&& !grep { !MQTT2_Discovery::DevicePlanner::topic_has_prefix($_->{topic}, $old_device_topic) }
				@device_topic_entries) {
		$render_device_topic = $old_device_topic;
	}

	# Der explizite Neuaufbau normalisiert devicetopic gemeinsam mit den vollstaendig
	# ersetzten Listen, damit alle drei Attribute denselben Discovery-Stand abbilden.
	if ($rebuild_lists) {
		$manage_device_topic = 1;
		$render_device_topic = $generated_device_topic;
	}
	my $mode = gateway($hash)->attr_value(
		$hash->{NAME}, 'existingDevice', 'conservative',
	);
	my $effective_mode = $rebuild_lists ? 'replace' : $mode;
	my $old_reading = gateway($hash)->attr_value($name, 'readingList', '');
	my $old_set = gateway($hash)->attr_value($name, 'setList', '');
	my $merge_reading = $rebuild_lists ? '' : $old_reading;
	my $merge_set = $rebuild_lists ? '' : $old_set;
	my $previous_owned_reading = $rebuild_lists ? [] : $record->{owned_reading};
	my $previous_owned_set = $rebuild_lists ? [] : $record->{owned_set};
	my $matching_device_topic = defined($render_device_topic) && $render_device_topic ne ''
		? $render_device_topic
		: $old_device_topic_exists && defined($old_device_topic) && $old_device_topic ne ''
			? $old_device_topic : $name;
	my @json_conflicts;

	# Konflikte werden vor dem Gruppieren der JSON-Readings bestimmt; danach
	# verschmelzen manuelle und generierte Zeilen nach dem gewaehlten Modus.
	my ($prepared_readings, $prepared_old_reading) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
		$effective_mode, $merge_reading, $previous_owned_reading, \@reading_entries, \@json_conflicts,
		$matching_device_topic, $record->{cid},
	);
	# Mit readings=parse wertet ParseFn die Zeilen ueber ihre Laufzeitreferenz
	# aus. Eine Zeile ohne Template hat keine, wuerde also verloren gehen; die
	# Identitaet leistet dasselbe wie die kurze Form und ist auswertbar.
	runtime_readable($prepared_readings)
		if key($hash, $record, 'readings') eq 'parse';
	my $initial_reading_names = expected_reading_names($prepared_readings);
	# Das IODev wandelt ':' in empfangenen Topics zu '_'. Die erzeugten
	# readingList-Zeilen muessen denselben Namen treffen.
	local $MQTT2_Discovery::Mapper::Renderer::TOPIC_CONVERSION =
		gateway($hash)->attr_value(
			$hash->{IODevName} // '', 'topicConversion', 1,
		) ? 1 : 0;
	local $MQTT2_Discovery::Mapper::Renderer::AVAILABILITY_VISIBLE =
		availability_reading($hash, $record) ne '' ? 1 : 0;

	# Abgewaehlte Felder einer Sammelzeile lassen sich nicht als Eintrag
	# weglassen; sie werden in der Umbenennungsliste auf den leeren String
	# abgebildet und damit verworfen.
	# Abgewaehlt ist der sichtbare Name. Ein eigenes jsonMap am Zielgeraet kann
	# ihn jederzeit aendern, deshalb wird zusaetzlich beim Auswerten gefiltert;
	# hier faellt nur weg, was ohne Umbenennung schon am Schluessel erkennbar ist.
	local $MQTT2_Discovery::Mapper::Renderer::HIDDEN_JSON_KEYS = \%hidden_json;
	@reading_entries = @{ MQTT2_Discovery::Mapper::render_entries(
		$prepared_readings, $render_device_topic, $reserved_readings, \%runtime_references,
	) };

	# Mit sets=hook entsteht kein setList-Attribut mehr: Die Befehle liegen
	# strukturiert in der Registry und werden ueber den Hook angeboten und
	# ausgefuehrt. Nicht unterstuetzte Befehlsarten bleiben im Attribut.
	my $via_hook = key($hash, $record, 'sets') eq 'hook'
		&& !grep {
			ref($_) ne 'HASH' || ($_->{kind} // '') !~ /^(?:button|choice)$/
		} @set_entries;
	if ($via_hook) {
		$record->{hook_sets} = [ map { {
			name => $_->{name}, spec => $_->{spec}, kind => $_->{kind}, topic => $_->{topic},
			(defined($_->{payload}) ? (payload => $_->{payload}) : ()),
			(ref($_->{mapping}) eq 'HASH' ? (mapping => { %{ $_->{mapping} } }) : ()),
		} } @set_entries ];
		@set_entries = ();
	} else {
		delete $record->{hook_sets};
	}
	@set_entries = @{ MQTT2_Discovery::Mapper::render_entries(
		\@set_entries, $render_device_topic, undef, \%runtime_references,
	) };

	# Mit readings=parse entsteht kein readingList-Attribut mehr: Die erzeugten
	# Zeilen werden in Regexp und Runtime-Referenz zerlegt und in der Registry
	# abgelegt; ausgewertet wird spaeter in ParseFn. Manuelle Zeilen des Anwenders
	# bleiben im Attribut und arbeiten unveraendert weiter.
	if (key($hash, $record, 'readings') eq 'parse') {
		my (@parsed, @kept);

		for my $entry (@reading_entries) {
			my $line = ref($entry) eq 'HASH' ? $entry->{line} : $entry;
			next if !defined($line) || $line eq '';
			my ($regexp, $reference) = $line =~ /^(\S+):\.\*\s+\{[^}]*'(r_[a-f0-9]+)'/;

			# Eine Sammelzeile hat keine feste Feldliste und damit keine
			# Laufzeitreferenz. Sie laesst sich trotzdem uebernehmen, weil der
			# Renderer Namensraum und Umbenennungsliste strukturiert mitgibt und
			# die Auswertung die eigene Funktion des Moduls ist.
			if (!defined($reference) && ref($entry) eq 'HASH'
					&& ref($entry->{json_readings}) eq 'HASH') {
				my ($topic) = $line =~ /^(\S+):\.\*\s+\{/;

				if (defined($topic)) {
					$topic =~ s/\$DEVICETOPIC/$render_device_topic/g
						if defined($render_device_topic) && $render_device_topic ne '';
					push @parsed, { regexp => "$topic:.*",
						json => { %{ $entry->{json_readings} } } };
					next;
				}
			}

			# Was sich weder in Muster und Referenz zerlegen noch als Sammelzeile
			# uebernehmen laesst, etwa die Sequenzzeile mit vorgeschaltetem
			# Auspacken, bleibt im Attribut. Stillschweigend weglassen hiesse:
			# Das Reading kommt nie wieder.
			if (!defined($regexp) || !defined($reference)) {
				push @kept, $entry;
				next;
			}

			# Der Geraetestamm wird gleich aufgeloest. Ohne readingList-Attribut
			# braucht das Zielgeraet dann kein devicetopic mehr, und die gespeicherten
			# Muster haengen nicht an einem Attribut, das jemand aendern kann.
			$regexp =~ s/\$DEVICETOPIC/$render_device_topic/g
				if defined($render_device_topic) && $render_device_topic ne '';

			# Das eigene Antworttopic wird nicht gespeichert, sondern beim Auswerten
			# aus dem aktuellen Namen dieser Instanz und dem Geraeteschluessel
			# zusammengesetzt. So uebersteht es ein rename des Discovery-Devices.
			if ($regexp =~ m{^mqtt2_discovery/[^/]+/shelly/([a-f0-9]{16})/state/rpc$}) {
				$record->{reply_key} = $1;
				$record->{reply_reference} = $reference;
				next;
			}
			push @parsed, { regexp => "$regexp:.*", reference => $reference };
		}

		$record->{parse_readings} = \@parsed;
		@reading_entries = @kept;
	} else {
		delete $record->{parse_readings};
	}
	update_match();
	my $reading = merge_generated_lines(
		kind => 'reading', mode => $effective_mode, current => $prepared_old_reading,
		previous_owned => $previous_owned_reading, generated => \@reading_entries,
	);
	my $set = merge_generated_lines(
		kind => 'set', mode => $effective_mode, current => $merge_set,
		previous_owned => $previous_owned_set, generated => \@set_entries,
	);
	# Ohne erzeugte readingList und setList braucht das Zielgeraet keinen
	# Topic-Stamm mehr; ein vorhandenes devicetopic bleibt unangetastet, falls
	# manuelle Zeilen es verwenden.
	$manage_device_topic = 0
		if $reading->{value} eq '' && $set->{value} eq ''
			&& !exists($attr{$name}{devicetopic});
	my $plan = MQTT2_Discovery::DevicePlanner::attribute_plan(
		device => $name,
		manage_device_topic => $manage_device_topic,
		device_topic => $generated_device_topic,
		previous_device_topic_exists => $old_device_topic_exists,
		previous_device_topic => $old_device_topic,
		reading_list => $reading->{value},
		previous_reading_list_exists => (exists($attr{$name}) && exists($attr{$name}{readingList})),
		previous_reading_list => $old_reading,
		set_list => $set->{value},
		previous_set_list_exists => (exists($attr{$name}) && exists($attr{$name}{setList})),
		previous_set_list => $old_set,
	);

	# Alle Attribute werden mit Rollback als eine logische Einheit angewendet.
	my $error = $plan->execute(gateway($hash));
	return $error if $error;

	# Erst nach dem atomaren Attributplan wird die passende Referenztabelle aktiv;
	# bei einem Rollback bleiben damit Attribute und Runtime-Daten synchron.
	$record->{runtime_refs} = { %runtime_references };
	$defs{$name}{helper}{mqtt2_discovery_runtime_refs} = $record->{runtime_refs};
	$defs{$name}{helper}{mqtt2_discovery_availability_reading} = $availability_reading;
	$defs{$name}{helper}{mqtt2_discovery_hidden_readings} = { %hidden_json };
	$defs{$name}{helper}{mqtt2_discovery_json_map} = {
		%{ ref($defs{$name}{JSONMAP}) eq 'HASH' ? $defs{$name}{JSONMAP} : {} }
	};
	clear_device_readings($hash, $record)
		if $rebuild_lists && $options->{clear_readings};
	initialize_device_readings(
		$hash, $record, $initial_reading_names, $reading->{conflicts},
	);
	$record->{owned_reading} = $reading->{owned};
	$record->{owned_set} = $set->{owned};
	$record->{owned_devicetopic} = $manage_device_topic ? $generated_device_topic : undef;
	$record->{availability_topics} = \@availability_topics;
	$record->{availability_reading} = $availability_reading;
	$record->{owned_availability_reading} = $availability_reading;
	$record->{reachability} = key($hash, $record, 'reachability');
	apply_device_semantics($hash, $record, \%resolved_by_key);
	my @conflicts = (@json_conflicts, @{ $reading->{conflicts} }, @{ $set->{conflicts} });

	# Manuell gewonnene Konflikte sind kein Apply-Fehler, muessen aber sichtbar
	# machen, welche generierten readingList- oder setList-Anteile nicht uebernommen wurden.
	if (@conflicts) {
		my $conflicts = join(',', stable_unique(@conflicts));
		reading($hash, 'conflicts', $conflicts);
		log_message($hash, 2, "manual configuration wins for target=$name; conflicts=$conflicts");
	}
	log_message($hash, 4, "attributes updated for target=$name; readingLines="
		. scalar(@{ $reading->{owned} }) . '; setLines=' . scalar(@{ $set->{owned} }));
	my $io_available = defined($hash->{helper}{io_available})
		? $hash->{helper}{io_available}
		: iodev_available($hash);
	sync_target_availability($hash, $record, $io_available);

	# Beim Umbenennen wird nur der zuvor nachweislich modulverwaltete Name
	# entfernt; eine explizit manuell verbliebene readingList-Belegung bleibt erhalten.
	if ($previous_availability_reading ne $availability_reading
			&& $previous_availability_owned
			&& ref($defs{$name}{READINGS}) eq 'HASH'
			&& exists($defs{$name}{READINGS}{$previous_availability_reading})
			&& !record_has_manual_reading(
				$hash, $record, $previous_availability_reading,
			)) {
		my $delete_error = gateway($hash)->delete_reading(
			$defs{$name}, $previous_availability_reading,
		);
		log_message($hash, 2, "old availability reading removal failed for target=$name; reading=$previous_availability_reading; error=$delete_error")
			if $delete_error;
	}

	# Dasselbe gilt fuer die Quellen und Regeln der Kette. Mit availability=none
	# entfaellt die Kette ganz; ohne das Aufraeumen behielte jede Quelle ihren
	# letzten Wert und das Geraet meldete eine Erreichbarkeit, die niemand mehr
	# fortschreibt.
	my $current_availability_names = availability_reading_names($record->{runtime_refs});

	# Der IO-Zustand wird nicht aus einem Deskriptor gespeist, sondern beim
	# Abgleich geschrieben. Mit none schreibt ihn niemand mehr fort, also gehoert
	# er zu den aufzuraeumenden Readings.
	$previous_availability_names->{'.availability_io'} = 1
		if key($hash, $record, 'reachability') eq 'none';

	# Ein Name, den vorher eine einfache Zeile trug und den jetzt nichts mehr
	# erzeugt, gehoert ebenfalls aufgeraeumt.
	my $generated = generated_reading_names($record, $record->{owned_reading});
	$previous_availability_names->{$_} = 1
		for grep { !$generated->{$_} } keys %$previous_plain_names;

	# Ein abgewaehltes Feld entsteht nicht mehr; sein letzter Wert soll nicht
	# stehen bleiben, als kaeme er weiterhin vom Geraet.
	$previous_availability_names->{$_} = 1 for keys %ignored_entities;

	for my $reading (sort keys %$previous_availability_names) {
		next if $current_availability_names->{$reading} || $generated->{$reading};
		next if ref($defs{$name}{READINGS}) ne 'HASH'
			|| !exists($defs{$name}{READINGS}{$reading});
		next if record_has_manual_reading($hash, $record, $reading);
		my $delete_error = gateway($hash)->delete_reading($defs{$name}, $reading);
		log_message($hash, 2, "old availability source removal failed for target=$name; reading=$reading; error=$delete_error")
			if $delete_error;
	}

	# Erst nach erfolgreichem Attributplan und initialem leerem Reading wird fuer
	# jedes neu hinzugekommene Availability-Topic genau ein Abruf vorgemerkt.
	for my $topic (@availability_topics) {
		schedule_availability_refresh($hash, $topic)
			if !$previous_availability_topics{$topic};
	}

	return undef;
}

# Komponiert und hinterlegt semantische Metadaten fuer automatisch erzeugte Devices.
sub apply_device_semantics {
	my ($hash, $record, $resolved) = @_;

	# Uebernommene Bestandsdevices erhalten keine automatisch erzeugten
	# semantischen Metadaten; ihre bestehende Beschreibung bleibt unangetastet.
	return if !$record->{created};
	my $name = $record->{name};
	return if !$defs{$name};
	my @items;
	my %id_count;

	for my $entity_key (sort keys %{ $record->{entities} || {} }) {
		my $mapping = ref($resolved) eq 'HASH' && $resolved->{$entity_key}
			? $resolved->{$entity_key} : $record->{entities}{$entity_key};
		my $source = $mapping->{semantic_entity};
		next if ref($source) ne 'HASH';
		my $entry = JSON::PP->new->decode(JSON::PP->new->canonical(1)->encode($source));
		push @items, {
			entity_key => $entity_key,
			entry => $entry,
			mapping => $mapping,
		};
	}

	my $composed = MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@items);
	my @entries = map { [$_->{entity_key}, $_->{entry}] } @$composed;
	++$id_count{ $_->[1]{id} // 'entity' } for @entries;

	# Erst nach Device-Komposition werden verbleibende Entity-ID-Kollisionen
	# stabil aufgeloest.
	for my $item (@entries) {
		my ($entity_key, $entry) = @$item;
		my $id = $entry->{id} // 'entity';
		$entry->{id} = $id . '_' . stable_suffix($entity_key, 6) if $id_count{$id} > 1;
	}

	# Vorhandene semantische Entities werden als gemeinsamer Device-Vertrag gesetzt;
	# ohne Entities muss ein frueherer Vertrag explizit entfernt werden.
	if (@entries) {
		gateway($hash)->set_semantic_metadata($name, {
			confidence => 0.95,
			entities => [ map { $_->[1] } @entries ],
		});
	} else {
		gateway($hash)->set_semantic_metadata($name, undef);
	}
	my $integration_ended = eval {
		gateway($hash)->semantic_integration_end($name);
	} || 0;
	log_message($hash, 2, "semantic integration end failed for target=$name") if $@;
	publish_semantic_update($hash, $name) if !$integration_ended;
	log_message($hash, 4, "semantic metadata updated for target=$name; entities=" . scalar(@entries));
	return;
}

# Erzeugt aus der aktuellen Beschreibung ein semantisches Upsert- oder Remove-Ereignis.
sub publish_semantic_update {
	my ($hash, $name) = @_;
	my $gateway = gateway($hash);
	return if !$gateway->can_publish_semantics();
	my $definition = eval { $gateway->semantic_description($name) };

	# Ohne gueltige Beschreibung kann kein wohldefiniertes Upsert- oder Remove-
	# Ereignis erzeugt werden; ein Broadcast wuerde nur unvollstaendige Daten verteilen.
	if ($@ || ref($definition) ne 'HASH') {
		log_message($hash, 2, "semantic update failed for target=$name");
		return;
	}
	my $event = $definition->{visible}
		? { type => 'device_upsert', device => $definition }
		: { type => 'device_remove', device => $name };
	eval { $gateway->semantic_broadcast($event) };
	log_message($hash, 2, "semantic broadcast failed for target=$name") if $@;
	return;
}

# Entfernt passende Entities aus der Registry und rendert betroffene Devices neu.
sub delete_entity {
	my ($hash, $registry, $entity, $batch) = @_;

	for my $identity (sort keys %{ $registry->{devices} }) {
		my $record = $registry->{devices}{$identity};
		my @delete = grep {
			my $mapping = $record->{entities}{$_};
			$mapping->{discovery_topic} eq $entity->{discovery_topic}
				&& ($entity->{operation} eq 'delete_device' || $_ eq $entity->{entity_key});
		} keys %{ $record->{entities} };
		next if !@delete;

		# Der manuelle Zustand wird vor dem Entfernen/Neurendern erfasst, damit
		# autoDelete ein ehemals angepasstes Device nicht versehentlich loescht.
		my $hadManual = record_has_manual_lines($hash, $record);
		delete $record->{entities}{$_} for @delete;
		my $extensions = ref($entity->{_canonical_extensions}) eq 'HASH'
			? $entity->{_canonical_extensions} : {};

		# Der Tasmota-Parser ersetzt sein zusammengesetztes Geraetemodell intern.
		# Nur externe Discovery-Loeschungen gehoeren in das sichtbare Level-2-Log.
		if ($extensions->{internal_rebuild}) {
			log_message($hash, 4, 'temporarily removed ' . scalar(@delete)
				. " discovery entity/entities from $record->{name} during internal rebuild");
		} else {
			log_message($hash, 2, 'removed ' . scalar(@delete)
				. " discovery entity/entities from $record->{name}");
		}

		# Innerhalb eines Batchs wird das betroffene Device erst nach allen Deletes
		# neu gerendert; der vorherige manuelle Zustand bleibt fuer autoDelete erhalten.
		if ($batch) {
			$batch->{pending_identities}{$identity} = 1;
			$batch->{delete_had_manual}{$identity} = $hadManual
				if !exists $batch->{delete_had_manual}{$identity};
			next;
		}
		my $error = apply_device_lines($hash, $record);
		return $error if $error;
		$error = MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
		return $error if $error;
	}

	return undef;
}

# Erkennt konservativ, ob ein verwaltetes Device noch benutzereigene Konfiguration enthaelt.
sub record_has_manual_lines {
	my ($hash, $record) = @_;
	my $name = $record->{name};
	return 1 if !$defs{$name};

	# Ein abweichendes oder nicht als eigenerzeugt vermerktes devicetopic ist eine
	# manuelle Anpassung und sperrt das automatische Entfernen des ganzen Devices.
	if (exists($attr{$name}) && exists($attr{$name}{devicetopic})) {
		return 1 if !defined($record->{owned_devicetopic})
			|| $attr{$name}{devicetopic} ne $record->{owned_devicetopic};
	}

	for my $attribute (['readingList', 'owned_reading'], ['setList', 'owned_set']) {

		# Alles, was nicht exakt in der Registry als eigenerzeugt vermerkt ist,
		# gilt konservativ als manuelle Benutzerkonfiguration.
		my %owned = map { $_ => 1 } @{ $record->{ $attribute->[1] } || [] };
		my @current = grep { $_ ne '' } split /\r?\n/,
			gateway($hash)->attr_value($name, $attribute->[0], '');
		return 1 if grep { !$owned{$_} } @current;
	}

	return 0;
}

# Berechnet und schreibt die Anzahl aktiver Registry-Devices und Entities.
sub update_counts {
	my ($hash) = @_;
	my $registry = registry($hash);
	my ($devices, $entities) = (0, 0);

	for my $record (values %{ $registry->{devices} }) {
		my $count = scalar keys %{ $record->{entities} || {} };
		++$devices if $count;
		$entities += $count;
	}

	reading($hash, 'discoveredDevices', $devices);
	reading($hash, 'discoveredEntities', $entities);
	log_message($hash, 4, "counts updated; devices=$devices; entities=$entities");
	return;
}

# Schreibt ein Modulreading ueber das Gateway mit normalisiertem undef-Wert.
sub reading {
	my ($hash, $name, $value) = @_;
	gateway($hash)->update_reading(
		$hash, $name, defined($value) ? $value : '', 1,
	);
	return;
}

# Entfernt den Set-Kommandonamen und liefert nur den vom Benutzer uebergebenen Wert.
sub MQTT2_Discovery_commandValue {
	my ($event) = @_;
	$event = '' if !defined $event;
	$event =~ s/^\S+\s*//;
	return $event;
}

# Baut den sicheren Home-Assistant-Kontext fuer MQTT-Device-Trigger auf.
sub triggerVars {
	my ($event) = @_;
	$event = '' if !defined $event;
	my ($decoded, $has_json);
	$has_json = eval { $decoded = JSON::PP::decode_json($event); 1 } ? 1 : 0;
	my %trigger = (
		payload => $event,
		value   => $has_json ? $decoded : $event,
	);

	# JSON-Trigger erhalten dieselben strukturierten Aliase, die HA-Templates
	# fuer value_json und payload_json bereitstellen.
	if ($has_json) {
		$trigger{value_json} = $decoded;
		$trigger{payload_json} = $decoded;
	}

	return { trigger => \%trigger };
}

# Baut einen JSON-Payload aus einem dynamischen Wert und validierten Konstantfeldern.
sub jsonPayload {
	my ($key, $value, $constants) = @_;
	return undef if !defined($key) || ref($key) || $key !~ /^[A-Za-z_][A-Za-z0-9_]*$/;
	$constants = {} if !defined $constants;
	return undef if ref($constants) ne 'HASH';
	my %payload;

	# Auch direkte Runtime-Aufrufe duerfen keine verschachtelten Werte,
	# Steuerzeichen oder eine Ueberschreibung des dynamischen Feldes einschleusen.
	for my $constant (keys %$constants) {
		my $constant_value = $constants->{$constant};
		return undef if $constant !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || $constant eq $key
			|| !defined($constant_value) || ref($constant_value)
			|| $constant_value =~ /[\x00-\x1f]/;
		$payload{$constant} = $constant_value;
	}

	$payload{$key} = $value;
	return \%payload;
}

# Der Dispatcher ruft nur die sichere Template-Engine auf; Discovery-Text wird nie als Perl-Code evaluiert.
# Bildet genau ein Reading ueber seine angekuendigte Wertetabelle ab. Unbekannte
# Werte bleiben unveraendert, damit nichts still verschwindet.
sub applyValueMap {
	my ($values, $name, $map) = @_;
	return $values if ref($values) ne 'HASH' || ref($map) ne 'HASH'
		|| !defined($name) || !exists($values->{$name});
	my $value = $values->{$name};
	return $values if !defined($value) || ref($value);
	return $values if grep { !defined($_) || ref($_) || /[\x00-\x1f]/ }
		(keys %$map, values %$map);
	$values->{$name} = $map->{"$value"} if exists($map->{"$value"});
	return $values;
}

sub runtime {
	my ($operation, @arguments) = @_;
	my $answer;

	# Jede Runtime-Operation liefert lediglich den von MQTT2_DEVICE erwarteten
	# Reading-Hash oder "topic payload"-String. Fehler bleiben lokal und ergeben undef.
	my $ok = eval {

		# Die Operation bestimmt den erlaubten, fest implementierten Rendering-Pfad;
		# unbekannte Namen erreichen weder Template-Auswertung noch MQTT-Payloadbau.
		if ($operation eq 'reading') {
			my ($template, $event, $reading) = @arguments;
			my $compiled = MQTT2_Discovery::Template::compile($template);
			my $result = MQTT2_Discovery::Template::render($compiled, value => $event);
			$answer = { $reading => $result->{value} }
				if ref($result) eq 'HASH' && $result->{ok};
		} elsif ($operation eq 'triggerReading') {
			my ($template, $event, $reading, $configuration) = @arguments;
			my $compiled = MQTT2_Discovery::Template::compile($template);
			my $result = MQTT2_Discovery::Template::render(
				$compiled, value => $event, vars => triggerVars($event),
			);
			my $accepted = 1;

			# Topicgruppen vergleichen den bereits gerenderten HA-Triggerwert mit den
			# Payloadvarianten, waehrend bestehende Einzelaufrufe ungefiltert bleiben.
			if (defined($configuration)) {
				die 'Ungueltige Triggerfilter-Konfiguration'
					if ref($configuration) ne 'HASH'
						|| ref($configuration->{payloads}) ne 'ARRAY'
						|| !exists($configuration->{match_all})
						|| ref($configuration->{match_all});

				for my $payload (@{ $configuration->{payloads} }) {
					die 'Ungueltiger Triggerfilter-Payload'
						if !defined($payload) || ref($payload) || $payload =~ /[\x00-\x1f]/;
				}

				# Ohne unbedingte Variante muss genau eine deklarierte Payload dem
				# skalaren Ergebnis des value_template entsprechen.
				if (!$configuration->{match_all}) {
					$accepted = 0;

					if (ref($result) eq 'HASH' && $result->{ok}
							&& defined($result->{value}) && !ref($result->{value})) {

						for my $payload (@{ $configuration->{payloads} }) {
							if ("$payload" eq "$result->{value}") {
								$accepted = 1;
								last;
							}
						}

					}
				}
			}
			$answer = { $reading => $result->{value} }
				if ref($result) eq 'HASH' && $result->{ok} && $accepted;
		} elsif ($operation eq 'topic') {
			my ($device, $event, $configuration) = @arguments;
			die 'Ungueltige Topic-Konfiguration'
				if ref($configuration) ne 'HASH'
					|| ref($configuration->{readings}) ne 'ARRAY';
			my %updates;

			# Alle explizit angekuendigten Readings werden ueber ihre bereits
			# validierten HA-Templates gezielt aus demselben Payload gelesen.
			for my $reading (@{ $configuration->{readings} }) {
				die 'Ungueltiges Topic-Reading'
					if ref($reading) ne 'HASH'
						|| !defined($reading->{name}) || ref($reading->{name})
						|| $reading->{name} !~ /^[A-Za-z0-9_.-]+$/
						|| !defined($reading->{template}) || ref($reading->{template});
				# Gefilterte Ereignisarrays werden vollstaendig durchlaufen; pro Reading gilt der letzte Treffer.
				if (exists($reading->{items})) {
					my $items = $reading->{items};
					die 'Ungueltiger Ereignisfilter' if ref($items) ne 'HASH'
						|| ref($items->{path}) ne 'ARRAY' || !@{ $items->{path} }
						|| ref($items->{match}) ne 'HASH' || !keys %{ $items->{match} }
						|| grep { !defined($_) || ref($_) || /[\x00-\x1f]/ }
							(@{ $items->{path} }, keys %{ $items->{match} }, values %{ $items->{match} });
					my $data = eval { JSON::PP::decode_json($event) };

					# Fehlende oder ungueltige Quellpfade lassen bestehende Readings unveraendert.
					for my $key (@{ $items->{path} }) {
						$data = ref($data) eq 'HASH' ? $data->{$key} : undef;
					}

					next if ref($data) ne 'ARRAY';

					for my $item (@$data) {
						next if ref($item) ne 'HASH' || grep {
							!defined($item->{$_}) || ref($item->{$_}) || "$item->{$_}" ne "$items->{match}{$_}"
						} keys %{ $items->{match} };
						my $values = runtime('reading', $reading->{template},
							JSON::PP::encode_json($item), $reading->{name});
						$values = applyValueMap($values, $reading->{name}, $reading->{map})
							if ref($reading->{map}) eq 'HASH';
						@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
					}

					next;
				}
				my $reading_operation = ($reading->{context} || '') eq 'trigger'
					? 'triggerReading' : 'reading';
				my $values = runtime(
					$reading_operation, $reading->{template}, $event, $reading->{name},
				);
				$values = applyValueMap($values, $reading->{name}, $reading->{map})
					if ref($reading->{map}) eq 'HASH';
				@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
			}

			# Nutzt dasselbe MQTT-Ereignis zugleich eine Availability-Regel, werden
			# deren interner Zustand und das sichtbare Reading atomar mitgeliefert.
			if (ref($configuration->{availability}) eq 'HASH') {
				my $values = runtime(
					'availability', $device, $event, $configuration->{availability},
				);
				@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
			}
			$answer = \%updates;
		} elsif ($operation eq 'availability') {
			my ($device, $event, $configuration) = @arguments;
			die 'Ungueltige Availability-Konfiguration'
				if ref($configuration) ne 'HASH'
					|| ref($configuration->{sources}) ne 'ARRAY'
					|| ref($configuration->{policies}) ne 'ARRAY';
			# Ein leerer Name unterdrueckt das sichtbare Reading; ein fehlender
			# Schluessel behaelt den bisherigen Standardnamen.
			my $availability_reading = $configuration->{reading} // 'availability';
			$availability_reading = undef if $availability_reading eq '';
			die 'Ungueltiger Availability-Readingname'
				if defined($availability_reading) && (ref($availability_reading)
					|| $availability_reading !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/);
			my (%updates, %updated_sources);

			# Jede fuer das aktuelle Topic deklarierte Quelle wertet ihren eigenen
			# Payloadvertrag aus und speichert nur normalisierte Online-Werte.
			for my $source (@{ $configuration->{sources} }) {
				next if ref($source) ne 'HASH' || !defined($source->{reading})
					|| !defined($source->{available}) || !defined($source->{unavailable});
				my $value = $event;

				# Ein optionales HA-Template extrahiert den Vergleichswert aus dem
				# empfangenen Payload, bevor Online und Offline unterschieden werden.
				if (defined($source->{template}) && $source->{template} ne '') {
					my $compiled = MQTT2_Discovery::Template::compile($source->{template});
					my $result = MQTT2_Discovery::Template::render($compiled, value => $event);
					next if ref($result) ne 'HASH' || !$result->{ok};
					$value = $result->{value};
				}
				my $status;
				$status = 'online'
					if defined($value) && "$value" eq "$source->{available}";
				$status = 'offline'
					if defined($value) && "$value" eq "$source->{unavailable}";
				next if !defined($status);
				$updates{ $source->{reading} } = $status;
				$updated_sources{ $source->{reading} } = 1;
			}
			$answer = {};

			# Nur von der aktuellen Nachricht betroffene Regeln werden neu bewertet;
			# gespeicherte Quellreadings liefern dabei die uebrigen Zustaende.
			for my $policy (@{ $configuration->{policies} }) {
				next if ref($policy) ne 'HASH' || !defined($policy->{reading})
					|| ref($policy->{sources}) ne 'ARRAY';
				my @changed = grep { $updated_sources{$_} } @{ $policy->{sources} };
				next if !@changed;
				my @states = map {
					exists($updates{$_}) ? $updates{$_} : ReadingsVal($device, $_, 'unknown')
				} @{ $policy->{sources} };
				my $mode = $policy->{mode} || 'latest';
				my $status;
				if ($mode eq 'all') {
					$status = (grep { $_ eq 'offline' } @states) ? 'offline'
						: @states && !(grep { $_ ne 'online' } @states)
							? 'online' : 'unknown';
				} elsif ($mode eq 'any') {
					$status = (grep { $_ eq 'online' } @states)
						? 'online'
						: @states && !(grep { $_ ne 'offline' } @states)
							? 'offline' : 'unknown';
				} else {
					$status = $updates{ $changed[-1] };
				}
				$updates{ $policy->{reading} } = $status;
			}

			# Die Entity-Regeln behalten ihre jeweilige HA-Semantik. Das gruppierte
			# FHEM-Device ist online, sobald mindestens eine seiner Entities verfuegbar
			# ist, und erst offline, wenn alle Entities sicher offline sind.
			if (defined($availability_reading) && %updated_sources
					&& @{ $configuration->{policies} }) {
				my @policy_states = map {
					exists($updates{ $_->{reading} })
						? $updates{ $_->{reading} }
						: ReadingsVal($device, $_->{reading}, 'unknown')
				} grep { ref($_) eq 'HASH' && defined($_->{reading}) }
					@{ $configuration->{policies} };
				$updates{$availability_reading}
					= device_availability_status(\@policy_states);
			}

			# Die Brokerverbindung ist eine zusaetzliche, uebergeordnete HA-Bedingung.
			# Quell- und Regelreadings werden auch offline aktualisiert, der sichtbare
			# Zustand darf dadurch aber nicht wieder online werden.
			$updates{$availability_reading} = 'offline'
				if defined($availability_reading) && %updated_sources
					&& ReadingsVal($device, '.availability_io', 'online') ne 'online';
			$answer = \%updates;
		} elsif ($operation eq 'templatePublish') {
			my ($topic, $template, $event) = @arguments;
			my $value = MQTT2_Discovery_commandValue($event);
			my $result = MQTT2_Discovery::Template::render($template, value => $value);
			$answer = $topic . ' ' . $result->{value}
				if ref($result) eq 'HASH' && $result->{ok};
		} elsif ($operation eq 'choice') {
			my ($topic, $mapping, $event) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);
			$answer = $topic . ' ' . $mapping->{$choice}
				if ref($mapping) eq 'HASH' && exists $mapping->{$choice};
		} elsif ($operation eq 'templateChoice') {
			my ($topic, $template, $mapping, $event) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);

			# Nur konfigurierte Auswahlwerte werden in das Template eingesetzt; freie
			# Benutzereingaben duerfen die vorgegebene Choice-Abbildung nicht umgehen.
			if (ref($mapping) eq 'HASH' && exists $mapping->{$choice}) {
				my $result = MQTT2_Discovery::Template::render($template, value => $mapping->{$choice});
				$answer = $topic . ' ' . $result->{value}
					if ref($result) eq 'HASH' && $result->{ok};
			}
		} elsif ($operation eq 'publish') {
			my ($topic, $payload) = @arguments;
			$answer = $topic . ' ' . $payload;
		} elsif ($operation eq 'jsonPublish') {
			my ($topic, $key, $event, $constants) = @arguments;
			my $value = MQTT2_Discovery_commandValue($event);

			# JSON-Zahlen werden als numerische Werte codiert; andere Eingaben duerfen
			# nicht stillschweigend als String einen numerischen Aktor ansteuern.
			if ($value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/) {
				my $payload = jsonPayload($key, 0 + $value, $constants);
				$answer = $topic . ' ' . JSON::PP->new->canonical(1)->encode($payload)
					if $payload;
			}
		} elsif ($operation eq 'jsonChoice') {
			my ($topic, $key, $mapping, $event, $constants) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);

			# Nur deklarierte Choices gelangen als JSON-String auf das Command-Topic;
			# dadurch koennen freie Eingaben weder Mapping noch JSON-Struktur umgehen.
			if (ref($mapping) eq 'HASH' && exists $mapping->{$choice}) {
				my $payload = jsonPayload($key, $mapping->{$choice}, $constants);
				$answer = $topic . ' ' . JSON::PP->new->canonical(1)->encode($payload)
					if $payload;
			}
		} else {
			die "Unbekannte Runtime-Operation: $operation";
		}
		1;
	};
	return $ok ? $answer : undef;
}

# Findet den Registry-Eintrag eines verwalteten Zieldevices.
sub runtimeRegistryRecord {
	my ($device) = @_;
	return if !defined($device) || ref($device) || $device eq '';
	my $registered = $modules{MQTT2_DISCOVERY}{defptr};
	return if ref($registered) ne 'HASH';

	# Die Discovery-Registry ist die gemeinsame Quelle fuer Runtime-Referenzen
	# und fuer den reservierten Availability-Namen nach einem Neustart.
	for my $discovery (values %$registered) {
		next if ref($discovery) ne 'HASH';
		my $registry = registry($discovery);
		next if ref($registry) ne 'HASH' || ref($registry->{devices}) ne 'HASH';

		for my $record (values %{ $registry->{devices} }) {
			next if ref($record) ne 'HASH' || !defined($record->{name})
				|| ref($record->{name}) || $record->{name} ne $device;
			return ($discovery, $record);
		}

	}

	return;
}

# Findet die zu einem Zieldevice gehoerende deklarative Runtime-Referenz.
sub runtimeReference {
	my ($device, $reference) = @_;
	return undef if !defined($device) || ref($device) || $device eq ''
		|| !defined($reference) || ref($reference)
		|| $reference !~ /^r_[a-f0-9]{16,40}$/;
	my $target = $defs{$device};
	my $cached = ref($target) eq 'HASH'
		? $target->{helper}{mqtt2_discovery_runtime_refs} : undef;
	return $cached->{$reference}
		if ref($cached) eq 'HASH' && ref($cached->{$reference}) eq 'HASH';
	my (undef, $record) = runtimeRegistryRecord($device);
	return undef if ref($record) ne 'HASH' || ref($record->{runtime_refs}) ne 'HASH';

	# Nach einem Neustart wird der Cache bei der ersten Verwendung aus dem
	# zuvor gemeinsam gefundenen Registry-Eintrag aufgebaut.
	$target->{helper}{mqtt2_discovery_runtime_refs} = $record->{runtime_refs}
		if ref($target) eq 'HASH';
	return $record->{runtime_refs}{$reference}
		if ref($record->{runtime_refs}{$reference}) eq 'HASH';
	return undef;
}

# Liefert skalare Runtime-Ergebnisse als eindeutigen UTF-8-Bytestrom an MQTT2_DEVICE weiter.
sub mqttBytes {
	my ($value) = @_;
	return $value if !defined($value) || ref($value) || !utf8::is_utf8($value);
	return Encode::encode('UTF-8', $value);
}

# Codiert alle skalaren Readingwerte fuer FHEMs bytestream-basierte Laufzeit,
# ohne bereits codierte MQTT-Payloads oder nichtskalare Werte zu veraendern.
sub mqttReadingBytes {
	my ($readings) = @_;
	return {} if ref($readings) ne 'HASH';
	my %encoded = %$readings;

	# Jeder Unicode-Wert wird genau einmal an der MQTT-/FHEM-Grenze codiert.
	for my $name (keys %encoded) {
		$encoded{$name} = mqttBytes($encoded{$name});
	}

	return \%encoded;
}

# Loest eine kurze Attributreferenz ausschliesslich ueber fest implementierte
# Runtime-Operationen auf; gespeicherter Discovery-Text wird niemals evaluiert.
sub runtimeRef {
	my ($device, $reference, $event) = @_;
	my $descriptor = runtimeReference($device, $reference);
	return undef if ref($descriptor) ne 'HASH';
	my $operation = $descriptor->{operation} || '';

	# Reading-Referenzen unterscheiden Einzel-, Trigger-, Topic- und
	# Availability-Auswertung, liefern aber immer nur einen Reading-Hash.
	if ($operation eq 'reading') {
		my $runtime = $descriptor->{runtime} || '';
		my $template = $descriptor->{template};
		my $name = $descriptor->{name};
		return {} if $runtime !~ /^(?:reading|triggerReading)$/
			|| !defined($template) || ref($template)
			|| !defined($name) || ref($name) || $name !~ /^[A-Za-z0-9_.-]+$/;
		my $answer = runtime(
			$runtime, $template, $event, $name,
			($runtime eq 'triggerReading' && ref($descriptor->{filter}) eq 'HASH'
				? ($descriptor->{filter}) : ()),
		);
		$answer = applyValueMap($answer, $name, $descriptor->{map})
			if ref($descriptor->{map}) eq 'HASH';
		return mqttReadingBytes($answer);
	}
	if ($operation eq 'topic' || $operation eq 'availability') {
		my $configuration = $descriptor->{configuration};
		return {} if ref($configuration) ne 'HASH';
		my $answer = runtime(
			$operation, $device, $event, $configuration,
		);
		return mqttReadingBytes($answer);
	}
	return undef if $operation ne 'set';
	my $kind = $descriptor->{kind} || '';
	my $topic = $descriptor->{topic};
	return undef if $kind !~ /^(?:publish|choice|button|json|json_choice)$/
		|| !defined($topic) || ref($topic) || $topic eq '' || $topic =~ /[\x00-\x1f]/;
	my $answer;

	# Jeder Set-Typ wird auf denselben bereits validierten Runtime-Pfad wie die
	# bisherige ausgeschriebene Attributform abgebildet.
	if ($kind eq 'publish') {
		return undef if !defined($descriptor->{template}) || ref($descriptor->{template});
		$answer = runtime(
			'templatePublish', $topic, $descriptor->{template}, $event,
		);
	} elsif ($kind eq 'choice') {
		my $mapping = $descriptor->{mapping};
		return undef if ref($mapping) ne 'HASH' || grep {
			ref($_) || !defined($_) || $_ =~ /[\x00-\x1f]/
		} (keys(%$mapping), values(%$mapping));
		$answer = defined($descriptor->{template}) && $descriptor->{template} ne ''
			? runtime(
				'templateChoice', $topic, $descriptor->{template}, $mapping, $event,
			)
			: runtime('choice', $topic, $mapping, $event);
	} elsif ($kind eq 'button') {
		return undef if !defined($descriptor->{payload}) || ref($descriptor->{payload})
			|| $descriptor->{payload} =~ /[\x00-\x1f]/;
		$answer = runtime('publish', $topic, $descriptor->{payload});
	} elsif ($kind eq 'json') {
		$answer = runtime(
			'jsonPublish', $topic, $descriptor->{key}, $event, $descriptor->{constants},
		);
	} else {
		$answer = runtime(
			'jsonChoice', $topic, $descriptor->{key}, $descriptor->{mapping},
			$event, $descriptor->{constants},
		);
	}
	return mqttBytes($answer);
}

# Liefert fuer freie JSON-Auswertung den aktuell verbindlich reservierten
# Availability-Namen des verwalteten Zieldevices.
sub runtimeAvailabilityReading {
	my ($device) = @_;
	return $DEFAULT_AVAILABILITY_READING
		if !defined($device) || ref($device) || $device eq '';
	my $target = $defs{$device};
	my $cached = ref($target) eq 'HASH'
		? $target->{helper}{mqtt2_discovery_availability_reading} : undef;
	return $cached if defined($cached) && !ref($cached)
		&& $cached =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
	my ($discovery, $record) = runtimeRegistryRecord($device);
	if (ref($discovery) eq 'HASH' && ref($record) eq 'HASH') {
		my $name = $record->{availability_reading};
		$name = availability_reading($discovery, $record)
			if !defined($name) || ref($name)
				|| $name !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
		$target->{helper}{mqtt2_discovery_availability_reading} = $name
			if ref($target) eq 'HASH';
		return $name;
	}

	return $DEFAULT_AVAILABILITY_READING;
}

# Ergaenzt JSON-Zuordnungen um kollisionsfreie Namen reservierter Rollenreadings.
sub runtimeJSONMap {
	my ($device_or_map, $renames) = @_;
	my $json_map = ref($device_or_map) eq 'HASH'
		? $device_or_map
		: defined($device_or_map) && exists($defs{$device_or_map})
			&& ref($defs{$device_or_map}{JSONMAP}) eq 'HASH'
				? $defs{$device_or_map}{JSONMAP} : {};
	my %mapping = ref($json_map) eq 'HASH' ? %$json_map : ();
	return \%mapping if ref($renames) ne 'HASH';

	for my $source_name (sort keys %$renames) {
		my $target_name = $renames->{$source_name};
		next if !defined($source_name) || $source_name eq ''
			|| !defined($target_name) || ref($target_name);

		# Der leere Zielname ist keine Umbenennung, sondern eine Abwahl:
		# json2nameValue verwirft solche Schluessel (next if(!$map->{$name})).
		if ($target_name eq '') {
			$mapping{$source_name} = '';
			next;
		}

		# Auch ein vorhandenes jsonMap darf keinen beliebigen Quellwert auf den
		# inzwischen fuer eine technische Rolle reservierten Namen abbilden.
		for my $key (keys %mapping) {
			next if !defined($mapping{$key}) || ref($mapping{$key});
			$mapping{$key} = $target_name if $mapping{$key} eq $source_name;
		}

		# Ohne benutzerdefinierte Zuordnung wird ein gleichnamiges rohes JSON-Feld
		# auf denselben kollisionsfreien Zielnamen umgeleitet.
		$mapping{$source_name} = $target_name if !exists($mapping{$source_name});
	}

	return \%mapping;
}

# Entpackt freie JSON-Payloads ueber FHEMs Standardhelfer und schuetzt den frei
# konfigurierbaren Availability-Namen mit einem topicbezogenen Zielnamen.
sub jsonReadings {
	my ($device, $path, $event, $renames) = @_;
	return '' if !defined($path) || ref($path)
		|| !defined($event) || ref($event);
	$path =~ s/[^A-Za-z0-9]+/_/g;
	$path =~ s/^_+|_+$//g;
	return '' if $path eq '';
	$path = lc($path);
	my $availability = runtimeAvailabilityReading($device);
	my $json_map = runtimeJSONMap($device, $renames);

	# Explizite Discovery-Zuordnungen haben Vorrang; jedes danach noch auf den
	# reservierten Namen zielende Feld wird anhand seines Topic-Pfads qualifiziert.
	$json_map = runtimeJSONMap(
		$json_map, { $availability => $path . '_' . $availability },
	);
	my $values = json2nameValue($event, '', $json_map);
	return $values if ref($values) ne 'HASH';

	# Abgewaehlt wird der sichtbare Name. Weil ein eigenes jsonMap ihn erst hier
	# erzeugt, entscheidet das Ergebnis und nicht der Schluessel der Nachricht;
	# eine Aenderung am Attribut wirkt damit sofort.
	my $hidden = defined($device) && !ref($device) && $defs{$device}
		? $defs{$device}{helper}{mqtt2_discovery_hidden_readings} : undef;
	return $values if ref($hidden) ne 'HASH' || !%$hidden;
	delete @{$values}{ grep { $hidden->{$_} } keys %$values };
	return $values;
}

1;

=pod

=head1 NAME

MQTT2_DISCOVERY - native Home-Assistant-MQTT-Discovery fuer FHEM

=head1 SYNOPSIS

	define mqttDiscovery MQTT2_DISCOVERY mqttServer
	get mqttDiscovery devices
	set mqttDiscovery activate

=head1 SECURITY

Das Modul fuehrt kein C<save> aus und wertet Discovery-Payloads nicht als Perl-Code aus.

=item device
=item summary Home Assistant MQTT, Tasmota, Sonos2mqtt and Shelly discovery for MQTT2_DEVICE
=item summary_DE Home-Assistant-MQTT-, Tasmota-, Sonos2mqtt- und Shelly-Discovery fuer MQTT2_DEVICE

=begin html

<a id="MQTT2_DISCOVERY"></a>
<h3>MQTT2_DISCOVERY</h3>
<p>Processes Home Assistant MQTT Discovery and native Tasmota, Sonos2mqtt and Shelly Gen2/Gen3/Gen4 messages
and creates conservatively managed <code>MQTT2_DEVICE</code> devices.</p>

<p>A device with more than one switchable channel becomes one FHEM device per
channel, as in CUL_HM or ZWave. Everything that belongs to no channel &mdash;
availability, telemetry, sensors &mdash; stays with the main device, which keeps
the name of the discovered device; the channels are named after the channel name
from the discovery, or after its number when there is none. A device with a
single channel stays a single device.</p>

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>
<p>The bound IO device gates the public reachability reading of every managed
target: <code>lwt</code> for a registered last will, <code>availability</code>
for a reachability computed by a bridge. A
disconnected client marks all targets offline. After reconnect,
the most recently known discovery availability sources are evaluated again;
targets without such sources follow the IO device directly. Each entity retains
its announced Home Assistant availability semantics. A target that combines
multiple entities is online when at least one entity is available, offline only
when all entities are explicitly offline, and unknown otherwise. For each newly
applied availability topic on an <code>MQTT2_CLIENT</code>, one timer requests only
that retained topic after 60 seconds; normal MQTT traffic is not cached or
evaluated by this module. Deleting the bound IO device discards pending discovery
work, marks all managed targets offline and leaves this discovery device <code>inactive</code>.</p>

<a id="MQTT2_DISCOVERY-get"></a>
<h4>Get</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-get-payloads"></a><b>payloads &lt;device&gt;</b><br>
Returns the discovery messages a managed device was built from, as a block ready
to paste into a forum post. Values behind keys such as <code>pass</code>,
<code>user</code> or <code>token</code> are replaced by <code>xxx</code>, and
what describes the installation becomes a fixed example value: host
name, SSID and addresses. Topics and device identifiers stay as they are.
Replacing them would describe a different device: the twin built from the block
would publish on a branch no hardware answers on, so it could never switch. The
messages are kept in memory only, so after a restart they reappear with the next
discovery; for a natively queried adapter the call starts that query itself.
The block is only shown, no file is written: in FHEMWEB it appears in a text box
to copy from, everywhere else it is plain text. Paste it into a post, or save it
yourself if you want to attach it. Someone helping reads it back with
<a href="#MQTT2_DISCOVERY-set-replayPayloads">replayPayloads</a> and rebuilds the
device without the hardware.
</li><br>
<li><a id="MQTT2_DISCOVERY-get-devices"></a><b>devices</b><br>
Lists all currently existing <code>MQTT2_DEVICE</code> devices bound to the same
IO device, split into devices managed by this discovery instance and unmanaged
devices. Existing devices adopted by discovery count as managed; stale registry
entries without a live device are omitted. In FHEMWEB, the result opens in a
popup and each device name links to its detail view.<br>
Syntax: <code>get &lt;name&gt; devices</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-set"></a>
<h4>Set</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-set-activate"></a><b>activate</b><br>
Adds <code>MQTT2_DISCOVERY</code> to the IO device's current <code>clientOrder</code>
before the regular MQTT2 consumers without removing other clients.<br>
Syntax: <code>set &lt;name&gt; activate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deactivate"></a><b>deactivate</b><br>
Removes only <code>MQTT2_DISCOVERY</code> from the IO device's current
<code>clientOrder</code> and discards pending discovery work.<br>
Syntax: <code>set &lt;name&gt; deactivate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rebuildDevice"></a><b>rebuildDevice</b><br>
Completely replaces <code>devicetopic</code>, <code>readingList</code>, and
<code>setList</code> of one device managed by this discovery instance from its
persisted registry. <code>devicetopic</code> is normalized to the deepest common
segment-aligned topic prefix, and both lists are rendered relative to it.
Existing manual lines and a differing <code>devicetopic</code> are discarded
regardless of <code>existingDevice</code>. Other attributes and existing reading
values remain unchanged. This does not request new messages from the broker.
The optional <code>clearReadings</code> argument
subsequently removes all non-hidden readings, including manual ones. Hidden
readings whose names start with a dot remain. Availability and readings selected
by <code>createReadings</code> are initialized again; all other values require
new MQTT messages.<br>
Syntax: <code>set &lt;name&gt; rebuildDevice &lt;MQTT2_DEVICE&gt; [clearReadings]</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deviceKey"></a><b>deviceKey &lt;device&gt; &lt;key&gt;=&lt;value&gt; [...]</b><br>
Sets a key at a managed device. The command checks the spelling, merges it with
the keys already set there and only then writes the device attribute
<code>mqttDiscoveryKeys</code>, which can also be set by hand.
An empty value takes a single key back, it then falls through to family and
global level (see <a href="#MQTT2_DISCOVERY-attr-keys">keys</a>).<br>
Example: <code>set &lt;name&gt; deviceKey Werkstatt sets=hook</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-replayPayloads"></a><b>replayPayloads [&lt;file&gt;]</b><br>
Processes the messages of a block from
<a href="#MQTT2_DISCOVERY-get-payloads">payloads</a> as if they had just arrived.
The device is created without its hardware being present, which makes a foreign
report reproducible.<br>
Without an argument FHEMWEB opens an input field: paste the block there and press
OK. With an argument the command reads a file you saved the block to. Pasting the
block into the command line does not work, because the block loses its line
breaks there; the command says so.<br>
The block holds one message per line, topic and payload separated by a blank, as
<code>get payloads</code> prints them. Lines starting with <code>#</code> and
anything that is not such a line are ignored and reported as <code>ignored</code>;
a block without a single message line is rejected. A log file is therefore not a
valid input, however similar it may look.<br>
A block carries the topics and identifiers of its device. Replaying your own
block therefore meets the same device: nothing new is created, and a device that
is currently missing is restored, with its own client id rather than the
substitute the replay is processed under.<br>
A block from someone else describes hardware this installation does not have. Its
device publishes on the correct <code>cmnd</code> branch, but nobody answers, so
its <code>state</code> stays at <code>set_&lt;command&gt;</code>; the device
carries a <code>comment</code> saying so. Publishing one of its reading topics by
hand does update it. Should its name collide with a managed device, the foreign
one gets the alternative name; a name held by another record counts as taken even
while its device is missing.<br>
Example: <code>set &lt;name&gt; replayPayloads /tmp/aus-dem-forum.txt</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rescan"></a><b>rescan</b><br>
Processes matching retained discovery messages from an <code>MQTT2_SERVER</code>
again. An <code>MQTT2_CLIENT</code> has no local retained-message cache.<br>
Syntax: <code>set &lt;name&gt; rescan</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-discoverShelly"></a><b>discoverShelly [mqtt-prefix]</b><br>
Requests native Shelly Gen2/Gen3/Gen4 discovery. Without an argument, broadcasts
<code>announce</code>; an explicit MQTT prefix starts read-only RPC queries directly.
MQTT-RPC and either RPC status notifications or generic MQTT status updates must
be enabled on the Shelly. Broadcast discovery additionally requires MQTT Control.
The module supports relays, switch inputs, CCT lights and reported measurements.
CCT commands use percent for brightness and Kelvin for color temperature.
Paired BTHome components provide sensor values, battery, RSSI, timestamps and
button/rotation events on the gateway device. All dynamic component pages must
complete before the snapshot is applied. Events require RPC notifications.
Gen1, covers, non-CCT dimmers, RGB, other virtual components and local input button
events are not supported. Repeat the query after profile or pairing changes.
No Shelly settings are changed and no Bluetooth devices are paired automatically.<br>
Syntax: <code>set &lt;name&gt; discoverShelly [mqtt-prefix]</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-attr"></a>
<h4>Attributes</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-attr-keys"></a><b>keys</b><br>
Settings as <code>key=value</code>, separated by blanks. A key may be prefixed
with a family, which is the adapter that discovered the device
(<code>shelly</code>, <code>tasmota</code>, <code>homeassistant</code>,
<code>sonos2mqtt</code>). A key is looked up at the device
(<a href="#MQTT2_DEVICE-attr-mqttDiscoveryKeys">mqttDiscoveryKeys</a>), then for
its family, then globally, and falls back to the built-in default.<br>
Known keys with their defaults: <code>style</code>
(<code>fhem</code>|<code>raw</code>),
<code>sets</code> (<code>hook</code>|<code>list</code>),
<code>readings</code> (<code>parse</code>|<code>list</code>),
<code>reachability</code> (<code>sources</code>|<code>full</code>|<code>none</code>),
<code>forceNEXT</code> (<code>0</code>|<code>1</code>) and <code>hide</code>
(comma-separated reading names).<br>
<code>reachability</code> has three levels: <code>full</code> writes the
source readings and the condensed reading, <code>sources</code> only the sources,
<code>none</code> nothing at all. The visible reading is named
<code>lwt</code> when at least one source is the device's own last will, and
<code>availability</code> when a bridge states the reachability.<br>
Example: <code>attr &lt;name&gt; keys style=fhem shelly:sets=hook</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-shellyDiscovery"></a><b>shellyDiscovery</b><br>
Enables native Shelly discovery independently of <code>discoveryPrefixes</code>.
Default: <code>1</code>. Activation, startup and broker reconnect request native
announcements. Allow device topics and <code>mqtt2_discovery/&lt;name&gt;/shelly/#</code>
in MQTT subscriptions and broker ACLs. Set to <code>0</code> to stop new discovery;
existing device bindings remain usable.
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-discoveryPrefixes"></a><b>discoveryPrefixes</b><br>
Comma-separated discovery topic prefixes. Default: <code>homeassistant,tasmota/discovery,sonos2mqtt</code>.<br>
Example: <code>attr &lt;name&gt; discoveryPrefixes homeassistant,tasmota/discovery,sonos2mqtt</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-deviceNamePrefix"></a><b>deviceNamePrefix</b><br>
Optional prefix for newly created device names. By default no prefix is added.<br>
Example: <code>attr &lt;name&gt; deviceNamePrefix HA_</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-existingDevice"></a><b>existingDevice</b><br>
Controls handling of existing devices: <code>conservative</code> keeps manual
configuration, <code>ignore</code> skips the device and <code>replace</code> replaces
conflicting generated lines while preserving unrelated manual lines. Existing
<code>MQTT2_DEVICE</code> devices are resolved through FHEM's CID registry, independent
of their current name. Configured <code>bridgeRegexp</code> rules are applied to the
announced state topics before this lookup. Since an <code>MQTT2_CLIENT</code> cannot
observe the original publisher CID, a stable virtual CID derived from the discovery
device identity is used when no bridge rule matches. <code>MQTT2_SERVER</code> keeps
the publisher CID.<br>
Syntax: <code>attr &lt;name&gt; existingDevice &lt;conservative|ignore|replace&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-extraJsonReadings"></a><b>extraJsonReadings</b><br>
Controls JSON fields that are not explicitly named by discovery. The default
<code>include</code> retains the current flexible behaviour and expands additional
payload fields. <code>ignore</code> renders only concretely announced fields and
omits open JSON expansion and JSON sequences. Changing or deleting the attribute
re-renders every device managed by this discovery instance from its persisted
registry; discovery messages do not need to be received again.<br>
Syntax: <code>attr &lt;name&gt; extraJsonReadings &lt;include|ignore&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoCreate"></a><b>autoCreate</b><br>
Allows (<code>1</code>, default) or prevents (<code>0</code>) creation of new
<code>MQTT2_DEVICE</code> devices.<br>
Syntax: <code>attr &lt;name&gt; autoCreate &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoDelete"></a><b>autoDelete</b><br>
If set to <code>1</code>, devices created and still fully managed by this module
may be deleted after their last discovery entity is removed. Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; autoDelete &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-createReadings"></a><b>createReadings</b><br>
If set to <code>1</code>, safely predictable state readings announced by a
discovery message are created immediately with an empty value. FHEM remains
responsible for how this value is displayed. Existing readings are never
overwritten. Freely expanded JSON fields and JSON sequences remain data-driven
because discovery does not announce their concrete names. Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; createReadings &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-disable"></a><b>disable</b><br>
Disables (<code>1</code>) or enables (<code>0</code>) discovery processing. Disabling
also discards pending discovery work.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code>
</li><br>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html

=begin html_DE

<a id="MQTT2_DISCOVERY"></a>
<h3>MQTT2_DISCOVERY</h3>
<p>Verarbeitet Home-Assistant-MQTT-Discovery sowie native Tasmota-, Sonos2mqtt- und Shelly-Gen2/Gen3/Gen4-Nachrichten
und erzeugt daraus konservativ verwaltete <code>MQTT2_DEVICE</code>-Devices.</p>

<p>Ein Geraet mit mehr als einem schaltbaren Kanal wird in ein FHEM-Geraet je
Kanal aufgeteilt, wie man es von CUL_HM oder ZWave kennt. Was zu keinem Kanal
gehoert &mdash; Erreichbarkeit, Telemetrie, Sensoren &mdash; bleibt beim
Hauptgeraet, das den Namen des erkannten Geraets behaelt; die Kanaele tragen den
Kanalnamen aus der Discovery, ersatzweise ihre Nummer. Ein Geraet mit einem
einzigen Kanal bleibt ein einziges Geraet.</p>

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>
<p>Das gebundene IODev bestimmt zusaetzlich das sichtbare Reading fuer die
Erreichbarkeit aller verwalteten Ziele: <code>lwt</code> bei einem angemeldeten
letzten Willen, <code>availability</code> bei einer von einer Bruecke
errechneten Erreichbarkeit. Eine getrennte Client-Verbindung
setzt alle Ziele offline. Nach dem Reconnect werden die zuletzt bekannten
Discovery-Availability-Quellen erneut ausgewertet; Ziele ohne solche Quellen
folgen direkt dem IODev. Jede Entity behaelt dabei ihre angekuendigte
Home-Assistant-Availability-Semantik. Ein aus mehreren Entities bestehendes Ziel
ist online, sobald mindestens eine Entity verfuegbar ist, erst bei ausschliesslich
offline gemeldeten Entities offline und andernfalls unknown. Fuer jedes neu
angewendete Availability-Topic an einem
<code>MQTT2_CLIENT</code> fordert ein eigener Timer nach 60 Sekunden nur dieses
Retained-Topic an; der normale MQTT-Datenstrom wird weder gecacht noch durch das
Modul ausgewertet. Wird das gebundene IODev geloescht, werden ausstehende
Discovery-Arbeiten verworfen, alle verwalteten Ziele offline gesetzt und dieses
Discovery-Device bleibt als <code>inactive</code> definiert.</p>

<a id="MQTT2_DISCOVERY-get"></a>
<h4>Get</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-get-payloads"></a><b>payloads &lt;device&gt;</b><br>
Liefert die Discovery-Nachrichten, aus denen ein verwaltetes Geraet entstanden
ist, als Block zum Einfuegen in einen Forumsbeitrag. Werte hinter Schluesseln wie
<code>pass</code>, <code>user</code> oder <code>token</code> sind durch
<code>xxx</code> ersetzt, und alles, was die Anlage kenntlich macht, durch
feste Beispielwerte: Hostname, SSID und Adressen. Topics und Kennungen der
Geraete bleiben, wie sie sind. Ersetzt man sie, beschreibt der Block ein anderes
Geraet: Sein Zwilling sendet dann auf einen Zweig, auf dem keine Hardware
antwortet, und kann nie schalten. Die Nachrichten liegen nur im Speicher; nach
einem Neustart entstehen sie mit der naechsten Erkennung neu, bei einem nativ
abgefragten Adapter stoesst der Aufruf die Abfrage selbst an.
Der Block wird nur angezeigt, es entsteht keine Datei: In FHEMWEB steht er in
einem Textfeld zum Kopieren, sonst als reiner Text. Er gehoert in den Beitrag
oder, wenn er angehaengt werden soll, in eine selbst angelegte Datei. Ein Helfer
liest ihn mit <a href="#MQTT2_DISCOVERY-set-replayPayloads">replayPayloads</a>
wieder ein und baut das Geraet ohne die Hardware nach.
</li><br>
<li><a id="MQTT2_DISCOVERY-get-devices"></a><b>devices</b><br>
Listet alle aktuell vorhandenen <code>MQTT2_DEVICE</code>-Devices am selben IODev,
getrennt nach den von dieser Discovery-Instanz verwalteten und den nicht
verwalteten Devices. Von Discovery uebernommene Bestandsdevices gelten als
verwaltet; veraltete Registry-Eintraege ohne vorhandenes Device werden
ausgelassen. In FHEMWEB erscheint das Ergebnis als Popup und jeder Devicename
verlinkt auf seine Detailansicht.<br>
Syntax: <code>get &lt;name&gt; devices</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-set"></a>
<h4>Set</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-set-activate"></a><b>activate</b><br>
Fuegt <code>MQTT2_DISCOVERY</code> vor den normalen MQTT2-Consumern in die aktuelle
<code>clientOrder</code> des IODev ein, ohne fremde Clients zu entfernen.<br>
Syntax: <code>set &lt;name&gt; activate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deactivate"></a><b>deactivate</b><br>
Entfernt nur <code>MQTT2_DISCOVERY</code> aus der aktuellen <code>clientOrder</code>
des IODev und verwirft noch nicht verarbeitete Discovery-Arbeit.<br>
Syntax: <code>set &lt;name&gt; deactivate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rebuildDevice"></a><b>rebuildDevice</b><br>
Ersetzt <code>devicetopic</code>, <code>readingList</code> und <code>setList</code>
eines von dieser Discovery-Instanz verwalteten Devices vollstaendig aus der
gespeicherten Registry. <code>devicetopic</code> wird auf den tiefsten gemeinsamen
segmentgenauen Topic-Stamm normalisiert und beide Listen werden passend relativ
dazu aufgebaut. Vorhandene manuelle Zeilen sowie ein abweichendes
<code>devicetopic</code> werden unabhaengig von <code>existingDevice</code>
verworfen. Andere Attribute und vorhandene Readingwerte bleiben unveraendert.
Dabei werden keine neuen Nachrichten vom Broker angefordert. Der optionale
Zusatz <code>clearReadings</code> entfernt
anschliessend alle nicht versteckten Readings einschliesslich manueller Werte.
Versteckte Readings mit fuehrendem Punkt bleiben erhalten. Availability und die
ueber <code>createReadings</code> ausgewaehlten Readings werden erneut
initialisiert; alle anderen Werte benoetigen neue MQTT-Nachrichten.<br>
Syntax: <code>set &lt;name&gt; rebuildDevice &lt;MQTT2_DEVICE&gt; [clearReadings]</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deviceKey"></a><b>deviceKey &lt;device&gt; &lt;schluessel&gt;=&lt;wert&gt; [...]</b><br>
Setzt einen Schluessel an einem verwalteten Geraet. Der Befehl prueft die
Schreibweise, mischt sie mit den dort bereits gesetzten Schluesseln und schreibt
erst dann das Geraeteattribut <code>mqttDiscoveryKeys</code>, das sich auch von
Hand setzen laesst. Ein leerer Wert nimmt einen einzelnen Schluessel zurueck,
er faellt dann auf Familien- und globale Ebene
(siehe <a href="#MQTT2_DISCOVERY-attr-keys">keys</a>).<br>
Beispiel: <code>set &lt;name&gt; deviceKey Werkstatt sets=hook</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-replayPayloads"></a><b>replayPayloads [&lt;datei&gt;]</b><br>
Verarbeitet die Nachrichten eines Blocks von
<a href="#MQTT2_DISCOVERY-get-payloads">payloads</a>, als waeren sie gerade
eingetroffen. Das Geraet entsteht damit ohne die zugehoerige Hardware, eine
fremde Meldung wird so nachstellbar.<br>
Ohne Angabe oeffnet FHEMWEB ein Eingabefeld: Block einfuegen, OK druecken. Mit
Angabe liest der Befehl eine Datei, in der der Block abgelegt wurde. In die
Befehlszeile eingefuegt funktioniert er nicht, weil er dort seine
Zeilenumbrueche verliert; der Befehl sagt das auch.<br>
Der Block enthaelt je Zeile eine Nachricht, Topic und Nutzdaten durch ein
Leerzeichen getrennt, so wie <code>get payloads</code> sie ausgibt. Zeilen mit
<code>#</code> am Anfang und alles, was keine solche Zeile ist, werden
uebergangen und als <code>ignored</code> gemeldet; ein Block ohne eine einzige
Nachrichtenzeile wird abgewiesen. Eine Logdatei ist also keine gueltige Eingabe,
so aehnlich sie auch aussieht.<br>
Ein Block traegt die Topics und Kennungen seines Geraets. Der eigene Block trifft
deshalb dasselbe Geraet: Es entsteht nichts Neues, und ein gerade fehlendes
Geraet wird wiederhergestellt, mit seiner eigenen Client-ID statt mit der
Ersatz-ID, unter der ein Block verarbeitet wird.<br>
Ein fremder Block beschreibt Hardware, die es in dieser Anlage nicht gibt. Sein
Geraet sendet auf dem richtigen <code>cmnd</code>-Zweig, es antwortet nur
niemand, und sein <code>state</code> bleibt darum auf
<code>set_&lt;befehl&gt;</code> stehen; das Geraet traegt einen
<code>comment</code>, der das sagt. Wird eines seiner Reading-Topics von Hand
veroeffentlicht, zieht es nach. Trifft sein Name den eines verwalteten Geraets,
bekommt der fremde den Ausweichnamen; ein Name, den ein anderer Datensatz haelt,
gilt auch ohne sein Geraet als belegt.<br>
Beispiel: <code>set &lt;name&gt; replayPayloads /tmp/aus-dem-forum.txt</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rescan"></a><b>rescan</b><br>
Verarbeitet passende retained Discovery-Nachrichten aus dem lokalen Cache eines
<code>MQTT2_SERVER</code> erneut. Ein <code>MQTT2_CLIENT</code> besitzt keinen solchen Cache.<br>
Syntax: <code>set &lt;name&gt; rescan</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-discoverShelly"></a><b>discoverShelly [mqtt-prefix]</b><br>
Fordert native Discovery fuer Shelly Gen2/Gen3/Gen4 an. Ohne Argument wird
<code>announce</code> gesendet; ein konkreter MQTT-Prefix startet direkt lesende
RPC-Abfragen. MQTT-RPC und mindestens RPC-Statusmeldungen oder generische
MQTT-Statusupdates muessen am Shelly aktiviert sein. Die Broadcast-Suche benoetigt
zusaetzlich MQTT Control. Unterstuetzt werden Relais, Schalteingaenge, CCT-Leuchten
und gemeldete Messwerte. CCT-Befehle verwenden Prozent fuer die Helligkeit und
Kelvin fuer die Farbtemperatur. Gekoppelte BTHome-Komponenten liefern Sensorwerte,
Batterie, RSSI, Zeitstempel sowie Taster- und Drehereignisse am Gateway-Device.
Alle dynamischen Komponentenseiten muessen vor dem Anwenden vollstaendig vorliegen.
Ereignisse benoetigen RPC-Meldungen. Gen1, Cover, andere Dimmer, RGB, sonstige
virtuelle Komponenten und lokale Eingangstaster-Ereignisse werden nicht unterstuetzt.
Nach Profilwechsel oder Aenderungen gekoppelter BLU-Komponenten die Abfrage wiederholen.
Shelly-Einstellungen werden nicht veraendert und keine Bluetooth-Geraete gekoppelt.<br>
Syntax: <code>set &lt;name&gt; discoverShelly [mqtt-prefix]</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-attr"></a>
<h4>Attribute</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-attr-keys"></a><b>keys</b><br>
Einstellungen als <code>schluessel=wert</code>, durch Leerzeichen getrennt. Einem
Schluessel darf eine Familie vorangestellt werden; das ist der Adapter, der das
Geraet erkannt hat (<code>shelly</code>, <code>tasmota</code>,
<code>homeassistant</code>, <code>sonos2mqtt</code>). Gesucht wird am Geraet
(<a href="#MQTT2_DEVICE-attr-mqttDiscoveryKeys">mqttDiscoveryKeys</a>), dann fuer
seine Familie, dann global; zuletzt gilt die Vorgabe im Modul.<br>
Bekannte Schluessel, der erste Wert ist jeweils die Vorgabe:
<code>style</code> (<code>fhem</code>|<code>raw</code>),
<code>sets</code> (<code>hook</code>|<code>list</code>),
<code>readings</code> (<code>parse</code>|<code>list</code>),
<code>reachability</code> (<code>sources</code>|<code>full</code>|<code>none</code>),
<code>forceNEXT</code> (<code>0</code>|<code>1</code>) und <code>hide</code>
(kommaseparierte Readingnamen).<br>
<code>reachability</code> kennt drei Stufen: <code>full</code> schreibt die
Quellreadings und das verdichtete Reading, <code>sources</code> nur die Quellen,
<code>none</code> gar nichts davon. Das sichtbare Reading heisst
<code>lwt</code>, wenn mindestens eine Quelle der letzte Wille des Geraets ist,
und <code>availability</code>, wenn eine Bruecke die Erreichbarkeit aussagt.<br>
Beispiel: <code>attr &lt;name&gt; keys style=fhem shelly:sets=hook</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-shellyDiscovery"></a><b>shellyDiscovery</b><br>
Aktiviert native Shelly-Erkennung unabhaengig von <code>discoveryPrefixes</code>.
Default: <code>1</code>. Aktivierung, Start und Broker-Reconnect fordern native
Announcements an. Geraetetopics und <code>mqtt2_discovery/&lt;name&gt;/shelly/#</code>
muessen durch MQTT-Subscriptions und Broker-ACLs zugelassen sein.
Mit <code>0</code> werden neue Discovery-Abfragen unterbunden; bestehende
Device-Bindings bleiben nutzbar.
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-discoveryPrefixes"></a><b>discoveryPrefixes</b><br>
Kommaseparierte Discovery-Topic-Prefixe. Default: <code>homeassistant,tasmota/discovery,sonos2mqtt</code>.<br>
Beispiel: <code>attr &lt;name&gt; discoveryPrefixes homeassistant,tasmota/discovery,sonos2mqtt</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-deviceNamePrefix"></a><b>deviceNamePrefix</b><br>
Optionaler Prefix fuer neu angelegte Device-Namen. Standardmaessig wird kein Prefix vorangestellt.<br>
Beispiel: <code>attr &lt;name&gt; deviceNamePrefix HA_</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-existingDevice"></a><b>existingDevice</b><br>
Behandlung vorhandener Devices: <code>conservative</code> bewahrt manuelle
Konfiguration, <code>ignore</code> ueberspringt das Device und <code>replace</code>
ersetzt kollidierende erzeugte Zeilen, behaelt aber unabhaengige manuelle Zeilen.
Vorhandene <code>MQTT2_DEVICE</code>-Devices werden unabhaengig von ihrem aktuellen
Namen ueber FHEMs CID-Register aufgeloest. Konfigurierte <code>bridgeRegexp</code>-
Regeln werden davor auf die angekuendigten State-Topics angewandt. Da ein
<code>MQTT2_CLIENT</code> die urspruengliche Publisher-CID nicht kennt, wird ohne
passende Bridge-Regel eine stabile virtuelle CID aus der Discovery-Geraeteidentitaet
gebildet. Beim <code>MQTT2_SERVER</code> bleibt die Publisher-CID erhalten.<br>
Syntax: <code>attr &lt;name&gt; existingDevice &lt;conservative|ignore|replace&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-extraJsonReadings"></a><b>extraJsonReadings</b><br>
Steuert JSON-Felder, deren konkrete Namen nicht durch Discovery angekuendigt
werden. Der Default <code>include</code> behaelt das bisherige flexible Verhalten
und entpackt zusaetzliche Payload-Felder. <code>ignore</code> rendert nur konkret
angekuendigte Felder und laesst offene JSON-Auswertungen sowie JSON-Sequenzen
weg. Eine Aenderung oder das Loeschen des Attributes rendert alle von dieser
Discovery-Instanz verwalteten Devices aus der gespeicherten Registry neu; die
Discovery-Nachrichten muessen nicht erneut empfangen werden.<br>
Syntax: <code>attr &lt;name&gt; extraJsonReadings &lt;include|ignore&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoCreate"></a><b>autoCreate</b><br>
Erlaubt (<code>1</code>, Default) oder verhindert (<code>0</code>) das Anlegen neuer
<code>MQTT2_DEVICE</code>-Devices.<br>
Syntax: <code>attr &lt;name&gt; autoCreate &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoDelete"></a><b>autoDelete</b><br>
Bei <code>1</code> duerfen vom Modul angelegte und weiterhin vollstaendig verwaltete
Devices nach dem Entfernen ihrer letzten Discovery-Entity geloescht werden. Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; autoDelete &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-createReadings"></a><b>createReadings</b><br>
Bei <code>1</code> werden sicher vorhersagbare, in einer Discovery-Nachricht
angekuendigte State-Readings sofort mit einem leeren Wert angelegt. Wie dieser
Wert dargestellt wird, bleibt FHEM ueberlassen. Vorhandene Readings werden nie
ueberschrieben. Frei entpackte JSON-Felder und JSON-Sequenzen bleiben
nutzdatengetrieben, weil Discovery ihre konkreten Namen nicht ankuendigt.
Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; createReadings &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-disable"></a><b>disable</b><br>
Deaktiviert (<code>1</code>) oder aktiviert (<code>0</code>) die Discovery-Verarbeitung.
Beim Deaktivieren wird auch noch nicht verarbeitete Discovery-Arbeit verworfen.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code>
</li><br>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html_DE

=cut
