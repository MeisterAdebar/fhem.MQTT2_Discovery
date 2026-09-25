# Testdouble fuer FHEMs GPUtils. Die Testsuite laeuft ohne FHEM-Installation,
# das Modul braucht aber GP_Import und GP_Export. Beide verhalten sich wie das
# Original (FHEM/GPUtils.pm): GP_Import legt Aliase auf die Symbole aus main an,
# GP_Export macht aus FHEM::MQTT2_DISCOVERY::foo ein FHEM::MQTT2_DISCOVERY::foo.
package GPUtils;

use strict;
use warnings;
use Exporter qw(import);

our %EXPORT_TAGS = (all => [qw(GP_Import GP_Export)]);
our @EXPORT_OK = @{ $EXPORT_TAGS{all} };

sub GP_Import {
	no strict 'refs';  ## no critic (ProhibitNoStrict)

	# Die Testumgebung definiert manche FHEM-Funktion erst spaeter; ein Alias auf
	# ein noch leeres Symbol ist hier kein Tippfehler.
	no warnings 'once';  ## no critic (ProhibitNoWarnings)
	my $package = caller(0);
	*{ $package . '::' . $_ } = *{ 'main::' . $_ } for @_;
	return;
}

sub GP_Export {
	no strict 'refs';  ## no critic (ProhibitNoStrict)
	my $package = caller(0);
	my $target = $package;
	$target =~ s/\A(?:.+::)?([^:]+)\z/main::$1_/;
	*{ $target . $_ } = *{ $package . '::' . $_ } for @_;
	return;
}

1;
