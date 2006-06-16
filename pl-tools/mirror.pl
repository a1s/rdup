#!/usr/bin/perl -w
#
# Copyright (c) 2005, 2006 Miek Gieben; Mark J Hewitt
# See LICENSE for the license
#
# This script implement a mirroring backup scheme
# -c is used for remote mirroring

use strict;

use Getopt::Std;
use File::Basename;
use File::Path;
use File::Copy;
use File::Copy::Recursive qw(dircopy rcopy fcopy);
use Fcntl qw(:mode);

my $ts = time;
my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($ts);

my $S_MMASK = 07777;			# mask to get permission
my $S_ISDIR = 040000;
my $S_ISLNK = 0120000;

my $progName = basename $0;

my %opt;

getopts('acvhb:V', \%opt);

usage() if $opt{'h'};			# Usage for -h
version() if $opt{'V'};			# Version for -V
my $verbose = $opt{'v'};		# Verbose messages for -v
my $attr = $opt{'a'};			# Extended attributes set for -a
my $remote = $opt{'c'};			# Find content in pipe for -c
my $hostname = `hostname`;		# This hostname
chomp $hostname;
                                        # Location of backup root in local filesystem
my $backupDir = (defined $opt{'b'} ? $opt{'b'} : "/vol/backup/" . $hostname) . "/" . sprintf "%04d%02d", 1900+$year, $mon;

my $attr_there = check_attr();		# Can we set extended attributes?

# Statistics
my $ftsize = 0;				# Total file size
my $ireg = 0;				# Number of regular files
my $idir = 0;				# Number of directories
my $ilnk = 0;				# Number of symbolic links
my $irm  = 0;				# Number of files removed

if ($remote)
{
    remote_mirror($backupDir);
}
else
{
    local_mirror($backupDir);
}

my $te = time;
printf STDERR "** #REG FILES  : %d\n", $ireg;
printf STDERR "** #DIRECTORIES: %d\n", $idir;
printf STDERR "** #LINKS      : %d\n", $ilnk;
printf STDERR "** #(RE)MOVED  : %d\n", $irm;
printf STDERR "** SIZE        : %d KB\n", $ftsize/1024;
printf STDERR "** STORED IN   : %s\n", $backupDir;
printf STDERR "** ELAPSED     : %d s\n", $te - $ts;

exit 0;


