# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use File::Find qw(find);

# Perl::Critic gehoert nicht zu den Laufzeitabhaengigkeiten des Moduls. Ohne die
# Installation bleibt dieser Test still, damit die Perl-Matrix davon unberuehrt
# bleibt; die Pruefung selbst laeuft im eigenen CI-Job.
BEGIN {
	eval { require Perl::Critic; 1 }
		or plan skip_all => 'Perl::Critic ist nicht installiert';
}

my @files;
find(
	{
		no_chdir => 1,
		wanted => sub { push @files, $File::Find::name if /\.pm\z/ },
	},
	'FHEM', 'lib',
);
@files = sort @files;
ok(scalar(@files), 'es gibt Dateien zu pruefen');

# Die Prueflatte steht in .perlcriticrc und gilt fuer alle gleich; der Test
# liest sie, statt eine eigene Strenge zu erfinden.
my $critic = Perl::Critic->new(-profile => '.perlcriticrc');

for my $file (@files) {
	my @violations = $critic->critique($file);
	is(
		[ map { sprintf('%s:%d %s', $file, $_->line_number(), $_->policy()) } @violations ],
		[],
		"$file haelt die Prueflatte ein",
	);
}

done_testing();
