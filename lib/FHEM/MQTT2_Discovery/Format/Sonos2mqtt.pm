# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Format::Sonos2mqtt;

use strict;
use warnings;
use MQTT2_Discovery::Parser::Sonos2mqtt ();
use MQTT2_Discovery::Model ();


# Liefert die stabile Kennung fuer Registry, Status und Fehlerzuordnung.
sub id { return 'sonos2mqtt'; }

# Delegiert die exakte Topic-Erkennung an den Sonos2mqtt-Parser.
sub claims {
	my (%args) = @_;
	return MQTT2_Discovery::Parser::Sonos2mqtt::matches(%args) ? 1 : 0;
}

# Parst die Speaker-Discovery und uebergibt die gemeinsame Modellbildung an Model.
sub consume {
	my (%args) = @_;
	my $parsed = MQTT2_Discovery::Parser::Sonos2mqtt::parse(%args);
	return MQTT2_Discovery::Model::from_parser_result(adapter => id(), parsed => $parsed);
}

1;
