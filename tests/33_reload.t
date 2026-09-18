# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv ();

# FHEMs reload uebersetzt dieselbe Datei erneut im laufenden Prozess. Erst dabei
# gelten die Prototypen der bereits definierten Funktionen auch fuer Aufrufe, die
# oberhalb ihrer Definition stehen.
subtest 'Das Modul laesst sich im selben Prozess erneut laden' => sub {
	my $first = do './FHEM/10_MQTT2_DISCOVERY.pm';
	ok(defined($first), 'erstes Laden gelingt') or diag($@ || $!);

	# Warnungen ueber neu definierte Funktionen sind beim reload erwartet.
	local $SIG{__WARN__} = sub { };
	my $second = do './FHEM/10_MQTT2_DISCOVERY.pm';
	ok(defined($second), 'zweites Laden gelingt') or diag($@ || $!);
	is($@, '', 'kein Uebersetzungsfehler beim zweiten Laden');
};

done_testing();
