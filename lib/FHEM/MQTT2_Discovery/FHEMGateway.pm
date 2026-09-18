# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::FHEMGateway;

use strict;
use warnings;
use Encode ();


# Das Gateway kapselt alle Zugriffe auf globale FHEM-Funktionen. Tests koennen
# fuer jeden Zugriff einen Callback injizieren, ohne FHEM selbst zu starten.
sub new {
	my ($class, %callbacks) = @_;
	return bless { callbacks => \%callbacks }, $class;
}

# Waehlt einen injizierten Test-Callback oder die produktive FHEM-Implementierung aus.
sub _callback {
	my ($self, $name, $fallback) = @_;
	return $self->{callbacks}{$name} if ref($self->{callbacks}{$name}) eq 'CODE';
	return $fallback;
}

# Liest einen FHEM-Attributwert ueber die austauschbare Gateway-Grenze.
sub attr_value {
	my ($self, @args) = @_;
	my $callback = $self->_callback(attr_value => sub { return &main::AttrVal(@_) });
	return $callback->(@args);
}

# Liest ein FHEM-Reading mit dem von FHEM vorgegebenen Fallbackverhalten.
sub reading_value {
	my ($self, @args) = @_;
	my $callback = $self->_callback(reading_value => sub { return &main::ReadingsVal(@_) });
	return $callback->(@args);
}

# Liefert getrennt, ob ein Attribut existiert und welchen Wert es aktuell besitzt.
sub attribute_state {
	my ($self, $device, $attribute) = @_;
	my $callback = $self->_callback(attribute_state => sub {
		return (0, undef) if !exists($main::attr{$device})
			|| !exists($main::attr{$device}{$attribute});
		return (1, $main::attr{$device}{$attribute});
	});
	return $callback->($device, $attribute);
}

# Loest einen FHEM-Devicenamen auf den aktuellen internen Device-Hash auf.
sub device {
	my ($self, $name) = @_;
	my $callback = $self->_callback(device => sub { return $main::defs{$_[0]}; });
	return $callback->($name);
}

