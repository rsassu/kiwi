#================
# FILE          : KIWIResult.pm
#----------------
# PROJECT       : openSUSE Build-Service
# COPYRIGHT     : (c) 2014 SUSE LINUX Products GmbH, Germany
#               :
# AUTHOR        : Marcus Schaefer <ms@suse.de>
#               :
# BELONGS TO    : Operating System images
#               :
# DESCRIPTION   : This module is used to bundle build results
#               :
#               :
# STATUS        : Production
#----------------
package KIWIResult;
#==========================================
# Modules
#------------------------------------------
use strict;
use warnings;
use Config::IniFiles;

#==========================================
# KIWI Modules
#------------------------------------------
use KIWIGlobals;
use KIWILog;
use KIWIQX;

#==========================================
# Constructor
#------------------------------------------
sub new {
	# ...
	# Create a new KIWIResult object
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
	my $sourcedir = shift;
	my $destdir   = shift;
	my $buildnr   = shift;
	#==========================================
	# Parameter check
	#------------------------------------------
	my $kiwi = KIWILog->instance();
	if (-d $destdir) {
		$kiwi -> error ("Destination dir $destdir already exists");
		$kiwi -> failed();
		return;
	}
	if (! $sourcedir) {
		$kiwi -> error ("No image source directory specified");
		$kiwi -> failed();
		return;
	}
	if (! $buildnr) {
		$kiwi -> error ("No build-id specified");
		$kiwi -> failed();
		return;
	}
	#==========================================
	# read in build information file
	#------------------------------------------
	my $file = $sourcedir.'/kiwi.buildinfo';
	if (! -e $file) {
		$kiwi -> error ("Can't find $file");
		$kiwi -> failed ();
		return;
	}
	my $buildinfo = Config::IniFiles -> new (
		-file => $file, -allowedcommentchars => '#'
	);
	my $imagebase = $buildinfo->val('main','image.basename');
	if (! $imagebase) {
		$kiwi -> error ("Can't find image.basename");
		$kiwi -> failed ();
		return;
	}
	#==========================================
	# create temp. dir
	#------------------------------------------
	my $tmpdir = KIWIQX::qxx (
		"mktemp -qdt kiwiresult.XXXXXX"
	);
	my $result = $? >> 8;
	if ($result != 0) {
		$kiwi -> error  ("Couldn't create tmp dir: $tmpdir: $!");
		$kiwi -> failed ();
		return;
	}
	chomp $tmpdir;
	#==========================================
	# Store object data
	#------------------------------------------
	$this->{imagebase} = $imagebase;
	$this->{tmpdir}    = $tmpdir;
	$this->{buildinfo} = $buildinfo;
	$this->{kiwi}      = $kiwi;
	$this->{sourcedir} = $sourcedir;
	$this->{destdir}   = $destdir;
	$this->{buildnr}   = $buildnr;
	return $this;
}

#==========================================
# buildRelease
#------------------------------------------
sub buildRelease {
	# ...
	# bundle result image files into a tmpdir and skip
	# intermediate build results as well as the build
	# metadata. The result files will contain the
	# given build number
	# ---
	my $this = shift;
	my $buildnr = $this->{buildnr};
	my $kiwi = $this->{kiwi};
	my $buildinfo = $this->{buildinfo};
	my $result;
	$kiwi -> info ("Bundle build results for release: $buildnr\n");
	#==========================================
	# Evaluate bundler method
	#------------------------------------------
	my $type = $buildinfo->val('main','image.type');
	if (! $type) {
		$kiwi -> info ("--> Calling default bundler\n");
		$result = $this -> __bundleDefault();
		$this->DESTROY if ! $result;
		return $result;
	}
	if ($type eq 'product') {
		$kiwi -> info ("--> Calling product bundler\n");
		$result = $this -> __bundleProduct();
	} elsif ($type eq 'docker') {
		$kiwi -> info ("--> Calling docker bundler\n");
		$result = $this -> __bundleDocker();
	} elsif ($type eq 'lxc') {
		$kiwi -> info ("--> Calling LXC bundler\n");
		$result = $this -> __bundleLXC();
	} elsif ($type eq 'iso') {
		$kiwi -> info ("--> Calling ISO bundler\n");
		$result = $this -> __bundleISO();
	} elsif ($type eq 'tbz') {
		$kiwi -> info ("--> Calling TBZ bundler\n");
		$result = $this -> __bundleTBZ();
	} elsif ($type eq 'vmx') {
		$kiwi -> info ("--> Calling Disk VMX bundler\n");
		$result = $this -> __bundleDisk();
	} elsif ($type eq 'oem') {
		$kiwi -> info ("--> Calling Disk OEM bundler\n");
		$result = $this -> __bundleDisk();
	} else {
		$kiwi -> info ("--> Calling default bundler\n");
		$result = $this -> __bundleDefault();
	}
	$this->DESTROY if ! $result;
	return $result;
}

#==========================================
# populateRelease
#------------------------------------------
sub populateRelease {
	# ...
	# Move files from tmpdir back to destdir and
	# delete level 1 files from the destdir before
	# ---
	my $this   = shift;
	my $kiwi   = $this->{kiwi};
	my $dest   = $this->{destdir};
	my $tmpdir = $this->{tmpdir};
	$kiwi -> info ("Populating build results to: $dest");
	my $data = KIWIQX::qxx (
		"mkdir -p $dest && mv $tmpdir/* $dest/ 2>&1"
	);
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> failed ();
		$kiwi -> error  (
			"Failed to populate results, keeping data in $tmpdir: $data"
		);
		$kiwi -> failed ();
		return;
	}
	$this->DESTROY;
	$kiwi -> done();
	return $this;
}

