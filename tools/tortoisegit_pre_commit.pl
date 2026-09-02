#!/usr/bin/env perl

use strict;
use warnings;
use File::Copy qw(copy);
use File::Spec ();
use File::Temp qw(tempfile);

# Erlaubt den Tests einen Git-Dummy, waehrend der produktive Hook git.exe verwendet.
sub git_command {
	return ($^X, $ENV{MQTT2_DISCOVERY_GIT_HELPER})
		if defined($ENV{MQTT2_DISCOVERY_GIT_HELPER})
		&& $ENV{MQTT2_DISCOVERY_GIT_HELPER} ne '';
	return ('git');
}

# Schreibt die unveraenderte Ausgabe eines Git-Lesebefehls binaer in eine Datei.
sub git_output_to_file {
	my ($output, @arguments) = @_;
	my @command = (git_command(), @arguments);
	open my $input, '-|', @command
		or die "Git-Befehl konnte nicht gestartet werden: $!\n";
	binmode $input;
	open my $target, '>:raw', $output
		or die "Kann $output nicht schreiben: $!\n";
	my $buffer;

	# Die Ausgabe wird blockweise uebertragen, damit auch eine grosse Historie stabil bleibt.
	while (1) {
		my $read = read($input, $buffer, 64 * 1024);
		die "Git-Ausgabe konnte nicht gelesen werden: $!\n" if !defined($read);
		last if $read == 0;
		print {$target} $buffer
			or die "Kann $output nicht schreiben: $!\n";
	}

	close $target or die "Kann $output nicht schliessen: $!\n";
	my $closed = close $input;
	my $status = $? >> 8;
	die "Git-Befehl ist mit Exitcode $status fehlgeschlagen.\n" if !$closed;
}

# Fuehrt einen Git-Schreibschritt aus und bricht den TortoiseGit-Commit bei Fehlern ab.
sub run_git {
	my (@arguments) = @_;
	my @command = (git_command(), @arguments);
	my $status = system(@command);
	die "Git-Befehl konnte nicht gestartet werden: $!\n" if $status == -1;
	my $exit_code = $status >> 8;
	die "Git-Befehl ist mit Exitcode $exit_code fehlgeschlagen.\n"
		if $exit_code != 0;
}

my ($paths_file, $message_file, $working_directory) = @ARGV;
die "Verwendung: $0 PATHS MESSAGEFILE CWD\n"
	if @ARGV != 3
	|| !defined($paths_file) || !defined($message_file)
	|| !defined($working_directory);
die "TortoiseGit-Pfaddatei fehlt: $paths_file\n" if !-f $paths_file;
die "TortoiseGit-Commit-Message fehlt: $message_file\n" if !-f $message_file;
die "TortoiseGit-Arbeitsverzeichnis fehlt: $working_directory\n"
	if !-d $working_directory;

my $root = File::Spec->rel2abs($working_directory);
chdir $root or die "Kann nicht in das Projektverzeichnis $root wechseln: $!\n";
my $generator = File::Spec->catfile('tools', 'update_changed.pl');
die "CHANGED-Generator fehlt: $generator\n" if !-f $generator;

my ($temporary_handle, $prepared_changed) = tempfile(
	'.tortoisegit-changed-XXXXXX',
	DIR => '.',
	UNLINK => 1,
);
close $temporary_handle
	or die "Kann $prepared_changed nicht schliessen: $!\n";

# Jeder Versuch beginnt beim committed Stand, damit eine geaenderte Nachricht
# keinen Eintrag eines zuvor abgebrochenen Commit-Versuchs zuruecklaesst.
git_output_to_file($prepared_changed, 'show', 'HEAD:CHANGED');
system(
	$^X,
	$generator,
	'--output', $prepared_changed,
	'--quiet',
	$message_file,
) == 0 or die "Aktualisieren von CHANGED aus der Commit-Message fehlgeschlagen.\n";

copy($prepared_changed, 'CHANGED')
	or die "Kann die vorbereitete CHANGED nicht uebernehmen: $!\n";
run_git('add', '--', 'CHANGED');
print "CHANGED fuer den TortoiseGit-Commit vorbereitet.\n";
