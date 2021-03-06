################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package Build;

use strict;
use Digest::MD5;
use Build::Rpm;
use Data::Dumper;
use POSIX qw(strftime);

our $expand_dbg;

our $do_rpm;
our $do_deb;
our $do_kiwi;
our $do_arch;
our $do_livebuild;

sub import {
  for (@_) {
    $do_rpm = 1 if $_ eq ':rpm';
    $do_deb = 1 if $_ eq ':deb';
    $do_kiwi = 1 if $_ eq ':kiwi';
    $do_arch = 1 if $_ eq ':arch';
    $do_livebuild = 1 if $_ eq ':livebuild';
  }
  $do_rpm = $do_deb = $do_kiwi = $do_arch = $do_livebuild = 1 if !$do_rpm && !$do_deb && !$do_kiwi && !$do_arch && !$do_livebuild;
  if ($do_deb) {
    require Build::Deb;
  }
  if ($do_kiwi) {
    require Build::Kiwi;
  }
  if ($do_arch) {
    require Build::Arch;
  }
  if ($do_livebuild) {
    require Build::LiveBuild;
  }
}

package Build::Features;
our $preinstallimage = 1;	# on sale now
package Build;

my $std_macros = q{
%define nil
%define ix86 i386 i486 i586 i686 athlon
%define arm armv4l armv5l armv6l armv7l armv4b armv5l armv5b armv5el armv5eb armv5tel armv5teb armv6hl armv6el armv6eb armv7el armv7eb armv7hl armv7nhl armv8el
%define arml armv4l armv5l armv6l armv7l armv5tel armv5el armv6el armv6hl armv7el armv7hl armv7nhl armv8el
%define armb armv4b armv5b armv5teb armv5eb armv6eb armv7eb
%define sparc sparc sparcv8 sparcv9 sparcv9v sparc64 sparc64v
};
my $extra_macros = '';

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub define($)
{
  my $def = shift;
  $extra_macros .= '%define '.$def."\n";
}

sub init_helper_hashes {
  my ($config) = @_;

  $config->{'preferh'} = { map {$_ => 1} @{$config->{'prefer'}} };

  my %ignore;
  for (@{$config->{'ignore'}}) {
    if (!/:/) {
      $ignore{$_} = 1;
      next;
    }
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    $ignore{"$s:$_"} = 1 for @s;
  }
  $config->{'ignoreh'} = \%ignore;

  my %conflicts;
  for (@{$config->{'conflict'}}) {
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    push @{$conflicts{$s}}, @s;
    push @{$conflicts{$_}}, $s for @s;
  }
  for (keys %conflicts) {
    $conflicts{$_} = [ unify(@{$conflicts{$_}}) ]
  }
  $config->{'conflicth'} = \%conflicts;
}

