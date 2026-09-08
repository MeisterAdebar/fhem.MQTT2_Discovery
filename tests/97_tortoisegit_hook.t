# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec ();
use File::Temp qw(tempdir);

my $temp = tempdir('mqtt2-discovery-tgit-XXXXXX', DIR => '.', CLEANUP => 1);
my $tools = File::Spec->catdir($temp, 'tools');
make_path($tools);
my $hook = File::Spec->catfile($tools, 'tortoisegit_pre_commit.pl');
my $generator = File::Spec->catfile($tools, 'update_changed.pl');
copy(File::Spec->catfile('tools', 'tortoisegit_pre_commit.pl'), $hook)
	or die "Kann TortoiseGit-Hook nicht kopieren: $!";
copy(File::Spec->catfile('tools', 'update_changed.pl'), $generator)
	or die "Kann CHANGED-Generator nicht kopieren: $!";

my $changed = File::Spec->catfile($temp, 'CHANGED');
my $head_changed = File::Spec->catfile($temp, 'HEAD_CHANGED');
my $paths = File::Spec->catfile($temp, 'PATHS');
my $message = File::Spec->catfile($temp, 'MESSAGE');
my $git_log = File::Spec->catfile($temp, 'git.log');
my $fake_git = File::Spec->catfile($temp, 'fake_git.pl');

# Schreibt Testdateien binaer, damit die erwarteten LF-Zeilenenden erhalten bleiben.
sub write_raw {
	my ($file, $content) = @_;
	open my $output, '>:raw', $file or die "Kann $file nicht schreiben: $!";
	print {$output} $content;
	close $output or die "Kann $file nicht schliessen: $!";
}

# Liest die vollstaendige binaere Testausgabe fuer die Inhaltspruefung ein.
sub read_raw {
	my ($file) = @_;
	open my $input, '<:raw', $file or die "Kann $file nicht lesen: $!";
	local $/;
	my $content = <$input> // '';
	close $input or die "Kann $file nicht schliessen: $!";
	return $content;
}

# Fuehrt den Hook mit einem Git-Dummy aus, ohne den echten Repository-Index zu veraendern.
sub run_hook {
	local $ENV{MQTT2_DISCOVERY_GIT_HELPER} = abs_path($fake_git);
	local $ENV{MQTT2_DISCOVERY_TEST_HEAD_CHANGED} = abs_path($head_changed);
	local $ENV{MQTT2_DISCOVERY_TEST_GIT_LOG} = abs_path($git_log);
	my $result = system(
		$^X,
		abs_path($hook),
		abs_path($paths),
		abs_path($message),
		abs_path($temp),
	);
	is($result, 0, 'TortoiseGit-Hook ist erfolgreich');
}

my $base = <<'CHANGED';
# MQTT2_DISCOVERY changes, newest entries first.
# Generated from commit messages by tools/update_changed.pl.
# Msg-SHA256: 0000000000000000000000000000000000000000000000000000000000000000
- change: MQTT2_DISCOVERY: Bereits committed
CHANGED
write_raw($head_changed, $base);
write_raw($changed, $base . "- change: MQTT2_DISCOVERY: Abgebrochener Versuch\n");
write_raw($paths, "FHEM/10_MQTT2_DISCOVERY.pm\n");
write_raw($git_log, '');
write_raw($fake_git, <<'FAKE_GIT');
#!/usr/bin/env perl
use strict;
use warnings;

if (@ARGV == 2 && $ARGV[0] eq 'show' && $ARGV[1] eq 'HEAD:CHANGED') {
	open my $input, '<:raw', $ENV{MQTT2_DISCOVERY_TEST_HEAD_CHANGED}
		or die "Kann HEAD_CHANGED nicht lesen: $!";
	local $/;
	binmode STDOUT;
	print STDOUT scalar(<$input>);
	close $input or die "Kann HEAD_CHANGED nicht schliessen: $!";
	exit 0;
}

if (@ARGV == 3 && $ARGV[0] eq 'add' && $ARGV[1] eq '--' && $ARGV[2] eq 'CHANGED') {
	open my $log, '>>:raw', $ENV{MQTT2_DISCOVERY_TEST_GIT_LOG}
		or die "Kann Git-Log nicht schreiben: $!";
	print {$log} "add -- CHANGED\n";
	close $log or die "Kann Git-Log nicht schliessen: $!";
	exit 0;
}

die "Unerwarteter Git-Aufruf: @ARGV\n";
FAKE_GIT

write_raw($message, "Ersten TortoiseGit-Eintrag erzeugt\n");
run_hook();
my $first = read_raw($changed);
like($first, qr/^- change: MQTT2_DISCOVERY: Ersten TortoiseGit-Eintrag erzeugt$/m,
	'finale TortoiseGit-Nachricht wird uebernommen');
unlike($first, qr/Abgebrochener Versuch/,
	'abgebrochener vorheriger Versuch wird verworfen');

write_raw($message, "Geaenderte TortoiseGit-Nachricht verwendet\n");
run_hook();
my $second = read_raw($changed);
like($second, qr/^- change: MQTT2_DISCOVERY: Geaenderte TortoiseGit-Nachricht verwendet$/m,
	'geaenderte Nachricht wird beim Wiederholen verwendet');
unlike($second, qr/Ersten TortoiseGit-Eintrag/,
	'Wiederholung beginnt erneut beim committed Stand');
is(read_raw($git_log), "add -- CHANGED\nadd -- CHANGED\n",
	'CHANGED wird bei jedem Versuch gezielt gestaged');

my $configuration = read_raw('.tgitconfig');
# Die Inhaltspruefung gilt fuer Linux- und Windows-Checkouts mit denselben Hook-Einstellungen.
$configuration =~ s/\r\n/\n/g;
like($configuration, qr/^\[hook "precommit"\]$/m,
	'repositoryweiter TortoiseGit-Pre-Commit-Hook ist konfiguriert');
like(
	$configuration,
	qr/^\s*cmdline = "perl \\"%root%\\\\tools\\\\tortoisegit_pre_commit\.pl\\""$/m,
	'TortoiseGit-Hook ueberlaesst die automatischen Parameter der Anwendung',
);

done_testing;
