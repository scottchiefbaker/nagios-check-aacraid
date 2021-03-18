#!/usr/bin/env perl

##########################################################
# Nagios plugin to check the status of Adaptec Raid Cards
# Requires arcconf installed and probably sudo as well
#
# Scott Baker - <scott@perturb.org>
# 2021-02-02
#
# Version 0.1
##########################################################

use strict;
use warnings;
use v5.16;
use Getopt::Long;

# For sudo access you need to put the following in your sudo config
# nagios ALL=(root) NOPASSWD: /usr/Arcconf/arcconf GETCONFIG 1 *

my $arcconf_cmd;
if (!is_root()) {
	$arcconf_cmd = "sudo /usr/Arcconf/arcconf GETCONFIG 1";
} else {
	$arcconf_cmd = "/usr/Arcconf/arcconf GETCONFIG 1";
}

###############################################################################
###############################################################################

use constant {
	NAGIOS_OK       => 0,
	NAGIOS_WARNING  => 1,
	NAGIOS_CRITICAL => 2,
	NAGIOS_UNKNOWN  => 3,
};

if (is_running("arcconf")) {
	print "arcconf is already running. Refusing to run again";
	exit(NAGIOS_UNKNOWN);
}

my $verbose      = 0;
my $include_phys = 0;
my $dry;

GetOptions(
	'verbose'  => \$verbose,
	'physical' => \$include_phys,
	'dry=s'    => \$dry,
	'help'     => sub { usage() },
);

my $x = parse_arcconf();

# We start out OK, and change if we find an error
my $exit = NAGIOS_OK;

####################################################
# General Controller Check
####################################################

my @out;

my $controller_ok = $x->{controller}->{temp_str} eq "Normal" && $x->{controller}->{status} eq "Optimal";
if ($controller_ok) {
	push(@out, "Controller: OK");
} else {
	push(@out, "Controller: " . $x->{controller}->{status});
	$exit = NAGIOS_CRITICAL;
}

####################################################
# Logical Disk Check
####################################################

my @lds = @{$x->{logical}};
foreach my $x (@lds) {
	my $ld_ok = $x->{status} eq "Optimal";
	my $name  = $x->{name};

	if ($ld_ok) {
		push(@out, "Logical Disk '$name': OK");
	} else {
		push(@out, "Logical Disk '$name': " . $x->{status});
		$exit = NAGIOS_CRITICAL;
	}
}

####################################################
# Physical Disk Check
####################################################

if ($include_phys && $x->{physical}) {
	my @pds          = @{$x->{physical}};
	my $total        = 0;
	my $total_errors = 0;
	foreach my $x (@pds) {
		my $pd_ok = $x->{state} eq "Online" && $x->{has_errors} == 0;

		if (!$pd_ok) {
			$total_errors++;

			if ($verbose) {
				k($x);
			}
		}

		$total++;
	}

	if ($total_errors) {
		my $good_drives = $total - $total_errors;
		push(@out, "Physical disks: $total_errors drives with errors $good_drives drives OK");
		$exit = NAGIOS_CRITICAL;
	} else {
		push(@out, "Physical disks: $total OK");
	}
}

####################################################
# Output and exit code
####################################################

print join("  ", @out) . "\n";
exit($exit);

###############################################################################
# General functions
###############################################################################

sub parse_arcconf {
	my $str = '';

	# If we're in --dry we load arcconf output from a text file (for testing)
	if ($dry) {
		if (!-r $dry) {
			print "$dry is not readable\n";
			exit(NAGIOS_WARNING);
		}

		$str = file_get_contents($dry);

		if (!$str) {
			print "Unable to load $dry\n";
			exit(NAGIOS_WARNING);
		}
	# Read the full config from arcconf
	} else {
		no warnings "exec";

		$str      = `$arcconf_cmd`;
		my $lexit = $?;

		if ($lexit != 0) {
			print "Error running arcconf: '$arcconf_cmd'\n";
			exit(NAGIOS_CRITICAL);
		}

		if (!trim($str)) {
			print "No output from arcconf?\n";
			exit(NAGIOS_CRITICAL);
		}
	}

	# Split the arcconf config at the major section headings
	my @p = split(/-{70}\n.+?-{70}/s,$str);

	# We should get four sections
	# 0: Bogus empty one from the split
	# 1: Controller config
	# 2: Logical device config
	# 3: Physical device config
	if (scalar(@p) < 4) {
		print "Unable to parse arcconf output. Not enough sections\n";
		exit(NAGIOS_CRITICAL);
	}

	my $ret            = {};
	$ret->{controller} = process_controller_section($p[1]);
	$ret->{logical}    = process_logical_section($p[2]);

	if ($include_phys) {
		$ret->{physical} = process_physical_section($p[3]);
	}

	return $ret;
}

sub process_controller_section {
	my $str = shift();
	my $ret = {};

	($ret->{bios})     = $str =~ /BIOS\s+: ([\d.-]+)/;
	($ret->{mode})     = $str =~ /Controller Mode\s+: (.+)/;
	($ret->{model})    = $str =~ /Controller Model\s+: (.+)/;
	($ret->{serial})   = $str =~ /Controller Serial Number\s+: (.+)/;
	($ret->{temp_f})   = $str =~ /Temperature\s+:.*\/ (\d+)/;
	($ret->{temp_str}) = $str =~ /Temperature\s+:.+?\((\w+)\)/;
	($ret->{status})   = $str =~ /Controller Status\s+: (.+)/;

	my (@temp)  = $str =~ /Temperature\s+: (\d+) C\/ (\d+) F \((.+)\)/;

	$ret->{temp_c}   = $temp[0] || -1;
	$ret->{temp_f}   = $temp[1] || -1;
	$ret->{temp_str} = $temp[2] || "unknown";

	return $ret;
}