# 'canonicalize' dist string as found in rpm dist tags
sub dist_canon($$) {
  my ($rpmdist, $arch) = @_;
  $rpmdist = lc($rpmdist);
  $rpmdist =~ s/-/_/g;
  $rpmdist =~ s/opensuse/suse linux/;
  my $rpmdista;
  if ($rpmdist =~ /\(/) {
    $rpmdista = $rpmdist;
    $rpmdista =~ s/.*\(//;
    $rpmdista =~ s/\).*//;
  } else {
    $rpmdista = $arch;
  }
  $rpmdista =~ s/i[456]86/i386/;
  $rpmdist = '' unless $rpmdista =~ /^(i386|x86_64|ia64|ppc|ppc64|ppc64le|s390|s390x)$/;
  my $dist = 'default';
  if ($rpmdist =~ /unitedlinux 1\.0.*/) {
    $dist = "ul1-$rpmdista";
  } elsif ($rpmdist =~ /suse sles_(\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux enterprise (\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (\d+)\.(\d+)\.[4-9]\d/) {
    # alpha version
    $dist = "$1.".($2 + 1)."-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (\d+\.\d+)/) {
    $dist = "$1-$rpmdista";
  }
  return $dist;
}

sub read_config_dist {
  my ($dist, $archpath, $configdir) = @_;

  my $arch = $archpath;
  $arch = 'noarch' unless defined $arch;
  $arch =~ s/:.*//;
  $arch = 'noarch' if $arch eq '';
  die("Please specify a distribution!\n") unless defined $dist;
  if ($dist !~ /\//) {
    my $saved = $dist;
    $configdir = '.' unless defined $configdir;
    $dist =~ s/-.*//;
    $dist = "sl$dist" if $dist =~ /^\d/;
    $dist = "$configdir/$dist.conf";
    if (! -e $dist) {
      $dist =~ s/-.*//;
      $dist = "sl$dist" if $dist =~ /^\d/;
      $dist = "$configdir/$dist.conf";
    }
    if (! -e $dist) {
      warn "$saved.conf not found, using default.conf\n" unless $saved eq 'default';
      $dist = "$configdir/default.conf";
    }
  }
  die("$dist: $!\n") unless -e $dist;
  my $cf = read_config($arch, $dist);
  die("$dist: parse error\n") unless $cf;
  return $cf;
}

sub read_config {
  my ($arch, $cfile) = @_;
  my @macros = split("\n", $std_macros.$extra_macros);
  push @macros, "%define _target_cpu $arch";
  push @macros, "%define _target_os linux";
  my $config = {'macros' => \@macros, 'arch' => $arch};
  my @config;
  if (ref($cfile)) {
    @config = @$cfile;
  } elsif (defined($cfile)) {
    local *CONF;
    return undef unless open(CONF, '<', $cfile);
    @config = <CONF>;
    close CONF;
    chomp @config;
  }
  # create verbatim macro blobs
  my @newconfig;
  while (@config) {
    push @newconfig, shift @config;
    next unless $newconfig[-1] =~ /^\s*macros:\s*$/si;
    $newconfig[-1] = "macros:\n";
    while (@config) {
      my $l = shift @config;
      last if $l =~ /^\s*:macros\s*$/si;
      $newconfig[-1] .= "$l\n";
    }
  }
  my @spec;
  $config->{'save_expanded'} = 1;
  Build::Rpm::parse($config, \@newconfig, \@spec);
  delete $config->{'save_expanded'};
  $config->{'preinstall'} = [];
  $config->{'vminstall'} = [];
  $config->{'cbpreinstall'} = [];
  $config->{'cbinstall'} = [];
  $config->{'runscripts'} = [];
  $config->{'required'} = [];
  $config->{'support'} = [];
  $config->{'keep'} = [];
  $config->{'prefer'} = [];
  $config->{'ignore'} = [];
  $config->{'conflict'} = [];
  $config->{'substitute'} = {};
  $config->{'substitute_vers'} = {};
  $config->{'optflags'} = {};
  $config->{'order'} = {};
  $config->{'exportfilter'} = {};
  $config->{'publishfilter'} = [];
  $config->{'rawmacros'} = '';
  $config->{'release'} = '<CI_CNT>.<B_CNT>';
  $config->{'repotype'} = [];
  $config->{'patterntype'} = [];
  $config->{'fileprovides'} = {};
  $config->{'constraint'} = [];
  $config->{'expandflags'} = [];
  $config->{'buildflags'} = [];
  $config->{'singleexport'} = '';
  for my $l (@spec) {
    $l = $l->[1] if ref $l;
    next unless defined $l;
    my @l = split(' ', $l);
    next unless @l;
    my $ll = shift @l;
    my $l0 = lc($ll);
    if ($l0 eq 'macros:') {
      $l =~ s/.*?\n//s;
      if ($l =~ /^!\n/s) {
	$config->{'rawmacros'} = substr($l, 2);
      } else {
	$config->{'rawmacros'} .= $l;
      }
      next;
    }
    if ($l0 eq 'preinstall:' || $l0 eq 'vminstall:' || $l0 eq 'required:' || $l0 eq 'support:' || $l0 eq 'keep:' || $l0 eq 'prefer:' || $l0 eq 'ignore:' || $l0 eq 'conflict:' || $l0 eq 'runscripts:' || $l0 eq 'expandflags:' || $l0 eq 'buildflags:') {
      my $t = substr($l0, 0, -1);
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{$t} = [];
	} elsif ($l =~ /^!/) {
	  $config->{$t} = [ grep {"!$_" ne $l} @{$config->{$t}} ];
	} else {
	  push @{$config->{$t}}, $l;
	}
      }
    } elsif ($l0 eq 'substitute:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'substitute'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'substitute'}->{$1};
      } else {
	$config->{'substitute'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'fileprovides:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'fileprovides'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'fileprovides'}->{$1};
      } else {
	$config->{'fileprovides'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'exportfilter:') {
      next unless @l;
      $ll = shift @l;
      $config->{'exportfilter'}->{$ll} = [ @l ];
    } elsif ($l0 eq 'publishfilter:') {
      $config->{'publishfilter'} = [ @l ];
    } elsif ($l0 eq 'optflags:') {
      next unless @l;
      $ll = shift @l;
      $config->{'optflags'}->{$ll} = join(' ', @l);
    } elsif ($l0 eq 'order:') {
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{'order'} = {};
	} elsif ($l =~ /^!(.*)$/) {
	  delete $config->{'order'}->{$1};
	} else {
	  $config->{'order'}->{$l} = 1;
	}
      }
    } elsif ($l0 eq 'repotype:') { # type of generated repository data
      $config->{'repotype'} = [ @l ];
    } elsif ($l0 eq 'type:') { # kind of recipe system (spec,dsc,arch,kiwi,...)
      $config->{'type'} = $l[0];
    } elsif ($l0 eq 'buildengine:') { # build engine (build,mock)
      $config->{'buildengine'} = $l[0];
    } elsif ($l0 eq 'binarytype:') { # kind of binary packages (rpm,deb,arch,...)
      $config->{'binarytype'} = $l[0];
    } elsif ($l0 eq 'patterntype:') { # kind of generated patterns in repository
      $config->{'patterntype'} = [ @l ];
    } elsif ($l0 eq 'release:') {
      $config->{'release'} = $l[0];
    } elsif ($l0 eq 'cicntstart:') {
      $config->{'cicntstart'} = $l[0];
    } elsif ($l0 eq 'releaseprg:') {
      $config->{'releaseprg'} = $l[0];
    } elsif ($l0 eq 'releasesuffix:') {
      $config->{'releasesuffix'} = join(' ', @l);
    } elsif ($l0 eq 'changetarget:' || $l0 eq 'target:') {
      $config->{'target'} = join(' ', @l);
      push @macros, "%define _target_cpu ".(split('-', $config->{'target'}))[0] if $config->{'target'};
    } elsif ($l0 eq 'hostarch:') {
      $config->{'hostarch'} = join(' ', @l);
    } elsif ($l0 eq 'constraint:') {
      my $l = join(' ', @l);
      if ($l eq '!*') {
	$config->{'constraint'} = [];
      } else {
	push @{$config->{'constraint'}}, $l;
      }
    } elsif ($l0 eq 'singleexport:') {
      $config->{'singleexport'} = $l[0]; # avoid to export multiple package container in maintenance_release projects
    } elsif ($l0 !~ /^[#%]/) {
      warn("unknown keyword in config: $l0\n");
    }
  }
  for my $l (qw{preinstall vminstall required support keep runscripts repotype patterntype}) {
    $config->{$l} = [ unify(@{$config->{$l}}) ];
  }
  for my $l (keys %{$config->{'substitute'}}) {
    $config->{'substitute_vers'}->{$l} = [ map {/^(.*?)(=)?$/g} unify(@{$config->{'substitute'}->{$l}}) ];
    $config->{'substitute'}->{$l} = [ unify(@{$config->{'substitute'}->{$l}}) ];
    s/=$// for @{$config->{'substitute'}->{$l}};
  }
  init_helper_hashes($config);
  if (!$config->{'type'}) {
    # Fallback to old guessing method if no type (spec, dsc or kiwi) is defined
    if (grep {$_ eq 'rpm'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'spec';
    } elsif (grep {$_ eq 'debianutils'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'dsc';
    } elsif (grep {$_ eq 'pacman'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'arch';
    } else {
      $config->{'type'} = 'UNDEFINED';
    }
  }
  if (!$config->{'binarytype'}) {
    $config->{'binarytype'} = 'rpm' if $config->{'type'} eq 'spec' || $config->{'type'} eq 'kiwi';
    $config->{'binarytype'} = 'deb' if $config->{'type'} eq 'dsc' || $config->{'type'} eq 'livebuild';
    $config->{'binarytype'} = 'arch' if $config->{'type'} eq 'arch';
    $config->{'binarytype'} ||= 'UNDEFINED';
  }
  # add rawmacros to our macro list
  if ($config->{'rawmacros'} ne '') {
    for my $rm (split("\n", $config->{'rawmacros'})) {
      if (@macros && $macros[-1] =~ /\\$/) {
	if ($rm =~ /\\$/) {
	  push @macros, '...\\';
	} else {
	  push @macros, '...';
	}
      } elsif ($rm !~ /^%/) {
	push @macros, $rm;
      } else {
	push @macros, "%define ".substr($rm, 1);
      }
    }
  }
  for (@{$config->{'expandflags'} || []}) {
    if (/^([^:]+):(.*)$/s) {
      $config->{"expandflags:$1"} = $2;
    } else {
      $config->{"expandflags:$_"} = 1;
    }
  }
  for (@{$config->{'buildflags'} || []}) {
    if (/^([^:]+):(.*)$/s) {
      $config->{"buildflags:$1"} = $2;
    } else {
      $config->{"buildflags:$_"} = 1;
    }
  }
  return $config;
}

sub do_subst {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute'};
  while (@deps) {
    my $d = shift @deps;
    next if $done{$d};
    my $ds = $d;
    $ds =~ s/\s*[<=>].*$//s;
    if ($subst->{$ds}) {
      unshift @deps, @{$subst->{$ds}};
      push @res, $d if grep {$_ eq $ds} @{$subst->{$ds}};
    } else {
      push @res, $d;
    }
    $done{$d} = 1;
  }
  return @res;
}

sub do_subst_vers {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute_vers'};
  while (@deps) {
    my ($d, $dv) = splice(@deps, 0, 2);
    next if $done{$d};
    if ($subst->{$d}) {
      unshift @deps, map {defined($_) && $_ eq '=' ? $dv : $_} @{$subst->{$d}};
      push @res, $d, $dv if grep {defined($_) && $_ eq $d} @{$subst->{$d}};
    } else {
      push @res, $d, $dv;
    }
    $done{$d} = 1;
  }
  return @res;
}

my %subst_defaults = (
  # defaults live-build package dependencies base on 4.0~a26 gathered with:
  # grep Check_package -r /usr/lib/live/build
  'build-packages:livebuild' => [
    'apt-utils', 'dctrl-tools', 'debconf', 'dosfstools', 'e2fsprogs', 'grub',
    'librsvg2-bin', 'live-boot', 'live-config', 'mtd-tools', 'parted',
    'squashfs-tools', 'syslinux', 'syslinux-common', 'wget', 'xorriso', 'zsync',
  ],
  'system-packages:livebuild' => [
    'apt-utils', 'cpio', 'dpkg-dev', 'live-build', 'lsb-release', 'tar',
  ],
  'system-packages:mock' => [
    'mock', 'createrepo',
  ],
  'system-packages:debootstrap' => [
    'debootstrap', 'lsb-release',
  ],
  'system-packages:kiwi-image' => [
    'kiwi', 'createrepo', 'tar',
  ],
  'system-packages:kiwi-product' => [
    'kiwi',
  ],
  'system-packages:deltarpm' => [
    'deltarpm',
  ],
);

# Delivers all packages which get used for building
sub get_build {
  my ($config, $subpacks, @deps) = @_;

  if ($config->{'type'} eq 'livebuild') {
    push @deps, @{$config->{'substitute'}->{'build-packages:livebuild'}
		  || $subst_defaults{'build-packages:livebuild'} || []};
  }
  my @ndeps = grep {/^-/} @deps;
  my %ndeps = map {$_ => 1} @ndeps;
  my @directdepsend;
  if ($ndeps{'--directdepsend--'}) {
    @directdepsend = @deps;
    for (splice @deps) {
      last if $_ eq '--directdepsend--';
      push @deps, $_;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @deps + 1);
  }
  my @extra = (@{$config->{'required'}}, @{$config->{'support'}});
  if (@{$config->{'keep'} || []}) {
    my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
    for (@{$subpacks || []}) {
      next if $keep{$_};
      push @ndeps, "-$_";
      $ndeps{"-$_"} = 1;
    }
  } else {
    # new "empty keep" mode, filter subpacks from required/support
    my %subpacks = map {$_ => 1} @{$subpacks || []};
    @extra = grep {!$subpacks{$_}} @extra;
  }
  @deps = grep {!$ndeps{$_}} @deps;
  push @deps, @{$config->{'preinstall'}};
  push @deps, @extra;
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  if (@directdepsend) {
    @directdepsend = do_subst($config, @directdepsend);
    @directdepsend = grep {!$ndeps{"-$_"}} @directdepsend;
    unshift @directdepsend, '--directdepsend--' if @directdepsend;
  }
  @deps = expand($config, @deps, @ndeps, @directdepsend);
  return @deps;
}

# return the package needed for setting up the build environment.
# an empty result means that the packages from get_build should
# be used instead.
sub get_sysbuild {
  my ($config, $buildtype, $extradeps) = @_;
  my $engine = $config->{'buildengine'} || '';
  $buildtype ||= $config->{'type'} || '';
  my @sysdeps;
  if ($engine eq 'mock' && $buildtype eq 'spec') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:mock'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:mock'} || []} unless @sysdeps;
  } elsif ($engine eq 'debootstrap' && $buildtype eq 'dsc') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:debootstrap'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:debootstrap'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'livebuild') {
    # packages used for build environment setup (build-recipe-livebuild deps)
    @sysdeps = @{$config->{'substitute'}->{'system-packages:livebuild'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:livebuild'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'kiwi-image') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:kiwi-image'} || []};
    @sysdeps = @{$config->{'substitute'}->{'kiwi-setup:image'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:kiwi-image'} || []} unless @sysdeps;
    push @sysdeps, @$extradeps if $extradeps;
  } elsif ($buildtype eq 'kiwi-product') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:kiwi-product'} || []};
    @sysdeps = @{$config->{'substitute'}->{'kiwi-setup:product'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:kiwi-product'} || []} unless @sysdeps;
    push @sysdeps, @$extradeps if $extradeps;
  } elsif ($buildtype eq 'deltarpm') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:deltarpm'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:deltarpm'} || []} unless @sysdeps;
  }
  return () unless @sysdeps;
  my @ndeps = grep {/^-/} @sysdeps;
  my %ndeps = map {$_ => 1} @ndeps;
  @sysdeps = grep {!$ndeps{$_}} @sysdeps;
  push @sysdeps, @{$config->{'preinstall'}}, @{$config->{'required'}};
  push @sysdeps, @{$config->{'support'}} if $buildtype eq 'kiwi-image' || $buildtype eq 'kiwi-product';	# compat to old versions
  @sysdeps = do_subst($config, @sysdeps);
  @sysdeps = grep {!$ndeps{$_}} @sysdeps;
  my $configtmp = $config;
  @sysdeps = expand($configtmp, @sysdeps, @ndeps);
  return @sysdeps unless $sysdeps[0];
  shift @sysdeps;
  @sysdeps = unify(@sysdeps, get_preinstalls($config));
  return (1, @sysdeps);
}

# Delivers all packages which shall have an influence to other package builds (get_build reduced by support packages)
sub get_deps {
  my ($config, $subpacks, @deps) = @_;
  my @ndeps = grep {/^-/} @deps;
  my @extra = @{$config->{'required'}};
  if (@{$config->{'keep'} || []}) {
    my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
    for (@{$subpacks || []}) {
      push @ndeps, "-$_" unless $keep{$_};
    }
  } else {
    # new "empty keep" mode, filter subpacks from required
    my %subpacks = map {$_ => 1} @{$subpacks || []};
    @extra = grep {!$subpacks{$_}} @extra;
  }
  my %ndeps = map {$_ => 1} @ndeps;
  @deps = grep {!$ndeps{$_}} @deps;
  push @deps, @extra;
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  my %bdeps = map {$_ => 1} (@{$config->{'preinstall'}}, @{$config->{'support'}});
  delete $bdeps{$_} for @deps;
  @deps = expand($config, @deps, @ndeps);
  if (@deps && $deps[0]) {
    my $r = shift @deps;
    @deps = grep {!$bdeps{$_}} @deps;
    unshift @deps, $r;
  }
  return @deps;
}

sub get_preinstalls {
  my ($config) = @_;
  return @{$config->{'preinstall'}};
}

sub get_vminstalls {
  my ($config) = @_;
  return @{$config->{'vminstall'}};
}

sub get_runscripts {
  my ($config) = @_;
  return @{$config->{'runscripts'}};
}

### just for API compability
sub get_cbpreinstalls { return @{[]}; }
sub get_cbinstalls { return @{[]}; }

###########################################################################

sub readdeps {
  my ($config, $pkginfo, @depfiles) = @_;

  my %requires;
  local *F;
  my %provides;
  my %pkgconflicts;
  my %pkgobsoletes;
  my $dofileprovides = %{$config->{'fileprovides'} || {}};
  for my $depfile (@depfiles) {
    if (ref($depfile) eq 'HASH') {
      for my $rr (keys %$depfile) {
	$provides{$rr} = $depfile->{$rr}->{'provides'};
	$requires{$rr} = $depfile->{$rr}->{'requires'};
	$pkgconflicts{$rr} = $depfile->{$rr}->{'conflicts'};
	$pkgobsoletes{$rr} = $depfile->{$rr}->{'obsoletes'};
      }
      next;
    }
    # XXX: we don't support different architectures per file
    open(F, '<', $depfile) || die("$depfile: $!\n");
    while(<F>) {
      my @s = split(' ', $_);
      my $s = shift @s;
      if ($pkginfo && ($s =~ /^I:(.*)\.(.*)-\d+\/\d+\/\d+:$/)) {
	my $pkgid = $1;
	my $arch = $2; 
	my $evr = $s[0];
	$pkginfo->{$pkgid}->{'arch'} = $1 if $s[1] && $s[1] =~ s/-(.*)$//;
	$pkginfo->{$pkgid}->{'buildtime'} = $s[1] if $s[1];
	if ($evr =~ s/^\Q$pkgid-//) {
	  $pkginfo->{$pkgid}->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
	  $pkginfo->{$pkgid}->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
	  $pkginfo->{$pkgid}->{'version'} = $evr;
	}
	next;
      }
      my @ss;
      while (@s) {
	if (!$dofileprovides && $s[0] =~ /^\//) {
	  shift @s;
	  next;
	}
	if ($s[0] =~ /^rpmlib\(/) {
	    splice(@s, 0, 3);
	    next;
	}
	push @ss, shift @s;
	while (@s && $s[0] =~ /^[\(<=>|]/) {
	  $ss[-1] .= " $s[0] $s[1]";
	  $ss[-1] =~ s/ \((.*)\)/ $1/;
	  $ss[-1] =~ s/(<|>){2}/$1/;
	  splice(@s, 0, 2);
	}
      }
      my %ss;
      @ss = grep {!$ss{$_}++} @ss;
      if ($s =~ /^(P|R|C|O):(.*)\.(.*)-\d+\/\d+\/\d+:$/) {
	my $pkgid = $2;
	my $arch = $3;
	if ($1 eq "P") {
	  $provides{$pkgid} = \@ss;
	  if ($pkginfo) {
	    $pkginfo->{$pkgid}->{'name'} = $pkgid;
	    $pkginfo->{$pkgid}->{'arch'} = $arch;
	    $pkginfo->{$pkgid}->{'provides'} = \@ss;
	  }
	}
	if ($1 eq "R") {
	  $requires{$pkgid} = \@ss;
	  $pkginfo->{$pkgid}->{'requires'} = \@ss if $pkginfo;
	  next;
	}
	if ($1 eq "C") {
	  $pkgconflicts{$pkgid} = \@ss;
	  $pkginfo->{$pkgid}->{'conflicts'} = \@ss if $pkginfo;
	  next;
	}
	if ($1 eq "O") {
	  $pkgobsoletes{$pkgid} = \@ss;
	  $pkginfo->{$pkgid}->{'obsoletes'} = \@ss if $pkginfo;
	  next;
	}
      }
    }
    close F;
  }
  if ($pkginfo) {
    # extract evr from self provides if there is no 'I' line
    for my $pkg (values %$pkginfo) {
      next if defined $pkg->{'version'};
      my $n = $pkg->{'name'};
      next unless defined $n;
      my @sp = grep {/^\Q$n\E\s*=\s*/} @{$pkg->{'provides'} || []};
      next unless @sp;
      my $evr = $sp[-1];
      $evr =~ s/^\Q$n\E\s*=\s*//;
      $pkg->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
      $pkg->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
      $pkg->{'version'} = $evr;
    }
  }
  $config->{'providesh'} = \%provides;
  $config->{'requiresh'} = \%requires;
  $config->{'pkgconflictsh'} = \%pkgconflicts;
  $config->{'pkgobsoletesh'} = \%pkgobsoletes;
  makewhatprovidesh($config);
}

sub getbuildid {
  my ($q) = @_;
  my $evr = $q->{'version'};
  $evr = "$q->{'epoch'}:$evr" if $q->{'epoch'};
  $evr .= "-$q->{'release'}" if defined $q->{'release'};;
  my $buildtime = $q->{'buildtime'} || 0;
  $evr .= " $buildtime";
  $evr .= "-$q->{'arch'}" if defined $q->{'arch'};
  return "$q->{'name'}-$evr";
}

sub writedeps {
  my ($fh, $pkg, $url) = @_;
  $url = '' unless defined $url;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  my $id = $pkg->{'id'};
  $id = ($pkg->{'buildtime'} || 0)."/".($pkg->{'filetime'} || 0)."/0" unless $id;
  $id = "$pkg->{'name'}.$pkg->{'arch'}-$id: ";
  print $fh "F:$id$url$pkg->{'location'}\n";
  print $fh "P:$id".join(' ', @{$pkg->{'provides'} || []})."\n";
  print $fh "R:$id".join(' ', @{$pkg->{'requires'}})."\n" if $pkg->{'requires'};
  print $fh "C:$id".join(' ', @{$pkg->{'conflicts'}})."\n" if $pkg->{'conflicts'};
  print $fh "O:$id".join(' ', @{$pkg->{'obsoletes'}})."\n" if $pkg->{'obsoletes'};
  print $fh "I:$id".getbuildid($pkg)."\n";
}

sub makewhatprovidesh {
  my ($config) = @_;

  my %whatprovides;
  my $provides = $config->{'providesh'};

  for my $p (keys %$provides) {
    my @pp = @{$provides->{$p}};
    s/[ <=>].*// for @pp;
    push @{$whatprovides{$_}}, $p for unify(@pp);
  }
  for my $p (keys %{$config->{'fileprovides'}}) {
    my @pp = map {@{$whatprovides{$_} || []}} @{$config->{'fileprovides'}->{$p}};
    @{$whatprovides{$p}} = unify(@{$whatprovides{$p} || []}, @pp) if @pp;
  }
  $config->{'whatprovidesh'} = \%whatprovides;
}

sub setdeps {
  my ($config, $provides, $whatprovides, $requires) = @_;
  $config->{'providesh'} = $provides;
  $config->{'whatprovidesh'} = $whatprovides;
  $config->{'requiresh'} = $requires;
}

sub forgetdeps {
  my ($config) = @_;
  delete $config->{'providesh'};
  delete $config->{'whatprovidesh'};
  delete $config->{'requiresh'};
  delete $config->{'pkgconflictsh'};
  delete $config->{'pkgobsoletesh'};
}

my %addproviders_fm = (
  '>'  => 1,
  '='  => 2,
  '>=' => 3,
  '<'  => 4,
  '<=' => 6,
);

sub addproviders {
  my ($config, $r) = @_;

  my @p;
  my $whatprovides = $config->{'whatprovidesh'};
  $whatprovides->{$r} = \@p;
  if ($r =~ /\|/) {
    for my $or (split(/\s*\|\s*/, $r)) {
      push @p, @{$whatprovides->{$or} || addproviders($config, $or)};
    }
    @p = unify(@p) if @p > 1;
    return \@p;
  }
  return \@p if $r !~ /^(.*?)\s*([<=>]{1,2})\s*(.*?)$/;
  my $rn = $1;
  my $rv = $3;
  my $rf = $addproviders_fm{$2};
  return \@p unless $rf;
  my $provides = $config->{'providesh'};
  my @rp = @{$whatprovides->{$rn} || []};
  for my $rp (@rp) {
    for my $pp (@{$provides->{$rp} || []}) {
      if ($pp eq $rn) {
	# debian: unversioned provides do not match
	# kiwi: supports only rpm, so we need to hand it like it
	next if $config->{'binarytype'} eq 'deb';
	push @p, $rp;
	last;
      }
      next unless $pp =~ /^\Q$rn\E\s*([<=>]{1,2})\s*(.*?)$/;
      my $pv = $2;
      my $pf = $addproviders_fm{$1};
      next unless $pf;
      if ($pf & $rf & 5) {
	push @p, $rp;
	last;
      }
      if ($pv eq $rv) {
	next unless $pf & $rf & 2;
	push @p, $rp;
	last;
      }
      my $rr = $rf == 2 ? $pf : ($rf ^ 5);
      $rr &= 5 unless $pf & 2;
      # verscmp for spec and kiwi types
      my $vv;
      if ($config->{'binarytype'} eq 'deb') {
	$vv = Build::Deb::verscmp($pv, $rv, 1);
      } else {
	$vv = Build::Rpm::verscmp($pv, $rv, 1);
      }
      if ($rr & (1 << ($vv + 1))) {
	push @p, $rp;
	last;
      }
    }
  }
  @p = unify(@p) if @p > 1;
  return \@p;
}

# XXX: should also check the package EVR
sub nevrmatch {
  my ($config, $r, @p) = @_;
  my $rn = $r;
  $rn =~ s/\s*([<=>]{1,2}).*$//;
  return grep {$_ eq $rn} @p;
}

sub checkconflicts {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  for my $r (@r) {
    my @eq = grep {$ins->{$_}} @{$whatprovides->{$r} || addproviders($config, $r)};
    next unless @eq;
    push @$eq, map {"provider $q conflicts with installed $_"} @eq;
    return 1;
  }
  return 0;
}

sub checkobsoletes {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  for my $r (@r) {
    my @eq = grep {$ins->{$_}} nevrmatch($config, $r, @{$whatprovides->{$r} || addproviders($config, $r)});
    next unless @eq;
    push @$eq, map {"provider $q is obsoleted by installed $_"} @eq;
    return 1;
  }
  return 0;
}

sub expand {
  my ($config, @p) = @_;

  my $conflicts = $config->{'conflicth'};
  my $pkgconflicts = $config->{'pkgconflictsh'} || {};
  my $pkgobsoletes = $config->{'pkgobsoletesh'} || {};
  my $prefer = $config->{'preferh'};
  my $ignore = $config->{'ignoreh'};
  my $ignoreconflicts = $config->{'expandflags:ignoreconflicts'};
  my $ignoreignore;

  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};

  my %xignore = map {substr($_, 1) => 1} grep {/^-/} @p;
  $ignoreignore = 1 if $xignore{'-ignoreignore--'};
  my @directdepsend;
  if ($xignore{'-directdepsend--'}) {
    delete $xignore{'-directdepsend--'};
    my @directdepsend = @p;
    for my $p (splice @p) {
      last if $p eq '--directdepsend--';
      push @p, $p;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @p + 1);
  }

  my %aconflicts;	# packages we are conflicting with
  for (grep {/^!/} @p) {
    my $r = /^!!/ ? substr($_, 2) : substr($_, 1);
    my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
    @q = nevrmatch($config, $r, @q) if /^!!/;
    $aconflicts{$_} = "is in BuildConflicts" for @q;
  }

  @p = grep {!/^[-!]/} @p;
  my %p;		# expanded packages

  # add direct dependency packages. this is different from below,
  # because we add packages even if the dep is already provided and
  # we break ambiguities if the name is an exact match.
  for my $p (splice @p) {
    my @q = @{$whatprovides->{$p} || addproviders($config, $p)};
    if (@q > 1) {
      my $pn = $p;
      $pn =~ s/ .*//;
      @q = grep {$_ eq $pn} @q;
    }
    if (@q != 1) {
      push @p, $p;
      next;
    }
    return (undef, "$q[0] $aconflicts{$q[0]}") if $aconflicts{$q[0]};
    print "added $q[0] because of $p (direct dep)\n" if $expand_dbg;
    push @p, $q[0];
    $p{$q[0]} = 1;
    $aconflicts{$_} = "conflict from project config with $q[0]" for @{$conflicts->{$q[0]} || []};
    if (!$ignoreconflicts) {
      for my $r (@{$pkgconflicts->{$q[0]}}) {
	$aconflicts{$_} = "conflicts with installed $q[0]" for @{$whatprovides->{$r} || addproviders($config, $r)};
      }
      for my $r (@{$pkgobsoletes->{$q[0]}}) {
	$aconflicts{$_} = "is obsoleted by installed $q[0]" for nevrmatch($config, $r, @{$whatprovides->{$r} || addproviders($config, $r)});
      }
    }
  }
  push @p, @directdepsend;

  my @pamb = ();
  my $doamb = 0;
  while (@p) {
    my @error = ();
    my @rerror = ();
    for my $p (splice @p) {
      for my $r (@{$requires->{$p} || [$p]}) {
	my $ri = (split(/[ <=>]/, $r, 2))[0];
	if (!$ignoreignore) {
	  next if $ignore->{"$p:$ri"} || $xignore{"$p:$ri"};
	  next if $ignore->{$ri} || $xignore{$ri};
	}
	my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
	next if grep {$p{$_}} @q;
	if (!$ignoreignore) {
	  next if grep {$xignore{$_}} @q;
	  next if grep {$ignore->{"$p:$_"} || $xignore{"$p:$_"}} @q;
	}
	my @eq = map {"provider $_ $aconflicts{$_}"} grep {$aconflicts{$_}} @q;
	@q = grep {!$aconflicts{$_}} @q;
	if (!$ignoreconflicts) {
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgconflicts->{$q} || []} && checkconflicts($config, \%p, $q, \@eq, @{$pkgconflicts->{$q}});
	  }
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgobsoletes->{$q} || []} && checkobsoletes($config, \%p, $q, \@eq, @{$pkgobsoletes->{$q}});
	  }
	}
	if (!@q) {
	  my $eq = @eq ? " (".join(', ', @eq).")" : '';
	  my $msg = @eq ? 'conflict for providers of' : 'nothing provides';
	  if ($r eq $p) {
	    push @rerror, "$msg $r$eq";
	  } else {
	    next if $r =~ /^\// && !@eq;
	    push @rerror, "$msg $r needed by $p$eq";
	  }
	  next;
	}
	if (@q > 1 && !$doamb) {
	  push @pamb, $p unless @pamb && $pamb[-1] eq $p;
	  print "undecided about $p:$r: @q\n" if $expand_dbg;
	  next;
	}
	if (@q > 1) {
	  my @pq = grep {!$prefer->{"-$_"} && !$prefer->{"-$p:$_"}} @q;
	  @q = @pq if @pq;
	  @pq = grep {$prefer->{$_} || $prefer->{"$p:$_"}} @q;
	  if (@pq > 1) {
	    my %pq = map {$_ => 1} @pq;
	    @q = (grep {$pq{$_}} @{$config->{'prefer'}})[0];
	  } elsif (@pq == 1) {
	    @q = @pq;
	  }
	}
	if (@q > 1 && $r =~ /\|/) {
	    # choice op, implicit prefer of first match...
	    my %pq = map {$_ => 1} @q;
	    for my $rr (split(/\s*\|\s*/, $r)) {
		next unless $whatprovides->{$rr};
		my @pq = grep {$pq{$_}} @{$whatprovides->{$rr}};
		next unless @pq;
		@q = @pq;
		last;
	    }
	}
	if (@q > 1) {
	  if ($r ne $p) {
	    push @error, "have choice for $r needed by $p: @q";
	  } else {
	    push @error, "have choice for $r: @q";
	  }
	  push @pamb, $p unless @pamb && $pamb[-1] eq $p;
	  next;
	}
	push @p, $q[0];
	print "added $q[0] because of $p:$r\n" if $expand_dbg;
	$p{$q[0]} = 1;
	$aconflicts{$_} = "conflict from project config with $q[0]" for @{$conflicts->{$q[0]} || []};
	if (!$ignoreconflicts) {
	  for my $r (@{$pkgconflicts->{$q[0]}}) {
	    $aconflicts{$_} = "conflicts with installed $q[0]" for @{$whatprovides->{$r} || addproviders($config, $r)};
	  }
	  for my $r (@{$pkgobsoletes->{$q[0]}}) {
	    $aconflicts{$_} = "is obsoleted by installed $q[0]" for nevrmatch($config, $r, @{$whatprovides->{$r} || addproviders($config, $r)});
	  }
        }
	@error = ();
	$doamb = 0;
      }
    }
    return undef, @rerror if @rerror;
    next if @p;		# still work to do

    # only ambig stuff left
    if (@pamb && !$doamb) {
      @p = @pamb;
      @pamb = ();
      $doamb = 1;
      print "now doing undecided dependencies\n" if $expand_dbg;
      next;
    }
    return undef, @error if @error;
  }
  return 1, (sort keys %p);
}