# Sucht alle lebenden MQTT2_DEVICE-Instanzen, die einer Client-ID zugeordnet sind.
sub mqtt2_devices_for_cid {
	my ($self, $cid) = @_;
	my $callback = $self->{callbacks}{mqtt2_devices_for_cid};
	return $callback->($cid) if ref($callback) eq 'CODE';
	return [] if !defined($cid) || ref($cid) || $cid eq '';

	my @devices;

	# Der offizielle defptr-Index ist schnell und bildet FHEMs eigene
	# Zuordnung einer Client-ID ab.
	# FHEM stellt diesen Index als Package-Global bereit. In diesem Gateway ist
	# der einzelne Zugriff beabsichtigt und kein Tippfehler.
	no warnings 'once';
	my $registered = $main::modules{MQTT2_DEVICE}{defptr}{cid}{$cid};
	push @devices, grep {
		ref($_) eq 'HASH' && defined($_->{NAME})
			&& $main::defs{ $_->{NAME} } && $main::defs{ $_->{NAME} } == $_
			&& ($_->{TYPE} || '') eq 'MQTT2_DEVICE'
	} @$registered if ref($registered) eq 'ARRAY';

	# Der FHEM-CID-Index ist die primaere Quelle. Der Scan macht die Aufloesung
	# auch waehrend der Initialisierung und in schlanken Testumgebungen robust.
	if (!@devices) {
		push @devices, grep {
			my $device = $main::defs{$_};
			($device->{TYPE} || '') eq 'MQTT2_DEVICE'
				&& (($device->{CID} // $device->{DEF} // '') eq $cid)
		} sort keys %main::defs;
		@devices = map { $main::defs{$_} } @devices;
	}

	my %seen;
	return [ grep { !$seen{ $_->{NAME} }++ } @devices ];
}

# Sucht alle lebenden MQTT2_DEVICE-Instanzen, die exakt am angegebenen IODev haengen.
sub mqtt2_devices_for_iodev {
	my ($self, $iodev) = @_;
	my $callback = $self->{callbacks}{mqtt2_devices_for_iodev};
	return $callback->($iodev) if ref($callback) eq 'CODE';
	return [] if ref($iodev) ne 'HASH' || !defined($iodev->{NAME})
		|| ref($iodev->{NAME}) || $iodev->{NAME} eq '';
	my $io_name = $iodev->{NAME};

	# Eine veraltete IODev-Referenz darf keine scheinbar zugeordneten Devices liefern.
	return [] if !$main::defs{$io_name} || $main::defs{$io_name} != $iodev;
	my @devices;

	# Nur aktuelle MQTT2_DEVICE-Hashes mit derselben IODev-Referenz gehoeren zur Liste.
	for my $name (sort keys %main::defs) {
		my $device = $main::defs{$name};
		next if ref($device) ne 'HASH'
			|| ($device->{TYPE} || '') ne 'MQTT2_DEVICE';
		next if ref($device->{IODev}) ne 'HASH'
			|| $device->{IODev} != $iodev;
		push @devices, $device;
	}

	return \@devices;
}

# Setzt oder entfernt ein Attribut idempotent und gibt einen FHEM-Fehler zurueck.
sub set_attribute {
	my ($self, $device, $attribute, $value) = @_;
	my ($exists, $current) = $self->attribute_state($device, $attribute);

	# Identische Werte und das Loeschen nicht vorhandener Attribute sind No-ops.
	return undef if defined($value) && $value ne '' && $exists && $current eq $value;
	return undef if (!defined($value) || $value eq '') && !$exists;

	# Nichtleere Werte werden mit attr gesetzt; ein leerer Zielwert bedeutet in
	# dieser Abstraktion bewusst das Entfernen des vorhandenen Attributes.
	if (defined($value) && $value ne '') {
		my $callback = $self->_callback(command_attr => sub {
			return main::CommandAttr(undef, $_[0]);
		});
		return $callback->("$device $attribute $value");
	}
	my $callback = $self->_callback(command_delete_attr => sub {
		return main::CommandDeleteAttr(undef, $_[0]);
	});
	return $callback->("$device $attribute");
}

# Sendet ein einzelnes MQTT-Publish ueber das gebundene IODev ohne Retain und ohne FHEM-Kommandoparser.
sub can_publish_mqtt {
	my ($self) = @_;
	return ref($self->{callbacks}{publish_mqtt}) eq 'CODE' || defined(&main::CallFn) ? 1 : 0;
}

# Uebergibt validierte Topic- und Payloadwerte direkt an die MQTT-WriteFn.
sub publish_mqtt {
	my ($self, $iodev, $topic, $payload) = @_;
	return 'Ungueltiges MQTT-Publish' if ref($iodev) ne 'HASH' || !defined($topic)
		|| ref($topic) || $topic eq '' || $topic =~ /[\s\x00-\x1f+#]/ || $topic =~ /:r$/
		|| !defined($payload) || ref($payload);
	my $callback = $self->_callback(publish_mqtt => sub {
		return 'FHEM WriteFn ist nicht verfuegbar' if !defined(&main::CallFn);
		return main::CallFn($_[0]{NAME}, 'WriteFn', $_[0], 'publish', "$_[1] $_[2]");
	});
	return $callback->($iodev, $topic, $payload);
}

# Legt ein MQTT2_DEVICE mit Client-ID und IODev ueber FHEMs Define-Schnittstelle an.
sub define_mqtt2_device {
	my ($self, $name, $cid, $io_name) = @_;
	my $callback = $self->_callback(command_define => sub {
		return main::CommandDefine(undef, $_[0]);
	});
	return $callback->("$name MQTT2_DEVICE $cid $io_name");
}

# Entfernt ein Device ausschliesslich ueber FHEMs regulaere Delete-Schnittstelle.
sub delete_device {
	my ($self, $name) = @_;
	my $callback = $self->_callback(command_delete => sub {
		return main::CommandDelete(undef, $_[0]);
	});
	return $callback->($name);
}

# Aktualisiert ein Reading und normalisiert undef sowie den Event-Trigger.
sub update_reading {
	my ($self, $hash, $name, $value, $trigger) = @_;
	my $callback = $self->_callback(update_reading => sub {
		return &main::readingsSingleUpdate(@_);
	});
	return $callback->($hash, $name, defined($value) ? $value : '', $trigger ? 1 : 0);
}

# Schreibt mehrere Readings eines Zielgeraets in einem Ereignisblock, wie es
# MQTT_GENERIC_BRIDGE fuer fremde Devices tut.
sub update_readings {
	my ($self, $hash, $values) = @_;
	return undef if ref($hash) ne 'HASH' || ref($values) ne 'HASH' || !keys %$values;
	my $callback = $self->_callback(update_readings => sub {
		my ($target, $readings) = @_;

		# Schlanke Umgebungen ohne Ereignisblock erhalten dieselben Werte einzeln.
		if (!defined(&main::readingsBeginUpdate)) {
			$self->update_reading($target, $_, $readings->{$_}, 1) for sort keys %$readings;
			return undef;
		}
		main::readingsBeginUpdate($target);

		for my $name (sort keys %$readings) {
			main::readingsBulkUpdate($target, $name, $readings->{$name});
		}

		main::readingsEndUpdate($target, 1);
		return undef;
	});
	return $callback->($hash, $values);
}

# Entfernt genau ein Reading, nachdem dessen Besitz durch den Aufrufer geprueft wurde.
sub delete_reading {
	my ($self, $hash, $name) = @_;
	my $callback = $self->_callback(delete_reading => sub {
		my ($target, $reading) = @_;
		return undef if ref($target) ne 'HASH' || !defined($target->{NAME});

		# Im vollstaendigen FHEM sorgt deletereading fuer den regulaeren Lebenszyklus;
		# dessen Erfolgstext darf jedoch nicht als Fehlermeldung weitergereicht werden.
		if (defined(&main::CommandDeleteReading)) {
			my $pattern = quotemeta($reading);
			my $result = main::CommandDeleteReading(undef, "$target->{NAME} ^$pattern\$");

			# Der tatsaechliche Readingzustand entscheidet, weil FHEM auch bei Erfolg
			# den nichtleeren Text "Deleted reading ..." zurueckliefert.
			return undef if ref($target->{READINGS}) ne 'HASH'
				|| !exists($target->{READINGS}{$reading});
			return defined($result) && $result ne '' ? $result
				: "Reading $reading wurde an $target->{NAME} nicht geloescht";
		}

		# Schlanke Testumgebungen erhalten denselben Datenzustand direkt im Hash.
		delete $target->{READINGS}{$reading} if ref($target->{READINGS}) eq 'HASH';
		return undef;
	});
	return $callback->($hash, $name);
}

# Schreibt eine bereits aufbereitete Meldung mit Name und Stufe in FHEMs Log.
sub log {
	my ($self, $name, $level, $message) = @_;
	my $callback = $self->_callback(log => sub {
		return main::Log3($_[0], $_[1], $_[2]);
	});
	return $callback->($name, $level, $message);
}

# Meldet, ob ein injizierter oder nativer FHEM-Timer zur Verfuegung steht.
sub can_schedule {
	my ($self) = @_;
	return 1 if ref($self->{callbacks}{schedule}) eq 'CODE';
	return defined(&main::InternalTimer) && defined(&main::gettimeofday);
}

# FHEM-Timer erhalten Hash und Funktionsnamen in einer anderen Reihenfolge als
# der testfreundliche Gateway-Callback; der Adapter vereinheitlicht beides.
sub schedule {
	my ($self, $delay, $hash, $function) = @_;
	my $callback = $self->_callback(schedule => sub {
		# waitIfInitNotDone muss 0 bleiben: Der Wert 1 blockiert FHEM waehrend
		# der Initialisierung. Das Zurueckstellen uebernimmt der Lifecycle der Queue.
		return main::InternalTimer(main::gettimeofday() + $_[0], $_[2], $_[1], 0);
	});
	return $callback->($delay, $hash, $function);
}

# Entfernt einen passenden geplanten Timer, sofern die Laufzeit dies unterstuetzt.
sub cancel_timer {
	my ($self, $hash, $function) = @_;
	my $callback = $self->{callbacks}{cancel_timer};
	return $callback->($hash, $function) if ref($callback) eq 'CODE';
	return undef if !defined(&main::RemoveInternalTimer);
	return main::RemoveInternalTimer($hash, $function);
}

# Codiert MQTTs variable Remaining-Length-Darstellung ohne weitere Bibliothek.
sub _mqtt_remaining_length {
	my ($length) = @_;
	my @bytes;

	do {
		my $byte = $length % 128;
		$length = int($length / 128);
		$byte |= 0x80 if $length;
		push @bytes, $byte;
	} while ($length);

	return pack('C*', @bytes);
}

# Abonniert am laufenden MQTT2_CLIENT exakt ein Topic, damit dessen Retained-Wert
# zugestellt wird. Das zusaetzliche Abonnement endet beim naechsten Reconnect.
sub refresh_retained_topic {
	my ($self, $iodev, $topic) = @_;
	my $callback = $self->{callbacks}{refresh_retained_topic};
	return $callback->($iodev, $topic) if ref($callback) eq 'CODE';
	return 'IODev fehlt' if ref($iodev) ne 'HASH';
	return 'Retained-Abruf wird nur fuer MQTT2_CLIENT unterstuetzt'
		if ($iodev->{TYPE} || '') ne 'MQTT2_CLIENT';
	return 'MQTT2_CLIENT ist nicht vollstaendig verbunden'
		if ($iodev->{STATE} || '') ne 'opened' || $iodev->{connecting}
			|| !defined($iodev->{FD});
	return 'Availability-Topic ist leer oder enthaelt ungueltige Zeichen'
		if !defined($topic) || ref($topic) || $topic eq ''
			|| $topic =~ /[\x00+#]/;
	return 'MQTT2_CLIENT stellt die benoetigte Sendefunktion nicht bereit'
		if !defined(&main::MQTT2_CLIENT_send);
	my $wire_topic = Encode::encode('UTF-8', $topic);
	return 'Availability-Topic ist fuer MQTT zu lang' if length($wire_topic) > 65_535;

	# Eine eigene fortlaufende Paket-ID vermeidet Kollisionen zwischen mehreren
	# gleichzeitig geplanten Availability-Abrufen derselben Client-Verbindung.
	my $packet_id = 1 + (($iodev->{'.mqtt2_discovery_packet_id'}
		// $iodev->{FD} // 0) % 65_535);
	$iodev->{'.mqtt2_discovery_packet_id'} = $packet_id;
	my $payload = pack('n', $packet_id)
		. pack('n', length($wire_topic)) . $wire_topic . pack('C', 0);
	my $packet = pack('C', 0x82) . _mqtt_remaining_length(length($payload)) . $payload;
	my $ok = eval {
		# doSend=1 stellt sicher, dass der gezielte SUBSCRIBE nicht von einem alten
		# Verbindungsaufbauzustand verworfen wird; die Vorpruefung schliesst ihn aus.
		main::MQTT2_CLIENT_send($iodev, $packet, 0, 1);
		1;
	};
	return 'MQTT2_CLIENT konnte das Availability-Topic nicht abonnieren: '
		. ($@ || 'unbekannter Fehler') if !$ok;
	return undef;
}

# Ruft die aktuelle semantische Device-Beschreibung optional ueber Semantic ab.
sub semantic_description {
	my ($self, $name) = @_;
	my $callback = $self->{callbacks}{semantic_description};
	return $callback->($name) if ref($callback) eq 'CODE';
	return undef if !defined(&main::Semantic_DescribeDevice);
	return main::Semantic_DescribeDevice($name);
}

# Beendet eine semantische Integrationsphase und meldet, ob Semantic selbst publiziert hat.
sub semantic_integration_end {
	my ($self, $name) = @_;
	my $callback = $self->{callbacks}{semantic_integration_end};
	return $callback->($name) if ref($callback) eq 'CODE';
	return 0 if !defined(&main::Semantic_EndIntegration);
	return main::Semantic_EndIntegration($name) ? 1 : 0;
}

# Prueft, ob Beschreibung und Broadcast fuer semantische Updates gemeinsam verfuegbar sind.
sub can_publish_semantics {
	my ($self) = @_;
	return 1 if ref($self->{callbacks}{semantic_description}) eq 'CODE'
		&& ref($self->{callbacks}{semantic_broadcast}) eq 'CODE';
	return defined(&main::Semantic_DescribeDevice) && defined(&main::SemanticWEB_Broadcast);
}

# Hinterlegt oder entfernt die von Discovery erzeugten semantischen Metadaten am Device.
sub set_semantic_metadata {
	my ($self, $name, $metadata) = @_;
	my $callback = $self->{callbacks}{set_semantic_metadata};
	return $callback->($name, $metadata) if ref($callback) eq 'CODE';
	return undef if !exists $main::defs{$name};

	# undef bedeutet bewusst "Metadaten entfernen", nicht "leere Metadaten".
	if (defined $metadata) {
		$main::defs{$name}{SEMANTIC_METADATA} = $metadata;
	} else {
		delete $main::defs{$name}{SEMANTIC_METADATA};
	}
	return undef;
}

# Verteilt ein semantisches Upsert- oder Remove-Ereignis an verbundene Oberflaechen.
sub semantic_broadcast {
	my ($self, $event) = @_;
	my $callback = $self->{callbacks}{semantic_broadcast};
	return $callback->($event) if ref($callback) eq 'CODE';
	return undef if !defined(&main::SemanticWEB_Broadcast);
	return main::SemanticWEB_Broadcast($event);
}

1;
