package PVE::Storage::Custom::MooseFSPlugin;

use strict;
use warnings;

use Data::Dumper qw(Dumper);
use IO::File;
use IO::Socket::UNIX;
use File::Path;
use POSIX qw(strftime);

use PVE::Storage::Plugin;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;

use base qw(PVE::Storage::Plugin);

# Logging function, called only when needed explicitly
sub log_debug {
    my ($msg) = @_;
    my $logfile = '/var/log/mfsplugindebug.log';
    my $timestamp = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);

    # Direct file write instead of fragile shell echo
    my $fh = IO::File->new(">> $logfile");
    if ($fh) {
        print $fh "$timestamp: $msg\n";
        $fh->close;
    } else {
        warn "Failed to open $logfile for writing: $!";
    }
}

# MooseFS helper functions
sub moosefs_is_mounted {
    my ($mfsmaster, $mfsport, $mountpoint, $mountdata, $mfssubfolder) = @_;
    $mountdata = PVE::ProcFSTools::parse_proc_mounts() if !$mountdata;

    # Default to empty subfolder if not provided
    $mfssubfolder ||= '';
    # Strip leading slashes from mfssubfolder
    $mfssubfolder =~ s|^/+||;
    my $subfolder_pattern = ($mfssubfolder ne '') ? "\Q/$mfssubfolder\E" : "";

    # Check that we return something like mfs#mfsmaster:9421 or mfs#mfsmaster:9421/subfolder
    # on a fuse filesystem with the correct mountpoint
    # Note: mfsbdev may add a trailing slash when no subfolder is specified
    return $mountpoint if grep {
        $_->[2] eq 'fuse' &&
        $_->[0] =~ /^mfs(#|\\043)\Q$mfsmaster\E\Q:\E\Q$mfsport\E$subfolder_pattern\/?$/ &&
        $_->[1] eq $mountpoint
    } @$mountdata;
    return undef;
}

# Returns true only if /dev/mfs/nbdsock exists _and_ we can open() it as a UNIX stream.
sub moosefs_bdev_is_active {
    my ($scfg) = @_;
    die "Invalid config: expected hashref" unless ref($scfg) eq 'HASH';

    my $sockpath = '/dev/mfs/nbdsock';

    # Quick check: does the file exist and is it a socket?
    return unless -e $sockpath && -S $sockpath;

    # Now try to connect
    my $sock = IO::Socket::UNIX->new(
        Peer    => $sockpath,
        Timeout => 0.1,                # 100ms timeout
    );

    # If we got a socket object, the daemon is listening
    return defined($sock) ? 1 : 0;
}

sub moosefs_start_bdev {
    my ($scfg) = @_;

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfspassword = $scfg->{mfspassword};

    my $mfsport = $scfg->{mfsport};

    my $mfssubfolder = $scfg->{mfssubfolder};

    # Do not start mfsbdev if it is already running
    return if moosefs_bdev_is_active($scfg);

    # Ensure NBD module is loaded before starting mfsbdev
    my $nbd_loaded = system("lsmod | grep -q '^nbd '") == 0;
    if (!$nbd_loaded) {
        eval { run_command(['modprobe', 'nbd', 'max_part=16'], errmsg => 'Failed to load nbd module'); };
        if ($@) {
            die "Cannot start mfsbdev: NBD kernel module not loaded. Please run: modprobe nbd max_part=16\n";
        }
    }

    my $cmd = ['/usr/sbin/mfsbdev', 'start', '-H', $mfsmaster];
    
    # mfsbdev requires -S parameter, use '/' if no subfolder specified
    if (defined $mfssubfolder && $mfssubfolder ne '') {
        push @$cmd, '-S', $mfssubfolder;
    } else {
        push @$cmd, '-S', '/';
    }
    
    # Add port if specified (mfsbdev uses -P for port)
    if (defined $mfsport) {
        push @$cmd, '-P', $mfsport;
    }
    
    # Add password if specified
    if (defined $mfspassword) {
        push @$cmd, '-p', $mfspassword;
    }
    
    push @$cmd, '-o', 'mfsioretries=99999999';

    run_command($cmd, errmsg => 'mfsbdev start failed');
}

sub moosefs_stop_bdev {
    my ($scfg) = @_;

    my $cmd = ['/usr/sbin/mfsbdev', 'stop'];

    run_command($cmd, errmsg => 'mfsbdev stop failed');
}

# Mounting functions

sub moosefs_mount {
    my ($scfg) = @_;

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfspassword = $scfg->{mfspassword};

    my $mfsport = $scfg->{mfsport};

    my $mfssubfolder = $scfg->{mfssubfolder};

    my $cmd = ['/usr/bin/mfsmount'];

    if (defined $mfsmaster) {
        push @$cmd, '-o', "mfsmaster=$mfsmaster";
    }

    if (defined $mfsport) {
        push @$cmd, '-o', "mfsport=$mfsport";
    }

    if (defined $mfspassword) {
        push @$cmd, '-o', "mfspassword=$mfspassword";
    }

    if (defined $mfssubfolder) {
        push @$cmd, '-o', "mfssubfolder=$mfssubfolder";
    }

    push @$cmd, '-o', "mfsioretries=99999999";

    push @$cmd, $scfg->{path};

    run_command($cmd, errmsg => "mount error");
}

sub moosefs_unmount {
    my ($scfg) = @_;

    my $mountdata = PVE::ProcFSTools::parse_proc_mounts();

    my $path = $scfg->{path};

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfsport = $scfg->{mfsport} // '9421';

    if (moosefs_is_mounted($mfsmaster, $mfsport, $path, $mountdata)) {
        my $cmd = ['/bin/umount', $path];
        run_command($cmd, errmsg => 'umount error');
    }
}

sub api {
    return 12;
}

sub type {
    return 'moosefs';
}

sub plugindata {
    return {
        content => [ { images => 1, vztmpl => 1, iso => 1, backup => 1, rootdir => 1, import => 1, snippets => 1},
                    { images => 1 } ],
        format => [ { raw => 1, qcow2 => 1, vmdk => 1 } , 'raw' ],
        shared => 1,
    };
}

sub properties {
    return {
        mfsmaster => {
            description => "MooseFS master to use for connection (default 'mfsmaster').",
            type => 'string',
        },
        mfsport => {
            description => "Port with which to connect to the MooseFS master (default 9421)",
            type => 'string',
        },
        mfspassword => {
            description => "Password with which to connect to the MooseFS master (default none)",
            type => 'string',
        },
        mfssubfolder => {
            description => "Define subfolder to mount as root (default: /)",
            type => 'string',
        },
        mfsbdev => {
            description => "Use mfsbdev for raw image allocation",
            type => 'boolean',
        }
    };
}

sub options {
    return {
        path => { fixed => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        mfsmaster => { optional => 1 },
        mfsport => { optional => 1 },
        mfspassword => { optional => 1 },
        mfssubfolder => { optional => 1 },
        mfsbdev => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        shared => { optional => 1 },
        content => { optional => 1 },
    };
}

sub get_volume_attribute {
    return PVE::Storage::DirPlugin::get_volume_attribute(@_);
}

sub update_volume_attribute {
    return PVE::Storage::DirPlugin::update_volume_attribute(@_);
}

# Deprecated but still called by PVE
sub update_volume_notes {
    return PVE::Storage::DirPlugin::update_volume_notes(@_);
}

sub get_volume_notes {
    return PVE::Storage::DirPlugin::get_volume_notes(@_);
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;
    my $features = {
        snapshot => {
            current => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
            snap => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 }
        },
        clone => {
            base => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
            current => { raw => 1 },
            snap => { raw => 1 },
        },
        template => {
            current => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
        },
        copy => {
            base => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
            current => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
            snap => { qcow2 => 1, raw => 1 },
        },
        sparseinit => {
            base => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
            current => { qcow2 => 1, raw => 1, vmdk => 1, subvol => 1 },
        },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) = $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    } else {
        $key =  $isBase ? 'base' : 'current';
    }

    # If mfsbdev is active, qcow2 and vmdk are generally not supported for NBD-backed devices.
    # However, we want to keep them enabled for efidisks, as they will be file-backed.
    if ($scfg->{mfsbdev}) {
        if (!(defined($name) && $name =~ m/efidisk/i)) {
            log_debug "[volume_has_feature] mfsbdev is ON and '$name' is NOT an efidisk. Disabling qcow2/vmdk for $feature/$key.";
            $features->{$feature}->{$key}->{qcow2} = 0;
            $features->{$feature}->{$key}->{vmdk} = 0;
        } else {
            log_debug "[volume_has_feature] mfsbdev is ON but '$name' IS an efidisk. qcow2/vmdk support remains for $feature/$key.";
        }
    }

    if (defined($features->{$feature}->{$key}->{$format})) {
        return 1;
    }
    return undef;
}