sub order {
  my ($config, @p) = @_;

  my $requires = $config->{'requiresh'};
  my $whatprovides = $config->{'whatprovidesh'};
  my %deps;
  my %rdeps;
  my %needed;
  my %p = map {$_ => 1} @p;
  for my $p (@p) {
    my @r;
    for my $r (@{$requires->{$p} || []}) {
      my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
      push @r, grep {$_ ne $p && $p{$_}} @q;
    }
    if (%{$config->{'order'} || {}}) {
      push @r, grep {$_ ne $p && $config->{'order'}->{"$_:$p"}} @p;
    }
    @r = unify(@r);
    $deps{$p} = \@r;
    $needed{$p} = @r;
    push @{$rdeps{$_}}, $p for @r;
  }
  @p = sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @p;
  my @good;
  my @res;
  # the big sort loop
  while (@p) {
    @good = grep {$needed{$_} == 0} @p;
    if (@good) {
      @p = grep {$needed{$_}} @p;
      push @res, @good;
      for my $p (@good) {
	$needed{$_}-- for @{$rdeps{$p}};
      }
      next;
    }
    # uh oh, cycle alert. find and remove all cycles.
    my %notdone = map {$_ => 1} @p;
    $notdone{$_} = 0 for @res;  # already did those
    my @todo = @p;
    while (@todo) {
      my $v = shift @todo;
      if (ref($v)) {
	$notdone{$$v} = 0;      # finished this one
	next;
      }
      my $s = $notdone{$v};
      next unless $s;
      my @e = grep {$notdone{$_}} @{$deps{$v}};
      if (!@e) {
	$notdone{$v} = 0;       # all deps done, mark as finished
	next;
      }
      if ($s == 1) {
	$notdone{$v} = 2;       # now under investigation
	unshift @todo, @e, \$v;
	next;
      }
      # reached visited package, found a cycle!
      my @cyc = ();
      my $cycv = $v;
      # go back till $v is reached again
      while(1) {
	die unless @todo;
	$v = shift @todo;
	next unless ref($v);
	$v = $$v;
	$notdone{$v} = 1 if $notdone{$v} == 2;
	unshift @cyc, $v;
	last if $v eq $cycv;
      }
      unshift @todo, $cycv;
      print STDERR "cycle: ".join(' -> ', @cyc)."\n";
      my $breakv;
      my @breakv = (@cyc, $cyc[0]);
      while (@breakv > 1) {
	last if $config->{'order'}->{"$breakv[0]:$breakv[1]"};
	shift @breakv;
      }
      if (@breakv > 1) {
	$breakv = $breakv[0];
      } else {
	$breakv = (sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @cyc)[-1];
      }
      push @cyc, $cyc[0];	# make it loop
      shift @cyc while $cyc[0] ne $breakv;
      $v = $cyc[1];
      print STDERR "  breaking dependency $breakv -> $v\n";
      $deps{$breakv} = [ grep {$_ ne $v} @{$deps{$breakv}} ];
      $rdeps{$v} = [ grep {$_ ne $breakv} @{$rdeps{$v}} ];
      $needed{$breakv}--;
    }
  }
  return @res;
}

