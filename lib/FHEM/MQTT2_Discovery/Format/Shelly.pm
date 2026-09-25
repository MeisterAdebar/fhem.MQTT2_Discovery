# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Format::Shelly;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use Digest::SHA qw(sha1_hex);
use MQTT2_Discovery::Parser::Shelly ();
use MQTT2_Discovery::Model ();

# Liefert die Adapterkennung fuer Registry und Diagnose.
sub id { return 'shelly'; }

# Liest MQTT-JSON ohne Exceptions in den Dispatch gelangen zu lassen.
sub _json {
	my ($payload) = @_;
	my $data = eval { decode_json($payload // '') };
	return ref($data) eq 'HASH' ? $data : {};
}

# Ordnet ausschliesslich native Gen2+-Nachrichten oder eigene RPC-Antworten zu.
sub route {
	my (%args) = @_;
	return if exists($args{shelly_enabled}) && !$args{shelly_enabled};
	my $topic = $args{topic} // '';
	my $reply = $args{reply_prefix} // 'mqtt2_discovery/shelly';
	return ('reply', $1, $2) if $topic =~ m{\A\Q$reply\E/([a-f0-9]{16})/(info|config|status|components)/rpc\z};
	my $data;

	# Announce enthaelt die Generation; Gen1 bleibt beim normalen MQTT2_DEVICE-Parser.
	if ($topic =~ m{\A(.+)/announce\z}) {
		my $prefix = $1;
		$data = _json($args{payload});
		return if !MQTT2_Discovery::Parser::Shelly::valid_info($data);
		$prefix = $data->{id} if $prefix eq 'shellies';
		return ('announce', $prefix) if MQTT2_Discovery::Parser::Shelly::valid_prefix($prefix);
	}

	# Native IDs oder bereits identifizierte individuelle Prefixe erlauben Online-Erkennung.
	if ($topic =~ m{\A(.+)/online\z}) {
		my $prefix = $1;
		return ('online', $prefix) if $prefix =~ /\Ashelly[a-z0-9]+-[a-f0-9]{12}\z/i
			|| (ref($args{state}) eq 'HASH' && ref($args{state}{devices}) eq 'HASH'
				&& exists($args{state}{devices}{$prefix}));
	}

	# Ein RPC-Ereignis identifiziert auch individuelle MQTT-Prefixe ohne Modellraten.
	if ($topic =~ m{\A(.+)/events/rpc\z}) {
		my $prefix = $1;
		my $devices = ref($args{state}) eq 'HASH' ? $args{state}{devices} : undef;
		# Bekannte laufende Geraete benoetigen fuer ihre Telemetrie keine weitere Discovery-Queue.
		return if ref($devices) eq 'HASH' && $devices->{$prefix} && $devices->{$prefix}{complete};
		$data = _json($args{payload});
		return ('event', $prefix) if MQTT2_Discovery::Parser::Shelly::valid_prefix($prefix)
			&& defined($data->{src}) && !ref($data->{src})
			&& $data->{src} =~ /\Ashelly[a-z0-9]+-[a-f0-9]{12}\z/i;
	}

	return;
}

# Die Topic-Erkennung veraendert keinen Adapterzustand.
sub claims {
	my @route = route(@_);
	return @route ? 1 : 0;
}

# Nennt die offene Teilabfrage einer laufenden Sitzung. Wer gespeicherte
# Antworten einspielt, braucht sie: Eine Antwort gilt nur zu der Anfrage, die
# gerade offen ist.
sub pending {
	my ($state, $prefix) = @_;
	my $entry = ref($state) eq 'HASH' ? $state->{devices}{$prefix} : undef;
	return undef if ref($entry) ne 'HASH' || ref($entry->{pending}) ne 'HASH';
	return {
		part => $entry->{pending}{part}, id => $entry->{pending}{id},
		reply => $entry->{reply},
	};
}

# Erzeugt ausschliesslich lesende RPC-Anfragen mit einer pro Versuch eindeutigen ID.
sub _request {
	my ($state, $entry, $part) = @_;
	my %methods = (info => 'Shelly.GetDeviceInfo', config => 'Shelly.GetConfig',
		status => 'Shelly.GetStatus', components => 'Shelly.GetComponents');
	my $request_id = ++$state->{sequence};
	$entry->{pending} = { part => $part, id => $request_id };
	return {
		topic => "$entry->{prefix}/rpc",
		payload => JSON::PP->new->canonical(1)->encode({
			id => $request_id, src => "$entry->{reply}/$part", method => $methods{$part},
			($part eq 'components' ? (params => {
				offset => $entry->{components_offset} || 0,
				include => ['config', 'status'], dynamic_only => JSON::PP::true,
			}) : ()),
		}),
	};
}

# Beginnt einen Snapshot; schnelle Wiederholungen und unvollstaendige Altantworten werden begrenzt.
sub begin {
	my (%args) = @_;
	my $prefix = $args{mqtt_prefix};
	return { status => 'error', error_class => 'arguments', error => 'Ungueltiger Shelly-MQTT-Prefix' }
		if !MQTT2_Discovery::Parser::Shelly::valid_prefix($prefix);
	my $state = $args{state};
	my $now = $args{now} // time;
	my $previous = $state->{devices}{$prefix};
	return { status => 'ok', events => [], requests => [] }
		if !$args{force} && $previous && $now - $previous->{started} < 30;
	my $key = substr(sha1_hex($prefix), 0, 16);
	my $entry = {
		prefix => $prefix, started => $now, cid => $args{cid},
		reply => ($args{reply_prefix} // 'mqtt2_discovery/shelly') . "/$key",
	};
	$state->{devices}{$prefix} = $entry;
	$state->{keys}{$key} = $prefix;
	return { status => 'ok', events => [], requests => [_request($state, $entry, 'info')] };
}

# Fuehrt Info, Konfiguration und Status sequentiell zu genau einem atomaren Snapshot zusammen.
sub consume {
	my (%args) = @_;
	my ($kind, $key, $part) = route(%args);
	return { status => 'next' } if !defined($kind);
	my $state = $args{state};
	my $empty = { status => 'ok', events => [], requests => [] };

	# Statusmeldungen bleiben fuer die Zieldevices sichtbar und starten nur fehlende Erkennung.
	if ($kind ne 'reply') {
		my $entry = $state->{devices}{$key};
		my $data = _json($args{payload});
		return $empty if $kind eq 'online' && ($args{payload} // '') ne 'true';
		return $empty if $kind eq 'event' && $entry && $entry->{complete};
		return begin(%args, mqtt_prefix => $key);
	}
	my $prefix = $state->{keys}{$key};
	my $entry = defined($prefix) ? $state->{devices}{$prefix} : undef;
	return $empty if !$entry || !$entry->{pending} || $entry->{pending}{part} ne $part
		|| ($args{now} // time) - $entry->{started} > 120;
	my $data = _json($args{payload});
	return { status => 'error', error_class => 'schema', error => "Shelly: Ungueltiger RPC-Antwortrahmen $part" }
		if !defined($data->{id}) || ref($data->{id});
	return $empty if $data->{id} ne $entry->{pending}{id};
	return { status => 'error', error_class => 'rpc', error => "Shelly: RPC-Abfrage $part fehlgeschlagen" }
		if exists($data->{error});
	my $result = $data->{result};
	return { status => 'error', error_class => 'schema', error => "Shelly: Ungueltige RPC-Antwort $part" }
		if ref($result) ne 'HASH' || !defined($data->{src}) || ref($data->{src});

	# Der erste Antwortsatz bestaetigt die Identitaet; alle weiteren muessen vom selben Shelly stammen.
	if ($part eq 'info') {
		return { status => 'error', error_class => 'schema', error => 'Shelly: Keine gueltige Gen2+-Identitaet' }
			if !MQTT2_Discovery::Parser::Shelly::valid_info($result) || $data->{src} ne $result->{id};
		$entry->{info} = $result;
		return { %$empty, requests => [_request($state, $entry, 'config')] };
	}
	return { status => 'error', error_class => 'schema', error => 'Shelly: Antwort stammt von einem anderen Geraet' }
		if $data->{src} ne $entry->{info}{id};

	# Nur die fuer Discovery benoetigten Konfigurationsfelder bleiben im fluechtigen Cache.
	if ($part eq 'config') {
		my $mqtt = $result->{mqtt};
		return { status => 'error', error_class => 'schema', error => 'Shelly: MQTT-Konfiguration fehlt' }
			if ref($mqtt) ne 'HASH';
		my $configured_prefix = $mqtt->{topic_prefix} // $entry->{info}{id};
		return { status => 'error', error_class => 'schema', error => 'Shelly: MQTT-Prefix stimmt nicht mit der Abfrage ueberein' }
			if ref($configured_prefix) || $configured_prefix ne $prefix;
		$entry->{config} = { mqtt => { map { $_ => $mqtt->{$_} } qw(rpc_ntf status_ntf) } };
		$entry->{config}{sys}{device}{name} = $result->{sys}{device}{name}
			if ref($result->{sys}) eq 'HASH' && ref($result->{sys}{device}) eq 'HASH';

		for my $component (grep { /\A(?:input|switch|cct):\d+\z/ } keys %$result) {
			next if ref($result->{$component}) ne 'HASH';
			$entry->{config}{$component} = { map { $_ => $result->{$component}{$_} } qw(id type ct_range) };
		}

		$entry->{has_bthome} = ref($result->{bthome}) eq 'HASH' ? 1 : 0;
		return { %$empty, requests => [_request($state, $entry, 'status')] };
	}

	# Dynamische BLU-Komponenten werden nur bei vorhandener BTHome-Funktion abgefragt.
	if ($part eq 'status') {
		$entry->{snapshot} = $result;
		return { %$empty, requests => [_request($state, $entry, 'components')] }
			if $entry->{has_bthome} || ref($result->{bthome}) eq 'HASH';
	}

	# Jede Seite muss zur selben Revision gehoeren und den angeforderten Offset fortsetzen.
	if ($part eq 'components') {
		my $offset = $entry->{components_offset} || 0;
		my $components = $result->{components};
		return { status => 'error', error_class => 'schema', error => 'Shelly: Ungueltige Komponentenseite' }
			if ref($components) ne 'ARRAY'
				|| grep { !defined($result->{$_}) || ref($result->{$_}) || $result->{$_} !~ /\A\d+\z/ } qw(offset total cfg_rev);
		return { status => 'error', error_class => 'schema', error => 'Shelly: Inkonsistente Komponentenseiten' }
			if $result->{offset} != $offset || $result->{total} > 256
				|| $offset + @$components > $result->{total}
				|| (!@$components && $offset < $result->{total})
				|| (defined($entry->{components_revision}) && $entry->{components_revision} != $result->{cfg_rev})
				|| (defined($entry->{components_total}) && $entry->{components_total} != $result->{total});
		$entry->{components_revision} = $result->{cfg_rev};
		$entry->{components_total} = $result->{total};

		# Nur benoetigte Statusfelder bleiben im Snapshot; Schluessel und Metadaten werden verworfen.
		for my $component (@$components) {
			return { status => 'error', error_class => 'schema', error => 'Shelly: Ungueltige dynamische Komponente' }
				if ref($component) ne 'HASH' || !defined($component->{key}) || ref($component->{key})
					|| $component->{key} !~ /\A[a-z][a-z0-9]*:\d+\z/
					|| $entry->{component_keys}{$component->{key}}++;
			my $key = $component->{key};

			# Unbekannte dynamische Typen werden wie unbekannte statische Komponenten sichtbar gemeldet.
			if ($key !~ /\Abthome(?:device|sensor):(\d+)\z/) {
				push @{ $entry->{component_warnings} }, "Shelly: Dynamische Komponente $key wird noch nicht unterstuetzt";
				next;
			}
			my $channel = $1;
			my $values = $component->{status};
			return { status => 'error', error_class => 'schema', error => "Shelly: Ungueltiger Status von $key" }
				if ref($values) ne 'HASH' || !defined($values->{id}) || ref($values->{id}) || "$values->{id}" ne "$channel";
			$entry->{snapshot}{$key} = { map { $_ => $values->{$_} }
				grep { exists($values->{$_}) } qw(id value battery rssi packet_id last_update_ts last_updated_ts) };
		}

		$entry->{components_offset} = $offset + @$components;
		return { %$empty, requests => [_request($state, $entry, 'components')] }
			if $entry->{components_offset} < $result->{total};
	}
	my $parsed = MQTT2_Discovery::Parser::Shelly::parse(
		info => $entry->{info}, config => $entry->{config}, status => $entry->{snapshot},
		mqtt_prefix => $prefix, discovery_topic => "shelly/$entry->{info}{id}/config",
		state_topic => "$entry->{reply}/state/rpc", component_reply => "$entry->{reply}/state",
	);
	push @{ $parsed->{warnings} }, @{ $entry->{component_warnings} || [] } if $parsed->{status} eq 'ok';
	my $model = MQTT2_Discovery::Model::from_parser_result(adapter => id(), parsed => $parsed);
	return $model if $model->{status} ne 'ok';
	$entry->{complete} = 1;
	delete $entry->{pending};
	$model->{cid} = $entry->{cid};
	# Erst nach dem Device-Apply wird ein weiterer Status fuer die jetzt vorhandenen Readings angefordert.
	$model->{after_apply} = [{
		topic => "$prefix/rpc", payload => JSON::PP->new->canonical(1)->encode({
			id => ++$state->{sequence}, src => "$entry->{reply}/state", method => 'Shelly.GetStatus',
		}),
	}];

	# Gekoppelte BLU-Geraete bekommen Initialwerte ueber ihre dokumentierten Einzelabfragen.
	for my $component (sort keys %{ $entry->{snapshot} }) {
		next if $component !~ /\A(bthomedevice|bthomesensor):(\d+)\z/;
		my ($type, $channel) = ($1, 0 + $2);
		my $method = $type eq 'bthomedevice' ? 'BTHomeDevice.GetStatus' : 'BTHomeSensor.GetStatus';
		push @{ $model->{after_apply} }, {
			topic => "$prefix/rpc", payload => JSON::PP->new->canonical(1)->encode({
				id => ++$state->{sequence}, src => "$entry->{reply}/state/$component",
				method => $method, params => { id => $channel },
			}),
		};
	}

	delete @{$entry}{qw(snapshot component_keys component_warnings)};
	return $model;
}

1;
