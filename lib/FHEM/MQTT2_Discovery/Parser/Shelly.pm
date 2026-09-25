# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Parser::Shelly;

use strict;
use warnings;
use utf8;
use JSON::PP ();
use MQTT2_Discovery::Model ();

# Akzeptiert ausschliesslich konkrete MQTT-Pfade, die auch im FHEM-Publish sicher sind.
sub valid_prefix {
	my ($prefix) = @_;
	return defined($prefix) && !ref($prefix) && length($prefix) <= 300
		&& $prefix =~ m{\A[A-Za-z0-9_-][A-Za-z0-9_./-]*\z}
		&& $prefix !~ m{/$} ? 1 : 0;
}

# Prueft die native Gen2+-Identitaet, bevor ein fremdes MQTT-Geraet angesprochen wird.
sub valid_info {
	my ($info) = @_;
	return ref($info) eq 'HASH' && defined($info->{id}) && !ref($info->{id})
		&& $info->{id} =~ /\Ashelly[a-z0-9]+-[a-f0-9]{12}\z/i
		&& defined($info->{gen}) && !ref($info->{gen}) && $info->{gen} =~ /\A[234]\z/
		&& defined($info->{model}) && !ref($info->{model}) && $info->{model} ne '';
}

# Liest nur vorhandene skalare Messwerte; null und unbekannte Objektformen sind keine Sensoren.
sub _value {
	my ($data, $path) = @_;

	for my $key (split /\./, $path) {
		return undef if ref($data) ne 'HASH' || !exists($data->{$key});
		$data = $data->{$key};
	}

	return undef if !defined($data) || (ref($data) && !JSON::PP::is_bool($data));
	return $data;
}

# Beschreibt denselben Wert auf Komponenten-, RPC-Ereignis- und Abfragetopics.
sub _entity {
	my ($context, $component, $path, $kind, $suffix, %configuration) = @_;
	my $name = $component;
	$name =~ s/:/_/g;
	$name .= "_$suffix" if defined($suffix) && $suffix ne '';
	my $topic = $context->{discovery_topic};
	my $prefix = $context->{mqtt_prefix};

	# Das Geraet meldet nur ueber die Wege, die in seiner MQTT-Konfiguration
	# eingeschaltet sind; Zeilen fuer abgeschaltete Wege wuerden nie ausloesen.
	my $mqtt = ref($context->{config}) eq 'HASH' && ref($context->{config}{mqtt}) eq 'HASH'
		? $context->{config}{mqtt} : {};
	my $pushes_status = $mqtt->{status_ntf} ? 1 : 0;
	my $pushes_events = $mqtt->{rpc_ntf} ? 1 : 0;
	my $reply_signal = {
		type => 'template', topic => $context->{state_topic}, name => $name,
		template => "{{ value_json.result['$component'].$path }}",
	};

	# Ohne gepushten Status traegt die Antwort der eigenen Abfrage den Wert.
	my ($state_topic, $value_template) = $pushes_status
		? ("$prefix/status/$component", "{{ value_json.$path }}")
		: ($reply_signal->{topic}, $reply_signal->{template});
	return {
		operation => 'upsert', format => 'shelly', prefix => 'shelly',
		component => $kind, component_key => $name, object_id => $name,
		preferred_entity_name => $name, name => $name,
		unique_id => "$context->{info}{id}_$name", device => $context->{device},
		discovery_topic => $topic, entity_key => "$topic|$name", device_topic => $prefix,
		state_topic => $state_topic,
		value_template => $value_template, state_reading_name => $name,
		json_autocreate => 0,
		availability => [
			{ topic => "$prefix/online", payload_available => 'true', payload_not_available => 'false' },
			{ topic => $context->{state_topic}, value_template => '{{ value_json.src }}',
				payload_available => $context->{info}{id}, payload_not_available => 'offline' },
		],
		supplemental_signals => [
			($pushes_events ? ({ type => 'template', topic => "$prefix/events/rpc", name => $name,
				template => "{{ value_json.params['$component'].$path }}" }) : ()),
			($pushes_status ? ($reply_signal) : ()),
			# Dynamische Komponenten fehlen in GetStatus und erhalten eine eigene Initialantwort.
			($component =~ /\Abthome(?:device|sensor):\d+\z/ ? ({
				type => 'template', topic => "$context->{component_reply}/$component/rpc", name => $name,
				template => "{{ value_json.result.$path }}",
			}) : ()),
		],
		%configuration,
	};
}

