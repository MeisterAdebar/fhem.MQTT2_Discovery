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
	return {
		operation => 'upsert', format => 'shelly', prefix => 'shelly',
		component => $kind, component_key => $name, object_id => $name,
		preferred_entity_name => $name, name => $name,
		unique_id => "$context->{info}{id}_$name", device => $context->{device},
		discovery_topic => $topic, entity_key => "$topic|$name", device_topic => $prefix,
		state_topic => "$prefix/status/$component",
		value_template => "{{ value_json.$path }}", state_reading_name => $name,
		json_autocreate => 0,
		availability => [
			{ topic => "$prefix/online", payload_available => 'true', payload_not_available => 'false' },
			{ topic => $context->{state_topic}, value_template => '{{ value_json.src }}',
				payload_available => $context->{info}{id}, payload_not_available => 'offline' },
		],
		supplemental_signals => [
			{ type => 'template', topic => "$prefix/events/rpc", name => $name,
				template => "{{ value_json.params['$component'].$path }}" },
			{ type => 'template', topic => $context->{state_topic}, name => $name,
				template => "{{ value_json.result['$component'].$path }}" },
		],
		%configuration,
	};
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
	# Ein konfiguriertes Relais muss auch im vollstaendigen Status vorhanden sein.
	for my $component (grep { /\Aswitch:\d+\z/ } keys %$config) {
		return { status => 'error', error_class => 'schema', error => "Shelly: Status von $component fehlt" }
			if ref($status->{$component}) ne 'HASH';
	}

	push @warnings, 'Shelly: RPC status notifications oder Generic status update over MQTT aktivieren'
		if !$mqtt->{rpc_ntf} && !$mqtt->{status_ntf};

	# Nur tatsaechlich gemeldete Komponenten und Werte werden als Funktionen angelegt.
	for my $component (sort keys %$status) {
		my $values = $status->{$component};
		return { status => 'error', error_class => 'schema', error => "Shelly: Ungueltige Komponente $component" }
			if ref($values) ne 'HASH';
		my $settings = ref($config->{$component}) eq 'HASH' ? $config->{$component} : {};
		my @measurements;

		# Relaisbefehle verwenden feste JSON-RPC-Payloads und benoetigen MQTT Control nicht.
		if ($component =~ /\Aswitch:(\d+)\z/) {
			my $channel = 0 + $1;
			return { status => 'error', error_class => 'schema', error => "Shelly: $component.output fehlt oder ist ungueltig" }
				if !JSON::PP::is_bool($values->{output});
			return { status => 'error', error_class => 'schema', error => "Shelly: Kanal-ID von $component stimmt nicht ueberein" }
				if !defined($values->{id}) || ref($values->{id}) || "$values->{id}" ne "$channel";
			my $json = JSON::PP->new->canonical(1);
			# Schaltantworten teilen das bereits gelesene Ereignistopic, ohne neue Discovery auszulösen.
			my $source = "$args{mqtt_prefix}/events";
			push @entities, _entity(\%args, $component, 'output', 'switch', '',
				command_topic => "$args{mqtt_prefix}/rpc", state_on => 'true', state_off => 'false',
				payload_on => $json->encode({ id => 1, src => $source, method => 'Switch.Set', params => { id => $channel, on => JSON::PP::true } }),
				payload_off => $json->encode({ id => 1, src => $source, method => 'Switch.Set', params => { id => $channel, on => JSON::PP::false } }),
			);
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
		} elsif ($component =~ /:\d+\z/ && $component !~ /\A(?:script|bthome)/) {
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
