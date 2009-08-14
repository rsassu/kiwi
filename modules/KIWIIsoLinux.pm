#================
# FILE          : KIWIIsoLinux.pm
#----------------
# PROJECT       : OpenSUSE Build-Service
# COPYRIGHT     : (c) 2006 SUSE LINUX Products GmbH, Germany
#               :
# AUTHOR        : Marcus Schaefer <ms@suse.de>
#               :
# BELONGS TO    : Operating System images
#               :
# DESCRIPTION   : This module is used to create an ISO
#               : filesystem based on genisoimage/mkisofs
#               : 
#               :
# STATUS        : Development
#----------------
package KIWIIsoLinux;
#==========================================
# Modules
#------------------------------------------
use strict;
use Carp qw (cluck);
use File::Find;
use File::Basename;
use KIWILog;
use KIWIQX;

#==========================================
# Constructor
#------------------------------------------
sub new {
	# ...
	# Create a new KIWIIsoLinux object which is used to wrap
	# around the major genisoimage/mkisofs call. This code requires a
	# specific source directory structure which is:
	# ---
	# $source/boot/<arch>/loader
	# ---
	# Below the loader path the initrd and kernel as well as
	# all isolinux related binaries and files must be stored
	# Given that structure this module creates a bootable
	# ISO file from the data below $source
	# ---
	#==========================================
	# Object setup
	#------------------------------------------
	my $this  = {};
	my $class = shift;
	bless $this,$class;
	#==========================================
	# Module Parameters
	#------------------------------------------
	my $kiwi         = shift;  # log object
	my $source       = shift;  # location of source tree
	my $dest         = shift;  # destination for the iso file
	my $params       = shift;  # global genisoimage/mkisofs parameters
	my $mediacheck   = shift;  # run tagmedia with --check y/n
	#==========================================
	# Constructor setup
	#------------------------------------------
	my %base;
	my @catalog;
	my $code;
	my $sort;
	my $ldir;
	my $tool;
	my $check = 0;
	#==========================================
	# create log object if not done
	#------------------------------------------
	if (! defined $kiwi) {
		$kiwi = new KIWILog ("tiny");
	}
	if (! -d $source) {
		$kiwi -> error  ("No such file or directory: $source");
		$kiwi -> failed (); 
		return undef;
	}
	if (! defined $dest) {
		$kiwi -> error  ("No destination file specified");
		$kiwi -> failed ();
		return undef;
	}
	#==========================================
	# Find iso tool to use on this system
	#------------------------------------------
	if (-x "/usr/bin/genisoimage") {
		$tool = "/usr/bin/genisoimage";
	} elsif (-x "/usr/bin/mkisofs") {
		$tool = "/usr/bin/mkisofs";
	} else {
		$kiwi -> error  ("No ISO creation tool found");
		$kiwi -> failed ();
		return undef;
	}
	#=======================================
	# path setup for supported archs
	#---------------------------------------
	# s390x
	$base{s390x}{boot}   = "boot/s390x";
	$base{s390x}{loader} = "undef";
	$base{s390x}{efi}    = "undef";
	# s390
	$base{s390}{boot}    = "boot/s390";
	$base{s390}{loader}  = "undef";
	$base{s390}{efi}     = "undef";
	# ix86
	$base{ix86}{boot}    = "boot/i386";
	$base{ix86}{loader}  = "boot/i386/loader/isolinux.bin";
	$base{ix86}{efi}     = "boot/i386/efi";
	# x86_64
	$base{x86_64}{boot}  = "boot/x86_64";
	$base{x86_64}{loader}= "boot/x86_64/loader/isolinux.bin";
	$base{x86_64}{efi}   = "boot/x86_64/efi";
	# ia64
	$base{ia64}{boot}    = "boot/ia64";
	$base{ia64}{loader}  = "undef";
	$base{ia64}{efi}     = "boot/ia64/efi";
	#=======================================
	# 1) search for legacy boot
	#---------------------------------------
	foreach my $arch (sort keys %base) {
		if (-d $source."/".$base{$arch}{boot}) {
			if ($arch eq "x86_64") {
				$catalog[0] = "x86_64_legacy";
			}
			if ($arch eq "ix86") {
				$catalog[0] = "ix86_legacy";
			}
		}
	}
	#=======================================
	# 2) search for efi/ikr boot
	#---------------------------------------
	foreach my $arch (sort keys %base) {
		if (-d $source."/".$base{$arch}{efi}) {
			if ($arch eq "x86_64") {
				push (@catalog, "x86_64_efi");
			}
			if ($arch eq "ix86") {
				push (@catalog, "ix86_efi");
			}
			if ($arch eq "ia64") {
				push (@catalog, "ia64_efi");
			}
			if ($arch eq "s390") {
				push (@catalog, "s390_ikr");
			}
			if ($arch eq "s390x") {
				push (@catalog, "s390x_ikr");
			}
		}
	}
	#==========================================
	# create tmp files/directories 
	#------------------------------------------
	$sort = qxx ("mktemp /tmp/kiso-sort-XXXXXX 2>&1"); chomp $sort;
	$code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Couldn't create sort file: $sort: $!");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	$ldir = qxx ("mktemp -q -d /tmp/kiso-loader-XXXXXX 2>&1"); chomp $ldir;
	$code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Couldn't create tmp directory: $ldir: $!");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	qxx ("chmod 755 $ldir");
	#==========================================
	# Store object data
	#------------------------------------------
	$this -> {kiwi}   = $kiwi;
	$this -> {source} = $source;
	$this -> {dest}   = $dest;
	$this -> {params} = $params;
	$this -> {base}   = \%base;
	$this -> {tmpfile}= $sort;
	$this -> {tmpdir} = $ldir;
	$this -> {catalog}= \@catalog;
	$this -> {tool}   = $tool;
	$this -> {check}  = $mediacheck;
	return $this;
}