sub get_formats {
    my ($class, $scfg, $storeid) = @_;

    # In bdev mode, only support raw format
    if ($scfg->{mfsbdev}) {
        return { default => 'raw', valid => { 'raw' => 1 } };
    }

    # In non-bdev mode, support all formats but default to raw
    return {
        default => 'raw',
        valid => {
            'raw' => 1,
            'qcow2' => 1,
            'vmdk' => 1,
        }
    };
}

sub parse_name_dir {
    my $name = shift;
    return PVE::Storage::Plugin::parse_name_dir($name);
}

sub parse_volname {
    my ($class, $volname) = @_;

    if (ref($volname) eq 'HASH') {
        $volname = $volname->{volid} || $volname->{name}
            || die "[parse_volname] invalid hashref volname with no 'volid' or 'name'";
    }

    # If $volname is not a defined scalar, or if it's a reference (e.g., HASHref),
    # log the situation and delegate to the parent class's implementation.
    # This handles cases where PVE calls with undef during cleanup.
    unless (defined $volname && !ref($volname)) {
        log_debug "[parse-volname] volname is not a defined non-reference scalar: " .
                  (defined $volname ? ref($volname) : 'undef') .
                  ". Delegating to SUPER::parse_volname.";
        return $class->SUPER::parse_volname($volname);
    }

    log_debug "[parse-volname] Parsing volume name: $volname";

    my $storeid;
    if ($volname =~ m/^([^:]+):(.+)$/) {
        $storeid = $1;
        $volname = $2;
    }

    if ($volname =~ m!^(\d+)/(.+)$!) {
        my ($vmid, $name) = ($1, $2);
        my $format = 'raw';
        $format = 'qcow2' if $name =~ /\.qcow2$/;
        $format = 'vmdk'  if $name =~ /\.vmdk$/;
        return ('images', $name, $vmid, undef, undef, undef, $format, $storeid);
    }

    elsif ($volname =~ m!^((vm|base)-(\d+)-\S+)$!) {
        my ($name, $is_base, $vmid) = ($1, $2 eq 'base', $3);
        my $format = 'raw';
        $format = 'qcow2' if $name =~ /\.qcow2$/;
        $format = 'vmdk'  if $name =~ /\.vmdk$/;
        return ('images', $name, $vmid, undef, undef, $is_base, $format, $storeid);
    }

    return $class->SUPER::parse_volname($volname);
}

