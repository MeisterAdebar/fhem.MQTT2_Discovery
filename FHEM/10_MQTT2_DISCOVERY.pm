# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

##############################################
# Native Home-Assistant-MQTT-Discovery fuer FHEM
package main;

use strict;
use warnings;
use lib './lib/FHEM';
use Encode ();
# Vermeidet JSON-Funktionsimporte in den mit anderen FHEM-Modulen geteilten Namensraum.
use JSON::PP ();
use MQTT2_Discovery::Helper qw(stable_unique stable_suffix split_lines line_key merge_generated_lines);
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Semantics ();
use MQTT2_Discovery::Template ();
use MQTT2_Discovery::FHEMGateway ();
use MQTT2_Discovery::DevicePlanner ();
use vars qw(%defs %attr %modules %data $readingFnAttributes);

our $MQTT2_DISCOVERY_VERSION = '0.9.11';
our $MQTT2_DISCOVERY_QUEUE_DELAY = 0.01;
our $MQTT2_DISCOVERY_AVAILABILITY_REFRESH_DELAY = 60;
our $MQTT2_DISCOVERY_AVAILABILITY_RETRY_DELAY = 10;
our $MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING = 'availability';

# --- FHEM-Zugriffe und Logging ------------------------------------------------

# Pro Modulinstanz wird genau ein Gateway erzeugt und fuer alle FHEM-Zugriffe
# wiederverwendet. Tests koennen vorab ein eigenes Gateway einsetzen.
sub MQTT2_DISCOVERY_gateway($) {
	my ($hash) = @_;
	return $hash->{helper}{gateway} ||= MQTT2_Discovery::FHEMGateway->new();
}

# Das normale FHEM-Attribut verbose steuert alle Meldungen dieses Devices.
sub MQTT2_DISCOVERY_log_enabled($$) {
	my ($hash, $level) = @_;
	return 0 if ref($hash) ne 'HASH' || !defined($hash->{NAME});
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	my $verbose = $gateway->attr_value(
		$hash->{NAME}, 'verbose', $gateway->attr_value('global', 'verbose', 3),
	);
	$verbose = 3 if !defined($verbose) || $verbose !~ /^\d+$/;
	return $verbose >= $level ? 1 : 0;
}

# Schreibt begrenzte einzeilige Diagnosemeldungen nur ab der aktiven Verbose-Stufe.
sub MQTT2_DISCOVERY_log($$$) {
	my ($hash, $level, $message) = @_;
	return if !MQTT2_DISCOVERY_log_enabled($hash, $level);
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	$message = substr($message, 0, 4096) . '... <truncated>' if length($message) > 4096;
	MQTT2_DISCOVERY_gateway($hash)->log(
		$hash->{NAME}, $level, "MQTT2_DISCOVERY $hash->{NAME}: $message",
	);
	return;
}

# Vorwaertsdeklaration fuer die rekursive Schwaerzung verschachtelter Logdaten.
sub MQTT2_DISCOVERY_log_redacted($);

# Schwaerzt Geheimnisse rekursiv, bevor strukturierte Payloaddaten protokolliert werden.
sub MQTT2_DISCOVERY_log_redacted($) {
	my ($value) = @_;

	# Hashes werden schluesselweise kopiert, damit vertrauliche Felder maskiert
	# werden koennen, ohne die fuer die Diagnose wichtige Struktur zu verlieren.
	if (ref($value) eq 'HASH') {
		my %safe;

		# Schluesselnamen werden bewusst breit erkannt; ein zu stark geschwaerzter
		# Diagnosewert ist sicherer als ein versehentlich protokolliertes Geheimnis.
		for my $key (keys %$value) {
			$safe{$key} = $key =~ /(?:pass(?:word)?|passwd|secret|token|auth(?:orization)?|credential|api[_-]?key|private[_-]?key|client[_-]?id|user(?:name)?|email)/i
				? '[REDACTED]' : MQTT2_DISCOVERY_log_redacted($value->{$key});
		}

		return \%safe;
	}
	return [ map { MQTT2_DISCOVERY_log_redacted($_) } @$value ] if ref($value) eq 'ARRAY';
	return $value if !ref($value);
	return '<unsupported value>';
}

# Payloads erscheinen nur auf Stufe 5, kanonisch, begrenzt und mit geschwaerzten Geheimnissen.
sub MQTT2_DISCOVERY_log_payload($) {
	my ($payload) = @_;
	$payload = '' if !defined $payload;
	return '<empty payload>' if $payload eq '';
	my ($decoded, $safe);
	my $ok = eval {
		$decoded = JSON::PP::decode_json($payload);
		$safe = JSON::PP->new->canonical(1)->encode(MQTT2_DISCOVERY_log_redacted($decoded));
		1;
	};
	return '<invalid or unloggable JSON; length=' . length($payload) . '>' if !$ok;
	return length($safe) <= 4096 ? $safe : substr($safe, 0, 4096) . '... <truncated>';
}

# --- FHEM-Lebenszyklus und Benutzerbefehle -----------------------------------

# Registriert FHEMs Lebenszyklus-, Parser- und Attributschnittstellen fuer den Modultyp.
# Vorwaertsdeklaration der Verarbeitung: Ohne sie gilt ihr Prototyp erst ab dem
# zweiten Laden der Datei, weshalb ein reload bisher mit einem Argumentfehler abbrach.
sub MQTT2_DISCOVERY_process($$$$;$);

sub MQTT2_DISCOVERY_Initialize($) {
	my ($hash) = @_;
	# Ein Fremdmodul traegt sich ein, statt in 10_MQTT2_DEVICE.pm namentlich zu
	# stehen; dort genuegt dann der Aufruf des hinterlegten Namens. Die Ablage
	# erfolgt in %data wie bei FHEMWEB und ausdruecklich nicht in %modules: Ein
	# Schreibzugriff auf $modules{<noch nicht geladenes Modul>} erzeugt dort einen
	# Eintrag ohne Match und ParseFn, an dem Dispatch spaeter stirbt.
	$data{MQTT2_DEVICE}{SetExtensionsFn} = 'MQTT2_DISCOVERY_SetExtensions';
	$hash->{DefFn} = 'MQTT2_DISCOVERY_Define';
	$hash->{UndefFn} = 'MQTT2_DISCOVERY_Undef';
	$hash->{GetFn} = 'MQTT2_DISCOVERY_Get';
	$hash->{SetFn} = 'MQTT2_DISCOVERY_Set';
	$hash->{AttrFn} = 'MQTT2_DISCOVERY_Attr';
	$hash->{ParseFn} = 'MQTT2_DISCOVERY_Parse';
	$hash->{NotifyFn} = 'MQTT2_DISCOVERY_Notify';
	# Kontextbezogene FHEMWEB-Hilfe fuer Get, Set und Attr aktivieren. Die
	# zugehoerigen Commandref-Anker stehen in der eingebetteten HTML-Dokumentation.
	$hash->{FW_deviceOverview} = 1;
	# Match bleibt absichtlich prefixunabhaengig, da Prefixe je IODev konfiguriert sind.
	$hash->{Match} = '\\x00(?:[^\\x00]+/(?:config|sensors|announce|online|events/rpc)|mqtt2_discovery/[^/\\x00]+/shelly/[a-f0-9]{16}/(?:info|config|status|components)/rpc|[^\\x00]+/discovery/[^/\\x00]+/[^/\\x00]+)\\x00';
	$hash->{AttrList} = 'discoveryPrefixes shellyDiscovery:0,1 fhemConventions:0,1 deviceNamePrefix existingDevice:conservative,ignore,replace extraJsonReadings:include,ignore availabilityReading autoCreate:0,1 autoDelete:0,1 createReadings:0,1 disable:0,1 ' . $readingFnAttributes;
	$hash->{AttrList} = 'discoveryPrefixes shellyDiscovery:0,1 setsViaHook:0,1 deviceNamePrefix existingDevice:conservative,ignore,replace extraJsonReadings:include,ignore availabilityReading autoCreate:0,1 autoDelete:0,1 createReadings:0,1 disable:0,1 ' . $readingFnAttributes;
	$hash->{AttrList} = 'discoveryPrefixes shellyDiscovery:0,1 readingsViaParse:0,1 deviceNamePrefix existingDevice:conservative,ignore,replace extraJsonReadings:include,ignore availabilityReading autoCreate:0,1 autoDelete:0,1 createReadings:0,1 disable:0,1 ' . $readingFnAttributes;
	$modules{MQTT2_DISCOVERY}{defptr} ||= {};
}

# Validiert die Definition und bindet genau eine Discovery-Instanz an ein MQTT2-IODev.
sub MQTT2_DISCOVERY_Define($$) {
	my ($hash, $definition) = @_;
	my @parts = split /[ \t]+/, $definition;

	# Eine unvollstaendige Definition darf weder ein IODev binden noch einen
	# halb initialisierten Eintrag in der globalen Discovery-Registry hinterlassen.
	if (@parts != 3) {
		my $error = 'Usage: define <name> MQTT2_DISCOVERY <MQTT2_SERVER|MQTT2_CLIENT>';
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}
	my ($name, undef, $io_name) = @parts;
	my $iodev = $defs{$io_name};

	# Ohne vorhandenes IODev gibt es weder einen MQTT-Dispatch noch eine sichere
	# Stelle, an der die Discovery-Instanz registriert werden koennte.
	if (!$iodev) {
		my $error = "MQTT2_DISCOVERY: IODev $io_name existiert nicht";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}

	# Nur MQTT2_SERVER und MQTT2_CLIENT stellen den Parser-Dispatch bereit, den
	# dieses Modul fuer Discovery-Nachrichten benoetigt.
	if (($iodev->{TYPE} || '') !~ /^MQTT2_(?:SERVER|CLIENT)$/) {
		my $error = "MQTT2_DISCOVERY: $io_name ist weder MQTT2_SERVER noch MQTT2_CLIENT";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}
	my $registered = $modules{MQTT2_DISCOVERY}{defptr}{$io_name};

	# Pro IODev darf genau eine Instanz Nachrichten konsumieren; zwei Instanzen
	# wuerden dieselbe Config doppelt verarbeiten und konkurrierende Devices pflegen.
	if ($registered && $registered != $hash) {
		my $error = "MQTT2_DISCOVERY: Fuer $io_name ist bereits $registered->{NAME} definiert";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}

	# FHEM ruft die DefFn bei modify/defmod mit gesetztem OLDDEF erneut auf.
	# Erst nach erfolgreicher Validierung des neuen IODev die bisherige
	# Registrierung und eventuell noch geplante Arbeit entfernen. Schlaegt die
	# Validierung fehl, bleibt die alte Definition dadurch voll funktionsfaehig.
	MQTT2_DISCOVERY_Undef($hash, undef) if defined $hash->{OLDDEF};

	$hash->{IODev} = $iodev;
	$hash->{IODevName} = $io_name;
	$hash->{DEF} = $io_name;
	MQTT2_DISCOVERY_set_notify_devices($hash);
	$modules{MQTT2_DISCOVERY}{defptr}{$io_name} = $hash;
	MQTT2_DISCOVERY_registry($hash);
	MQTT2_DISCOVERY_reconcile_registry_rendering($hash) if $main::init_done;
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_update_counts($hash);
	MQTT2_DISCOVERY_sync_io_availability($hash) if $main::init_done;
	MQTT2_DISCOVERY_log($hash, 2, "defined for $iodev->{TYPE} $io_name; version=$MQTT2_DISCOVERY_VERSION");
	MQTT2_DISCOVERY_check_ignore_regexp($hash);
	MQTT2_DISCOVERY_start_shelly($hash);
	return undef;
}

# Loest Timer und IODev-Registrierung einer entfernten oder geaenderten Instanz.
sub MQTT2_DISCOVERY_Undef($$) {
	my ($hash, undef) = @_;
	my $io_name = $hash->{IODevName};
	MQTT2_DISCOVERY_clear_queue($hash);
	MQTT2_DISCOVERY_clear_availability_refreshes($hash);
	MQTT2_DISCOVERY_log($hash, 2, 'undefined' . ($io_name ? "; IODev=$io_name" : ''));
	delete $modules{MQTT2_DISCOVERY}{defptr}{$io_name}
		if $io_name && $modules{MQTT2_DISCOVERY}{defptr}{$io_name} == $hash;
	return undef;
}

# Validiert Modulattribute und setzt disable-Aenderungen unmittelbar im Laufzeitstatus um.
sub MQTT2_DISCOVERY_Attr(@) {
	my ($operation, $name, $attribute, @values) = @_;
	my $hash = $defs{$name};

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
				MQTT2_DISCOVERY_clear_queue($hash);
				MQTT2_DISCOVERY_clear_availability_refreshes($hash);
			}
			MQTT2_DISCOVERY_reading($hash, 'state', $disabled ? 'disabled' : MQTT2_DISCOVERY_state($hash, 1));
			MQTT2_DISCOVERY_log($hash, 2, $disabled ? 'disabled by attribute' : 'enabled by attribute');
			MQTT2_DISCOVERY_enqueue_rerender($hash)
				if !$disabled && $hash->{helper}{rerender_pending};
		}
		return undef;
	}
	my $value = join(' ', @values);

	# Set-Operationen werden vor der Ablage des neuen Attributwertes validiert.
	if ($operation eq 'set') {
		if ($attribute eq 'discoveryPrefixes') {
			my ($prefixes, $error) = MQTT2_DISCOVERY_prefixes_from_value($value);
			return $error if $error;
			return 'discoveryPrefixes darf nicht leer sein' if !@$prefixes;
		} elsif ($attribute eq 'existingDevice') {
			return 'existingDevice muss conservative, ignore oder replace sein'
				if $value !~ /^(?:conservative|ignore|replace)$/;
		} elsif ($attribute eq 'extraJsonReadings') {
			return 'extraJsonReadings muss include oder ignore sein'
				if $value !~ /^(?:include|ignore)$/;
		} elsif ($attribute eq 'availabilityReading' && lc($value // '') eq 'none') {
			# none ist erlaubt und bedeutet kein sichtbares Reading.
		} elsif ($attribute eq 'readingsViaParse') {
			return 'readingsViaParse muss 0 oder 1 sein' if $value !~ /^[01]$/;
		} elsif ($attribute eq 'availabilityReading') {
			return 'availabilityReading muss mit einem Buchstaben oder Unterstrich beginnen und darf nur Buchstaben, Ziffern, Punkte, Unterstriche und Bindestriche enthalten'
				if $value !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
		} elsif ($attribute eq 'shellyDiscovery' || $attribute eq 'autoCreate' || $attribute eq 'autoDelete'
				|| $attribute eq 'createReadings') {
			return "$attribute muss 0 oder 1 sein" if $value !~ /^(?:0|1)$/;
		} elsif ($attribute eq 'deviceNamePrefix') {
			return 'deviceNamePrefix muss mit einem Buchstaben oder Unterstrich beginnen und darf nur Buchstaben, Ziffern, Unterstriche und Punkte enthalten'
				if $value !~ /^[A-Za-z_][A-Za-z0-9_.]*$/;
		}
	}

	# Auch das Loeschen wechselt verbindlich auf den Defaultnamen zurueck und
	# muss deshalb denselben globalen Konfliktschutz wie das Setzen durchlaufen.
	if ($hash && $attribute eq 'availabilityReading'
			&& $operation =~ /^(?:set|del)$/) {
		my $target_reading = $operation eq 'set'
			? $value : $MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING;
		my @conflicts = MQTT2_DISCOVERY_availability_reading_conflicts(
			$hash, $target_reading,
		);
		return 'availabilityReading wird bereits von manuellen readingList-Eintraegen verwendet: ' . join(', ', @conflicts)
			if @conflicts;
	}

	# Diese Attribute veraendern die erzeugte readingList aller verwalteten Devices.
	if ($operation =~ /^(?:set|del)$/
			&& ($attribute eq 'extraJsonReadings' || $attribute eq 'availabilityReading')) {
		MQTT2_DISCOVERY_enqueue_rerender($hash) if $hash;
	}
	return undef;
}