#==========================================
# x86_64_legacy
#------------------------------------------
sub x86_64_legacy {
	my $this  = shift;
	my $arch  = shift;
	my %base  = %{$this->{base}};
	my $para  = $this -> {params};
	my $sort  = $this -> createLegacySortFile ("x86_64");
	my $boot  = $base{$arch}{boot};
	my $loader= $base{$arch}{loader};
	$para.= " -sort $sort -no-emul-boot -boot-load-size 4 -boot-info-table";
	$para.= " -b $loader -c $boot/boot.catalog";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$this -> {params} = $para;
	$this -> createISOLinuxConfig ($boot);
}

#==========================================
# ix86_legacy
#------------------------------------------
sub ix86_legacy {
	my $this  = shift;
	my $arch  = shift;
	my %base  = %{$this->{base}};
	my $para  = $this -> {params};
	my $sort  = $this -> createLegacySortFile ("ix86");
	my $boot  = $base{$arch}{boot};
	my $loader= $base{$arch}{loader};
	$para.= " -sort $sort -no-emul-boot -boot-load-size 4 -boot-info-table";
    $para.= " -b $loader -c $boot/boot.catalog";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$this -> {params} = $para;
	$this -> createISOLinuxConfig ($boot);
}

#==========================================
# x86_64_efi
#------------------------------------------
sub x86_64_efi {
	my $this  = shift;
	my $arch  = shift;
	my %base  = %{$this->{base}};
	my $para  = $this -> {params};
	my $boot  = $base{$arch}{boot};
	my $loader= $base{$arch}{efi};
	$para.= " -eltorito-alt-boot";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$para.= " -b $loader";
	$this -> {params} = $para;
}

#==========================================
# ix86_efi
#------------------------------------------
sub ix86_efi {
	my $this  = shift;
	my $arch  = shift;
	my %base  = %{$this->{base}};
	my $para  = $this -> {params};
	my $boot  = $base{$arch}{boot};
	my $loader= $base{$arch}{efi};
	$para.= " -eltorito-alt-boot";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$para.= " -b $loader";
	$this -> {params} = $para;
}

#==========================================
# ia64_efi
#------------------------------------------
sub ia64_efi {
	my $this  = shift;
	my $arch  = shift;
	my %base  = %{$this->{base}};
	my $para  = $this -> {params};
	my $boot  = $base{$arch}{boot};
	my $loader= $base{$arch}{efi};
	$para.= " -eltorito-alt-boot";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$para.= " -b $loader";
	$this -> {params} = $para;
}