sub alloc_image {
    my ($class, @args) = @_;

    my ($storeid, $scfg, $vmid, $fmt, $name, $size);

    if (ref($args[1]) eq 'HASH') {
        # Correct signature (from other plugin code)
        ($storeid, $scfg, $vmid, $fmt, $name, $size) = @args;
    } else {
        # Legacy signature (what `PVE::Storage` actually calls)
        ($storeid, $vmid, $fmt, $name, $size) = @args;
        $scfg = PVE::Storage::config()->{ids}->{$storeid}
            or die "alloc_image: unable to resolve config for '$storeid'";
    }

    # If mfsbdev is not enabled, or if the volume is an efidisk, bypass the NBD logic.
    # We bypass the NBD logic for any disk of size <= 8MiB, as it's very likely an EFI disk.
    # Also bypass NBD logic for VM state files (vm-XXX-state-NAME.raw) which should remain as regular files
    return $class->SUPER::alloc_image($storeid, $scfg, $vmid, $fmt, $name, $size)
        if !$scfg->{mfsbdev} or $size <= 8 * 1024 or (defined($name) && $name =~ /^vm-\d+-state-/);

    die "mfsbdev only supports raw format" if $fmt ne 'raw';
    $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$name;

    my $imagedir = "images/$vmid";
    File::Path::make_path($scfg->{path}."/$imagedir");

    my $path = "/$imagedir/$name";

    # Write the size of the block device to a file alongside it
    my $write_size_file = "$scfg->{path}/$imagedir/$name.size";

    open(my $write_fh, '>', $write_size_file) or die "Failed to open $write_size_file: $!";
    print $write_fh $size;
    close $write_fh;

    # Size is in kibibytes, but MooseFS expects bytes
    my $size_bytes = $size * 1024;

    # Check if NBD module is loaded before trying to map
    my $nbd_loaded = system("lsmod | grep -q '^nbd '") == 0;
    if (!$nbd_loaded) {
        # Try to load the nbd module
        eval { run_command(['modprobe', 'nbd', 'max_part=16'], errmsg => 'Failed to load nbd module'); };
        if ($@) {
            die "NBD kernel module not loaded. Please run: modprobe nbd max_part=16\n";
        }
    }

    my $cmd = ['/usr/sbin/mfsbdev', 'map', '-f', $path, '-s', $size_bytes];
    eval { run_command($cmd, errmsg => 'mfsbdev map failed'); };
    if ($@) {
        if ($@ =~ /can't find free NBD device/) {
            die "No free NBD devices available. Check if nbd module is loaded (lsmod | grep nbd) and increase max_part if needed\n";
        }
        die $@;
    }

    return "$vmid/$name";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format_param) = @_;

    $scfg = PVE::Storage::config()->{ids}->{$storeid} unless ref($scfg) eq 'HASH';

    unless (defined $volname) {
        log_debug "[free_image] volname is undefined, skipping";
        return undef;
    }

    # $vol_format is the format determined by parse_volname, $format_param is what PVE passed to free_image directly.
    # We typically rely on $vol_format if available for internal logic.
    my ($vtype, $parsed_name, $vmid, undef, undef, undef, $vol_format) = $class->parse_volname($volname);

    # Fallback to SUPER for non-mfsbdev storage or non-image types
    if (!$scfg->{mfsbdev} || $vtype ne 'images') {
        my $reason = !$scfg->{mfsbdev} ? "mfsbdev_disabled" : "vtype_not_images ('$vtype')";
        log_debug "[free_image] Vol: $volname. Reason: $reason. Using SUPER::free_image.";
        return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $format_param);
    }

    # --- mfsbdev is ON and vtype IS 'images' ---
    my $mfs_internal_path = "/images/$vmid/$parsed_name";
    my $image_file_path   = "$scfg->{path}$mfs_internal_path";
    my $size_file_path    = "$image_file_path.size"; # Path for .size file, only relevant if it was NBD-managed

    # Determine if it's NBD-managed by checking the path type returned by filesystem_path.
    # filesystem_path handles its own logic for when to check mfsbdev list (e.g. for 'raw' images).
    my $resolved_path = $class->filesystem_path($scfg, $volname, undef); # $snapname is undef

    log_debug "[free_image] Vol: $volname. Resolved path via filesystem_path: '" . (defined $resolved_path ? $resolved_path : "undef") . "'";

    if (defined($resolved_path) && $resolved_path =~ m|^/dev/nbd\d+|) {
        # IS NBD-managed (filesystem_path returned /dev/nbdX)
        log_debug "[free_image] Path '$resolved_path' indicates NBD. Proceeding with mfsbdev unmap for $mfs_internal_path.";

        if (-e $image_file_path) { # Should generally exist if it was mapped
            my $cmd_unmap = ['/usr/sbin/mfsbdev', 'unmap', '-f', $mfs_internal_path];
            run_command($cmd_unmap, errmsg => "mfsbdev unmap -f $mfs_internal_path failed");

            log_debug "[free_image] Unmap for $volname ($mfs_internal_path) presumably successful. Unlinking image and .size files.";
            unlink $image_file_path or log_debug "[free_image] Failed to unlink $image_file_path post-unmap: $!" if -e $image_file_path;
            unlink $size_file_path or log_debug "[free_image] Failed to unlink $size_file_path post-unmap: $!" if -e $size_file_path;
        } else {
            log_debug "[free_image] Vol: $volname resolved to NBD '$resolved_path', but image $image_file_path MISSING. Attempting unmap for $mfs_internal_path and .size cleanup only.";
            my $cmd_unmap_missing = ['/usr/sbin/mfsbdev', 'unmap', '-f', $mfs_internal_path];
            eval { run_command($cmd_unmap_missing, errmsg => "mfsbdev unmap -f $mfs_internal_path attempted (image file was missing)"); };
            if ($@) { log_debug "[free_image] Unmap attempt for missing image $mfs_internal_path resulted in error (possibly expected): $@"; }
            unlink $size_file_path or log_debug "[free_image] Failed to unlink $size_file_path (image file was missing): $!" if -e $size_file_path;
        }
    } else {
        # NOT NBD-managed (filesystem_path returned a direct file path, or was undef/empty).
        # This covers small/EFI disks (handled by SUPER::alloc_image) and non-raw images.
        # Delegate to SUPER::free_image to handle these plain files correctly.
        log_debug "[free_image] Vol: $volname. Resolved path ('" . (defined $resolved_path ? $resolved_path : "undef") . "') is NOT NBD. Using SUPER::free_image for plain file deletion.";
        return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $format_param);
    }

    # Cleanup orphaned .size files and empty directories (defensive against partial allocations)
    my $image_dir_path = "$scfg->{path}/images/$vmid";

    # Remove orphaned .size file if disk file doesn't exist
    if (-e $size_file_path && !-e $image_file_path) {
        log_debug "[free_image] Found orphaned .size file without disk, removing: $size_file_path";
        unlink $size_file_path or log_debug "[free_image] Failed to remove orphaned .size file: $!";
    }

    # Remove empty VM image directory to prevent future allocation issues
    if (-d $image_dir_path) {
        opendir(my $dh, $image_dir_path) or log_debug "[free_image] Cannot open directory $image_dir_path: $!";
        if ($dh) {
            my @contents = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
            closedir($dh);

            if (@contents == 0) {
                log_debug "[free_image] Removing empty VM directory: $image_dir_path";
                rmdir($image_dir_path) or log_debug "[free_image] Failed to remove empty directory $image_dir_path: $!";
            }
        }
    }

    return undef;
}