# Liefert den einzigen lesenden Benutzerbefehl als FHEMWEB-faehige Device-Uebersicht.
sub MQTT2_DISCOVERY_Get($@) {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	MQTT2_DISCOVERY_log($hash, 3, 'get ' . (defined($command) ? $command : '<missing>'));
	MQTT2_DISCOVERY_log($hash, 4, 'get arguments=[' . join(', ', @arguments) . ']') if @arguments;

	# Ohne Kommandonamen liefert FHEM die verfuegbare Get-Auswahl.
	return 'Unknown argument ?, choose one of devices:noArg'
		if !defined $command;

	# devices akzeptiert bewusst keine Zusatzargumente und erzeugt keine Seiteneffekte.
	return MQTT2_DISCOVERY_devices_html($hash)
		if $command eq 'devices' && !@arguments;

	# Auch fehlerhafte Aufrufe nennen die vollstaendige Get-Auswahl.
	return "Unknown argument $command, choose one of devices:noArg";
}

# Escaped dynamische Texte, bevor sie in die bewusst rohe FHEMWEB-HTML-Antwort gelangen.
sub MQTT2_DISCOVERY_html_escape($) {
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
sub MQTT2_DISCOVERY_url_encode($) {
	my ($value) = @_;
	$value = '' if !defined($value) || ref($value);
	my $encoded = utf8::is_utf8($value)
		? Encode::encode('UTF-8', $value) : $value;
	$encoded =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
	return $encoded;
}

# Erzeugt einen themen- und Unterpfad-kompatiblen Link zur FHEMWEB-Detailansicht.
sub MQTT2_DISCOVERY_device_link($) {
	my ($name) = @_;
	my $label = MQTT2_DISCOVERY_html_escape($name);
	my $target = 'detail=' . MQTT2_DISCOVERY_url_encode($name);

	# Im FHEMWEB-Kontext uebernimmt der Kern Root-Pfad und Small-Screen-Verhalten.
	if (defined(&main::FW_pH)) {
		return &main::FW_pH($target, $label, 0, undef, 1, 1);
	}

	# Telnet und isolierte Tests erhalten einen gueltigen relativen Detail-Link.
	return qq{<a href="?$target">$label</a>};
}

# Ordnet alle lebenden MQTT2_DEVICEs am gebundenen IODev der Registry oder dem Rest zu.
sub MQTT2_DISCOVERY_device_groups($) {
	my ($hash) = @_;
	my $devices = MQTT2_DISCOVERY_gateway($hash)->mqtt2_devices_for_iodev(
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
	my $registry = MQTT2_DISCOVERY_registry($hash);
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
sub MQTT2_DISCOVERY_devices_table($$$) {
	my ($heading, $devices, $empty_text) = @_;
	my $html = '<table class="block wide"><tr class="odd"><td><b>'
		. MQTT2_DISCOVERY_html_escape($heading) . ' (' . scalar(@$devices)
		. ')</b></td></tr>';

	# Vorhandene Devices erhalten jeweils eine eigene, abwechselnd formatierte Linkzeile.
	if (@$devices) {
		my $row = 0;

		for my $device (@$devices) {
			my $class = $row++ % 2 ? 'odd' : 'even';
			$html .= qq{<tr class="$class"><td>}
				. MQTT2_DISCOVERY_device_link($device) . '</td></tr>';
		}

	} else {
		# Eine leere Gruppe bleibt explizit sichtbar statt scheinbar zu verschwinden.
		$html .= '<tr class="even"><td>'
			. MQTT2_DISCOVERY_html_escape($empty_text) . '</td></tr>';
	}

	return $html . '</table>';
}

# Baut die rohe HTML-Antwort, die FHEMWEB bei Get-Aufrufen automatisch im Popup zeigt.
sub MQTT2_DISCOVERY_devices_html($) {
	my ($hash) = @_;
	my ($managed, $unmanaged) = MQTT2_DISCOVERY_device_groups($hash);
	my $language = uc(MQTT2_DISCOVERY_gateway($hash)->attr_value(
		'global', 'language', 'EN',
	));
	my $german = $language eq 'DE';
	my $io_name = MQTT2_DISCOVERY_html_escape($hash->{IODevName} || '');
	my $title = $german ? "MQTT2-Devices an $io_name" : "MQTT2 devices on $io_name";
	my $managed_heading = $german ? 'Verwaltet' : 'Managed';
	my $unmanaged_heading = $german ? 'Nicht verwaltet' : 'Unmanaged';
	my $empty_text = $german ? 'Keine Devices' : 'No devices';

	return '<html><div class="makeTable wide"><span class="mkTitle">'
		. $title . '</span>'
		. MQTT2_DISCOVERY_devices_table($managed_heading, $managed, $empty_text)
		. '<br>'
		. MQTT2_DISCOVERY_devices_table($unmanaged_heading, $unmanaged, $empty_text)
		. '</div></html>';
}

# Die abgewaehlten Readings liegen bewusst neben den Geraetedatensaetzen: Wird ein
# MQTT2_DEVICE geloescht, verwirft die Registry seinen Datensatz und legt ihn bei
# der naechsten Erkennung neu an; die Auswahl soll das ueberleben.
sub MQTT2_DISCOVERY_ignored_entities($$) {
	my ($hash, $record) = @_;
	return () if ref($record) ne 'HASH' || !defined($record->{name});
	my $selections = MQTT2_DISCOVERY_registry($hash)->{selections};
	return () if ref($selections) ne 'HASH'
		|| ref($selections->{ $record->{name} }) ne 'ARRAY';
	return grep { defined($_) && !ref($_) && $_ ne '' } @{ $selections->{ $record->{name} } };
}

# Alle Readingnamen, die der Dialog zur Auswahl stellt.
sub MQTT2_DISCOVERY_selectable_readings($$) {
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

	return sort keys %names;
}

# FHEMWEB-Formular mit eigenem Knopf: Das Muster aus AttrTemplate.pm verlaesst sich
# auf den Knopf von FW_okDialog; bei einem abgeschickten Set-Formular rendert
# FHEMWEB die Antwort aber als ganze Seite, in der es diesen Knopf nicht gibt.
sub MQTT2_DISCOVERY_select_readings_dialog($$$$) {
	my ($hash, $target_name, $selectable, $ignored) = @_;
	my $command = MQTT2_DISCOVERY_html_escape("set $hash->{NAME} selectReadings $target_name");
	my $detail = MQTT2_DISCOVERY_html_escape($target_name);
	my $rows = join('', map {
		my $name = MQTT2_DISCOVERY_html_escape($_);
		my $checked = $ignored->{$_} ? '' : " checked='checked'";
		"<tr><td><input type='checkbox' class='m2dSelect' name='$name'$checked></td><td>$name</td></tr>";
	} @$selectable);
	return '<html>'
		. "<input type='hidden' id='m2dSelectCmd' value='$command'>"
		. "<p>Welche Readings soll $detail behalten?</p>"
		. "<table class='block wide'>$rows</table>"
		. "<br><input type='button' id='m2dSelectOk' value='&Uuml;bernehmen'>"
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
				document.getElementById("m2dSelectOk").onclick = apply;

				// Im Popup von FHEMWEB uebernimmt zusaetzlich dessen eigener Knopf.
				if(typeof \$ == "function" && \$("#FW_okDialog").length) {
					\$("#FW_okDialog").parent().find("button").css("display","block");
					\$("#FW_okDialog").parent().find(".ui-dialog-buttonpane button")
						.unbind("click").click(function(){ apply(); \$("#FW_okDialog").remove(); });
				}
			})();
		</script>}
		. '</html>';
}

# Zeigt die Auswahl an oder uebernimmt sie und baut die Listen neu auf.
sub MQTT2_DISCOVERY_select_readings($@) {
	my ($hash, $target_name, @pairs) = @_;
	return 'Usage: set <name> selectReadings <MQTT2_DEVICE> [<reading>=0|1 ...]'
		if !defined($target_name) || $target_name eq '';
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my @records = grep {
		ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $target_name
	} values %{ $registry->{devices} || {} };
	return "$target_name wird von $hash->{NAME} nicht verwaltet" if @records != 1;
	my $record = $records[0];
	my @selectable = MQTT2_DISCOVERY_selectable_readings($hash, $record);
	my %ignored = map { ($_ => 1) } MQTT2_DISCOVERY_ignored_entities($hash, $record);

	# Bereits abgewaehlte Namen entstehen nicht mehr und fehlen deshalb in den
	# Runtime-Referenzen; fuer den Dialog gehoeren sie wieder in die Liste.
	my %offered = map { ($_ => 1) } (@selectable, keys %ignored);
	@selectable = sort keys %offered;
	return "$target_name hat noch keine erkannten Readings" if !@selectable;

	if (!@pairs) {
		return MQTT2_DISCOVERY_select_readings_dialog($hash, $target_name, \@selectable, \%ignored)
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
	my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record, { rebuild_lists => 1 });
	return $error if $error;
	MQTT2_DISCOVERY_persist_registry($hash);

	# Ein abgewaehltes Reading wird nicht mehr beschrieben; es stehen zu lassen
	# wuerde einen veralteten Wert dauerhaft sichtbar machen.
	for my $reading (@ignore) {
		next if $reading =~ /^\./;
		next if ref($defs{$target_name}{READINGS}) ne 'HASH'
			|| !exists($defs{$target_name}{READINGS}{$reading});
		MQTT2_DISCOVERY_gateway($hash)->delete_reading($defs{$target_name}, $reading);
	}

	MQTT2_DISCOVERY_log($hash, 2,
		"selectReadings $target_name ignoriert: " . (@ignore ? join(',', @ignore) : '-'));
	return undef;
}