#==========================================
# s390_ikr
#------------------------------------------
sub s390_ikr {
	my $this = shift;
	my $arch = shift;
	my %base = %{$this->{base}};
	my $para = $this -> {params};
	my $boot = $base{$arch}{boot};
	my $ikr  = $this -> createS390CDLoader($boot);
	$para.= " -eltorito-alt-boot";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$para.= " -b $boot/cd.ikr";
	$this -> {params} = $para;
}

#==========================================
# s390x_ikri
#------------------------------------------
sub s390x_ikr {
	my $this = shift;
	my $arch = shift;
	my %base = %{$this->{base}};
	my $para = $this -> {params};
	my $boot = $base{$arch}{boot};
	my $ikr  = $this -> createS390CDLoader($boot);
	$para.= " -eltorito-alt-boot";
	$para.= " -hide $boot/boot.catalog -hide-joliet $boot/boot.catalog";
	$para.= " -b $boot/cd.ikr";
	$this -> {params} = $para; 
}

#==========================================
# callBootMethods 
#------------------------------------------
sub callBootMethods {
	my $this    = shift;
	my $kiwi    = $this->{kiwi};
	my @catalog = @{$this->{catalog}};
	my %base    = %{$this->{base}};
	my $ldir    = $this->{tmpdir};
	if (! @catalog) {
		$kiwi -> error  ("Can't find valid boot/<arch>/ layout");
		$kiwi -> failed ();
		return undef;
	}
	foreach my $boot (@catalog) {
		if ($boot =~ /(.*)_.*/) {
			my $arch = $1;
			qxx ("mkdir -p $ldir/".$base{$arch}{boot}."/loader");
			no strict 'refs';
			&{$boot}($this,$arch);
			use strict 'refs';
		}
	}
	return $this;
}
	