sub add_all_providers {
  my ($config, @p) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};
  my %a;
  for my $p (@p) {
    for my $r (@{$requires->{$p} || [$p]}) {
      my $rn = (split(' ', $r, 2))[0];
      $a{$_} = 1 for @{$whatprovides->{$rn} || []};
    }
  }
  push @p, keys %a;
  return unify(@p);
}

###########################################################################

sub recipe2buildtype {
  my ($recipe) = @_;
  return $1 if $recipe =~ /\.(spec|dsc|kiwi|livebuild)$/;
  $recipe =~ s/.*\///;
  $recipe =~ s/^_service:.*://;
  return 'arch' if $recipe eq 'PKGBUILD';
  return 'preinstallimage' if $recipe eq '_preinstallimage';
  return 'simpleimage' if $recipe eq 'simpleimage';
  return undef;
}

sub show {
  my ($conffile, $fn, $field, $arch) = @ARGV;
  my $cf = read_config($arch, $conffile);
  die unless $cf;
  my $d = Build::parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  $d->{'sources'} = [ map {ref($d->{$_}) ? @{$d->{$_}} : $d->{$_}} grep {/^source/} sort keys %$d ];
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "$_\n" for @$x;
}

sub parse_preinstallimage {
  return undef unless $do_rpm;
  my $d = Build::Rpm::parse(@_);
  $d->{'name'} ||= 'preinstallimage';
  return $d;
}