sub map_volume {
    my ($class, $storeid, $scfg, $volname, $snapname) = @_;

    # Ensure $scfg is a hashref if it was passed as a storeid (though less likely for this internal func)
    $scfg = PVE::Storage::config()->{ids}->{$storeid} unless ref($scfg) eq 'HASH';

    # This function's NBD mapping logic is only relevant if mfsbdev is enabled.
    if (!ref($scfg) || !$scfg->{mfsbdev}) {
        log_debug "[map_volume] mfsbdev not enabled or invalid scfg. Path: $scfg->{path}. Volname: $volname. Returning undef.";
        return undef;
    }

    # Return early if volname is undefined
    unless (defined $volname) {
        log_debug "[map_volume] volname is undefined, skipping";
        # Or, perhaps fall back to a SUPER call if appropriate for this method
        return $class->SUPER::activate_volume($storeid, $scfg, $volname, $snapname);
    }

    my ($vtype, $name, $vmid, undef, undef, $isBase, $format) = $class->parse_volname($volname);

    # Only handle raw format image volumes
    return $class->SUPER::activate_volume($storeid, $scfg, $volname, $snapname) if $vtype ne 'images' || $format ne 'raw';

    # Construct the MooseFS path from the parsed components
    my $mfs_path = "/images/$vmid/$name";

    # Check if MooseFS bdev is active
    if (!moosefs_bdev_is_active($scfg)) {
        log_debug "MooseFS bdev is not active, activating it";
        moosefs_start_bdev($scfg);
    }

    # Check if the volume is already mapped
    my $list_cmd = ['/usr/sbin/mfsbdev', 'list'];
    my $list_output = '';
    eval {
        run_command($list_cmd, outfunc => sub { $list_output .= shift; }, errmsg => 'mfsbdev list failed');
    };
    if ($@) {
        log_debug "Failed to list MooseFS block devices: $@";
        return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
    }

    # improved parsing: scan each line, allow any spacing/order
    for my $line (split /\r?\n/, $list_output) {
        # match "file: <path>" then later "device: /dev/nbdX" on the same line
        if ($line =~ /\bfile:\s*\Q$mfs_path\E\b.*?\bdevice:\s*(\/dev\/nbd\d+)/) {
            my $nbd_path = $1;
            log_debug "Found existing NBD device $nbd_path for volume $volname via improved parsing";
            return $nbd_path;
        }
    }

    # Fetch size from the size file alongside the block device
    my $size_file = "$scfg->{path}/images/$vmid/$name.size";
    log_debug "Size file $size_file";
    my $size_kib = 0; # Default to 0 KiB
    if (-e $size_file) {
        my $size_content = do { open(my $fh, '<', $size_file) or log_debug "Failed to open $size_file: $!"; local $/; <$fh> };
        if (defined $size_content && $size_content =~ /^(\d+)$/) {
            $size_kib = $1;
        } else {
            log_debug "Invalid or empty content in size file: $size_file. Content: '" . (defined $size_content ? $size_content : "undef") . "'";
        }
    } else {
        log_debug "Size file $size_file does not exist.";
    }

    my $path = "/images/$vmid/$name";

    # Size is in kibibytes, but MooseFS expects bytes
    my $size_bytes = $size_kib * 1024;

    # If size is 0 or less, log and return undef, as mapping such a volume is not possible or meaningful.
    if ($size_bytes <= 0) {
        log_debug "Calculated size_bytes is $size_bytes for volume $volname (source KiB: $size_kib). Cannot map, returning undef.";
        return undef; # Indicate failure to map due to invalid size
    }

    log_debug "Activating volume $volname with size $size_bytes";

    # Check if NBD module is loaded before trying to map
    my $nbd_loaded = system("lsmod | grep -q '^nbd '") == 0;
    if (!$nbd_loaded) {
        # Try to load the nbd module
        eval { run_command(['modprobe', 'nbd', 'max_part=16'], errmsg => 'Failed to load nbd module'); };
        if ($@) {
            log_debug "NBD kernel module not loaded and could not be loaded: $@";
            # Fall back to regular path if NBD is not available
            return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
        }
    }

    my $map_cmd = ['/usr/sbin/mfsbdev', 'map', '-f', $path, '-s', $size_bytes];
    my $map_output = '';
    eval {
        run_command($map_cmd,
            outfunc => sub { $map_output .= shift; },
            errmsg => 'mfsbdev map failed');
    };
    if ($@) {
        log_debug "Failed to map MooseFS block device: $@";
        if ($@ =~ /can't find free NBD device/) {
            log_debug "No free NBD devices available. Consider increasing max_part parameter for nbd module";
        }
        # Fall back to regular path if we can't get mappings
        return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
    }

    if ($map_output =~ m|->(/dev/nbd\d+)|) {
        my $nbd_path = $1;
        log_debug "Found NBD device $nbd_path for volume $volname";
        return $nbd_path;
    }

    # If we couldn't parse the output or no NBD device was found
    log_debug "No NBD device found in output: $map_output";
    return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # Defensive - make sure $scfg is a hashref, not a storeid
    $scfg = PVE::Storage::config()->{ids}->{$storeid} unless ref($scfg) eq 'HASH';

    log_debug "[activate-volume] Activating volume $volname";
    die "Expected hashref for \$scfg in activate_volume, got: $scfg" unless ref($scfg) eq 'HASH';

    return $class->SUPER::activate_volume($storeid, $scfg, $volname, $snapname) if !$scfg->{mfsbdev};

    $class->map_volume($storeid, $scfg, $volname, $snapname) if $scfg->{mfsbdev};

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # Defensive - make sure $scfg is a hashref, not a storeid
    $scfg = PVE::Storage::config()->{ids}->{$storeid} unless ref($scfg) eq 'HASH';

    return $class->SUPER::deactivate_volume($storeid, $scfg, $volname, $snapname, $cache) if !$scfg->{mfsbdev};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    return $class->SUPER::deactivate_volume($storeid, $scfg, $volname, $snapname, $cache) if $vtype ne 'images';

    # Skip deactivation for state files - they're not NBD-mapped
    if ($name =~ /^vm-\d+-state-/) {
        log_debug "Skipping deactivation for state file $volname";
        return 1;
    }

    # Check if volume is actually NBD-mapped by checking for .size file
    # Only NBD-mapped volumes have .size files
    my $size_file = "$scfg->{path}/images/$vmid/$name.size";
    if (!-e $size_file) {
        log_debug "Skipping deactivation for non-NBD volume $volname (no .size file)";
        return 1;
    }

    my $path = "/images/$vmid/$name";

    log_debug "Deactivating volume $volname";

    my $cmd = ['/usr/sbin/mfsbdev', 'unmap', '-f', $path];

    run_command($cmd, errmsg => "can't unmap MooseFS device '$path'");

    return 1;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    # sanity check: volname must be a simple scalar
    # also handle case where volname is undef before ref() check
    if (defined $volname && ref($volname)) {
        Carp::confess("[${\__PACKAGE__}::path] called with invalid volname: "
            . ref($volname));
    }

    # Return early if volname is undefined
    unless (defined $volname) {
        log_debug "[path] volname is undefined, returning filesystem_path";
        return $class->filesystem_path($scfg, $volname, $snapname);
    }

    # fallback to default if bdev not enabled
    if (!ref($scfg) || !$scfg->{mfsbdev}) {
        return $class->filesystem_path($scfg, $volname, $snapname);
    }

    # Use the plugin's own volume_size_info to lookup the size of the volume.
    # If it's <= 8MiB (8388608 bytes), it's treated as an EFI/small disk, use direct filesystem_path.
    # Call $class->volume_size_info, not SUPER, to use the plugin's own implementation.
    # Provide a short timeout, e.g., 5 seconds.
    my $size_in_bytes;
    eval {
        # $storeid is passed to path, $scfg is also available.
        my $info_returned = $class->volume_size_info($scfg, $storeid, $volname, 5); # 5s timeout

        if (defined $info_returned) {
            if (ref($info_returned) eq 'HASH' && defined $info_returned->{size}) {
                $size_in_bytes = $info_returned->{size};
                log_debug "[path] Vol: $volname. Size from volume_size_info (hashref): $size_in_bytes bytes.";
            } elsif (!ref($info_returned) && $info_returned =~ /^\d+$/) {
                $size_in_bytes = $info_returned; # Treat as direct size if scalar numeric
                log_debug "[path] Vol: $volname. Size from volume_size_info (scalar numeric): $size_in_bytes bytes.";
            } else {
                # Log if $info_returned is defined but not a HASH with 'size' or a plain number
                log_debug "[path] Vol: $volname. volume_size_info returned an unexpected defined type: " . Dumper($info_returned);
            }
        } else {
            log_debug "[path] Vol: $volname. volume_size_info returned undef.";
        }
    };
    if ($@) {
        log_debug "[path] Vol: $volname. Error calling/processing volume_size_info: $@. Proceeding without size check for small disk.";
        # Fallthrough to NBD logic if size check fails, rather than assuming it's small.
    }

    if (defined($size_in_bytes) && $size_in_bytes <= 8 * 1024 * 1024) { # Compare bytes to bytes
        log_debug "[path] Vol: $volname ($size_in_bytes bytes) is small/EFI disk. Forcing filesystem_path.";
        return $class->filesystem_path($scfg, $volname, $snapname);
    }

    log_debug "[path] Vol: $volname. Not a small/EFI disk based on size (or size check failed). Attempting MooseFS NBD lookup.";

    my $nbd = eval { $class->map_volume($storeid, $scfg, $volname, $snapname) };
    if ($@) {
        log_debug "[path] map_volume error for $volname: $@";
        return $class->filesystem_path($scfg, $volname, $snapname);
    }

    if ($nbd && -b $nbd) {
        my ($vtype_nbd, $name_nbd, $vmid_nbd) = $class->parse_volname($volname);
        log_debug "[path] using NBD $nbd for $volname (vmid $vmid_nbd, name $name_nbd, type $vtype_nbd)";
        return ($nbd, $vmid_nbd, $vtype_nbd);
    }

    log_debug "[path] no NBD found for $volname; defaulting back to filesystem_path.";
    return $class->filesystem_path($scfg, $volname, $snapname);
}