#==========================================
# createLegacySortFile
#------------------------------------------
sub createLegacySortFile {
	my $this = shift;
	my $arch = shift;
	my $kiwi = $this->{kiwi};
	my %base = %{$this->{base}};
	my $src  = $this->{source};
	my $sort = $this->{tmpfile};
	my $ldir = $this->{tmpdir};
	my $FD;
	if (! -d $src."/".$base{$arch}{boot}) {
		return undef;
	}
	if (! open $FD, ">$sort") {
		$kiwi -> error  ("Failed to open sort file: $!");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	sub generateWanted {
		my $filelist = shift;
		return sub {
			push (@{$filelist},$File::Find::name);
		}
	}
	my @list = ();
	my $wref = generateWanted (\@list);
	find ({wanted => $wref,follow => 0 },$src."/".$base{$arch}{boot}."/loader");
	print $FD "$ldir/boot/boot.catalog 3"."\n";
	print $FD "boot/boot.catalog 3"."\n";
	print $FD "$src/boot/boot.catalog 3"."\n";
	foreach my $file (@list) {
		print $FD "$file 1"."\n";
	}
	print $FD "$src/boot/isolinux.bin 2"."\n";
	close $FD;
	return $sort;
}

#==========================================
# createS390CDLoader 
#------------------------------------------
sub createS390CDLoader {
	my $this = shift;
	my $basez= shift;
	my $kiwi = $this->{kiwi};
	my $src  = $this->{source};
	my $ldir = $this->{tmpdir};
	if (-f $src."/".$basez."/vmrdr.ikr") {
		qxx ("mkdir -p $ldir/$basez");
		my $parmfile = $src."/".$basez."/parmfile";
		if (-e $parmfile.".cd") {
			$parmfile = $parmfile.".cd";
		}
		my $gen = "gen-s390-cd-kernel.pl";
		$gen .= " --initrd=$src/$basez/initrd";
		$gen .= " --kernel=$src/$basez/vmrdr.ikr";
		$gen .= " --parmfile=$parmfile";
		$gen .= " --outfile=$ldir/$basez/cd.ikr";
		qxx ($gen);
	}
	if (-f "$ldir/$basez/cd.ikr") {
		return "$basez/cd.ikr";
	}
	return undef
}

#==========================================
# createVolumeID 
#------------------------------------------
sub createVolumeID {
	my $this = shift;
	my $kiwi = $this->{kiwi};
	my $src  = $this->{source};
	my $hfsvolid = "unknown";
	my $FD;
	if (-f $src."/content") {
		my $number;
		my $version;
		my $name;
		my @media = glob ("$src/media.?");
		foreach my $i (@media) {
			if ((-d $i) && ( $i =~ /.*\.(\d+)/)) {
				$number = $1; last;
			}
		}
		open ($FD,"$src/content");
		foreach my $line (<$FD>) {
			if (($version) && ($name)) {
				last;
			}
			if ($line =~ /(NAME|PRODUCT)\s+(\w+)/) {
				$name=$2;
			}
			if ($line =~ /VERSION\s+([\d\.]+)/) {
				$version=$1;
			}
		}
		close $FD;
		if ($name) {
			$hfsvolid=$name;
		}
		if ($version) {
			$hfsvolid="$name $version";
		}
		if ($hfsvolid) {
			if ($number) {
				$hfsvolid = substr ($hfsvolid,0,25);
				$hfsvolid.= " $number";
			}
		} elsif (open ($FD,$src."media.1/build")) {
			my $line = <$FD>; close $FD;
			if ($line =~ /(\w+)-(\d+)-/) {
				$hfsvolid = "$1 $2 $number";
			}
		}
	}
	return $hfsvolid;
}

#==========================================
# createISOLinuxConfig 
#------------------------------------------
sub createISOLinuxConfig {
	my $this = shift;
	my $boot = shift;
	my $kiwi = $this -> {kiwi};
	my $src  = $this -> {source};
	my $isox = "/usr/bin/isolinux-config";
	if (! -x $isox) {
		$kiwi -> error  ("Can't find isolinux-config binary");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	my $data = qxx (
		"$isox --base $boot/loader $src/$boot/loader/isolinux.bin 2>&1"
	);
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to call isolinux-config binary: $data");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	return $this;
}

#==========================================
# createISO
#------------------------------------------
sub createISO {
	my $this = shift;
	my $kiwi = $this -> {kiwi};
	my $src  = $this -> {source};
	my $dest = $this -> {dest};
	my $para = $this -> {params};
	my $ldir = $this -> {tmpdir};
	my $prog = $this -> {tool};
	my $data = qxx (
		"$prog $para -o $dest $ldir $src 2>&1"
	);
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to call $prog: $data");
		$kiwi -> failed ();
		$this -> cleanISO();
		return undef;
	}
	$this -> cleanISO();
	return $this;
}

#==========================================
# cleanISO
#------------------------------------------
sub cleanISO {
	my $this = shift;
	my $sort = $this -> {tmpfile};
	my $ldir = $this -> {tmpdir};
	if (-f $sort) {
		qxx ("rm -f $sort 2>&1");
	}
	if (-d $ldir) {
		qxx ("rm -rf $ldir 2>&1");
	}
	return $this;
}

#==========================================
# checkImage
#------------------------------------------
sub checkImage {
	my $this = shift;
	my $kiwi = $this -> {kiwi};
	my $dest = $this -> {dest};
	my $check= $this -> {check};
	my $data;
	if (defined $this->{check}) {
		$data = qxx ("tagmedia --md5 --check --pad 150 $dest 2>&1");
	} else {
		$data = qxx ("tagmedia --md5 $dest 2>&1");
	}
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to call tagmedia: $data");
		$kiwi -> failed ();
		return undef;
	}
	return $this;
}