sub parse_simpleimage {
  return undef unless $do_rpm;
  my $d = Build::Rpm::parse(@_);
  $d->{'name'} ||= 'simpleimage';
  if (!defined($d->{'version'})) {
    my @s = stat($_[1]);
    $d->{'version'} = strftime "%Y.%m.%d-%H.%M.%S", gmtime($s[9] || time);
  }
  return $d;
}

sub parse {
  my ($cf, $fn, @args) = @_;
  return Build::Rpm::parse($cf, $fn, @args) if $do_rpm && $fn =~ /\.spec$/;
  return Build::Deb::parse($cf, $fn, @args) if $do_deb && $fn =~ /\.dsc$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /config\.xml$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /\.kiwi$/;
  return Build::LiveBuild::parse($cf, $fn, @args) if $do_livebuild && $fn =~ /\.livebuild$/;
  return parse_simpleimage($cf, $fn, @args) if $fn eq 'simpleimage';
  my $fnx = $fn;
  $fnx =~ s/.*\///;
  $fnx =~ s/^[0-9a-f]{32,}-//;	# hack for OBS srcrep implementation
  $fnx =~ s/^_service:.*://;
  return Build::Arch::parse($cf, $fn, @args) if $do_arch && $fnx eq 'PKGBUILD';
  return parse_preinstallimage($cf, $fn, @args) if $fnx eq '_preinstallimage';
  return undef;
}