# Beschreibt einen begrenzten RPC-Zahlenwert; ungueltige Eingaben erzeugen keinen Payload.
sub _rpc_number {
	my ($context, $component, $path, $method, $channel, $min, $max, $unit) = @_;
	my $json = JSON::PP->new->canonical(1);
	my $payload = $json->encode({
		id => 1, src => "$context->{mqtt_prefix}/events", method => $method,
		params => { id => $channel, $path => '__VALUE__' },
	});
	# Zwei bedingte Ausdruecke pruefen beide Grenzen innerhalb des sicheren Template-Subsets.
	$payload =~ s/"__VALUE__"/{{ value | float if value | float >= $min if value | float <= $max }}/;
	return _entity($context, $component, $path, 'number', $path,
		command_topic => "$context->{mqtt_prefix}/rpc", command_template => $payload,
		min => $min, max => $max, step => 1, unit_of_measurement => $unit);
}

# Liest gekoppelte BLU-Komponenten ohne angenommene Sensorart oder erfundene Einheiten.
sub _bthome_entities {
	my ($context, $component, $values) = @_;
	my @entities;

	# Ein schlafender Sensor wird auch mit noch unbekanntem Wert bereits gebunden.
	if ($component =~ /\Abthomesensor:/) {
		push @entities, _entity($context, $component, 'value', 'sensor', '');
	} else {
		push @entities, _entity($context, $component, 'battery', 'sensor', 'battery',
			device_class => 'battery', unit_of_measurement => '%');
		push @entities, _entity($context, $component, 'rssi', 'sensor', 'rssi',
			device_class => 'signal_strength', unit_of_measurement => 'dBm');
		push @entities, _entity($context, $component, 'packet_id', 'sensor', 'packet_id');
	}

	# Firmwareversionen verwenden beide Schreibweisen; alle Transportwege behalten denselben Namen.
	my $updated = _entity($context, $component, 'last_update_ts', 'sensor', 'last_update');

	for my $template (\$updated->{value_template}, map { \$_->{template} } @{ $updated->{supplemental_signals} }) {
		my ($root) = $$template =~ /\{\{ (.+)\.last_update_ts \}\}/;
		$$template = "{{ $root.last_updated_ts if $root.last_updated_ts is defined else $root.last_update_ts }}";
	}

	push @entities, $updated;

	# Ereignislisten werden nach Komponentenkennung gefiltert, unabhaengig von ihrer Arrayposition.
	for my $field (qw(event idx channel ts)) {
		my $name = $component;
		$name =~ s/:/_/g;
		push @{ $entities[0]{supplemental_signals} }, {
			type => 'template', topic => "$context->{mqtt_prefix}/events/rpc",
			name => "${name}_$field", template => "{{ value_json.$field }}",
			items => { path => ['params', 'events'], match => { component => $component } },
		};
	}

	return @entities;
}