use Carp qw(longmess);

sub filesystem_path {
    my ($class, @args) = @_;

    log_debug "[fs-path] ARGS = " . join(", ", map { defined($_) ? (ref($_) || $_) : 'undef' } @args);

    # Normalize @args to find the scfg hashref
    while (@args && ref($args[0]) ne 'HASH') {
        log_debug "[filesystem_path] Stripping leading non-HASH arg: $args[0]";
        shift @args;
    }

    my ($scfg, $volname, $snapname) = @args;
    die "[fs-path] invalid scfg" unless ref($scfg) eq 'HASH';

    # If volname is undefined, it's likely a request for the storage base path.
    unless (defined $volname) {
        log_debug "[fs-path] volname is undefined. Returning storage base path: $scfg->{path}";
        return $scfg->{path};
    }

    my $ts = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);

    my ($vtype, $name, $vmid, undef, undef, $isBase, $format) = $class->parse_volname($volname);

    # Handle snapshots for raw format in MooseFS
    if (defined($snapname) && $vtype eq 'images' && $format eq 'raw') {
        # MooseFS supports snapshots for raw files through mfsmakesnapshot
        # Return the path to the snapshot file
        my $mountpoint = $scfg->{path};
        return "$mountpoint/images/$vmid/snaps/$snapname/$name";
    }

    # Only do NBD logic for raw images without snapshots AND when a sidecar size file exists
    my $size_sidecar = defined($vmid) ? "$scfg->{path}/images/$vmid/$name.size" : undef;
    unless ($scfg->{mfsbdev} && $vtype eq 'images' && $format eq 'raw' && !defined($snapname) && -e $size_sidecar) {
        return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
    }

    log_debug "[fs-path] Attempting NBD path resolution for $volname";

    my $path = defined($vmid) ? "/images/$vmid/$name" : "/images/$name";

    if (!moosefs_bdev_is_active($scfg)) {
        log_debug "MooseFS bdev not active, activating";
        moosefs_start_bdev($scfg);
    }

    my $cmd = ['/usr/sbin/mfsbdev', 'list'];
    my $output = '';
    eval {
        run_command($cmd, outfunc => sub { $output .= shift; }, errmsg => 'mfsbdev list failed');
    };
    if ($@) {
        log_debug "[fs-path] mfsbdev list failed: $@";
        return $class->SUPER::filesystem_path($scfg, $volname, $snapname);
    }

    if ($output =~ m|file:\s+\Q$path\E\s+;\s+device:\s+(/dev/nbd\d+)|) {
        my $nbd = $1;
        log_debug "[fs-path] Found mapped device: $nbd";
        return $nbd;
    }

    log_debug "[fs-path] No mapped device found, falling back to $scfg->{path}$path";
    return "$scfg->{path}$path";
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    unless (defined $volname && !ref($volname)) {
        Carp::confess("[${\__PACKAGE__}::$0] called with invalid volname: " . (defined $volname ? ref($volname) : 'undef'));
    }

    # Defensive - make sure $scfg is a hashref, not a storeid
    $scfg = PVE::Storage::config()->{ids}->{$storeid} unless ref($scfg) eq 'HASH';

    return $class->SUPER::volume_resize(@_) if !$scfg->{mfsbdev};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    return $class->SUPER::volume_resize(@_) if $vtype ne 'images';

    my $path = "/images/$vmid/$name";

    if (-e $path) {
        my $cmd = ['/usr/sbin/mfsbdev', 'resize', $path, $size];
        run_command($cmd, errmsg => 'mfsbdev resize failed');
    } else {
        die "volume '$volname' does not exist\n";
    }

    return undef;
}