sub parse_typed {
  my ($cf, $fn, $buildtype, @args) = @_;
  $buildtype ||= '';
  return Build::Rpm::parse($cf, $fn, @args) if $do_rpm && $buildtype eq 'spec';
  return Build::Deb::parse($cf, $fn, @args) if $do_deb && $buildtype eq 'dsc';
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $buildtype eq 'kiwi';
  return Build::LiveBuild::parse($cf, $fn, @args) if $do_livebuild && $buildtype eq 'livebuild';
  return parse_simpleimage($cf, $fn, @args) if $buildtype eq 'simpleimage';
  return Build::Arch::parse($cf, $fn, @args) if $do_arch && $buildtype eq 'arch';
  return parse_preinstallimage($cf, $fn, @args) if $buildtype eq 'preinstallimage';
  return undef;
}

sub query {
  my ($binname, %opts) = @_;
  my $handle = $binname;
  if (ref($binname) eq 'ARRAY') {
    $handle = $binname->[1];
    $binname = $binname->[0];
  }
  return Build::Rpm::query($handle, %opts) if $do_rpm && $binname =~ /\.rpm$/;
  return Build::Deb::query($handle, %opts) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryiso($handle, %opts) if $do_kiwi && $binname =~ /\.iso$/;
  return Build::Arch::query($handle, %opts) if $do_arch && $binname =~ /\.pkg\.tar(?:\.gz|\.xz)?$/;
  return Build::Arch::query($handle, %opts) if $do_arch && $binname =~ /\.arch$/;
  return undef;
}