sub local_mirror
{
    my $dir = $_[0];

    while (($_ = <STDIN>))
    {
	chomp;
	my($mode, $uid, $gid, $psize, $fsize, $path) = split;
	my $dump = substr($mode, 0, 1);
	my $modebits = substr($mode, 1);

	sanity_check($dump, $modebits, $psize, $fsize, $uid, $gid);

	my $bits=$modebits & $S_MMASK; # permission bits
	my $typ = 0;
	$typ = 1 if ($modebits & $S_ISDIR) == $S_ISDIR;
	$typ = 2 if ($modebits & $S_ISLNK) == $S_ISLNK;
	print STDERR "$path\n" if $verbose;
	my $target = "$dir/$path";
	my $suffix = mirror_suffix($target);

	if ($dump eq '+')
	{				# add
	    if ($typ == 0)
	    {				# REG
		if ($suffix)
		{			# We only have a suffix if the file exists
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		copy($path, $target) or die "Copy failed: $!";
		chown $uid, $gid, $target;
		chown_attr($uid, $gid, $target);
		chmod $modebits, $target;
		$ftsize += $fsize;
		$ireg++;
	    }
	    elsif ($typ == 1)
	    {
		if (-f _ || -l _)
		{			# Type of entiry has changed
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		mkpath($target) unless -d _;
		chown $uid, $gid, $target;
		chown_attr($uid, $gid, $target);
		if ($> != 0 && $bits == 0)
		{
		    print STDERR "chmod $target to 700\n";
		    $bits = 0700;
		}
		chmod $bits, $target;
		$idir++;
	    }
	    elsif ($typ == 2)
	    {				# LNK; target id the content
		if ($suffix)
		{			# We only have a suffix if the file exists
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		copy $path, $target or die "$path: $!";
		chown $uid, $gid, $target;
		chown_attr($uid, $gid, $target);
		$ilnk++;
	    }
	}
	else
	{	     # move. It could be the stuff is not there, don't error on that.
	    if ($suffix)
	    {
		rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		$irm++;
	    }
	}
    }
}



sub remote_mirror
{
    my $dir = $_[0];

    while (($_ = <STDIN>))
    {
	chomp;

	my($mode, $uid, $gid, $psize, $fsize) = split;
	my $dump = substr($mode, 0, 1);
	my $modebits = substr($mode, 1);

	sanity_check($dump, $modebits, $psize, $fsize, $uid, $gid);
	my $path = "";
	read STDIN, $path, $psize;

	my $bits = $modebits & $S_MMASK;
	my $typ = 0;
	$typ = 1 if ($modebits & $S_ISDIR) == $S_ISDIR;
	$typ = 2 if ($modebits & $S_ISLNK) == $S_ISLNK;
	print STDERR "$path\n" if $verbose;
	my $target = "$dir/$path";
	my $suffix = mirror_suffix($target);
#
#       NOTE - mirror_suffix() calls stat() on the target.  We rely on thet below to avoid multiple expensive calls to stat.
#       If mirror_suffix is changed, or is naot called, it will be necassary to revise this assumtion.
#
	if ($dump eq '+')
	{				# add
	    if ($typ == 0)
	    {				# REG
		if ($suffix)
		{			# We only have a suffix if the file exists
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		open FILE, ">$target" or die "Cannot create $target: $!";
		if ($fsize != 0)
		{
		    copyout($fsize, *FILE);
		}
		chown $uid, $gid, *FILE;
		chown_attr($uid, $gid, $target);
		chmod $bits, *FILE;
		close FILE;
		$ftsize += $fsize;
		$ireg++;
	    }
	    elsif ($typ == 1)
	    {				# DIR
		if (-f _ || -l _)
		{			# Type of entiry has changed
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		mkpath($target) unless -d _;
		chown $uid, $gid, $target;
		chown_attr($uid, $gid, $target);
		if ($> != 0 && $bits == 0)
		{
		    print STDERR "chmod $target to 700\n";
		    $bits = 0700;
		}
		chmod $bits, $target;
		$idir++;
	    }
	    elsif ($typ == 2)
	    {				# LNK; target id the content
		if ($suffix)
		{			# We only have a suffix if the file exists
		    rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
		}
		my $linkTarget = "";
		read STDIN, $linkTarget, $fsize;
		symlink $target, $linkTarget;
		chown $uid, $gid, $target;
		chown_attr($uid, $gid, $target);
		$ilnk++;
	    }
	}
	else
	{				# Remove
	    if ($suffix)
	    {			# We only have a suffix if the file exists
		rename $target, ($target . $suffix) or die "Cannot rename $target: $!";
	    }
	    $irm++;
	}
    }
}


sub chown_attr
{
    return unless $attr_there;
    return unless $attr;

    my $xuid = $_[0];
    my $xgid = $_[1];
    my $file = $_[2];

    if ($^O eq "linux")
    {
	system("attr -q -s r_uid -V$xuid \"$file\"");
	system("attr -q -s r_gid -V$xgid \"$file\"");
    }
}


# Eg:
# 2006-05-05 01:50:18.000000000 +0100
#         ^^ ^^^^^
# => "+05.01:50
#
sub mirror_suffix
{
    my $filename = $_[0];

    lstat($filename);
    return "" unless -e _;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime((lstat(_))[9]);
    return sprintf "+%02d.%02d:%02d", $mday, $hour, $min;
}


sub sanity_check
{
    my $dump = $_[0];
    my $mode = $_[1];
    my $psize = $_[2];
    my $fsize = $_[3];
    my $uid = $_[4];
    my $gid = $_[5];

    die "$progName: dump ($dump) must be + or -"   if $dump ne "+" && $dump ne "-";
    die "$progName: mode ($mode) must be numeric"  unless $mode =~ "[0-9]+";
    die "$progName: psize ($psize) must be numeric" unless $psize =~ "[0-9]+";
    die "$progName: fsize ($fsize) must be numeric" unless $fsize =~ "[0-9]+";
    die "$progName: uid ($uid) must be numeric"   unless $uid =~ "[0-9]+";
    die "$progName: gid ($gid) must be numeric"   unless $gid =~ "[0-9]+";
}


sub check_attr
{
    if ($^O eq "linux")
    {
	map {return 1 if -x $_ . '/' . "attr"}  split(/:/, $ENV{'PATH'});
    }
    else
    {
	warn "Cannot set extended attributes";
    }
    return 0;
}


sub usage
{
    print "$progName [OPTIONS]\n\n";
    print "Mirror the files from the filelist of rdup\n\n";
    print "OPTIONS\n";
    print " -a      write extended attributes r_uid/r_gid with uid/gid\n";
    print " -c      process the file content also (rdup -c), for remote backups\n";
    print " -b DIR  use DIR as the backup directory, YYYYMM will be added\n";
    print " -v      print the files processed to stderr\n";
    print " -h      this help\n";
    print " -V      print version\n";
}

sub version
{
    print "** $progName: 0.2.12 (rdup-utils)"
}

sub copyout
{
    my $count = $_[0];
    my $pipe = $_[1];

    my $buf;
    my $n;

    while ($count > 4096)
    {
	$n = read STDIN, $buf, 4096;
	syswrite $pipe, $buf, $n;
	$count -= 4096;
    }
    if ($count > 0)
    {
	$n = read STDIN, $buf, $count;
	syswrite $pipe, $buf, $n;
    }
}