#==========================================
# createHybrid
#------------------------------------------
sub createHybrid {
	# ...
	# create hybrid ISO by calling isohybrid
	# ---
	my $this = shift;
	my $mbrid= shift;
	my $kiwi = $this->{kiwi};
	my $iso  = $this->{dest};
	my $loop;
	my $FD;
	#==========================================
	# Create partition table on iso
	#------------------------------------------
	if (! -x "/usr/bin/isohybrid") {
		$kiwi -> error  ("Can't find isohybrid, check your syslinux version");
		$kiwi -> failed ();
		return undef;
	}
	my $data = qxx ("isohybrid -id $mbrid -type 0x83 $iso 2>&1");
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to call isohybrid: $data");
		$kiwi -> failed ();
		return undef;
	}
	#==========================================
	# Make it DOS compatible
	#------------------------------------------
	my @commands = ("d","n","p","1",".",".","a","1","w","q");
	$loop = qxx ("/sbin/losetup -s -f $iso 2>&1"); chomp $loop;
	$code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to loop bind iso file: $loop");
		$kiwi -> failed ();
		return undef;
	}
	if (! open ($FD,"|/sbin/fdisk $loop &> /dev/null")) {
		$kiwi -> error  ("Failed to call fdisk");
		$kiwi -> failed ();
		qxx ("losetup -d $loop");
		return undef;
	}
	foreach my $cmd (@commands) {
		if ($cmd eq ".") {
			print $FD "\n";
		} else {
			print $FD "$cmd\n";
		}
	}
	close $FD;
	qxx ("losetup -d $loop");
	return $this;
}