#==========================================
# __bundleDefault
#------------------------------------------
sub __bundleDefault {
	my $this   = shift;
	my $kiwi   = $this->{kiwi};
	my $source = $this->{sourcedir};
	my $tmpdir = $this->{tmpdir};
	my $bnr    = $this->{buildnr};
	my $base   = $this->{imagebase};
	my @excl   = (
		'--exclude *.buildinfo',
		'--exclude *.verified',
		'--exclude *.packages'
	);
	my $opts = '--no-recursion';
	my $data = KIWIQX::qxx (
		"cd $source && find . -maxdepth 1 -type f 2>&1"
	);
	my $code = $? >> 8;
	if ($code == 0) {
		my @flist = split(/\n/,$data);
		$data = KIWIQX::qxx (
			"cd $source && tar $opts -czf $tmpdir/$base-$bnr.tgz @excl @flist"
		);
		$code = $? >> 8;
	}
	if ($code != 0) {
		$kiwi -> error  ("Failed to archive results: $data");
		$kiwi -> failed ();
		return;
	}
	return $this;
}

#==========================================
# __bundleExtension
#------------------------------------------
sub __bundleExtension {
	my $this   = shift;
	my $suffix = shift;
	my $base   = shift;
	my $kiwi   = $this->{kiwi};
	my $source = $this->{sourcedir};
	my $tmpdir = $this->{tmpdir};
	my $bnr    = $this->{buildnr};
	if (! $base) {
		$base = $this->{imagebase};
	}
	my $data = KIWIQX::qxx (
		"cp $source/$base.$suffix $tmpdir/$base-$bnr.$suffix 2>&1"
	);
	my $code = $? >> 8;
	if ($code != 0) {
		$kiwi -> error  ("Failed to move $suffix image: $data");
		$kiwi -> failed ();
		return;
	}
	if ($suffix =~ /json|vmx|xenconfig/) {
		my $file = $tmpdir/$base-$bnr.$suffix;
		$data = KIWIQX::qxx (
			"sed -i -e 's/$base.$suffix/$base-$bnr.$suffix/' $file 2>&1"
		);
		my $code = $? >> 8;
		if ($code != 0) {
			$kiwi -> error  (
				"Failed to update metadata contents of $file: $data"
			);
			$kiwi -> failed ();
			return;
		}
	}
	return $this;
}

#==========================================
# __bundleProduct
#------------------------------------------
sub __bundleProduct {
	my $this = shift;
	return $this -> __bundleExtension ('iso');
}

#==========================================
# __bundleDocker
#------------------------------------------
sub __bundleDocker {
	my $this = shift;
	return $this -> __bundleExtension ('docker');
}

#==========================================
# __bundleLXC
#------------------------------------------
sub __bundleLXC {
	my $this = shift;
	return $this -> __bundleExtension ('lxc');
}

#==========================================
# __bundleISO
#------------------------------------------
sub __bundleISO {
	my $this = shift;
	return $this -> __bundleExtension ('iso');
}

#==========================================
# __bundleTBZ
#------------------------------------------
sub __bundleTBZ {
	my $this = shift;
	return $this -> __bundleExtension ('tbz');
}

#==========================================
# __bundleDisk
#------------------------------------------
sub __bundleDisk {
	my $this   = shift;
	my $kiwi   = $this->{kiwi};
	my $base   = $this->{imagebase};
	my $source = $this->{sourcedir};
	my $tmpd   = $this->{tmpdir};
	my $bnr    = $this->{buildnr};
	my $buildinfo = $this->{buildinfo};
	my $data;
	my $code;
	#==========================================
	# handle install media
	#------------------------------------------
	if ($buildinfo->exists('main','install.iso')) {
		return $this -> __bundleExtension ('install.iso');
	} elsif ($buildinfo->exists('main','install.stick')) {
		return $this -> __bundleExtension ('install.raw');
	} elsif ($buildinfo->exists('main','install.pxe')) {
		return $this -> __bundleExtension ('install.tgz');
	}
	#==========================================
	# handle formats
	#------------------------------------------
	my $format = $buildinfo->val('main','image.format');
	if (! $format) {
		return $this -> __bundleExtension ('raw');
	}
	if ($format eq 'vagrant') {
		$code = 1;
		foreach my $box (glob ("$source/$base.*.box")) {
			if ($box =~ /$base\.(.*)\.box/) {
				my $provider = $1;
				if (! $this -> __bundleExtension('box',"$base.$provider")) {
					return;
				}
				if (! $this -> __bundleExtension('json',"$base.$provider")) {
					return;
				}
			}
		}
		if ($code != 0) {
			$kiwi -> error  ("No box files found");
			$kiwi -> failed ();
			return;
		}
		return $this;
	}
	if (! $this -> __bundleExtension ($format)) {
		return;
	}
	#==========================================
	# handle machine configuration
	#------------------------------------------
	if (-e "$source/$base.vmx") {
		return $this -> __bundleExtension ('vmx');
	}
	if (-e "$source/$base.xenconfig") {
		return $this -> __bundleExtension ('xenconfig');
	}
	return $this;
}

#==========================================
# Destructor
#------------------------------------------
sub DESTROY {
	my $this = shift;
	my $tmpdir = $this->{tmpdir};
	if (($tmpdir) && (-d $tmpdir)) {
		KIWIQX::qxx ("rm -rf $tmpdir");
	}
	return $this;
}

1;