# Die verwalteten Zieldevices erscheinen als Auswahlliste hinter selectReadings,
# damit FHEMWEB ein Klappmenue statt eines Textfelds anbietet.
sub MQTT2_DISCOVERY_set_list($) {
	my ($hash) = @_;
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my @targets = sort grep { defined($_) && !ref($_) && $defs{$_} } map {
		ref($_) eq 'HASH' ? $_->{name} : undef
	} values %{ $registry->{devices} || {} };
	my $select = @targets ? 'selectReadings:' . join(',', @targets) : 'selectReadings';
	return "activate:noArg deactivate:noArg rebuildDevice $select rescan:noArg discoverShelly";
}
# Bedient die Set-Kommandos eines verwalteten MQTT2_DEVICE, ohne dass dort ein
# setList-Attribut noetig ist: bei "?" ergaenzt die Funktion die Befehle in der
# Auswahl, sonst fuehrt sie den gewaehlten Befehl aus. Fremde Devices reicht sie
# unveraendert an SetExtensions weiter.
sub MQTT2_DISCOVERY_SetExtensions($$@) {
	my ($hash, $list, $name, $cmd, @a) = @_;
	my ($discovery, $record) = MQTT2_DISCOVERY_runtimeRegistryRecord($name);
	return SetExtensions($hash, $list, $name, $cmd, @a)
		if ref($record) ne 'HASH' || ref($record->{hook_sets}) ne 'ARRAY';
	my %sets = map { (($_->{name} // '') => $_) } @{ $record->{hook_sets} };
	my $entry = defined($cmd) ? $sets{$cmd} : undef;

	# Ohne passenden Befehl entscheidet SetExtensions, also auch bei "?".
	if (!$entry) {
		my $offered = join(' ', map {
			$_->{name} . (defined($_->{spec}) && $_->{spec} ne '' ? ":$_->{spec}" : '')
		} sort { ($a->{name} // '') cmp ($b->{name} // '') } @{ $record->{hook_sets} });
		$list .= ($list eq '' ? '' : ' ') . $offered if $offered ne '';
		return SetExtensions($hash, $list, $name, $cmd, @a);
	}
	my $payload = $entry->{kind} eq 'button' ? $entry->{payload}
		: ref($entry->{mapping}) eq 'HASH' && defined($a[0]) ? $entry->{mapping}{ $a[0] } : undef;
	return "Unbekannter Wert fuer $cmd" if !defined($payload);
	my $error = MQTT2_DISCOVERY_gateway($discovery)->publish_mqtt(
		$discovery->{IODev}, $entry->{topic}, $payload,
	);
	return $error if defined($error) && $error ne '';

	# MQTT2_DEVICE setzt state nur fuer Befehle aus seiner eigenen setList; auf
	# diesem Weg uebernimmt das Modul denselben Schritt.
	MQTT2_DISCOVERY_gateway($discovery)->update_reading($defs{$name}, 'state',
		$cmd . (@a ? ' ' . join(' ', @a) : ''), 1) if $defs{$name};
	MQTT2_DISCOVERY_log($discovery, 3, "set $name $cmd ueber den Hook ausgefuehrt");
	return undef;
}
# Mit readingsViaParse wertet das Modul die Nutzdaten selbst aus. Dafuer muss es
# alle Nachrichten sehen, deshalb wird der Match des Moduls weit gestellt, solange
# mindestens eine Instanz das Attribut gesetzt hat. Ohne das Attribut bleibt der
# enge Match erhalten und nichts am bisherigen Ablauf aendert sich.
our $MQTT2_DISCOVERY_NARROW_MATCH;
sub MQTT2_DISCOVERY_update_match() {
	$MQTT2_DISCOVERY_NARROW_MATCH = $modules{MQTT2_DISCOVERY}{Match}
		if !defined($MQTT2_DISCOVERY_NARROW_MATCH);
	my $wide = 0;

	for my $instance (values %{ $modules{MQTT2_DISCOVERY}{defptr} || {} }) {
		next if ref($instance) ne 'HASH' || !defined($instance->{NAME});
		$wide = 1 if MQTT2_DISCOVERY_gateway($instance)->attr_value(
			$instance->{NAME}, 'readingsViaParse', 0,
		);
	}

	$modules{MQTT2_DISCOVERY}{Match} = $wide ? '.*' : $MQTT2_DISCOVERY_NARROW_MATCH;
	return $wide;
}

# Liefert die vom Modul selbst auszuwertenden Zeilen eines Zielgeraets.
sub MQTT2_DISCOVERY_parse_readings($$) {
	my ($hash, $record) = @_;
	return () if ref($record) ne 'HASH' || ref($record->{parse_readings}) ne 'ARRAY';
	return @{ $record->{parse_readings} };
}

# Wertet eine Nutzdatennachricht fuer alle verwalteten Zieldevices aus und schreibt
# deren Readings direkt, ohne den Umweg ueber ein readingList-Attribut.
sub MQTT2_DISCOVERY_apply_parsed_readings($$$) {
	my ($hash, $topic, $payload) = @_;
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my $written = 0;

	for my $record (values %{ $registry->{devices} || {} }) {
		next if ref($record) ne 'HASH' || !defined($record->{name});
		my $target = $defs{ $record->{name} };
		next if !$target;
		my $device_topic = AttrVal($record->{name}, 'devicetopic', '');
		my %updates;

		for my $entry (MQTT2_DISCOVERY_parse_readings($hash, $record)) {
			next if ref($entry) ne 'HASH' || !defined($entry->{regexp}) || !defined($entry->{reference});
			my $pattern = $entry->{regexp};
			$pattern =~ s/\$DEVICETOPIC/\Q$device_topic\E/g if $device_topic ne '';
			next if "$topic:$payload" !~ /^$pattern$/s;
			my $values = MQTT2_DISCOVERY_runtimeRef($record->{name}, $entry->{reference}, $payload);
			next if ref($values) ne 'HASH';
			@updates{ keys %$values } = values %$values;
		}

		next if !%updates;
		MQTT2_DISCOVERY_gateway($hash)->update_readings($target, \%updates);
		MQTT2_DISCOVERY_log($hash, 4,
			"readings aus $topic fuer $record->{name}: " . join(',', sort keys %updates));
		$written++;
	}

	return $written;
}
# Verteilt die erlaubten Set-Kommandos auf Aktivierung, Deaktivierung oder Neuaufbau.
sub MQTT2_DISCOVERY_Set($@) {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	MQTT2_DISCOVERY_log($hash, 3, 'set ' . (defined($command) ? $command : '<missing>'));
	MQTT2_DISCOVERY_log($hash, 4, 'set arguments=[' . join(', ', @arguments) . ']') if @arguments;
	return 'Unknown argument ?, choose one of ' . MQTT2_DISCOVERY_set_list($hash)
		if !defined $command;
	return MQTT2_DISCOVERY_activate($hash) if $command eq 'activate' && !@arguments;
	return MQTT2_DISCOVERY_deactivate($hash) if $command eq 'deactivate' && !@arguments;
	return MQTT2_DISCOVERY_rebuild_device(
		$hash, $arguments[0], @arguments == 2 ? 1 : 0,
	) if $command eq 'rebuildDevice'
		&& (@arguments == 1
			|| (@arguments == 2 && $arguments[1] eq 'clearReadings'));
	return MQTT2_DISCOVERY_rescan($hash) if $command eq 'rescan' && !@arguments;
	return MQTT2_DISCOVERY_discover_shelly($hash, $arguments[0])
		if $command eq 'discoverShelly' && @arguments <= 1;
	return MQTT2_DISCOVERY_select_readings($hash, @arguments) if $command eq 'selectReadings';
	return "Unknown argument $command, choose one of " . MQTT2_DISCOVERY_set_list($hash);
}

# Liefert den instanzlokalen Antwortpfad und die getrennt schaltbare native Erkennung.
sub MQTT2_DISCOVERY_shelly_args($) {
	my ($hash) = @_;
	return (
		shelly_enabled => MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1),
		reply_prefix => "mqtt2_discovery/$hash->{NAME}/shelly",
	);
}

# Fuehrt deklarierte MQTT-Abfragen aus; Konfigurations- und Geraetebefehle entstehen hier nicht.
sub MQTT2_DISCOVERY_send_requests($$) {
	my ($hash, $requests) = @_;
	return undef if ref($requests) ne 'ARRAY' || !@$requests;
	return 'MQTT2_DISCOVERY ist deaktiviert' if MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	return 'Shelly-Discovery ist deaktiviert' if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	return 'MQTT-IODev ist nicht verbunden' if !MQTT2_DISCOVERY_iodev_available($hash);

	for my $request (@$requests) {
		my $error = MQTT2_DISCOVERY_gateway($hash)->publish_mqtt(
			$hash->{IODev}, $request->{topic}, $request->{payload},
		);
		return $error if defined($error) && $error ne '';
	}

	return undef;
}

# Fordert native Announcements oder einen gezielten Snapshot fuer einen individuellen Prefix an.
sub MQTT2_DISCOVERY_discover_shelly($;$) {
	my ($hash, $prefix) = @_;
	return 'MQTT2_DISCOVERY muss aktiv sein' if MQTT2_DISCOVERY_state($hash) ne 'active';
	return 'Shelly-Discovery ist deaktiviert' if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	my $requests = [{ topic => 'shellies/command', payload => 'announce' }];

	# Ein expliziter Prefix wird direkt abgefragt und benoetigt MQTT Control nicht.
	if (defined($prefix)) {
		my $result = MQTT2_Discovery::Format::Shelly::begin(
			MQTT2_DISCOVERY_shelly_args($hash), mqtt_prefix => $prefix, force => 1,
			state => ($hash->{helper}{formats}{shelly} ||= {}),
		);
		return $result->{error} if $result->{status} ne 'ok';
		$requests = $result->{requests};
	}
	my $error = MQTT2_DISCOVERY_send_requests($hash, $requests);
	MQTT2_DISCOVERY_reading($hash, 'lastShellyDiscovery', $error || 'requested');
	return $error;
}

# Startet native Erkennung einmal pro aktiver Brokerverbindung, auch nach einem FHEM-Neustart.
sub MQTT2_DISCOVERY_start_shelly($) {
	my ($hash) = @_;
	return if !$main::init_done;
	# Ein Verbindungsabbruch gibt den naechsten Start wieder frei.
	if (MQTT2_DISCOVERY_state($hash) ne 'active' || !MQTT2_DISCOVERY_iodev_available($hash)) {
		delete $hash->{helper}{shelly_started};
		return;
	}
	return if $hash->{helper}{shelly_started}
		|| !MQTT2_DISCOVERY_gateway($hash)->can_publish_mqtt()
		|| !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'shellyDiscovery', 1);
	my $error = MQTT2_DISCOVERY_discover_shelly($hash);
	$hash->{helper}{shelly_started} = 1 if !$error;
	MQTT2_DISCOVERY_log($hash, 2, "Shelly discovery failed: $error") if $error;
	return;
}

# Ersetzt devicetopic, readingList und setList eines verwalteten Zieldevices vollstaendig.
sub MQTT2_DISCOVERY_rebuild_device($$;$) {
	my ($hash, $target_name, $clear_readings) = @_;

	# Ein expliziter Neuaufbau darf die kontrollierte Moduldeaktivierung nicht umgehen.
	if (MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		return 'MQTT2_DISCOVERY ist durch disable=1 deaktiviert';
	}
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my @records = grep {
		ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} eq $target_name
	} values %{ $registry->{devices} || {} };

	# Nur ein bereits eindeutig von dieser Discovery-Instanz verwaltetes Device ist zulaessig.
	return "$target_name wird von $hash->{NAME} nicht verwaltet" if !@records;
	return "$target_name ist in der Discovery-Registry nicht eindeutig" if @records > 1;
	return "$target_name ist kein MQTT2_DEVICE"
		if !$defs{$target_name} || ($defs{$target_name}{TYPE} || '') ne 'MQTT2_DEVICE';
	my $error = MQTT2_DISCOVERY_apply_device_lines(
		$hash, $records[0], {
			rebuild_lists => 1,
			clear_readings => $clear_readings ? 1 : 0,
		},
	);

	# Ein fehlgeschlagener ActionPlan hat die Attribute bereits zurueckgerollt.
	if ($error) {
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_log($hash, 1, "rebuildDevice failed for target=$target_name: $error");
		return $error;
	}
	MQTT2_DISCOVERY_persist_registry($hash);
	MQTT2_DISCOVERY_log($hash, 2, "rebuildDevice completed for target=$target_name");
	return undef;
}

# Parst und validiert die kommagetrennte Liste erlaubter Discovery-Topic-Prefixe.
sub MQTT2_DISCOVERY_prefixes_from_value($) {
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
sub MQTT2_DISCOVERY_prefixes($) {
	my ($hash) = @_;
	my $value = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'discoveryPrefixes', 'homeassistant,tasmota/discovery,sonos2mqtt',
	);
	my ($prefixes, undef) = MQTT2_DISCOVERY_prefixes_from_value($value);
	return $prefixes || ['homeassistant', 'tasmota/discovery', 'sonos2mqtt'];
}

# Ermittelt die aktuelle MQTT-Parserreihenfolge aus Attribut oder IODev-Standard.
sub MQTT2_DISCOVERY_client_order($) {
	my ($hash) = @_;
	my $iodev = $hash->{IODev};
	my $configured = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientOrder', '',
	);
	my @order = $configured ne '' ? split(/\s+/, $configured) : grep { $_ ne '' } split(/:/, $iodev->{Clients} || '');
	@order = qw(MQTT2_DEVICE MQTT_GENERIC_BRIDGE) if !@order;
	return @order;
}

# Discovery muss vor MQTT2_DEVICE laufen, damit Discovery-Nachrichten nicht als
# normale Geraetetelemetrie autocreated werden.
sub MQTT2_DISCOVERY_is_active($) {
	my ($hash) = @_;
	my @order = MQTT2_DISCOVERY_client_order($hash);
	my %position;
	$position{$order[$_]} = $_ for 0 .. $#order;
	return 0 if !exists $position{MQTT2_DISCOVERY};
	return 0 if exists($position{MQTT2_DEVICE}) && $position{MQTT2_DISCOVERY} > $position{MQTT2_DEVICE};
	return 1;
}

# Leitet den sichtbaren Modulstatus aus disable und der tatsaechlichen Parserposition ab.
sub MQTT2_DISCOVERY_state($;$) {
	my ($hash, $ignore_disable) = @_;
	return 'disabled' if !$ignore_disable
		&& MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	my $io_name = $hash->{IODevName} || '';
	return 'inactive' if !$io_name || !$defs{$io_name}
		|| $defs{$io_name} != $hash->{IODev};
	return MQTT2_DISCOVERY_is_active($hash) ? 'active' : 'inactive';
}

# Ordnet Discovery vor den Device-Parsern ein und aktualisiert den Laufzeitstatus.
sub MQTT2_DISCOVERY_activate($) {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } MQTT2_DISCOVERY_client_order($hash);
	my $index = 0;

	# Vor den ersten Device-Parser einsortieren, andere Client-Reihenfolge aber
	# unveraendert lassen.
	++$index while $index < @order && $order[$index] ne 'MQTT2_DEVICE' && $order[$index] ne 'MQTT_GENERIC_BRIDGE';
	splice @order, $index, 0, 'MQTT2_DISCOVERY';
	my $error = MQTT2_DISCOVERY_gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', join(' ', @order),
	);

	# Bei einem FHEM-Fehler ist die neue Parserposition nicht verlaesslich aktiv;
	# Status und Erfolgsmeldung duerfen dann nicht vorgetaeuscht werden.
	if ($error) {
		MQTT2_DISCOVERY_log($hash, 1, "activation failed: $error");
		return $error;
	}
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_check_ignore_regexp($hash);
	MQTT2_DISCOVERY_log($hash, 2, 'activated; clientOrder=' . join(' ', @order));
	MQTT2_DISCOVERY_start_shelly($hash);
	return undef;
}

# Entfernt Discovery aus clientOrder und verwirft danach noch geplante Verarbeitung.
sub MQTT2_DISCOVERY_deactivate($) {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } MQTT2_DISCOVERY_client_order($hash);
	my $error = MQTT2_DISCOVERY_gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', @order ? join(' ', @order) : '',
	);

	# Schlaegt das Entfernen aus clientOrder fehl, kann der Parser weiterhin aktiv
	# sein; seine Warteschlange bleibt deshalb bis zu einer erfolgreichen Aenderung erhalten.
	if ($error) {
		MQTT2_DISCOVERY_log($hash, 1, "deactivation failed: $error");
		return $error;
	}
	MQTT2_DISCOVERY_clear_queue($hash);
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_log($hash, 2, 'deactivated; clientOrder=' . join(' ', @order));
	return undef;
}

# Warnt einmalig, wenn das IODev-ignoreRegexp ein typisches Discovery-Topic
# bereits vor dem Parser-Dispatch ausfiltern wuerde.
sub MQTT2_DISCOVERY_check_ignore_regexp($) {
	my ($hash) = @_;
	my $io_name = $hash->{IODevName};
	my $regexp = MQTT2_DISCOVERY_gateway($hash)->attr_value(
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
	for my $prefix (@{ MQTT2_DISCOVERY_prefixes($hash) }) {
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
			MQTT2_DISCOVERY_reading($hash, 'lastWarning', $warning);
			MQTT2_DISCOVERY_log($hash, 2, "warning: $warning; regexp=$regexp");
			return;
		}

	}

	delete $hash->{helper}{ignore_regexp_warning};
}