# Helper function to execute operations with NBD device temporarily unmapped
# This is critical for snapshot operations to avoid crashing the NBD daemon
sub with_nbd_unmapped {
    my ($class, $scfg, $volname, $operation) = @_;

    my ($vtype, $name, $vmid, undef, undef, $isBase, $format) = $class->parse_volname($volname);

    # Only apply NBD unmapping logic for raw images in mfsbdev mode
    if ($vtype ne 'images' || $format ne 'raw' || !$scfg->{mfsbdev}) {
        return $operation->();
    }

    my $mfs_path = "/images/$vmid/$name";
    my $was_mapped = 0;
    my $nbd_device = undef;

    # Check if currently mapped to an NBD device
    if (moosefs_bdev_is_active($scfg)) {
        my $list_cmd = ['/usr/sbin/mfsbdev', 'list'];
        my $list_output = '';
        eval {
            run_command($list_cmd, outfunc => sub { $list_output .= shift; }, errmsg => 'mfsbdev list failed');
        };

        # Parse mfsbdev list output to find if this volume is mapped
        for my $line (split /\r?\n/, $list_output) {
            if ($line =~ /\bfile:\s*\Q$mfs_path\E\b.*?\bdevice:\s*(\/dev\/nbd\d+)/) {
                $was_mapped = 1;
                $nbd_device = $1;
                log_debug "[with_nbd_unmapped] Volume $volname is mapped to $nbd_device, unmapping before snapshot operation";

                # Unmap the device to prevent NBD daemon crash during snapshot
                my $unmap_cmd = ['/usr/sbin/mfsbdev', 'unmap', '-f', $mfs_path];
                run_command($unmap_cmd, errmsg => "Failed to unmap $mfs_path before snapshot operation");
                last;
            }
        }
    }

    # Execute the snapshot operation with NBD unmapped
    my $result = eval { $operation->() };
    my $error = $@;

    # Remap if it was mapped before
    if ($was_mapped) {
        log_debug "[with_nbd_unmapped] Remapping volume $volname after snapshot operation";

        # Get size from .size file
        my $size_file = "$scfg->{path}$mfs_path.size";
        if (!-e $size_file) {
            log_debug "[with_nbd_unmapped] ERROR: Size file $size_file missing, cannot remap";
            die "Cannot remap volume after snapshot: size file missing at $size_file";
        }

        my $size_kib = do {
            open(my $fh, '<', $size_file) or die "Failed to read size file $size_file: $!";
            local $/;
            my $content = <$fh>;
            close $fh;
            $content;
        };
        chomp $size_kib;
        my $size_bytes = $size_kib * 1024;

        my $map_cmd = ['/usr/sbin/mfsbdev', 'map', '-f', $mfs_path, '-s', $size_bytes];
        eval { run_command($map_cmd, errmsg => "Failed to remap $mfs_path after snapshot operation"); };
        if ($@) {
            log_debug "[with_nbd_unmapped] ERROR: Failed to remap after snapshot: $@";
            die "Snapshot operation succeeded but failed to remap NBD device: $@";
        }

        log_debug "[with_nbd_unmapped] Successfully remapped $volname to NBD device";
    }

    die $error if $error;
    return $result;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($storageType, $name, $vmid, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);

    if ($format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot(@_);
    }

    die "snapshots not supported for this storage type" if $storageType ne 'images';

    # Wrap the snapshot operation with NBD unmapping to prevent daemon crashes
    return $class->with_nbd_unmapped($scfg, $volname, sub {
        my $mountpoint = $scfg->{path};

        my $snapdir = "$mountpoint/images/$vmid/snaps/$snap";

        File::Path::make_path($snapdir);

        log_debug "running '/usr/bin/mfsmakesnapshot $mountpoint/images/$vmid/$name $snapdir/$name'\n";

        my $cmd = ['/usr/bin/mfsmakesnapshot', "$mountpoint/images/$vmid/$name", "$snapdir/$name"];

        run_command($cmd, errmsg => 'An error occurred while making the snapshot');

        return undef;
    });
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my ($storageType, $name, $vmid, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);

    if ($format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot_delete(@_);
    }

    # Wrap the snapshot deletion with NBD unmapping to prevent daemon crashes
    return $class->with_nbd_unmapped($scfg, $volname, sub {
        my $mountpoint = $scfg->{path};

        my $cmd = ['/usr/bin/mfsrmsnapshot', "$mountpoint/images/$vmid/snaps/$snap/$name"];

        run_command($cmd, errmsg => 'An error occurred while deleting the snapshot');

        return undef;
    });
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($storageType, $name, $vmid, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);

    if ($format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot_rollback(@_);
    }

    # Wrap the snapshot rollback with NBD unmapping to prevent daemon crashes
    return $class->with_nbd_unmapped($scfg, $volname, sub {
        my $mountpoint = $scfg->{path};

        my $snapdir = "$mountpoint/images/$vmid/snaps/$snap";

        my $cmd = ['/usr/bin/mfsmakesnapshot', '-o', "$snapdir/$name", "$mountpoint/images/$vmid/$name"];

        run_command($cmd, errmsg => 'An error occurred while restoring the snapshot');

        return undef;
    });
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfsport = $scfg->{mfsport} // '9421';

    my $mfssubfolder = $scfg->{mfssubfolder};

    return undef if !moosefs_is_mounted($mfsmaster, $mfsport, $path, $cache->{mountdata}, $mfssubfolder);

    return $class->SUPER::status($storeid, $scfg, $cache);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfsport = $scfg->{mfsport} // '9421';

    my $mfssubfolder = $scfg->{mfssubfolder};

    if (!moosefs_is_mounted($mfsmaster, $mfsport, $path, $cache->{mountdata}, $mfssubfolder)) {

        File::Path::make_path($path) if !(defined($scfg->{mkdir}) && !$scfg->{mkdir});

        die "unable to activate storage '$storeid' - " .
            "directory '$path' does not exist\n" if ! -d $path;

        moosefs_mount($scfg);
    }

    if ($scfg->{mfsbdev} && !moosefs_bdev_is_active($scfg)) {
        moosefs_start_bdev($scfg);
    }

    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub on_delete_hook {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};

    my $mfsmaster = $scfg->{mfsmaster} // 'mfsmaster';

    my $mfsport = $scfg->{mfsport} // '9421';

    my $mfssubfolder = $scfg->{mfssubfolder};

    if (moosefs_is_mounted($mfsmaster, $mfsport, $path, $cache->{mountdata}, $mfssubfolder)) {
        moosefs_unmount($scfg);
    }
}

1;
