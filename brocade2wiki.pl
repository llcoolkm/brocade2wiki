#!/usr/bin/perl
#
# WHO
#   david.henden@addpro.se
#
# WHEN
#   Sat Sep  8 12:26:17 CEST 2018
#
# WHAT
#
#   - Read YAML config and read switch login info
#   - Connect to each switch and run switchshow
#   - Collect data for each port
#   - Write a port status table to a wiki page
#
# YAML
#
# switchname:
#   user: username
#   pass: password
#
# TODO
#
#   - Show more port attributes (portcfgshow)?
#
#------------------------------------------------------------------------------

use strict;
use warnings;
use Carp;
use Net::SSH::Perl;
use Net::Ping;
use File::Slurp;
use Time::Local;
use YAML qw(LoadFile);
use Data::Dumper;

# Settings {{{

use constant CONFIGFILE => '/root/scripts/switches.yml';

my $DEBUG = 0;
my $QUIET = 0;

use constant CMD_SWITCH    => 'switchshow';
use constant CMD_PORT      => 'portshow ';
use constant CMD_PORTCFG   => 'portcfgshow ';
use constant WIKIBASEDIR   => '/var/www/html/dokuwiki/data/pages/storage/switches/';
use constant WIKISTART     => '/start.txt';;
use constant SECTIONHEADER => "===== Ports =====\n\n";
use constant TABLEHEADER   => "^Port^Speed^State^Node^\n";
use constant TABLEROW      => "|%i|%s|%s|%s|\n";


# }}}
# Main script {{{
#------------------------------------------------------------------------------

my @DATE = (localtime time)[5,4,3,2,1];
my $DATE = sprintf "%02i-%02i-%02i %02i:%02i",
   $DATE[0] + 1900, ++$DATE[1], $DATE[2], $DATE[3], $DATE[4];

print "DATE: $DATE\n" unless $QUIET;

open my $fh_cfg, '<', CONFIGFILE or croak;
my $SWITCHES = LoadFile($fh_cfg);
close $fh_cfg;
$DEBUG and print Dumper($SWITCHES);

&get_input();
&write_wiki();

# }}}
# switch_command() {{{
#------------------------------------------------------------------------------

sub switch_command()
{
	my $switch  = shift;
	my $command = shift;
	my $stdout  = undef;
	my $stderr  = undef;
    my $exit    = undef;
	my $ping    = Net::Ping->new();

	# Only connect if switch is alive since Net::SSH has no error handling
	if ($ping->ping($switch))
	{

		# Log on to switch
		my $ssh = Net::SSH::Perl->new($switch);

		$ssh->login($SWITCHES->{$switch}{'user'}, $SWITCHES->{$switch}{'pass'});

		# Run command
		($stdout, $stderr, $exit) = $ssh->cmd($command);

		if ($DEBUG)
		{
			print "OUT: $stdout";
			print "ERR: $stderr";
			print "RC : $exit";
		}
	}
	else
	{
		print "No ping reply - skipping!\n" unless $QUIET;
	}

	return $stdout;
}

# }}}
# Process switches {{{
#------------------------------------------------------------------------------

sub get_input()
{
	for my $switch (sort keys %{$SWITCHES})
	{
		my $i = 0;

		print "SWITCH $switch\n" unless $QUIET;
		my $stdout = &switch_command($switch, CMD_SWITCH);
		next unless defined $stdout;

		# Loop output and store in global hash
		foreach (split /\n/, $stdout)
		{
			my (undef, $index, $port, $address, $media, $speed, $state, $proto, @rest) = split /\s+/;

			if (defined $port and $port =~ /\d/)
			{
				$i++;
				my $node = "@rest";

				$speed = ' ' unless $speed;
				$state = ' ' unless $state;
				$node  = ' ' unless $node;
				$node  =~ s/^[A-Z]+-Port //;

				$SWITCHES->{$switch}{'port'}{$port}{'speed'} = $speed;
				$SWITCHES->{$switch}{'port'}{$port}{'state'} = $state;
				$SWITCHES->{$switch}{'port'}{$port}{'node'}  = $node;

				# Handle NPIV
				if ($node =~ /NPIV/)
				{
					my @wwns;

					$stdout = &switch_command($switch, CMD_PORT . $port);
					foreach (split /\n/, $stdout)
					{
						push(@wwns, $1) if (/^\s+(\d+:.*)$/)
					}
					$node = join(', ', @wwns);
					$DEBUG and print "NODE: $node\n";
					$SWITCHES->{$switch}{'port'}{$port}{'node'} = $node;
				}

#				# Handle port attributes
#				$stdout = &switch_command($switch, CMD_PORTCFG . $port);
#				foreach (split /\n/, $stdout)
#				{
#					$DEBUG and print "$_\n";
#				}
#				#$SWITCHES{$switch}{'port'}{$port}{'node'} = $node;
			}
		}
		print "Found $i ports\n" unless $QUIET;
	}

	return defined;
}

# }}}
# Write output {{{
#------------------------------------------------------------------------------

sub write_wiki()
{
	my $fh_wiki;

	# Loop over switches
	for my $switch (keys %{$SWITCHES})
	{
		my ($section, $switchfile, $switchpage);

		next unless defined $SWITCHES->{$switch}{'port'};

		$switchfile = WIKIBASEDIR . $switch . WIKISTART;
		print "Writing $switchfile\n" unless $QUIET;
		$switchpage = read_file($switchfile, err_mode => 'quiet');
		next unless $switchpage;

		# Build our wiki section
		$section = sprintf SECTIONHEADER;
		$section .= sprintf TABLEHEADER;

		# Loop over ports
		for my $port (sort { $a <=> $b } keys %{$SWITCHES->{$switch}{'port'}})
		{
			$section .= sprintf TABLEROW,
				$port,
				$SWITCHES->{$switch}{'port'}{$port}{'speed'},
				$SWITCHES->{$switch}{'port'}{$port}{'state'},
				$SWITCHES->{$switch}{'port'}{$port}{'node'};
		}

		$section .= "\n";
		$section .= "Updated: $DATE";
		$section .= "\n\n";

		# Find section ===== Ports ===== and replace to next =
		$switchpage =~ s/===== Ports =====[^=]+=/$section=/g;
		$DEBUG and print $section;
		$DEBUG and print $switchpage;

		# Write
		write_file $switchfile, $switchpage;
	}

	return;
}

# }}}