# Spielt den lokalen MQTT2_SERVER-Retain-Cache als gemeinsamen Discovery-Batch erneut ein.
sub MQTT2_DISCOVERY_rescan($) {
	my ($hash) = @_;

	# Ein manueller Rescan darf die ausdrueckliche Deaktivierung nicht umgehen
	# und dadurch trotz disable=1 wieder Devices oder Attribute veraendern.
	if (MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		my $message = 'MQTT2_DISCOVERY ist durch disable=1 deaktiviert';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan skipped: $message");
		return $message;
	}
	my $iodev = $hash->{IODev};
	MQTT2_DISCOVERY_log($hash, 3, "rescan started; IODev=$hash->{IODevName}");

	# MQTT2_CLIENT verwaltet keinen lokalen Retain-Cache; dort kann nur der Broker
	# die Configs nach Reconnect oder erneuter Subscription wieder ausliefern.
	if (($iodev->{TYPE} || '') eq 'MQTT2_CLIENT') {
		my $message = 'MQTT2_CLIENT besitzt keinen lokalen Retain-Cache; Broker-Replay oder Reconnect erforderlich';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $retain = $iodev->{retain};

	# Ohne den erwarteten Hash ist keine vertrauenswuerdige Liste retained Topics
	# vorhanden, aus der ein lokaler Wiederholungslauf aufgebaut werden koennte.
	if (ref($retain) ne 'HASH') {
		my $message = 'Kein Retain-Cache vorhanden; respectRetain und retained Discovery pruefen';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $cid = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientId', $iodev->{NAME},
	);
	my ($processed, $failed) = (0, 0);

	# Alle retained Topics teilen eine Registry-Kopie und werden erst nach dem
	# vollstaendigen Scan pro Device angewendet.
	my $batch = { pending_identities => {}, created_identities => {} };

	for my $topic (sort keys %$retain) {
		my $entry = $retain->{$topic};
		my $payload = ref($entry) eq 'HASH' ? $entry->{val} : $entry;
		my $status = MQTT2_DISCOVERY_process($hash, $cid, $topic, $payload, $batch);
		++$processed if $status eq 'consumed';
		++$failed if $status eq 'error';
	}

	my $apply_error = MQTT2_DISCOVERY_finish_batch($hash, $batch);

	# Ein Fehler beim abschliessenden Device-Apply gehoert zur Rescan-Bilanz, auch
	# wenn alle einzelnen retained Nachrichten zuvor erfolgreich geparst wurden.
	if ($apply_error) {
		++$failed;
		MQTT2_DISCOVERY_reading($hash, 'lastError', $apply_error);
		MQTT2_DISCOVERY_log($hash, 1, "rescan apply failed: $apply_error");
	}
	my $message = "processed=$processed failed=$failed";
	MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
	MQTT2_DISCOVERY_log($hash, $failed ? 2 : 3, "rescan finished; $message");
	return undef;
}

# Konsumiert passende MQTT-Dispatchnachrichten und plant oder startet deren Verarbeitung.
sub MQTT2_DISCOVERY_Parse($$) {
	my ($iodev, $message) = @_;
	my $config = $modules{MQTT2_DISCOVERY}{defptr}{ $iodev->{NAME} };
	return '[NEXT]' if !$config;
	$message =~ s/^autocreate=[^\0]+\0//s;
	my ($cid, $topic, $payload) = split /\0/, $message, 3;
	return '[NEXT]' if !defined($topic) || !defined($payload);

	# Mit readingsViaParse schreibt das Modul die Readings selbst und gibt die
	# Nachricht danach weiter, damit manuelle Zeilen am Geraet erhalten bleiben.
	MQTT2_DISCOVERY_apply_parsed_readings($config, $topic, $payload)
		if MQTT2_DISCOVERY_gateway($config)->attr_value($config->{NAME}, 'readingsViaParse', 0);
	my @shelly = MQTT2_Discovery::Format::Shelly::route(
		MQTT2_DISCOVERY_shelly_args($config), topic => $topic, payload => $payload,
		state => $config->{helper}{formats}{shelly} || {},
	);
	my $native_topic = $topic =~ m{/(?:announce|online|events/rpc|(?:info|config|status|components)/rpc)$};
	return '[NEXT]' if $native_topic && !@shelly;

	# Auch deaktivierte Discovery-Nachrichten werden konsumiert, damit
	# MQTT2_DEVICE daraus keine unerwuenschten Fremd-Devices autocreated.
	if (MQTT2_DISCOVERY_gateway($config)->attr_value($config->{NAME}, 'disable', 0)) {
		MQTT2_DISCOVERY_log($config, 4, 'disabled; consuming discovery message without processing');
		return @shelly && $shelly[0] ne 'reply' ? '[NEXT]' : '';
	}
	return '[NEXT]' if !@shelly && !grep { MQTT2_Discovery::DevicePlanner::topic_has_prefix($topic, $_) }
		@{ MQTT2_DISCOVERY_prefixes($config) };

	# MQTT2_SERVER kann beim Start viele retained Configs in einem einzigen
	# Dispatch-Schub liefern. Die teure Parser-/Mapping-/Attributarbeit darf
	# dabei FHEMs Event-Loop nicht fuer den gesamten Schub blockieren.
	if (MQTT2_DISCOVERY_gateway($config)->can_schedule()) {
		MQTT2_DISCOVERY_enqueue($config, $cid, $topic, $payload);
		return @shelly && $shelly[0] ne 'reply' ? '[NEXT]' : '';
	}

	# Isolierte Testumgebungen ohne FHEM-Timer bleiben synchron nutzbar.
	my $status = MQTT2_DISCOVERY_process($config, $cid, $topic, $payload);
	return '[NEXT]' if @shelly && $shelly[0] ne 'reply';
	return '[NEXT]' if $status eq 'next';
	# Ein definierter Leerstring stoppt im aktuellen Dispatch die Parserkette ohne Device-Event.
	return '';
}

# --- Asynchrone Verarbeitung -------------------------------------------------

# Plant genau einen Queue-Worker; weitere Nachrichten werden bis zu dessen Lauf
# nur im bereits vorhandenen Queue-Zustand zusammengefuehrt.
sub MQTT2_DISCOVERY_schedule_queue($) {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return if ref($queue) ne 'HASH' || $queue->{scheduled};

	delete $queue->{waiting_for_init};
	$queue->{scheduled} = 1;
	MQTT2_DISCOVERY_gateway($hash)->schedule(
		$MQTT2_DISCOVERY_QUEUE_DELAY, $hash, 'MQTT2_DISCOVERY_process_queue',
	);
	return;
}

# Begrenzt FHEMs Notify-Auswertung auf Lebenszyklus und gebundenes MQTT-IODev.
sub MQTT2_DISCOVERY_set_notify_devices($) {
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
sub MQTT2_DISCOVERY_iodev_available($) {
	my ($hash) = @_;
	return 0 if ref($hash) ne 'HASH';
	my $iodev = $hash->{IODev};
	return 0 if ref($iodev) ne 'HASH';
	my $name = $iodev->{NAME} || '';

	# Eine im Hash verbliebene Perl-Referenz bedeutet nicht, dass das IODev noch
	# in FHEM definiert ist. Nur das aktuelle Objekt unter demselben Namen gilt.
	return 0 if $name eq '' || !$defs{$name} || $defs{$name} != $iodev;
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
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
sub MQTT2_DISCOVERY_availability_reading($) {
	my ($hash) = @_;
	my $name = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'availabilityReading',
		$MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING,
	);
	# none unterdrueckt das verdichtete sichtbare Reading vollstaendig.
	return '' if lc($name) eq 'none';
	return $name =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/
		? $name : $MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING;
}

# Erkennt Registry-Staende, deren zuletzt gerenderter Availability-Name nicht
# mehr dem aktuellen Attribut beziehungsweise Moduldefault entspricht.
sub MQTT2_DISCOVERY_registry_rendering_outdated($) {
	my ($hash) = @_;
	return 0 if ref($hash) ne 'HASH';
	my $expected = MQTT2_DISCOVERY_availability_reading($hash);
	my $registry = MQTT2_DISCOVERY_registry($hash);

	# Fehlende Felder kennzeichnen Registry-Staende vor der konfigurierbaren
	# Benennung und verwenden deshalb fuer den Vergleich den bisherigen Namen.
	for my $record (values %{ $registry->{devices} || {} }) {
		my $rendered = $record->{availability_reading} // 'availability';
		return 1 if $rendered ne $expected;
	}

	return 0;
}

# Erkennt eine explizite manuelle readingList-Belegung ausserhalb der zuletzt
# von dieser Discovery-Instanz erzeugten Zeilen.
sub MQTT2_DISCOVERY_record_has_manual_reading($$$) {
	my ($hash, $record, $reading) = @_;
	return 0 if ref($record) ne 'HASH' || !defined($record->{name});
	my %owned = map { ($_ => 1) } @{ $record->{owned_reading} || [] };
	my $current = MQTT2_DISCOVERY_gateway($hash)->attr_value(
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

# Prueft die globale Availability-Reservierung vor der Attributuebernahme fuer
# alle von dieser Discovery-Instanz verwalteten Zieldevices.
sub MQTT2_DISCOVERY_availability_reading_conflicts($$) {
	my ($hash, $reading) = @_;
	return () if ref($hash) ne 'HASH';
	my $mode = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'existingDevice', 'conservative',
	);
	return () if $mode ne 'conservative';
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my @conflicts;

	# Ein einziger manueller Anspruch verhindert die globale Umstellung, damit
	# nicht nur ein Teil der verwalteten Devices den neuen Namen verwendet.
	for my $record (values %{ $registry->{devices} || {} }) {
		push @conflicts, $record->{name}
			if MQTT2_DISCOVERY_record_has_manual_reading($hash, $record, $reading);
	}

	return sort(stable_unique(@conflicts));
}

# Gleicht einen veralteten Registry-Renderstand nur dann global ab, wenn kein
# manuelles Reading den aktuellen Default beziehungsweise Attributnamen belegt.
sub MQTT2_DISCOVERY_reconcile_registry_rendering($) {
	my ($hash) = @_;
	return if !MQTT2_DISCOVERY_registry_rendering_outdated($hash);
	my $reading = MQTT2_DISCOVERY_availability_reading($hash);
	my @conflicts = MQTT2_DISCOVERY_availability_reading_conflicts($hash, $reading);

	# Ein Lifecycle-Abgleich darf denselben konservativen Schutz wie eine direkte
	# Attributaenderung nicht umgehen und meldet deshalb den blockierenden Bestand.
	if (@conflicts) {
		my $message = 'Availability-Defaultabgleich durch manuelle readingList-Eintraege blockiert: '
			. join(', ', @conflicts);
		MQTT2_DISCOVERY_reading($hash, 'lastWarning', $message);
		MQTT2_DISCOVERY_log($hash, 2, $message);
		return;
	}

	MQTT2_DISCOVERY_enqueue_rerender($hash);
	return;
}

# Sammelt die verborgenen Entity-Regeln, die den sichtbaren Zustand bestimmen.
sub MQTT2_DISCOVERY_availability_policies($) {
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
sub MQTT2_DISCOVERY_device_availability_status($) {
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
sub MQTT2_DISCOVERY_availability_topics($) {
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
sub MQTT2_DISCOVERY_availability_topic_used($$) {
	my ($hash, $topic) = @_;
	my $registry = MQTT2_DISCOVERY_registry($hash);

	for my $record (values %{ $registry->{devices} || {} }) {
		return 1 if grep { $_ eq $topic } @{ MQTT2_DISCOVERY_availability_topics($record) };
	}

	return 0;
}

# Erkennt, ob ein Discovery-Batch noch Nachrichten vorbereitet oder Devices anwendet.
sub MQTT2_DISCOVERY_queue_busy($) {
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
sub MQTT2_DISCOVERY_schedule_availability_refresh($$;$) {
	my ($hash, $topic, $delay) = @_;
	return if ref($hash) ne 'HASH' || !defined($topic) || ref($topic) || $topic eq '';
	return if ref($hash->{IODev}) ne 'HASH'
		|| ($hash->{IODev}{TYPE} || '') ne 'MQTT2_CLIENT';
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	return if !$gateway->can_schedule();
	my $refreshes = $hash->{helper}{availability_refreshes} ||= {};
	my $timer = $refreshes->{$topic} ||= {
		discovery => $hash, topic => $topic, scheduled => 0,
	};
	return if $timer->{scheduled};
	delete $timer->{waiting_for_io};
	$timer->{scheduled} = 1;
	$gateway->schedule(
		defined($delay) ? $delay : $MQTT2_DISCOVERY_AVAILABILITY_REFRESH_DELAY,
		$timer, 'MQTT2_DISCOVERY_refresh_availability_topic',
	);
	return;
}

# Entfernt alle noch ausstehenden Topic-Timer einer Discovery-Instanz.
sub MQTT2_DISCOVERY_clear_availability_refreshes($) {
	my ($hash) = @_;
	my $refreshes = $hash->{helper}{availability_refreshes};
	return if ref($refreshes) ne 'HASH';

	for my $timer (values %$refreshes) {
		MQTT2_DISCOVERY_gateway($hash)->cancel_timer(
			$timer, 'MQTT2_DISCOVERY_refresh_availability_topic',
		) if ref($timer) eq 'HASH' && $timer->{scheduled};
	}

	delete $hash->{helper}{availability_refreshes};
	return;
}

# Setzt bei wieder geoeffnetem IODev zuvor verbindungslos geparkte Abrufe fort.
sub MQTT2_DISCOVERY_resume_availability_refreshes($) {
	my ($hash) = @_;
	return if !MQTT2_DISCOVERY_iodev_available($hash);
	my $refreshes = $hash->{helper}{availability_refreshes};
	return if ref($refreshes) ne 'HASH';

	for my $topic (sort keys %$refreshes) {
		my $timer = $refreshes->{$topic};
		next if ref($timer) ne 'HASH' || !$timer->{waiting_for_io};
		MQTT2_DISCOVERY_schedule_availability_refresh(
			$hash, $topic, $MQTT2_DISCOVERY_AVAILABILITY_RETRY_DELAY,
		);
	}

	return;
}

# Fordert nach allen Sicherheitspruefungen genau das Retained Availability-Topic an.
sub MQTT2_DISCOVERY_refresh_availability_topic($) {
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
			|| MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		delete $refreshes->{$topic};
		delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
		return;
	}

	# Der aktive Registry-Stand ist erst nach Abschluss des Queue-Batches sicher.
	# Solange der Worker laeuft, wird derselbe Topic-Timer kurz zurueckgestellt.
	if (MQTT2_DISCOVERY_queue_busy($hash)) {
		MQTT2_DISCOVERY_schedule_availability_refresh(
			$hash, $topic, $MQTT2_DISCOVERY_AVAILABILITY_RETRY_DELAY,
		);
		return;
	}

	# Eine inzwischen entfernte oder geaenderte Entity darf kein veraltetes Topic
	# mehr abonnieren. Die aktuelle Registry ist dafuer die einzige Quelle.
	if (!MQTT2_DISCOVERY_availability_topic_used($hash, $topic)) {
		delete $refreshes->{$topic};
		delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
		return;
	}

	# Ohne Brokerverbindung bleibt der Abruf ereignisbasiert geparkt. Notify setzt
	# ihn nach dem naechsten opened-Zustand fort, ohne dauerhaft zu pollen.
	if (!MQTT2_DISCOVERY_iodev_available($hash)) {
		$timer->{waiting_for_io} = 1;
		return;
	}

	my $error = MQTT2_DISCOVERY_gateway($hash)->refresh_retained_topic(
		$hash->{IODev}, $topic,
	);
	MQTT2_DISCOVERY_log($hash, $error ? 2 : 4, $error
		? "retained availability refresh failed for topic=$topic: $error"
		: "retained availability refresh requested for topic=$topic");
	delete $refreshes->{$topic};
	delete $hash->{helper}{availability_refreshes} if !keys %$refreshes;
	return;
}

# Verknuepft den IO-Zustand mit den erhaltenen Entity-Availability-Regeln.
sub MQTT2_DISCOVERY_sync_target_availability($$$) {
	my ($hash, $record, $io_available) = @_;
	return if ref($record) ne 'HASH' || !keys %{ $record->{entities} || {} };
	my $name = $record->{name};
	my $target = $defs{$name};
	return if !$target || ($target->{TYPE} || '') ne 'MQTT2_DEVICE';
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	my $io_status = $io_available ? 'online' : 'offline';
	my $availability_reading = $record->{availability_reading}
		// MQTT2_DISCOVERY_availability_reading($hash);

	# Das interne Reading verhindert, dass eine bereits zugestellte MQTT-Nachricht
	# einen inzwischen getrennten Brokerzugang wieder sichtbar online setzt.
	if ($gateway->reading_value($name, '.availability_io', '') ne $io_status) {
		$gateway->update_reading($target, '.availability_io', $io_status, 0);
	}
	my $policies = MQTT2_DISCOVERY_availability_policies($record);
	my $status = $io_available ? 'online' : 'offline';

	# Ohne erhaltenen Retained-Wert bleibt eine vorhandene HA-Regel unbekannt.
	# Mindestens eine verfuegbare Entity macht das Device online; offline erfordert
	# dagegen den sicheren Ausfall aller darin zusammengefassten Entity-Regeln.
	if ($io_available && @$policies) {
		my @states = map {
			$gateway->reading_value($name, $_, 'unknown')
		} @$policies;
		$status = MQTT2_DISCOVERY_device_availability_status(\@states);
	}
	$gateway->update_reading($target, $availability_reading, $status, 1)
		if $availability_reading ne ''
			&& $gateway->reading_value($name, $availability_reading, '') ne $status;
	return;
}

# Uebertraegt eine IO-Zustandsaenderung genau einmal auf alle Registry-Ziele.
sub MQTT2_DISCOVERY_sync_io_availability($;$$) {
	my ($hash, $force, $override) = @_;
	my $available = defined($override)
		? ($override ? 1 : 0)
		: MQTT2_DISCOVERY_iodev_available($hash);
	return if !$force && defined($hash->{helper}{io_available})
		&& $hash->{helper}{io_available} == $available;
	$hash->{helper}{io_available} = $available;
	my $registry = MQTT2_DISCOVERY_registry($hash);

	for my $record (values %{ $registry->{devices} || {} }) {
		MQTT2_DISCOVERY_sync_target_availability($hash, $record, $available);
	}

	MQTT2_DISCOVERY_log($hash, 3, 'IODev availability=' . ($available ? 'online' : 'offline')
		. '; targets=' . scalar(keys %{ $registry->{devices} || {} }));
	return;
}

# Startet vor INITIALIZED gesammelte Arbeit und uebernimmt IO-Zustandsereignisse.
sub MQTT2_DISCOVERY_Notify($$) {
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
		MQTT2_DISCOVERY_sync_io_availability($hash);
		MQTT2_DISCOVERY_resume_availability_refreshes($hash);
		MQTT2_DISCOVERY_start_shelly($hash);
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

	# Beim Loeschen des IODev darf weder eine vorgemerkte Config noch dessen
	# letzte Perl-Referenz einen scheinbar verfuegbaren Zustand erhalten.
	if ($io_deleted) {
		MQTT2_DISCOVERY_clear_queue($hash);
		MQTT2_DISCOVERY_clear_availability_refreshes($hash);
		MQTT2_DISCOVERY_sync_io_availability($hash, 1, 0);
		MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
		MQTT2_DISCOVERY_log($hash, 2, "bound IODev $io_name was deleted; targets offline");
	}

	# Beim Start sind IODev-Attribute und clientOrder vollstaendig geladen. Die
	# erneute, deduplizierte Pruefung erfasst deshalb auch gespeicherte Filter.
	# Globale Attributereignisse machen spaetere Aenderungen sofort sichtbar.
	MQTT2_DISCOVERY_check_ignore_regexp($hash)
		if $lifecycle || $ignore_regexp_changed;
	MQTT2_DISCOVERY_sync_io_availability($hash, 1)
		if !$io_deleted && ($lifecycle || $io_availability_changed);
	MQTT2_DISCOVERY_resume_availability_refreshes($hash)
		if !$io_deleted && ($lifecycle || $io_availability_changed);
	MQTT2_DISCOVERY_reconcile_registry_rendering($hash)
		if !$io_deleted && $lifecycle;

	# INITIALIZED folgt beim Start auf das statefile; REREADCFG wird unmittelbar
	# vor der Rueckkehr in den Eventloop ausgeloest und darf denselben Start planen.
	return undef if !$lifecycle;
	MQTT2_DISCOVERY_start_shelly($hash);
	my $queue = $hash->{helper}{queue};
	return undef if ref($queue) ne 'HASH' || !$queue->{waiting_for_init};

	MQTT2_DISCOVERY_schedule_queue($hash);
	return undef;
}

# Koalesziert Config-Nachrichten pro Topic und plant genau einen kurzen Queue-Timer.
sub MQTT2_DISCOVERY_enqueue($$$$) {
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

	MQTT2_DISCOVERY_schedule_queue($hash);
	return;
}

# Merkt eine vollstaendige Neuerzeugung aus der Registry vor. Dadurch muessen
# bereits empfangene Discovery-Nachrichten nicht erneut vom Broker kommen.
sub MQTT2_DISCOVERY_enqueue_rerender($) {
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
	return if !MQTT2_DISCOVERY_gateway($hash)->can_schedule();

	MQTT2_DISCOVERY_schedule_queue($hash);
	return;
}

# Verarbeitet pro Timerlauf eine Nachricht oder ein vorbereitetes Zieldevice atomar.
sub MQTT2_DISCOVERY_process_queue($) {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return if ref($queue) ne 'HASH';

	# Nach Loeschen, Ersetzen oder Deaktivieren des Devices darf ein alter Timer
	# keine bereits ueberholten Discovery-Nachrichten mehr anwenden.
	if (!$defs{ $hash->{NAME} } || $defs{ $hash->{NAME} } != $hash
			|| MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		MQTT2_DISCOVERY_clear_queue($hash);
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
		$batch->{registry} ||= MQTT2_DISCOVERY_clone_registry(
			MQTT2_DISCOVERY_registry($hash),
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
	MQTT2_DISCOVERY_process($hash, $message->[0], $message->[1], $message->[2], $batch)
		if $message;

	my $error;

	# Sind keine MQTT-Nachrichten mehr offen, wird pro Timerlauf genau ein bereits
	# zusammengefuehrtes Zieldevice angewendet, damit FHEMs Event-Loop responsiv bleibt.
	if (!$message && keys %{ $batch->{pending_identities} || {} }) {
		my ($identity) = sort keys %{ $batch->{pending_identities} };
		$error = MQTT2_DISCOVERY_apply_batch_identity($hash, $batch, $identity);
		delete $batch->{pending_identities}{$identity} if !$error;
	}

	# Ein fehlgeschlagener Apply beendet den gesamten Queue-Batch; nur in diesem
	# Lauf erzeugte Devices werden dabei als Teil der Transaktion zurueckgerollt.
	if ($error) {
		# Neu angelegte Devices gehoeren zur fehlgeschlagenen Transaktion und
		# werden entfernt; bestehende Devices bleiben durch den ActionPlan intakt.
		MQTT2_DISCOVERY_cleanup_created_devices($hash, $batch->{registry}, $batch->{created_identities});
		$hash->{helper}{registry} = $batch->{registry};
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_log($hash, 1, "queue apply failed: $error");
		$hash->{helper}{rerender_pending} = 1 if $batch->{rerender_all};
		MQTT2_DISCOVERY_clear_queue($hash);
	} elsif (@{ $queue->{order} || [] } || keys %{ $batch->{pending_identities} || {} }) {
		MQTT2_DISCOVERY_gateway($hash)->schedule(
			$MQTT2_DISCOVERY_QUEUE_DELAY, $hash, 'MQTT2_DISCOVERY_process_queue',
		);
	} else {
		$hash->{helper}{registry} = $batch->{registry} if ref($batch->{registry}) eq 'HASH';
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
		$queue->{scheduled} = 0;
		# Initialwerte werden erst angefordert, wenn alle Reading-Bindings des Batches vorhanden sind.
		my $request_error = MQTT2_DISCOVERY_send_requests($hash, $batch->{after_apply});
		MQTT2_DISCOVERY_reading($hash, 'lastError', $request_error) if $request_error;
		delete $queue->{batch};
	}
	return;
}

# Bricht geplante Queue-Arbeit ab und entfernt den vollstaendigen Batchzustand.
sub MQTT2_DISCOVERY_clear_queue($) {
	my ($hash) = @_;
	MQTT2_DISCOVERY_gateway($hash)->cancel_timer($hash, 'MQTT2_DISCOVERY_process_queue');
	delete $hash->{helper}{queue} if ref($hash->{helper}) eq 'HASH';
	delete $hash->{helper}{shelly_started};
	# Antworten abgebrochener Abfragen duerfen nach einer Reaktivierung keinen alten Snapshot anwenden.
	if (ref($hash->{helper}{formats}{shelly}) eq 'HASH') {
		$hash->{helper}{formats}{shelly} = { sequence => $hash->{helper}{formats}{shelly}{sequence} || 0 };
	}
	return;
}

# Vorwaertsdeklaration der inneren Verarbeitung fuer den davor definierten Fehlerwrapper.
sub MQTT2_DISCOVERY_process_inner($$$$;$);

# Issues werden pro Topic gespeichert. Ein spaeter erfolgreich verarbeitetes
# Topic kann dadurch genau seinen vorherigen Fehler oder seine Warnung loeschen.
# Synchronisiert Fehler- und Warnungszaehler mit den Topic-bezogenen Issue-Tabellen.
sub MQTT2_DISCOVERY_update_issue_readings($) {
	my ($hash) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	MQTT2_DISCOVERY_reading($hash, 'errorCount', scalar keys %{ $issues->{error} || {} });
	MQTT2_DISCOVERY_reading($hash, 'warningCount', scalar keys %{ $issues->{warning} || {} });
	return;
}

# Speichert einen Fehler oder eine Warnung samt Topic und Adapter in Readings und Speicher.
sub MQTT2_DISCOVERY_record_issue($$$$$) {
	my ($hash, $level, $topic, $adapter, $reason) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	$issues->{$level}{$topic} = {
		adapter => $adapter || 'unknown', reason => $reason || 'Unbekannter Fehler',
	};
	my $prefix = $level eq 'error' ? 'lastError' : 'lastWarning';
	MQTT2_DISCOVERY_reading($hash, $prefix, $reason || 'Unbekannter Fehler');
	MQTT2_DISCOVERY_reading($hash, $prefix . 'Adapter', $adapter || 'unknown');
	MQTT2_DISCOVERY_reading($hash, $prefix . 'Topic', $topic);
	MQTT2_DISCOVERY_update_issue_readings($hash);
	return;
}

# Entfernt ein geloestes Topic-Issue und aktualisiert die zugehoerigen Zaehler.
sub MQTT2_DISCOVERY_clear_issue($$$) {
	my ($hash, $level, $topic) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	delete $issues->{$level}{$topic};
	MQTT2_DISCOVERY_reading($hash, 'lastWarning', 'none')
		if $level eq 'warning' && !keys %{ $issues->{warning} || {} };
	MQTT2_DISCOVERY_update_issue_readings($hash);
	return;
}

# Kapselt die gesamte Topic-Verarbeitung in einer Exception-Grenze und pflegt Issues.
sub MQTT2_DISCOVERY_process($$$$;$) {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	delete $hash->{helper}{process_adapter};
	delete $hash->{helper}{process_warning};
	my $status;

	# Diese Exception-Grenze verhindert, dass fehlerhafte Fremddaten FHEMs
	# gesamten MQTT-Dispatch abbrechen.
	my $ok = eval {
		$status = MQTT2_DISCOVERY_process_inner($hash, $cid, $topic, $payload, $batch);
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
			MQTT2_DISCOVERY_record_issue(
				$hash, 'error', $topic,
				$hash->{helper}{process_adapter}
					|| MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastErrorAdapter', 'unknown'),
				MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastError', 'Unbekannter Fehler'),
			);
		} elsif ($status eq 'consumed') {
			MQTT2_DISCOVERY_clear_issue($hash, 'error', $topic);
			my $warning = delete $hash->{helper}{process_warning};

			# Ein erfolgreich konsumiertes Topic kann dennoch degradierte oder nicht
			# unterstuetzte Bestandteile enthalten, die als Warnung sichtbar bleiben sollen.
			if (defined($warning) && $warning ne '') {
				MQTT2_DISCOVERY_record_issue(
					$hash, 'warning', $topic,
					MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastAdapter', 'unknown'), $warning,
				);
			} else {
				MQTT2_DISCOVERY_clear_issue($hash, 'warning', $topic);
			}
			MQTT2_DISCOVERY_reading($hash, 'lastError', 'none')
				if !keys %{ $hash->{helper}{issues}{error} || {} };
		}
		return $status;
	}

	my $detail = $ok ? 'Verarbeitung lieferte keinen Status' : ($@ || 'unbekannter Fehler');
	$detail =~ s/[\r\n]+/ /g;
	$detail = substr($detail, 0, 1000) . '... <truncated>' if length($detail) > 1000;
	my $error = "Unerwarteter Fehler in der MQTT-Verarbeitung: $detail";
	eval { MQTT2_DISCOVERY_reading($hash, 'lastError', $error) };
	eval { MQTT2_DISCOVERY_record_issue(
		$hash, 'error', $topic, $hash->{helper}{process_adapter} || 'unknown', $error,
	) };
	eval { MQTT2_DISCOVERY_log($hash, 1, $error) };
	return 'error';
}

# Fuehrt Formatwahl, Modellierung, Mapping und transaktionales Device-Apply fuer ein Topic aus.
sub MQTT2_DISCOVERY_process_inner($$$$;$) {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	MQTT2_DISCOVERY_log($hash, 3, "processing topic=$topic");
	MQTT2_DISCOVERY_log($hash, 4, 'message cid=' . (defined($cid) ? $cid : '') . '; payloadLength=' . length(defined($payload) ? $payload : ''));
	MQTT2_DISCOVERY_log($hash, 5, 'discovery payload=' . MQTT2_DISCOVERY_log_payload($payload))
		if MQTT2_DISCOVERY_log_enabled($hash, 5);
	my $prefixes = MQTT2_DISCOVERY_prefixes($hash);
	my $parsed = MQTT2_Discovery::FormatRegistry::consume(
		topic => $topic, payload => $payload, prefixes => $prefixes,
		MQTT2_DISCOVERY_shelly_args($hash), cid => $cid,
		states => ($hash->{helper}{formats} ||= {}),
		(ref($hash->{helper}{format_adapters}) eq 'ARRAY'
			? (adapters => $hash->{helper}{format_adapters}) : ()),
	);
	$hash->{helper}{process_adapter} = $parsed->{adapter} if $parsed->{adapter};

	# Kein Adapter beansprucht das Topic; es muss fuer nachfolgende MQTT-Parser
	# freigegeben werden und darf keine Discovery-Readings veraendern.
	if ($parsed->{status} eq 'next') {
		MQTT2_DISCOVERY_log($hash, 4, "topic does not match configured prefixes; passing to next parser: $topic");
		return 'next';
	}
	MQTT2_DISCOVERY_reading($hash, 'lastTopic', $topic);

	# Parserfehler liefern kein belastbares kanonisches Modell und duerfen daher
	# weder Registry noch Zieldevices teilweise veraendern.
	if ($parsed->{status} ne 'ok') {
		my $error = $parsed->{error} || 'Unbekannter Parserfehler';
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_reading($hash, 'lastErrorAdapter', $parsed->{adapter} || 'unknown');
		MQTT2_DISCOVERY_reading($hash, 'lastErrorTopic', $topic);
		MQTT2_DISCOVERY_reading($hash, 'unsupportedCount', scalar @{ $parsed->{warnings} || [] }) if $parsed->{warnings};
		MQTT2_DISCOVERY_log($hash, 1, "parser error for topic=$topic: $error");
		return 'error';
	}
	my $request_error = MQTT2_DISCOVERY_send_requests($hash, $parsed->{requests});
	# Netzwerkfehler bleiben sichtbar; ohne vollstaendigen Snapshot wird keine Registry kopiert.
	if ($request_error) {
		MQTT2_DISCOVERY_reading($hash, 'lastError', $request_error);
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
			$batch->{registry} ||= MQTT2_DISCOVERY_clone_registry(MQTT2_DISCOVERY_registry($hash));
			$registry = $batch->{registry};
		} else {
			$registry = MQTT2_DISCOVERY_clone_registry(MQTT2_DISCOVERY_registry($hash));
		}
		1;
	};

	# Ohne vollstaendige Registry-Kopie fehlt die Rollback-Grenze; die Verarbeitung
	# muss abbrechen, bevor irgendein Device den neuen Stand sieht.
	if (!$clone_ok) {
		my $detail = $@ || 'unbekannter JSON-Fehler';
		$detail =~ s/[\r\n]+/ /g;
		my $error = "Registry konnte nicht kopiert werden: $detail";
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_log($hash, 1, $error);
		return 'error';
	}
	my @warnings = @{ $parsed->{warnings} || [] };
	my %pending_identities;
	my %created_identities;

	# Parser koennen aus einer Nachricht mehrere Upserts und Deletes liefern.
	# Zunaechst werden alle davon nur in der Registry-Kopie gesammelt.
	for my $event (@{ $parsed->{events} || [] }) {
		my $operation = $event->{operation} || 'upsert';
		MQTT2_DISCOVERY_log($hash, 4, 'entity operation=' . $operation
			. '; component=' . ($event->{entity}{kind} || '') . '; key=' . ($event->{source}{key} || ''));

		# Loeschereignisse entfernen bestehende Registry-Eintraege und durchlaufen
		# deshalb nicht das fuer Upserts bestimmte Mapping und Rendering.
		if ($operation eq 'delete' || $operation eq 'delete_device') {
			my ($entity, $model_error) = MQTT2_Discovery::Model::to_entity($event);

			# Eine nicht kanonisierbare Loeschung koennte die falsche Entity treffen;
			# in diesem Fall bleibt der bisherige Registry-Stand unveraendert.
			if ($model_error) {
				MQTT2_DISCOVERY_reading($hash, 'lastError', $model_error);
				MQTT2_DISCOVERY_log($hash, 1, "canonical delete failed for topic=$topic: $model_error");
				return 'error';
			}
			my $error = MQTT2_DISCOVERY_delete_entity($hash, $registry, $entity, $batch);

			# Fehler beim Neurendern oder automatischen Loeschen machen die gesamte
			# Delete-Operation unvollstaendig und werden als Topic-Fehler zurueckgegeben.
			if ($error) {
				MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
				MQTT2_DISCOVERY_log($hash, 1, "delete failed for topic=$topic: $error");
				return 'error';
			}
			next;
		}
		# Die Wertabbildung entsteht bereits beim Mapping, der Schalter muss deshalb
		# hier schon gelten.
		local $MQTT2_Discovery::Mapper::FHEM_CONVENTIONS = MQTT2_DISCOVERY_gateway($hash)->attr_value(
			$hash->{NAME}, 'fhemConventions', 0,
		) ? 1 : 0;
		my $mapping = MQTT2_Discovery::Mapper::map_model(
			model => $event, io_name => $hash->{IODevName},
			name_prefix => MQTT2_DISCOVERY_gateway($hash)->attr_value(
				$hash->{NAME}, 'deviceNamePrefix', '',
			),
		);

		# Nicht abbildbare Komponenten werden isoliert uebersprungen, damit andere
		# Entities derselben Discovery-Nachricht weiterhin nutzbar bleiben.
		if (!$mapping->{ok}) {
			push @warnings, $mapping->{error};
			MQTT2_DISCOVERY_log($hash, 2, 'mapping warning: ' . ($mapping->{error} || 'unknown mapping error'));
			next;
		}
		MQTT2_DISCOVERY_log($hash, 4, 'mapped component=' . ($mapping->{metadata}{component} || '')
			. '; target=' . ($mapping->{proposed_name} || '') . '; readings=' . scalar(@{ $mapping->{reading_lines} || [] })
			. '; sets=' . scalar(@{ $mapping->{set_lines} || [] }));
		push @warnings, @{ $mapping->{warnings} || [] };
		my $created_now = 0;
		my $error = MQTT2_DISCOVERY_stage_mapping(
			$hash, $registry, $mapping, $cid, \$created_now,
		);

		# Ein Staging-Fehler kann bereits ein neues Device angelegt haben; solche
		# Seiteneffekte dieses Laufs werden entfernt, bevor der Fehler weitergereicht wird.
		if ($error) {
			MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, \%created_identities);
			MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
			MQTT2_DISCOVERY_log($hash, 1, "apply failed for topic=$topic: $error");
			return 'error';
		}
		$pending_identities{ $mapping->{identity} } = 1;
		$created_identities{ $mapping->{identity} } = 1 if $created_now;
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
			my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);

			# Scheitert ein Zieldevice, gehoeren alle in dieser Nachricht neu erzeugten
			# Devices zum fehlgeschlagenen Apply und werden gemeinsam bereinigt.
			if ($error) {
				MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, \%created_identities);
				MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
				MQTT2_DISCOVERY_log($hash, 1, "apply failed for topic=$topic: $error");
				return 'error';
			}
		}

	}

	# Bei Einzelverarbeitung ist der neue Entwurf jetzt vollstaendig angewendet und
	# darf den sichtbaren Registry-Stand ersetzen; ein Batch tut das erst am Ende.
	if (!$batch) {
		$hash->{helper}{registry} = $registry;
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
		my $error = MQTT2_DISCOVERY_send_requests($hash, $parsed->{after_apply});
		if ($error) {
			MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
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
		MQTT2_DISCOVERY_reading($hash, 'lastWarning', $warning);
		MQTT2_DISCOVERY_log($hash, 2, "warning: $warning");
	}
	MQTT2_DISCOVERY_reading($hash, 'lastAdapter', $parsed->{adapter} || 'unknown');
	MQTT2_DISCOVERY_log($hash, 3, 'processing finished; topic=' . $topic
		. '; entities=' . scalar(@{ $parsed->{events} || [] }));
	return 'consumed';
}

# Prueft, ob eine geladene Registry die fuer sichere Weiterverarbeitung erwartete Struktur hat.
sub MQTT2_DISCOVERY_registry_valid($) {
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
sub MQTT2_DISCOVERY_registry($) {
	my ($hash) = @_;
	return $hash->{helper}{registry} if ref($hash->{helper}{registry}) eq 'HASH';
	my $may_cache = $main::init_done ? 1 : 0;
	my $stored = MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, '.registry', '');
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
	if (!MQTT2_DISCOVERY_registry_valid($registry)) {
		MQTT2_DISCOVERY_log($hash, 2, 'stored registry is empty or invalid; starting with an empty registry') if $stored ne '';
		$registry = { version => 1, devices => {} };
	}
	# Vor INITIALIZED ist das statefile noch nicht geladen. Der leere Zwischenstand
	# darf deshalb nicht den kurz darauf restaurierten Registry-Stand verdecken.
	$hash->{helper}{registry} = $registry if $may_cache;
	return $registry;
}

# Erstellt ueber kanonisches JSON eine tiefe Kopie des reinen Registry-Datenmodells.
sub MQTT2_DISCOVERY_clone_registry($) {
	my ($registry) = @_;
	my $json = JSON::PP->new->canonical(1);
	return $json->decode($json->encode($registry));
}

# Persistiert den kanonischen Registry-Stand in einer internen, nicht ausloesenden Reading.
sub MQTT2_DISCOVERY_persist_registry($) {
	my ($hash) = @_;
	my $json = JSON::PP->new->canonical(1)->encode(MQTT2_DISCOVERY_registry($hash));
	MQTT2_DISCOVERY_gateway($hash)->update_reading($hash, '.registry', $json, 0);
}

# Waehlt bei Namenskonflikten einen stabilen, reproduzierbaren Zieldevicenamen.
sub MQTT2_DISCOVERY_target_name($$$) {
	my ($mapping, $registry, $allow_existing) = @_;
	my $base = $mapping->{proposed_name};
	return $base if !$defs{$base} || $allow_existing;

	# Der Hash bleibt ueber Neustarts stabil; ein Zaehler ist nur der seltene
	# Fallback, wenn sogar dieser Name bereits belegt ist.
	my $suffix = stable_suffix($mapping->{identity});
	my $candidate = "${base}_$suffix";
	my $counter = 2;
	$candidate = "${base}_${suffix}_" . $counter++ while $defs{$candidate};
	return $candidate;
}

# Erzeugt fuer Transporte ohne Publisher-CID einen stabilen lokalen Routing-Schluessel.
sub MQTT2_DISCOVERY_virtual_cid($) {
	my ($mapping) = @_;
	return undef if !defined($mapping->{identity}) || $mapping->{identity} eq '';
	return 'mqtt2_discovery_' . stable_suffix($mapping->{identity}, 16);
}

# Leitet aus Bridge-Regeln oder fehlender Publisher-Identitaet die Ziel-CID ab.
sub MQTT2_DISCOVERY_autocreate_cid($$$) {
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
					$new_cid = eval $rule->{name};
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
		my $virtual_cid = MQTT2_DISCOVERY_virtual_cid($mapping);
		return (undef, 'Discovery-Geraeteidentitaet kann keine virtuelle Client-ID bilden')
			if !defined($virtual_cid);
		return ($virtual_cid, undef);
	}
	return ($transport_cid, undef);
}

# Findet unter Beruecksichtigung fremder Registry-Besitzer ein eindeutiges CID-Zieldevice.
sub MQTT2_DISCOVERY_existing_cid_target($$$$$) {
	my ($hash, $registry, $identity, $mapping, $cid) = @_;
	my $devices = MQTT2_DISCOVERY_gateway($hash)->mqtt2_devices_for_cid($cid);
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
sub MQTT2_DISCOVERY_stage_mapping($$$$;$) {
	my ($hash, $registry, $mapping, $cid, $created_now_ref) = @_;
	my $identity = $mapping->{identity};
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
		($target_cid, $cid_error) = MQTT2_DISCOVERY_autocreate_cid($mapping, $cid, $io_type);
	}
	return $cid_error if $cid_error;
	my ($cid_target, $target_error) = MQTT2_DISCOVERY_existing_cid_target(
		$hash, $registry, $identity, $mapping, $target_cid,
	);
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
				MQTT2_DISCOVERY_log($hash, 2,
					"stale registry target $stale_name is missing; reprocessing identity=$identity");
				$record = undef;
				my $io_type = $defs{ $hash->{IODevName} }{TYPE} || '';
				($target_cid, $cid_error) = MQTT2_DISCOVERY_autocreate_cid($mapping, $cid, $io_type);
				return $cid_error if $cid_error;
				($cid_target, $target_error) = MQTT2_DISCOVERY_existing_cid_target(
					$hash, $registry, $identity, $mapping, $target_cid,
				);
				return $target_error if $target_error;
			} else {
				MQTT2_DISCOVERY_log($hash, 2,
					"recovered renamed target device $record->{name} as $cid_target->{NAME} by cid=$target_cid");
				$record->{name} = $cid_target->{NAME};
			}
		}
		$record->{cid} = $target_cid if $record;
	}

	# Nur bisher unbekannte Identitaeten durchlaufen Uebernahme, Namenskonflikt
	# und gegebenenfalls die automatische Anlage eines MQTT2_DEVICE.
	if (!$record) {
		my $mode = MQTT2_DISCOVERY_gateway($hash)->attr_value(
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
			: MQTT2_DISCOVERY_target_name($mapping, $registry, $adopt_by_name);

		# Erst wenn weder CID-Aufloesung noch Bestandsdevice ein Ziel liefern, ist
		# eine Neuanlage erforderlich und dabei die autoCreate-Vorgabe massgeblich.
		if (!$defs{$name}) {
			return "autoCreate ist deaktiviert; $name wurde nicht angelegt"
				if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'autoCreate', 1);
			my $error = MQTT2_DISCOVERY_gateway($hash)->define_mqtt2_device(
				$name, $target_cid, $hash->{IODevName},
			);
			return $error if $error;
			$created_now = 1;
		}
		return "$name ist kein MQTT2_DEVICE" if ($defs{$name}{TYPE} || '') ne 'MQTT2_DEVICE';
		$record = {
			name => $name, created => $created_now ? 1 : 0, io => $hash->{IODevName},
			cid => $target_cid,
			entities => {}, owned_reading => [], owned_set => [], owned_devicetopic => undef,
		};
		$registry->{devices}{$identity} = $record;
		MQTT2_DISCOVERY_log($hash, 2, ($created_now ? 'created and registered' : 'adopted') . " target device $name");
	}
	$record->{entities}{ $mapping->{entity_key} } = $mapping;
	MQTT2_DISCOVERY_log($hash, 4, "staged target=$record->{name}; entity=$mapping->{entity_key}");
	$$created_now_ref = $created_now if ref($created_now_ref) eq 'SCALAR';
	return undef;
}