#==========================================
# relocateCatalog
#------------------------------------------
sub relocateCatalog {
	# ...
	# mkisofs/genisoimage leave one sector empty (or fill it with
	# version info if the ISODEBUG environment variable is set) before
	# starting the path table. We use this space to move the boot
	# catalog there. It's important that the boot catalog is at the
	# beginning of the media to be able to boot on any machine
	# ---
	my $this = shift;
	my $kiwi = $this->{kiwi};
	my $iso  = $this->{dest};
	my $ISO;
	$kiwi -> info ("Relocating boot catalog ");
	if (! open $ISO, "+<$iso") {
		$kiwi -> failed ();
		$kiwi -> error  ("Failed opening iso file: $iso: $!");
		$kiwi -> failed ();
		return undef;
	}
	my $rs = read_sector_closure  ($ISO);
	my $ws = write_sector_closure ($ISO);
	local *read_sector  = $rs;
	local *write_sector = $ws;
	my $vol_descr = read_sector (0x10);
	my $vol_id = substr($vol_descr, 0, 7);
	if ($vol_id ne "\x01CD001\x01") {
		$kiwi -> failed ();
		$kiwi -> error  ("No iso9660 filesystem");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $path_table = unpack "V", substr($vol_descr, 0x08c, 4);
	if ($path_table < 0x11) {
		$kiwi -> failed ();
		$kiwi -> error  ("Strange path table location: $path_table");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $new_location = $path_table - 1;
	my $eltorito_descr = read_sector (0x11);
	my $eltorito_id = substr($eltorito_descr, 0, 0x1e);
	if ($eltorito_id ne "\x00CD001\x01EL TORITO SPECIFICATION") {
		$kiwi -> failed ();
		$kiwi -> error  ("Given iso is not bootable");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $boot_catalog = unpack "V", substr($eltorito_descr, 0x47, 4);
	if ($boot_catalog < 0x12) {
		$kiwi -> failed ();
		$kiwi -> error  ("Strange boot catalog location: $boot_catalog");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $vol_descr2 = read_sector ($new_location - 1);
	my $vol_id2 = substr($vol_descr2, 0, 7);
	if($vol_id2 ne "\xffCD001\x01") {
		undef $new_location;
		for (my $i = 0x12; $i < 0x40; $i++) {
			$vol_descr2 = read_sector ($i);
			$vol_id2 = substr($vol_descr2, 0, 7);
			if ($vol_id2 eq "\x00TEA01\x01" || $boot_catalog == $i + 1) {
				$new_location = $i + 1;
				last;
			}
		}
	}
	if (! defined $new_location) {
		$kiwi -> failed ();
		$kiwi -> error  ("Unexpected iso layout");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	if ($boot_catalog == $new_location) {
		$kiwi -> skipped ();
		$kiwi -> info ("Boot catalog already relocated");
		$kiwi -> done ();
		close $ISO;
		return $this;
	}
	my $version_descr = read_sector ($new_location);
	if (
		($version_descr ne ("\x00" x 0x800)) &&
		(substr($version_descr, 0, 4) ne "MKI ")
	) {
		$kiwi -> skipped ();
		$kiwi -> info  ("Unexpected iso layout");
		$kiwi -> skipped ();
		close $ISO;
		return $this;
	}
	my $boot_catalog_data = read_sector ($boot_catalog);
	#==========================================
	# now reloacte to $path_table - 1
	#------------------------------------------
	substr($eltorito_descr, 0x47, 4) = pack "V", $new_location;
	write_sector ($new_location, $boot_catalog_data);
	write_sector (0x11, $eltorito_descr);
	close $ISO;
	$kiwi -> note ("from sector $boot_catalog to $new_location");
	$kiwi -> done();
	return $this;
}

#==========================================
# fixCatalog
#------------------------------------------
sub fixCatalog {
	my $this = shift;
	my $kiwi = $this->{kiwi};
	my $iso  = $this->{dest};
	my $ISO;
	$kiwi -> info ("Fixing boot catalog according to standard");
	if (! open $ISO, "+<$iso") {
		$kiwi -> failed ();
		$kiwi -> error  ("Failed opening iso file: $iso: $!");
		$kiwi -> failed ();
		return undef;
	}
	my $rs = read_sector_closure  ($ISO);
	my $ws = write_sector_closure ($ISO);
	local *read_sector  = $rs;
	local *write_sector = $ws;
	my $vol_descr = read_sector (0x10);
	my $vol_id = substr($vol_descr, 0, 7);
	if ($vol_id ne "\x01CD001\x01") {
		$kiwi -> failed ();
		$kiwi -> error  ("No iso9660 filesystem");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $eltorito_descr = read_sector (0x11);
	my $eltorito_id = substr($eltorito_descr, 0, 0x1e);
	if ($eltorito_id ne "\x00CD001\x01EL TORITO SPECIFICATION") {
		$kiwi -> failed ();
		$kiwi -> error  ("ISO Not bootable");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $boot_catalog_idx = unpack "V", substr($eltorito_descr, 0x47, 4);
	if ($boot_catalog_idx < 0x12) {
		$kiwi -> failed ();
		$kiwi -> error  ("Strange boot catalog location: $boot_catalog_idx");
		$kiwi -> failed ();
		close $ISO;
		return undef;
	}
	my $boot_catalog = read_sector ($boot_catalog_idx);
	my $entry1 = substr $boot_catalog, 32 * 1, 32;
	substr($entry1, 12, 20) = pack "Ca19", 1, "Legacy (isolinux)";
	substr($boot_catalog, 32 * 1, 32) = $entry1;
	my $entry2 = substr $boot_catalog, 32 * 2, 32;
	substr($entry2, 12, 20) = pack "Ca19", 1, "UEFI (elilo)";
	if((unpack "C", $entry2)[0] == 0x88) {
		substr($boot_catalog, 32 * 3, 32) = $entry2;
		$entry2 = pack "CCva28", 0x91, 0xef, 1, "";
		substr($boot_catalog, 32 * 2, 32) = $entry2;
		write_sector ($boot_catalog_idx, $boot_catalog);
		$kiwi -> done();
	} else {
		$kiwi -> skipped();
	}
	close $ISO;
}

#==========================================
# read_sector_closure
#------------------------------------------
sub read_sector_closure {
	my $ISO = shift;
	return sub {
		my $buf;
		if (! seek $ISO, $_[0] * 0x800, 0) {
			return undef;
		}
		if (sysread($ISO, $buf, 0x800) != 0x800) {
			return undef;
		}
		return $buf;
	}
}

#==========================================
# write_sector_closure
#------------------------------------------
sub write_sector_closure {
	my $ISO = shift;
	return sub {
		if (! seek $ISO, $_[0] * 0x800, 0) {
			return undef;
		}
		if (syswrite($ISO, $_[1], 0x800) != 0x800) {
			return undef;
		}
	}
}

#==========================================
# getTool
#------------------------------------------
sub getTool {
	# ...
	# return ISO toolkit name used on this system
	# ---
	my $this = shift;
	my $tool = $this->{tool};
	return basename $tool;
}

1;