sub showquery {
  my ($fn, $field) = @ARGV;
  my %opts;
  $opts{'evra'} = 1 if grep {$_ eq $field} qw{epoch version release arch buildid};
  $opts{'weakdeps'} = 1 if grep {$_ eq $field} qw{suggests enhances recommends supplements};
  $opts{'conflicts'} = 1 if grep {$_ eq $field} qw{conflicts obsoletes};
  $opts{'description'} = 1 if grep {$_ eq $field} qw{summary description};
  $opts{'filelist'} = 1 if $field eq 'filelist';
  $opts{'buildtime'} = 1 if grep {$_ eq $field} qw{buildtime buildid};
  my $d = Build::query($fn, %opts);
  die("cannot query $fn\n") unless $d;
  $d->{'buildid'} = getbuildid($d);
  my $x = $d->{$field};
  $x = [] unless defined $x;
  $x = [ $x ] unless ref $x;
  print "$_\n" for @$x;
}

sub queryhdrmd5 {
  my ($binname) = @_;
  return Build::Rpm::queryhdrmd5(@_) if $do_rpm && $binname =~ /\.rpm$/;
  return Build::Deb::queryhdrmd5(@_) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.iso$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw.install$/;
  return Build::Arch::queryhdrmd5(@_) if $do_arch && $binname =~ /\.pkg\.tar(?:\.gz|\.xz)?$/;
  return Build::Arch::queryhdrmd5(@_) if $do_arch && $binname =~ /\.arch$/;
  return undef;
}

sub queryinstalled {
  my ($binarytype, @args) = @_;
  return Build::Rpm::queryinstalled(@args) if $binarytype eq 'rpm';
  return Build::Deb::queryinstalled(@args) if $binarytype eq 'deb';
  return Build::Arch::queryinstalled(@args) if $binarytype eq 'arch';
  return undef;
}

1;