# Entfernt nach Fehlern ausschliesslich Devices, die in der aktuellen Transaktion entstanden.
sub MQTT2_DISCOVERY_cleanup_created_devices($$$) {
	my ($hash, $registry, $created_identities) = @_;

	# Ausschliesslich in diesem Lauf neu angelegte Devices duerfen bei einem
	# Fehler wieder entfernt werden; uebernommene Devices sind tabu.
	for my $identity (sort keys %{ $created_identities || {} }) {
		my $record = $registry->{devices}{$identity};
		MQTT2_DISCOVERY_gateway($hash)->delete_device($record->{name})
			if $record && $defs{ $record->{name} };
		delete $registry->{devices}{$identity};
	}

	return;
}

# Loescht einen leeren, vollstaendig automatisch verwalteten Registry-Datensatz optional mit Device.
sub MQTT2_Discovery_autoDeleteRecord {
	my ($hash, $registry, $identity, $record, $hadManual) = @_;
	return undef if keys %{ $record->{entities} };
	return undef if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'autoDelete', 0);
	return undef if !$record->{created} || $hadManual;
	return undef if MQTT2_DISCOVERY_record_has_manual_lines($hash, $record);

	# autoDelete gilt nur fuer vollstaendig von Discovery erzeugte Devices ohne
	# verbliebene manuelle Attribute oder Zeilen.
	my $error = MQTT2_DISCOVERY_gateway($hash)->delete_device($record->{name});
	return $error if $error;
	MQTT2_DISCOVERY_log($hash, 2, "deleted automatically managed MQTT2_DEVICE $record->{name}");
	delete $registry->{devices}{$identity};
	return undef;
}