# Normalisiert einen vollstaendigen, zusammengehoerigen RPC-Snapshot ohne Geraete-Modelltabelle.
sub parse {
	my (%args) = @_;
	my ($info, $config, $status) = @args{qw(info config status)};
	return { status => 'error', error_class => 'schema', error => 'Ungueltiger Shelly-Gen2+-Snapshot' }
		if !valid_info($info) || ref($config) ne 'HASH' || ref($status) ne 'HASH'
			|| ref($status->{sys}) ne 'HASH' || !valid_prefix($args{mqtt_prefix});
	my $sys = ref($config->{sys}) eq 'HASH' ? $config->{sys} : {};
	my $device = ref($sys->{device}) eq 'HASH' ? $sys->{device} : {};
	my $device_name = $device->{name};
	$device_name = $info->{id} if !defined($device_name) || ref($device_name) || $device_name eq '';
	$args{device} = {
		identifiers => [$info->{id}], name => $device_name, manufacturer => 'Shelly',
		model => $info->{model}, sw_version => $info->{ver},
	};
	my $mqtt = ref($config->{mqtt}) eq 'HASH' ? $config->{mqtt} : {};
	my (@entities, @warnings);
	# Konfigurierte Aktoren muessen auch im vollstaendigen Status vorhanden sein.
	for my $component (grep { /\A(?:switch|cct):\d+\z/ } keys %$config) {
		return { status => 'error', error_class => 'schema', error => "Shelly: Status von $component fehlt" }
			if ref($status->{$component}) ne 'HASH';
	}

	push @warnings, 'Shelly: weder rpc_ntf noch status_ntf aktiv; Werte kommen nur aus der Abfrage'
		if !$mqtt->{rpc_ntf} && !$mqtt->{status_ntf};

	# Nur tatsaechlich gemeldete Komponenten und Werte werden als Funktionen angelegt.
	for my $component (sort keys %$status) {
		my $values = $status->{$component};
		return { status => 'error', error_class => 'schema', error => "Shelly: Ungueltige Komponente $component" }
			if ref($values) ne 'HASH';
		my $settings = ref($config->{$component}) eq 'HASH' ? $config->{$component} : {};
		my @measurements;

		# Relaisbefehle verwenden feste JSON-RPC-Payloads und benoetigen MQTT Control nicht.
		if ($component =~ /\A(switch|cct):(\d+)\z/) {
			my $kind = $1;
			my $channel = 0 + $2;
			return { status => 'error', error_class => 'schema', error => "Shelly: $component.output fehlt oder ist ungueltig" }
				if !JSON::PP::is_bool($values->{output});
			return { status => 'error', error_class => 'schema', error => "Shelly: Kanal-ID von $component stimmt nicht ueberein" }
				if !defined($values->{id}) || ref($values->{id}) || "$values->{id}" ne "$channel";
			my $json = JSON::PP->new->canonical(1);
			# Schaltantworten teilen das bereits gelesene Ereignistopic, ohne neue Discovery auszulösen.
			my $source = "$args{mqtt_prefix}/events";
			my $method = $kind eq 'cct' ? 'CCT.Set' : 'Switch.Set';
			push @entities, _entity(\%args, $component, 'output', $kind eq 'cct' ? 'light' : 'switch', '',
				command_topic => "$args{mqtt_prefix}/rpc", state_on => 'true', state_off => 'false',
				payload_on => $json->encode({ id => 1, src => $source, method => $method, params => { id => $channel, on => JSON::PP::true } }),
				payload_off => $json->encode({ id => 1, src => $source, method => $method, params => { id => $channel, on => JSON::PP::false } }),
			);

			# CCT verwendet Prozent und Kelvin; die Farbtemperatur darf nicht als Mired gesendet werden.
			if ($kind eq 'cct') {
				return { status => 'error', error_class => 'schema', error => "Shelly: $component.brightness ist ungueltig" }
					if !defined($values->{brightness}) || ref($values->{brightness})
						|| $values->{brightness} !~ /\A\d+(?:\.\d+)?\z/
						|| $values->{brightness} > 100;
				push @entities, _rpc_number(\%args, $component, 'brightness', $method, $channel, 0, 100, '%');
				my $range = $settings->{ct_range};
				# Nur die dokumentierte Duo-Bulb-Voreinstellung ersetzt eine fehlende Bereichsangabe.
				$range = [2700, 6500] if !defined($range) && $info->{id} =~ /\Ashellyduobulbg3-/i;
				return { status => 'error', error_class => 'schema', error => "Shelly: $component.ct ist ungueltig" }
					if !defined($values->{ct}) || ref($values->{ct}) || $values->{ct} !~ /\A\d+\z/;

				# Ohne verlaessliche Grenzen bleibt die Temperatur lesbar und wird nicht geraten.
				if (ref($range) eq 'ARRAY' && @$range == 2
						&& !grep { !defined($_) || ref($_) || $_ !~ /\A\d+\z/ } @$range) {
					return { status => 'error', error_class => 'schema', error => "Shelly: $component.ct_range ist ungueltig" }
						if $range->[0] < 1000 || $range->[1] > 10000 || $range->[0] >= $range->[1];
					push @entities, _rpc_number(\%args, $component, 'ct', $method, $channel, @$range, 'K');
				} else {
					push @entities, _entity(\%args, $component, 'ct', 'sensor', 'ct', unit_of_measurement => 'K');
					push @warnings, "Shelly: $component ohne gueltiges ct_range, Farbtemperatur nur lesbar";
				}
			}

			@measurements = (
				['temperature.tC', 'temperature', 'temperature', '°C'],
				['apower', 'power', 'power', 'W'], ['voltage', 'voltage', 'voltage', 'V'],
				['current', 'current', 'current', 'A'], ['freq', 'frequency', 'frequency', 'Hz'],
				['aenergy.total', 'energy', 'energy', 'Wh', 'total_increasing'],
				['ret_aenergy.total', 'returned_energy', 'energy', 'Wh', 'total_increasing'],
			);
		} elsif ($component =~ /\Ainput:\d+\z/) {
			# Taster besitzen keinen dauerhaften Schaltzustand; daraus darf kein falsches off entstehen.
			if (($settings->{type} || '') eq 'button') {
				push @warnings, "Shelly: Tasterereignisse von $component werden noch nicht abgebildet";
			} elsif (JSON::PP::is_bool($values->{state})) {
				push @entities, _entity(\%args, $component, 'state', 'binary_sensor', '',
					payload_on => 'true', payload_off => 'false');
			}
			@measurements = (['percent', 'percent', undef, '%'], ['counts.total', 'count', undef, undef, 'total_increasing']);
		} elsif ($component =~ /\Atemperature:\d+\z/) {
			@measurements = (['tC', 'temperature', 'temperature', '°C']);
		} elsif ($component =~ /\Ahumidity:\d+\z/) {
			@measurements = (['rh', 'humidity', 'humidity', '%']);
		} elsif ($component eq 'wifi') {
			@measurements = (['rssi', 'rssi', 'signal_strength', 'dBm']);
		} elsif ($component eq 'sys') {
			@measurements = (['uptime', 'uptime', 'duration', 's']);
		} elsif ($component =~ /\Adevicepower:\d+\z/) {
			@measurements = (['battery.percent', 'battery', 'battery', '%']);
		} elsif ($component =~ /\Abthome(?:device|sensor):\d+\z/) {
			push @entities, _bthome_entities(\%args, $component, $values);
		} elsif ($component =~ /:\d+\z/ && $component !~ /\Ascript/) {
			push @warnings, "Shelly: Komponente $component wird noch nicht unterstuetzt";
		}

		# Messoptionen werden aus dem Snapshot erkannt und anschliessend dynamisch gelesen.
		for my $measurement (@measurements) {
			my ($path, $suffix, $class, $unit, $state_class) = @$measurement;
			my $value = _value($values, $path);
			next if !defined($value) || ref($value) || $value !~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?\z/i;
			push @entities, _entity(\%args, $component, $path, 'sensor', $suffix,
				(defined($class) ? (device_class => $class) : ()),
				(defined($unit) ? (unit_of_measurement => $unit) : ()),
				state_class => $state_class || 'measurement');
		}

	}

	# Ein neuer Snapshot ersetzt nur die eigenen bisherigen Entities, auch bei Profilwechseln.
	my $delete = {
		operation => 'delete_device', format => 'shelly', prefix => 'shelly',
		discovery_topic => $args{discovery_topic}, entity_key => "$args{discovery_topic}|",
		internal_rebuild => 1,
	};
	return { status => 'ok', entities => [$delete, @entities], warnings => \@warnings };
}

1;