sub process_logical_section {
	my $str = shift();
	$str    = trim($str);

	# Break up the string into sections for each LD
	my @ld    = split(/Logical Device number \d+/s, $str);
	# The first one is bogus from the split
	my $trash = shift(@ld);

	my $ret   = [];
	my $count = 0;
	foreach my $str (@ld) {
		($ret->[$count]->{name})        = $str =~ /Logical Device name\s+: (.+)/;
		($ret->[$count]->{raid_level})  = $str =~ /RAID level\s+: (.+)/;
		($ret->[$count]->{size})        = $str =~ /Size\s+: (.+)/;
		($ret->[$count]->{device_type}) = $str =~ /Device Type\s+: (.+)/;
		($ret->[$count]->{status})      = $str =~ /Status of Logical Device\s+: (.+)/;
		$count++;
	}

	#kd($ret);

	return $ret;
}

sub process_physical_section {
	my $str = shift();

	# Not all arcconf spits out per disk error stats?
	if ($str !~ /Hardware Error Count/) {
		print STDERR "Warning: Your arcconf output does not include physical disk errors\n";
		print STDERR "You may need to upgrade firmware to get individual disk error stats\n";
		print STDERR "\n";

		return undef;
	}

	# Split the string in to individual sections PER disk
	my @pds = split(/Device \#\d+/, $str);
	# Remove any empty sections
	@pds = grep { length(trim($_)) > 0; } @pds;

	my $count = 0;
	my $ret   = [];
	foreach my $x (@pds) {
		# Skip enclosures or anything that is NOT a HDD/SSD
		if ($x !~ /Device is a Hard drive/) {
			next;
		}

		($ret->[$count]->{state})  = $x =~ /State\s+: (.+)/;
		($ret->[$count]->{vendor}) = $x =~ /Vendor\s+: (.+)/;
		($ret->[$count]->{model})  = $x =~ /Model\s+: (.+)/;
		($ret->[$count]->{is_ssd}) = $x =~ /SSD\s+: (.+)/;
		($ret->[$count]->{size})   = $x =~ /Total Size\s+: (.+)/;
		($ret->[$count]->{serial}) = $x =~ /Serial number\s+: (.+)/;

		($ret->[$count]->{errors}->{hardware})       = $x =~ /Hardware Error Count\s+: (\d+)/;
		($ret->[$count]->{errors}->{medium})         = $x =~ /Medium Error Count\s+: (\d+)/;
		($ret->[$count]->{errors}->{parity})         = $x =~ /Parity Error Count\s+: (\d+)/;
		($ret->[$count]->{errors}->{link_fail})      = $x =~ /Link Failure Count\s+: (\d+)/;
		($ret->[$count]->{errors}->{aborted})        = $x =~ /Aborted Command Count\s+: (\d+)/;
		($ret->[$count]->{errors}->{smart_warnings}) = $x =~ /SMART Warning Count\s+: (\d+)/;

		($ret->[$count]->{has_errors}) =
			$ret->[$count]->{errors}->{hardware} +
			$ret->[$count]->{errors}->{medium} +
			$ret->[$count]->{errors}->{parity} +
			$ret->[$count]->{errors}->{link_fail} +
			#$ret->[$count]->{errors}->{aborted} + # This was generating false positives so we skip it for now
			$ret->[$count]->{errors}->{smart_warnings};

		# We remove the individual error reports from the return object so it's less verbose
		# All we really care about is "are there some errors" or not... not what type
		delete($ret->[$count]->{errors});

		$count++;
	}

	return $ret;
}

sub usage {
	print "Usage: $0 [--physical]\n";
	exit(NAGIOS_OK);
}

#####################################################
# Boilerplate functions
#####################################################

sub trim {
	my $s = shift();
	if (!defined($s) || length($s) == 0) { return ""; }
	$s =~ s/^\s*//;
	$s =~ s/\s*$//;

	return $s;
}

sub file_get_contents {
	my $file = shift();
	open (my $fh, "<", $file) or return undef;

	my $ret;
	while (<$fh>) { $ret .= $_; }

	return $ret;
}

sub file_put_contents {
	my ($file, $data) = @_;
	open (my $fh, ">", $file) or return undef;

	print $fh $data;
	return length($data);
}

sub is_root {
	my ($name, $passwd, $uid, $gid, $quota, $comment, $gcos, $dir, $shell) = getpwuid(0);

	my $ret = ($uid == 0);

	return $ret;
}

sub is_running {
	my $prog = shift();

	my $out = `pgrep $prog`;
	my @ret = split(' ', $out);

	return @ret;
}

# Debug print variable using either Data::Dump::Color (preferred) or Data::Dumper
# Creates methods k() and kd() to print, and print & die respectively
BEGIN {
	if (eval { require Data::Dump::Color }) {
		*k = sub { Data::Dump::Color::dd(@_) };
	} else {
		require Data::Dumper;
		*k = sub { print Data::Dumper::Dumper(\@_) };
	}

	sub kd {
		k(@_);

		printf("Died at %2\$s line #%3\$s\n",caller());
		exit(15);
	}
}

# vim: tabstop=4 shiftwidth=4 autoindent softtabstop=4