# Wendet alle vorgemerkten Batch-Identitaeten an und veroeffentlicht den Registry-Stand.
sub MQTT2_DISCOVERY_finish_batch($$) {
	my ($hash, $batch) = @_;
	return undef if ref($batch) ne 'HASH';
	my $registry = ref($batch->{registry}) eq 'HASH'
		? $batch->{registry} : MQTT2_DISCOVERY_registry($hash);

	for my $identity (sort keys %{ $batch->{pending_identities} || {} }) {
		my $error = MQTT2_DISCOVERY_apply_batch_identity($hash, $batch, $identity);

		# Ein einziges fehlgeschlagenes Zieldevice macht den gemeinsamen Registry-
		# Entwurf unvollstaendig; neu erzeugte Devices werden vor dem Abbruch bereinigt.
		if ($error) {
			MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, $batch->{created_identities});
			$hash->{helper}{registry} = $registry;
			MQTT2_DISCOVERY_persist_registry($hash);
			MQTT2_DISCOVERY_update_counts($hash);
			return $error;
		}
	}

	$hash->{helper}{registry} = $registry;
	MQTT2_DISCOVERY_persist_registry($hash);
	MQTT2_DISCOVERY_update_counts($hash);
	return MQTT2_DISCOVERY_send_requests($hash, delete $batch->{after_apply});
}

# Rendert ein einzelnes Batch-Ziel und fuehrt danach die geschuetzte autoDelete-Entscheidung aus.
sub MQTT2_DISCOVERY_apply_batch_identity($$$) {
	my ($hash, $batch, $identity) = @_;
	my $registry = $batch->{registry};
	return undef if ref($registry) ne 'HASH';
	my $record = $registry->{devices}{$identity};
	return undef if !$record;
	my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);
	return $error if $error;

	my $hadManual = delete $batch->{delete_had_manual}{$identity};
	return MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
}

# Ermittelt die aus Discovery sicher bekannten sichtbaren Reading-Namen.
sub MQTT2_DISCOVERY_expected_reading_names($) {
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
sub MQTT2_DISCOVERY_initialize_device_readings($$$$) {
	my ($hash, $record, $names, $conflicts) = @_;
	my $enabled = MQTT2_DISCOVERY_gateway($hash)->attr_value(
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
		MQTT2_DISCOVERY_gateway($hash)->update_reading(
			$target, $name, '', 1,
		);
		push @created, $name;
	}

	MQTT2_DISCOVERY_log($hash, 4, 'initialized target readings='
		. join(',', @created) . "; target=$record->{name}") if @created;
	return;
}

# Entfernt nach erfolgreichem Listenplan alle sichtbaren Readings eines Zieldevices.
sub MQTT2_DISCOVERY_clear_device_readings($$) {
	my ($hash, $record) = @_;
	my $target = $defs{ $record->{name} };
	return if !$target || ref($target->{READINGS}) ne 'HASH';
	my @readings = grep { $_ !~ /^\./ } sort keys %{ $target->{READINGS} };
	my ($deleted, $failed) = (0, 0);

	# Versteckte technische Readings bleiben erhalten; alle sichtbaren Werte sind explizit freigegeben.
	for my $reading (@readings) {
		my $error = MQTT2_DISCOVERY_gateway($hash)->delete_reading(
			$target, $reading,
		);

		# Einzelne FHEM-Fehler verhindern nicht die anschliessende Neuinitialisierung.
		if ($error) {
			++$failed;
			MQTT2_DISCOVERY_log(
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
		MQTT2_DISCOVERY_reading($hash, 'lastWarning', $message);
	}
	MQTT2_DISCOVERY_log(
		$hash, 3,
		"clearReadings completed for target=$record->{name}; deleted=$deleted failed=$failed",
	);
	return;
}

# Erstellt eine renderbare Kopie der Registry-Mappings fuer den aktuellen
# Reading-Modus und den global reservierten Availability-Namen.
sub MQTT2_DISCOVERY_prepare_device_mappings($$$) {
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
sub MQTT2_DISCOVERY_is_device_discovery_mapping($) {
	my ($mapping) = @_;
	return 0 if ref($mapping) ne 'HASH';
	return 1 if ($mapping->{source_layout} || '') eq 'device';
	my $topic = $mapping->{discovery_topic};
	return defined($topic) && !ref($topic)
		&& $topic =~ m{(?:^|/)device/[^/]+/config\z} ? 1 : 0;
}

# Beschreibt nur die funktionalen MQTT-Bindings eines Mappings, nicht dessen Anzeigenamen.
sub MQTT2_DISCOVERY_mapping_function_signature($) {
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
sub MQTT2_DISCOVERY_prefer_device_discovery_mappings($) {
	my ($mappings) = @_;
	my @source = grep { ref($_) eq 'HASH' } @{ $mappings || [] };
	my %device_signatures;

	# Zuerst werden alle von Device-Discovery bereits vollstaendig beschriebenen Funktionen erfasst.
	for my $mapping (@source) {
		next if !MQTT2_DISCOVERY_is_device_discovery_mapping($mapping);
		my $signature = MQTT2_DISCOVERY_mapping_function_signature($mapping);
		$device_signatures{$signature} = 1 if defined($signature);
	}
	return \@source if !keys %device_signatures;
	my @preferred;

	# Klassische Einzel-Entities bleiben erhalten, sofern keine funktional gleiche
	# atomare Komponente fuer dasselbe Registry-Device vorliegt.
	for my $mapping (@source) {
		my $signature = MQTT2_DISCOVERY_mapping_function_signature($mapping);
		next if !MQTT2_DISCOVERY_is_device_discovery_mapping($mapping)
			&& defined($signature) && $device_signatures{$signature};
		push @preferred, $mapping;
	}
	return \@preferred;
}

# Rendert und setzt alle verwalteten Attribute eines Zieldevices als atomaren Plan.
# Ein Geraet mit genau einem schaltbaren Kanal folgt der FHEM-Konvention: Der
# Zustand gehoert nach state, geschaltet wird mit on und off. Damit schreibt auch
# MQTT2_DEVICE_Set beim Setzen denselben Wert, den die Rueckmeldung liefert.
sub MQTT2_DISCOVERY_single_channel_state($$) {
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

sub MQTT2_DISCOVERY_apply_device_lines($$;$) {
	my ($hash, $record, $options) = @_;
	$options = {} if ref($options) ne 'HASH';
	my $rebuild_lists = $options->{rebuild_lists} ? 1 : 0;
	my $name = $record->{name};

	# Ein von Hand geloeschtes Zieldevice darf die Erkennung nicht dauerhaft
	# blockieren: Der verwaiste Datensatz wird verworfen, die naechste Erkennung
	# legt Device und Datensatz neu an.
	if (!$defs{$name}) {
		my $registry = MQTT2_DISCOVERY_registry($hash);

		for my $identity (keys %{ $registry->{devices} || {} }) {
			next if ($registry->{devices}{$identity} // 0) != $record;
			delete $registry->{devices}{$identity};
		}

		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_log($hash, 2, "verwaisten Registry-Eintrag fuer $name verworfen");
		return undef;
	}
	my %previous_availability_topics = map { ($_ => 1) }
		grep { defined($_) && !ref($_) && $_ ne '' }
		@{ $record->{availability_topics} || [] };
	my $availability_reading = MQTT2_DISCOVERY_availability_reading($hash);
	my $previous_availability_reading = $record->{availability_reading} // 'availability';
	my $previous_availability_owned = exists($record->{owned_availability_reading})
		? $record->{owned_availability_reading} eq $previous_availability_reading
		: !exists($record->{availability_reading})
			&& $previous_availability_reading eq 'availability';
	my $include_extra_json = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'extraJsonReadings', 'include',
	) eq 'include';

	# Namen werden ueber alle Entities des Devices gemeinsam aufgeloest, bevor
	# eine einzige readingList- oder setList-Zeile gerendert wird.
	my $reserved_readings = { $availability_reading => 1 };
	my $all_mappings = [
		map { $record->{entities}{$_} } sort keys %{ $record->{entities} }
	];
	my $preferred_mappings = MQTT2_DISCOVERY_prefer_device_discovery_mappings(
		$all_mappings,
	);
	MQTT2_DISCOVERY_log($hash, 3, 'suppressed equivalent legacy mappings='
		. (scalar(@$all_mappings) - scalar(@$preferred_mappings)) . "; target=$name")
		if @$preferred_mappings < @$all_mappings;
	my $prepared_mappings = MQTT2_DISCOVERY_prepare_device_mappings(
		$preferred_mappings, $availability_reading, $include_extra_json,
	);
	my $resolved_mappings = MQTT2_Discovery::Mapper::resolve_owned_mapping_names(
		$prepared_mappings, $reserved_readings,
	);
	$resolved_mappings = MQTT2_Discovery::Mapper::collapse_device_automation_readings(
		$resolved_mappings, $reserved_readings,
	);
	my %resolved_by_key = map { (($_->{entity_key} // '') => $_) } @$resolved_mappings;
	my (@reading_entries, @set_entries);
	my %runtime_references;

	for my $mapping (@$resolved_mappings) {
		push @reading_entries, @{ $mapping->{reading_lines} || [] };
		push @set_entries, @{ $mapping->{set_lines} || [] };
	}

	# Die Konventionen aendern bestehende Readingnamen und -werte und sind deshalb
	# abschaltbar; ohne das Attribut bleibt alles wie bisher.
	my $fhem_conventions = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'fhemConventions', 0,
	) ? 1 : 0;
	MQTT2_DISCOVERY_single_channel_state(\@reading_entries, \@set_entries)
		if $fhem_conventions;
	# Im Dialog abgewaehlte Readings entstehen gar nicht erst, weder als eigene
	# Zeile noch in den Sammelzeilen fuer die Abfrageantwort und die Ereignisse.
	my %ignored_entities = map { ($_ => 1) } MQTT2_DISCOVERY_ignored_entities($hash, $record);
	if (%ignored_entities) {

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
	my $mode = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'existingDevice', 'conservative',
	);
	my $effective_mode = $rebuild_lists ? 'replace' : $mode;
	my $old_reading = MQTT2_DISCOVERY_gateway($hash)->attr_value($name, 'readingList', '');
	my $old_set = MQTT2_DISCOVERY_gateway($hash)->attr_value($name, 'setList', '');
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
	my $initial_reading_names = MQTT2_DISCOVERY_expected_reading_names($prepared_readings);
	# Das IODev wandelt ':' in empfangenen Topics zu '_'. Die erzeugten
	# readingList-Zeilen muessen denselben Namen treffen.
	local $MQTT2_Discovery::Mapper::Renderer::TOPIC_CONVERSION =
		MQTT2_DISCOVERY_gateway($hash)->attr_value(
			$hash->{IODevName} // '', 'topicConversion', 1,
		) ? 1 : 0;
	local $MQTT2_Discovery::Mapper::Renderer::AVAILABILITY_VISIBLE =
		MQTT2_DISCOVERY_availability_reading($hash) ne '' ? 1 : 0;

	@reading_entries = @{ MQTT2_Discovery::Mapper::render_entries(
		$prepared_readings, $render_device_topic, $reserved_readings, \%runtime_references,
	) };

	# Mit setsViaHook entsteht kein setList-Attribut mehr: Die Befehle liegen
	# strukturiert in der Registry und werden ueber den Hook angeboten und
	# ausgefuehrt. Nicht unterstuetzte Befehlsarten bleiben im Attribut.
	my $via_hook = MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'setsViaHook', 0)
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

	# Mit readingsViaParse entsteht kein readingList-Attribut mehr: Die erzeugten
	# Zeilen werden in Regexp und Runtime-Referenz zerlegt und in der Registry
	# abgelegt; ausgewertet wird spaeter in ParseFn. Manuelle Zeilen des Anwenders
	# bleiben im Attribut und arbeiten unveraendert weiter.
	if (MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'readingsViaParse', 0)) {
		my @parsed;

		for my $entry (@reading_entries) {
			my $line = ref($entry) eq 'HASH' ? $entry->{line} : $entry;
			next if !defined($line) || $line eq '';
			my ($regexp, $reference) = $line =~ /^(\S+):\.\*\s+\{[^}]*'(r_[a-f0-9]+)'/;
			next if !defined($regexp) || !defined($reference);
			push @parsed, { regexp => "$regexp:.*", reference => $reference };
		}

		$record->{parse_readings} = \@parsed;
		@reading_entries = ();
	} else {
		delete $record->{parse_readings};
	}
	MQTT2_DISCOVERY_update_match();
	my $reading = merge_generated_lines(
		kind => 'reading', mode => $effective_mode, current => $prepared_old_reading,
		previous_owned => $previous_owned_reading, generated => \@reading_entries,
	);
	my $set = merge_generated_lines(
		kind => 'set', mode => $effective_mode, current => $merge_set,
		previous_owned => $previous_owned_set, generated => \@set_entries,
	);
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
	my $error = $plan->execute(MQTT2_DISCOVERY_gateway($hash));
	return $error if $error;

	# Erst nach dem atomaren Attributplan wird die passende Referenztabelle aktiv;
	# bei einem Rollback bleiben damit Attribute und Runtime-Daten synchron.
	$record->{runtime_refs} = { %runtime_references };
	$defs{$name}{helper}{mqtt2_discovery_runtime_refs} = $record->{runtime_refs};
	$defs{$name}{helper}{mqtt2_discovery_availability_reading} = $availability_reading;
	MQTT2_DISCOVERY_clear_device_readings($hash, $record)
		if $rebuild_lists && $options->{clear_readings};
	MQTT2_DISCOVERY_initialize_device_readings(
		$hash, $record, $initial_reading_names, $reading->{conflicts},
	);
	$record->{owned_reading} = $reading->{owned};
	$record->{owned_set} = $set->{owned};
	$record->{owned_devicetopic} = $manage_device_topic ? $generated_device_topic : undef;
	$record->{availability_topics} = \@availability_topics;
	$record->{availability_reading} = $availability_reading;
	$record->{owned_availability_reading} = $availability_reading;
	MQTT2_DISCOVERY_apply_device_semantics($hash, $record, \%resolved_by_key);
	my @conflicts = (@json_conflicts, @{ $reading->{conflicts} }, @{ $set->{conflicts} });

	# Manuell gewonnene Konflikte sind kein Apply-Fehler, muessen aber sichtbar
	# machen, welche generierten readingList- oder setList-Anteile nicht uebernommen wurden.
	if (@conflicts) {
		my $conflicts = join(',', stable_unique(@conflicts));
		MQTT2_DISCOVERY_reading($hash, 'conflicts', $conflicts);
		MQTT2_DISCOVERY_log($hash, 2, "manual configuration wins for target=$name; conflicts=$conflicts");
	}
	MQTT2_DISCOVERY_log($hash, 4, "attributes updated for target=$name; readingLines="
		. scalar(@{ $reading->{owned} }) . '; setLines=' . scalar(@{ $set->{owned} }));
	my $io_available = defined($hash->{helper}{io_available})
		? $hash->{helper}{io_available}
		: MQTT2_DISCOVERY_iodev_available($hash);
	MQTT2_DISCOVERY_sync_target_availability($hash, $record, $io_available);

	# Beim Umbenennen wird nur der zuvor nachweislich modulverwaltete Name
	# entfernt; eine explizit manuell verbliebene readingList-Belegung bleibt erhalten.
	if ($previous_availability_reading ne $availability_reading
			&& $previous_availability_owned
			&& ref($defs{$name}{READINGS}) eq 'HASH'
			&& exists($defs{$name}{READINGS}{$previous_availability_reading})
			&& !MQTT2_DISCOVERY_record_has_manual_reading(
				$hash, $record, $previous_availability_reading,
			)) {
		my $delete_error = MQTT2_DISCOVERY_gateway($hash)->delete_reading(
			$defs{$name}, $previous_availability_reading,
		);
		MQTT2_DISCOVERY_log($hash, 2, "old availability reading removal failed for target=$name; reading=$previous_availability_reading; error=$delete_error")
			if $delete_error;
	}

	# Erst nach erfolgreichem Attributplan und initialem leerem Reading wird fuer
	# jedes neu hinzugekommene Availability-Topic genau ein Abruf vorgemerkt.
	for my $topic (@availability_topics) {
		MQTT2_DISCOVERY_schedule_availability_refresh($hash, $topic)
			if !$previous_availability_topics{$topic};
	}

	return undef;
}

# Komponiert und hinterlegt semantische Metadaten fuer automatisch erzeugte Devices.
sub MQTT2_DISCOVERY_apply_device_semantics($$;$) {
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
		MQTT2_DISCOVERY_gateway($hash)->set_semantic_metadata($name, {
			confidence => 0.95,
			entities => [ map { $_->[1] } @entries ],
		});
	} else {
		MQTT2_DISCOVERY_gateway($hash)->set_semantic_metadata($name, undef);
	}
	my $integration_ended = eval {
		MQTT2_DISCOVERY_gateway($hash)->semantic_integration_end($name);
	} || 0;
	MQTT2_DISCOVERY_log($hash, 2, "semantic integration end failed for target=$name") if $@;
	MQTT2_DISCOVERY_publish_semantic_update($hash, $name) if !$integration_ended;
	MQTT2_DISCOVERY_log($hash, 4, "semantic metadata updated for target=$name; entities=" . scalar(@entries));
	return;
}

# Erzeugt aus der aktuellen Beschreibung ein semantisches Upsert- oder Remove-Ereignis.
sub MQTT2_DISCOVERY_publish_semantic_update($$) {
	my ($hash, $name) = @_;
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	return if !$gateway->can_publish_semantics();
	my $definition = eval { $gateway->semantic_description($name) };

	# Ohne gueltige Beschreibung kann kein wohldefiniertes Upsert- oder Remove-
	# Ereignis erzeugt werden; ein Broadcast wuerde nur unvollstaendige Daten verteilen.
	if ($@ || ref($definition) ne 'HASH') {
		MQTT2_DISCOVERY_log($hash, 2, "semantic update failed for target=$name");
		return;
	}
	my $event = $definition->{visible}
		? { type => 'device_upsert', device => $definition }
		: { type => 'device_remove', device => $name };
	eval { $gateway->semantic_broadcast($event) };
	MQTT2_DISCOVERY_log($hash, 2, "semantic broadcast failed for target=$name") if $@;
	return;
}

# Entfernt passende Entities aus der Registry und rendert betroffene Devices neu.
sub MQTT2_DISCOVERY_delete_entity($$$;$) {
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
		my $hadManual = MQTT2_DISCOVERY_record_has_manual_lines($hash, $record);
		delete $record->{entities}{$_} for @delete;
		my $extensions = ref($entity->{_canonical_extensions}) eq 'HASH'
			? $entity->{_canonical_extensions} : {};

		# Der Tasmota-Parser ersetzt sein zusammengesetztes Geraetemodell intern.
		# Nur externe Discovery-Loeschungen gehoeren in das sichtbare Level-2-Log.
		if ($extensions->{internal_rebuild}) {
			MQTT2_DISCOVERY_log($hash, 4, 'temporarily removed ' . scalar(@delete)
				. " discovery entity/entities from $record->{name} during internal rebuild");
		} else {
			MQTT2_DISCOVERY_log($hash, 2, 'removed ' . scalar(@delete)
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
		my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);
		return $error if $error;
		$error = MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
		return $error if $error;
	}

	return undef;
}

# Erkennt konservativ, ob ein verwaltetes Device noch benutzereigene Konfiguration enthaelt.
sub MQTT2_DISCOVERY_record_has_manual_lines($$) {
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
			MQTT2_DISCOVERY_gateway($hash)->attr_value($name, $attribute->[0], '');
		return 1 if grep { !$owned{$_} } @current;
	}

	return 0;
}

# Berechnet und schreibt die Anzahl aktiver Registry-Devices und Entities.
sub MQTT2_DISCOVERY_update_counts($) {
	my ($hash) = @_;
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my ($devices, $entities) = (0, 0);

	for my $record (values %{ $registry->{devices} }) {
		my $count = scalar keys %{ $record->{entities} || {} };
		++$devices if $count;
		$entities += $count;
	}

	MQTT2_DISCOVERY_reading($hash, 'discoveredDevices', $devices);
	MQTT2_DISCOVERY_reading($hash, 'discoveredEntities', $entities);
	MQTT2_DISCOVERY_log($hash, 4, "counts updated; devices=$devices; entities=$entities");
}

# Schreibt ein Modulreading ueber das Gateway mit normalisiertem undef-Wert.
sub MQTT2_DISCOVERY_reading($$$) {
	my ($hash, $name, $value) = @_;
	MQTT2_DISCOVERY_gateway($hash)->update_reading(
		$hash, $name, defined($value) ? $value : '', 1,
	);
}

# Entfernt den Set-Kommandonamen und liefert nur den vom Benutzer uebergebenen Wert.
sub MQTT2_Discovery_commandValue {
	my ($event) = @_;
	$event = '' if !defined $event;
	$event =~ s/^\S+\s*//;
	return $event;
}

# Baut den sicheren Home-Assistant-Kontext fuer MQTT-Device-Trigger auf.
sub MQTT2_DISCOVERY_triggerVars($) {
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
sub MQTT2_DISCOVERY_jsonPayload($$$) {
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
sub MQTT2_DISCOVERY_applyValueMap($$$) {
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

sub MQTT2_Discovery_runtime {
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
				$compiled, value => $event, vars => MQTT2_DISCOVERY_triggerVars($event),
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
						my $values = MQTT2_Discovery_runtime('reading', $reading->{template},
							JSON::PP::encode_json($item), $reading->{name});
						$values = MQTT2_DISCOVERY_applyValueMap($values, $reading->{name}, $reading->{map})
							if ref($reading->{map}) eq 'HASH';
						@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
					}

					next;
				}
				my $reading_operation = ($reading->{context} || '') eq 'trigger'
					? 'triggerReading' : 'reading';
				my $values = MQTT2_Discovery_runtime(
					$reading_operation, $reading->{template}, $event, $reading->{name},
				);
				$values = MQTT2_DISCOVERY_applyValueMap($values, $reading->{name}, $reading->{map})
					if ref($reading->{map}) eq 'HASH';
				@updates{keys %$values} = values %$values if ref($values) eq 'HASH';
			}

			# Nutzt dasselbe MQTT-Ereignis zugleich eine Availability-Regel, werden
			# deren interner Zustand und das sichtbare Reading atomar mitgeliefert.
			if (ref($configuration->{availability}) eq 'HASH') {
				my $values = MQTT2_Discovery_runtime(
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
					= MQTT2_DISCOVERY_device_availability_status(\@policy_states);
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
				my $payload = MQTT2_DISCOVERY_jsonPayload($key, 0 + $value, $constants);
				$answer = $topic . ' ' . JSON::PP->new->canonical(1)->encode($payload)
					if $payload;
			}
		} elsif ($operation eq 'jsonChoice') {
			my ($topic, $key, $mapping, $event, $constants) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);

			# Nur deklarierte Choices gelangen als JSON-String auf das Command-Topic;
			# dadurch koennen freie Eingaben weder Mapping noch JSON-Struktur umgehen.
			if (ref($mapping) eq 'HASH' && exists $mapping->{$choice}) {
				my $payload = MQTT2_DISCOVERY_jsonPayload($key, $mapping->{$choice}, $constants);
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
sub MQTT2_DISCOVERY_runtimeRegistryRecord($) {
	my ($device) = @_;
	return if !defined($device) || ref($device) || $device eq '';
	my $registered = $modules{MQTT2_DISCOVERY}{defptr};
	return if ref($registered) ne 'HASH';

	# Die Discovery-Registry ist die gemeinsame Quelle fuer Runtime-Referenzen
	# und fuer den reservierten Availability-Namen nach einem Neustart.
	for my $discovery (values %$registered) {
		next if ref($discovery) ne 'HASH';
		my $registry = MQTT2_DISCOVERY_registry($discovery);
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
sub MQTT2_DISCOVERY_runtimeReference($$) {
	my ($device, $reference) = @_;
	return undef if !defined($device) || ref($device) || $device eq ''
		|| !defined($reference) || ref($reference)
		|| $reference !~ /^r_[a-f0-9]{16,40}$/;
	my $target = $defs{$device};
	my $cached = ref($target) eq 'HASH'
		? $target->{helper}{mqtt2_discovery_runtime_refs} : undef;
	return $cached->{$reference}
		if ref($cached) eq 'HASH' && ref($cached->{$reference}) eq 'HASH';
	my (undef, $record) = MQTT2_DISCOVERY_runtimeRegistryRecord($device);
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
sub MQTT2_DISCOVERY_mqttBytes($) {
	my ($value) = @_;
	return $value if !defined($value) || ref($value) || !utf8::is_utf8($value);
	return Encode::encode('UTF-8', $value);
}

# Codiert alle skalaren Readingwerte fuer FHEMs bytestream-basierte Laufzeit,
# ohne bereits codierte MQTT-Payloads oder nichtskalare Werte zu veraendern.
sub MQTT2_DISCOVERY_mqttReadingBytes($) {
	my ($readings) = @_;
	return {} if ref($readings) ne 'HASH';
	my %encoded = %$readings;

	# Jeder Unicode-Wert wird genau einmal an der MQTT-/FHEM-Grenze codiert.
	for my $name (keys %encoded) {
		$encoded{$name} = MQTT2_DISCOVERY_mqttBytes($encoded{$name});
	}

	return \%encoded;
}

# Loest eine kurze Attributreferenz ausschliesslich ueber fest implementierte
# Runtime-Operationen auf; gespeicherter Discovery-Text wird niemals evaluiert.
sub MQTT2_DISCOVERY_runtimeRef($$$) {
	my ($device, $reference, $event) = @_;
	my $descriptor = MQTT2_DISCOVERY_runtimeReference($device, $reference);
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
		my $answer = MQTT2_Discovery_runtime(
			$runtime, $template, $event, $name,
			($runtime eq 'triggerReading' && ref($descriptor->{filter}) eq 'HASH'
				? ($descriptor->{filter}) : ()),
		);
		$answer = MQTT2_DISCOVERY_applyValueMap($answer, $name, $descriptor->{map})
			if ref($descriptor->{map}) eq 'HASH';
		return MQTT2_DISCOVERY_mqttReadingBytes($answer);
	}
	if ($operation eq 'topic' || $operation eq 'availability') {
		my $configuration = $descriptor->{configuration};
		return {} if ref($configuration) ne 'HASH';
		my $answer = MQTT2_Discovery_runtime(
			$operation, $device, $event, $configuration,
		);
		return MQTT2_DISCOVERY_mqttReadingBytes($answer);
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
		$answer = MQTT2_Discovery_runtime(
			'templatePublish', $topic, $descriptor->{template}, $event,
		);
	} elsif ($kind eq 'choice') {
		my $mapping = $descriptor->{mapping};
		return undef if ref($mapping) ne 'HASH' || grep {
			ref($_) || !defined($_) || $_ =~ /[\x00-\x1f]/
		} (keys(%$mapping), values(%$mapping));
		$answer = defined($descriptor->{template}) && $descriptor->{template} ne ''
			? MQTT2_Discovery_runtime(
				'templateChoice', $topic, $descriptor->{template}, $mapping, $event,
			)
			: MQTT2_Discovery_runtime('choice', $topic, $mapping, $event);
	} elsif ($kind eq 'button') {
		return undef if !defined($descriptor->{payload}) || ref($descriptor->{payload})
			|| $descriptor->{payload} =~ /[\x00-\x1f]/;
		$answer = MQTT2_Discovery_runtime('publish', $topic, $descriptor->{payload});
	} elsif ($kind eq 'json') {
		$answer = MQTT2_Discovery_runtime(
			'jsonPublish', $topic, $descriptor->{key}, $event, $descriptor->{constants},
		);
	} else {
		$answer = MQTT2_Discovery_runtime(
			'jsonChoice', $topic, $descriptor->{key}, $descriptor->{mapping},
			$event, $descriptor->{constants},
		);
	}
	return MQTT2_DISCOVERY_mqttBytes($answer);
}

# Liefert fuer freie JSON-Auswertung den aktuell verbindlich reservierten
# Availability-Namen des verwalteten Zieldevices.
sub MQTT2_DISCOVERY_runtimeAvailabilityReading($) {
	my ($device) = @_;
	return $MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING
		if !defined($device) || ref($device) || $device eq '';
	my $target = $defs{$device};
	my $cached = ref($target) eq 'HASH'
		? $target->{helper}{mqtt2_discovery_availability_reading} : undef;
	return $cached if defined($cached) && !ref($cached)
		&& $cached =~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
	my ($discovery, $record) = MQTT2_DISCOVERY_runtimeRegistryRecord($device);
	if (ref($discovery) eq 'HASH' && ref($record) eq 'HASH') {
		my $name = $record->{availability_reading};
		$name = MQTT2_DISCOVERY_availability_reading($discovery)
			if !defined($name) || ref($name)
				|| $name !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/;
		$target->{helper}{mqtt2_discovery_availability_reading} = $name
			if ref($target) eq 'HASH';
		return $name;
	}

	return $MQTT2_DISCOVERY_DEFAULT_AVAILABILITY_READING;
}

# Ergaenzt JSON-Zuordnungen um kollisionsfreie Namen reservierter Rollenreadings.
sub MQTT2_DISCOVERY_runtimeJSONMap($$) {
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
			|| !defined($target_name) || ref($target_name) || $target_name eq '';

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
sub MQTT2_DISCOVERY_jsonReadings($$$;$) {
	my ($device, $path, $event, $renames) = @_;
	return '' if !defined($path) || ref($path)
		|| !defined($event) || ref($event);
	$path =~ s/[^A-Za-z0-9]+/_/g;
	$path =~ s/^_+|_+$//g;
	return '' if $path eq '';
	$path = lc($path);
	my $availability = MQTT2_DISCOVERY_runtimeAvailabilityReading($device);
	my $json_map = MQTT2_DISCOVERY_runtimeJSONMap($device, $renames);

	# Explizite Discovery-Zuordnungen haben Vorrang; jedes danach noch auf den
	# reservierten Namen zielende Feld wird anhand seines Topic-Pfads qualifiziert.
	$json_map = MQTT2_DISCOVERY_runtimeJSONMap(
		$json_map, { $availability => $path . '_' . $availability },
	);
	return json2nameValue($event, '', $json_map);
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

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>
<p>The bound IO device gates the public <code>availability</code> reading (or the
name selected with <code>availabilityReading</code>) of every managed target. A
disconnected client marks all targets offline. After reconnect,
the most recently known discovery availability sources are evaluated again;
targets without such sources follow the IO device directly. Each entity retains
its announced Home Assistant availability semantics. A target that combines
multiple entities is online when at least one entity is available, offline only
when all entities are explicitly offline, and unknown otherwise. For each newly
applied availability topic on an <code>MQTT2_CLIENT</code>, one timer requests only
that retained topic after 60 seconds; normal MQTT traffic is not cached or
evaluated by this module. Deleting the bound IO device discards pending discovery
work, marks all managed targets offline and leaves this discovery device inactive.</p>

<a id="MQTT2_DISCOVERY-get"></a>
<h4>Get</h4>
<ul>
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
<li><a id="MQTT2_DISCOVERY-attr-availabilityReading"></a><b>availabilityReading</b><br>
Reserves one exact public Availability reading name for all devices managed by
this discovery instance. Without the attribute the name is
<code>availability</code>. Generated readings that would collide are renamed. Freely
expanded JSON fields use a compact runtime wrapper and qualify a collision with
their topic path, for example <code>state_availability</code>. In
<code>existingDevice conservative</code> mode, an
explicit manual <code>readingList</code> use rejects the global change before any
device is modified. Changing or deleting the attribute re-renders all managed
devices from the registry, recalculates the current status under the new name and
removes the previous reading only when it was owned by this module. Persisted
targets using an earlier module default are reconciled during the next FHEM
lifecycle event without requiring another discovery message.<br>
Syntax: <code>attr &lt;name&gt; availabilityReading &lt;reading-name&gt;</code>
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

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>
<p>Das gebundene IODev bestimmt zusaetzlich das sichtbare Reading
<code>availability</code> beziehungsweise den mit <code>availabilityReading</code>
festgelegten Namen aller verwalteten Ziele. Eine getrennte Client-Verbindung
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
<li><a id="MQTT2_DISCOVERY-attr-availabilityReading"></a><b>availabilityReading</b><br>
Reserviert einen verbindlichen sichtbaren Availability-Readingnamen fuer alle
von dieser Discovery-Instanz verwalteten Devices. Ohne Attribut lautet er
<code>availability</code>. Kollidierende erzeugte Readings werden umbenannt. Frei
entpackte JSON-Felder verwenden einen kompakten Runtime-Wrapper und qualifizieren
eine Kollision anhand des Topic-Pfads, beispielsweise als
<code>state_availability</code>. Im Modus <code>existingDevice conservative</code>
verhindert eine explizite manuelle <code>readingList</code>-Belegung die globale
Umstellung, bevor irgendein Device geaendert wird. Aendern oder Loeschen rendert
alle verwalteten Devices aus der Registry neu, berechnet den aktuellen Zustand
unter dem neuen Namen und entfernt den vorherigen Namen nur bei nachgewiesenem
Modulbesitz. Gespeicherte Ziele mit einem frueheren Moduldefault werden beim
naechsten FHEM-Lifecycle-Ereignis ohne erneute Discovery-Nachricht abgeglichen.<br>
Syntax: <code>attr &lt;name&gt; availabilityReading &lt;Reading-Name&gt;</code>
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
