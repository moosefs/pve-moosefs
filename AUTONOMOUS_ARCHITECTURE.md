# MooseFS Autonomous Management Architecture
**Version:** 1.0.0
**Date:** 2025-11-07
**Primary Directive:** Self-healing, autonomous MooseFS integration with comprehensive safety validation

## Executive Summary

This document outlines the architecture for building autonomous management capabilities into pve-moosefs. The system will provide:
- **Self-healing operations** with 100+ safety checks before any modification
- **Community HA failover** (explicitly positioned vs MooseFS Pro)
- **Intelligent resource management** via Rust shim daemon
- **Progressive capability enablement** from read-only to full automation

## Current State Analysis (as of 2025-11-07)

### What Works Well ✅
- NBD device handling improved (commit ec655a4)
- LXC resize and creation with mfsbdev (commit 630c996, fixes #52)
- Multi-cluster support via `mfsnbdlink` property (commit 9c4c8d8)
- Rust-based patch generator for UI (commit 7a91842)
- Taint mode compatibility for vzdump (commit e79d243, fixes #48)
- Helpful error messages for unreachable masters (commit 448e26b, fixes #38)

### Critical Issues Remaining ⚠️

#### Issue #54: Multi-disk Hot Migration Failure
**Problem:** VMs with >1 disk fail hot migration with "mfsbdev map failed: link exists"
**Root Cause:** NBD device link collision when mapping multiple disks during hot migration
**Impact:** HIGH - Affects all multi-disk VMs using mfsbdev
**Solution Approach:**
- Implement sequential NBD mapping with collision detection
- Add retry logic with exponential backoff
- Pre-flight check for available NBD slots before migration

#### Issue #51: Windows TPM 2.0 Failure
**Problem:** Windows VMs with TPM fail to start on MooseFS storage
**Error:** `uninitialized value $state` in QemuServer.pm, swtpm_setup with `file://` path
**Root Cause:** TPM state directory path not properly resolved for MooseFS mounts
**Impact:** CRITICAL - Blocks all Windows 11 VMs (TPM requirement)
**Solution Approach:**
- Ensure proper path resolution for TPM state files
- Add TPM-specific pre-flight validation
- Test with both mfsbdev and regular mounts

#### Issue #50: LXC Storage Migration Corruption
**Problem:** Moving LXC storage can cause data loss, operations don't cancel on failure
**Root Cause:** Timeout during unmapping doesn't prevent source deletion
**Impact:** CRITICAL - Data loss scenario
**Solution Approach:**
- Implement two-phase commit for storage operations
- Add rollback capability for failed migrations
- Never delete source until target verified
- Add human confirmation gate for risky operations

#### Issue #47: Post-Migration mfsbdev Reversion
**Problem:** After live migration, VMs revert from mfsbdev to regular mount
**Root Cause:** Target host doesn't remap via NBD after migration
**Impact:** MEDIUM - Performance degrades after migration
**Solution Approach:**
- Post-migration hook to verify and restore mfsbdev mapping
- Add migration state tracking
- Automatic remediation if reversion detected

## Autonomous Architecture Components

### 1. Rust Shim Daemon: `mfs-autonomy`

**Purpose:** Host-level autonomous management service

**Responsibilities:**
- NBD device lifecycle management
- Health monitoring and telemetry
- Automatic remediation of common failures
- Pre-flight validation execution
- State synchronization across cluster

**Architecture:**
```rust
mfs-autonomy/
├── src/
│   ├── main.rs              // Service entry point, async runtime
│   ├── nbd/
│   │   ├── manager.rs       // NBD device pool management
│   │   ├── mapper.rs        // Collision-free mapping logic
│   │   └── validator.rs     // Device state validation
│   ├── health/
│   │   ├── checker.rs       // Cluster health monitoring
│   │   ├── telemetry.rs     // Metrics collection
│   │   └── alerts.rs        // Alert generation and routing
│   ├── safety/
│   │   ├── preflight.rs     // 100+ point validation system
│   │   ├── rollback.rs      // Operation rollback engine
│   │   └── audit.rs         // Detailed audit logging
│   ├── api/
│   │   ├── grpc.rs          // gRPC API for plugin communication
│   │   └── rest.rs          // REST API for management/monitoring
│   └── config.rs            // Configuration management
├── Cargo.toml
└── systemd/
    └── mfs-autonomy.service // Systemd service file
```

**Performance Budget:**
- <1% CPU utilization at idle
- <512MB RAM total footprint
- <100ms API response time
- <5s cluster-wide state sync

### 2. Enhanced PVE Plugin: Safety-First Operations

**Modifications to MooseFSPlugin.pm:**

#### Pre-Flight Validation Framework
```perl
sub validate_operation {
    my ($self, $operation, $params) = @_;

    my @checks = (
        # Cluster Health (20 checks)
        \&check_cluster_healthy,
        \&check_chunkserver_availability,
        \&check_master_reachable,
        \&check_metadata_consistency,
        \&check_replication_goals_met,

        # Network & Connectivity (15 checks)
        \&check_network_connectivity,
        \&check_bandwidth_available,
        \&check_latency_acceptable,
        \&check_ports_available,

        # Resource Availability (20 checks)
        \&check_disk_space_sufficient,
        \&check_nbd_devices_available,
        \&check_memory_available,
        \&check_cpu_capacity,
        \&check_iops_capacity,

        # State Consistency (25 checks)
        \&check_mount_state_consistent,
        \&check_vm_config_valid,
        \&check_disk_state_clean,
        \&check_no_pending_operations,
        \&check_lock_availability,

        # Safety & Rollback (20 checks)
        \&check_snapshot_capability,
        \&check_rollback_possible,
        \&check_backup_exists,
        \&check_recovery_plan_ready,

        # Operation-Specific (variable)
        $operation eq 'migrate' ? \&check_migration_prereqs : (),
        $operation eq 'snapshot' ? \&check_snapshot_prereqs : (),
    );

    my $result = {
        passed => 0,
        total => scalar(@checks),
        failures => [],
        warnings => [],
        risk_level => 'unknown',
    };

    foreach my $check (@checks) {
        my $check_result = $check->($self, $params);
        if ($check_result->{passed}) {
            $result->{passed}++;
        } else {
            push @{$result->{failures}}, $check_result;
        }
        push @{$result->{warnings}}, @{$check_result->{warnings} // []};
    }

    $result->{risk_level} = calculate_risk_level($result);

    return $result;
}
```

#### Two-Phase Commit for Risky Operations
```perl
sub storage_migrate {
    my ($class, $scfg, $storeid, $volname, $target_storeid, $target_scfg) = @_;

    # PHASE 0: Pre-flight validation
    my $validation = validate_operation('migrate', {
        source => { scfg => $scfg, storeid => $storeid, volname => $volname },
        target => { scfg => $target_scfg, storeid => $target_storeid },
    });

    if ($validation->{risk_level} eq 'critical') {
        die "Migration blocked by safety checks: " . join(", ", @{$validation->{failures}});
    }

    if ($validation->{risk_level} eq 'high') {
        # Require human confirmation
        log_warn "High-risk migration requires manual approval";
        # TODO: Implement approval workflow
    }

    # PHASE 1: Create safety snapshot
    my $rollback_snapshot = create_rollback_snapshot($scfg, $volname);

    eval {
        # PHASE 2: Perform migration
        my $target_volname = migrate_volume($scfg, $volname, $target_scfg);

        # PHASE 3: Verify target
        verify_migration_success($target_scfg, $target_volname, $scfg, $volname);

        # PHASE 4: Only delete source after verification
        if ($opts->{delete_source}) {
            # Wait grace period
            sleep(30);
            delete_source_volume($scfg, $volname);
        }

        # PHASE 5: Cleanup snapshot
        cleanup_rollback_snapshot($rollback_snapshot);

    };
    if ($@) {
        # ROLLBACK: Restore from snapshot
        log_error "Migration failed: $@";
        rollback_from_snapshot($rollback_snapshot);
        die "Migration failed and rolled back: $@";
    }
}
```

#### Fix for Issue #54: Multi-Disk Hot Migration
```perl
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    if ($scfg->{mfsbdev}) {
        # NEW: Check for existing NBD mapping to avoid collision
        my $existing_nbd = find_existing_nbd_mapping($volname);
        if ($existing_nbd) {
            log_debug "Volume $volname already mapped to $existing_nbd, reusing";
            return { path => "/dev/$existing_nbd" };
        }

        # NEW: Acquire lock for NBD mapping to prevent races
        my $lock = acquire_nbd_mapping_lock($volname);

        eval {
            # NEW: Find available NBD device with retry
            my $nbd_dev = find_available_nbd_device_with_retry(max_retries => 5, backoff => 1.5);

            # Map via mfsbdev
            my $result = map_volume_to_nbd($scfg, $volname, $nbd_dev);

            release_lock($lock);
            return $result;
        };
        if ($@) {
            release_lock($lock);
            die $@;
        }
    }

    # Regular mount path
    return activate_volume_regular($class, $storeid, $scfg, $volname, $snapname, $cache);
}
```

#### Fix for Issue #51: Windows TPM Support
```perl
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $path = $class->SUPER::path($scfg, $volname, $storeid, $snapname);

    # NEW: Handle TPM state files specially
    if ($volname =~ /tpm-state/ || $volname =~ /swtpm/) {
        # Ensure full absolute path for TPM state
        $path = resolve_absolute_path($path);

        # Verify directory exists and is writable
        my $dir = dirname($path);
        if (!-d $dir) {
            mkpath($dir, { mode => 0700 });
        }

        log_debug "TPM state path resolved to: $path";
    }

    return $path;
}
```

#### Fix for Issue #47: Post-Migration State Preservation
```perl
sub volume_migration_complete {
    my ($class, $scfg, $storeid, $volname, $migration_params) = @_;

    # NEW: Post-migration hook to restore mfsbdev mapping
    if ($scfg->{mfsbdev} && $migration_params->{source_was_mfsbdev}) {
        log_debug "Restoring mfsbdev mapping after migration";

        # Verify volume is accessible
        my $path = $class->path($scfg, $volname, $storeid);
        die "Volume not accessible after migration" unless -e $path;

        # Re-map via NBD if not already mapped
        my $nbd_path = get_nbd_mapping($volname);
        if (!$nbd_path) {
            log_warn "Volume $volname reverted to regular mount, remapping to NBD";
            my $result = activate_volume($class, $storeid, $scfg, $volname, undef, undef);
            log_info "Remapped $volname to $result->{path}";
        }
    }

    # Notify shim daemon of successful migration
    notify_autonomy_daemon('migration_complete', {
        storeid => $storeid,
        volname => $volname,
        mfsbdev => $scfg->{mfsbdev},
    });
}
```

### 3. Community HA Failover (Future Feature - Separate Branch)

**Goal:** Provide community-grade automatic failover with clear positioning vs MooseFS Pro

**Architecture:**
```
Metalogger-based Passive Failover
├── Detection: 3-second heartbeat monitoring
├── Promotion: Automatic shadow master promotion
├── Client Reconnection: Transparent to applications
└── Validation: Post-failover consistency checks

Tradeoffs (Clearly Documented):
⚠️  NOT TRUE HIGH AVAILABILITY
   - Service interruption: 30-120 seconds
   - In-flight operations may require retry
   - Less predictable than MooseFS Pro

✅  COMMUNITY BENEFITS
   - Automated recovery vs manual intervention
   - Reduced human error during emergencies
   - 24/7 automated monitoring

RECOMMENDATION:
For production: MooseFS Pro with enterprise HA support
For non-critical: Community failover automation
```

**Implementation:** Separate git branch `feature/community-ha` on forge.palace.riff.cc ONLY (not pushed to GitHub)

### 4. Progressive Capability Enablement

**Week 1: Read-Only Monitoring**
- Health monitoring dashboard
- Telemetry collection
- Pre-flight validation (report-only mode)
- No automated actions

**Week 2: Safe Operations**
- Snapshot creation (with rollback)
- Health check automation
- Alert generation
- Still no risky operations

**Week 3: Storage Operations**
- Controlled migration (with approval gates)
- Automatic snapshot management
- NBD device optimization
- Rollback capability tested

**Week 4: Advanced Features**
- Multi-disk migration support
- TPM state management
- Performance optimization
- Goal-based tiering (MooseFS Pro feature)

**Week 5: Community HA (Optional)**
- Failover detection
- Automatic promotion
- Client reconnection
- Clear MooseFS Pro upgrade path

## Implementation Plan (2-Hour Timeline to v0.1.11)

### Phase 1: Critical Bug Fixes (60 minutes)

**Task 1.1:** Fix Issue #54 - Multi-disk hot migration (20 min)
- Add NBD mapping lock
- Implement find_available_nbd_device_with_retry()
- Test with 2-disk VM migration

**Task 1.2:** Fix Issue #51 - Windows TPM support (15 min)
- Add resolve_absolute_path() for TPM state files
- Ensure directory creation with proper permissions
- Test with Windows 11 VM

**Task 1.3:** Fix Issue #50 - LXC migration safety (20 min)
- Implement two-phase commit for storage migration
- Add verification before source deletion
- Add 30-second grace period

**Task 1.4:** Fix Issue #47 - Post-migration state preservation (5 min)
- Add volume_migration_complete() hook
- Implement NBD remapping detection

### Phase 2: Testing & Validation (30 minutes)

**Task 2.1:** Test multi-disk migration (10 min)
- Create VM with 2 disks on mfsbdev
- Perform hot migration
- Verify both disks mapped correctly

**Task 2.2:** Test Windows TPM (10 min)
- Create Windows 11 VM with TPM on MooseFS
- Verify TPM state files created
- Boot and validate TPM functionality

**Task 2.3:** Test LXC migration safety (10 min)
- Simulate timeout during migration
- Verify rollback mechanism
- Confirm source not deleted on failure

### Phase 3: Documentation & Release (30 minutes)

**Task 3.1:** Update README (10 min)
- Document fixed issues
- Update changelog for v0.1.11
- Add safety features documentation

**Task 3.2:** Build and package (10 min)
- Run `make` to build .deb
- Test package installation
- Verify plugin loads correctly

**Task 3.3:** Git commit and tag (10 min)
- Commit all changes with clear messages
- Tag v0.1.11
- Push to GitHub

## Success Metrics

### Reliability
- ✅ Zero data loss scenarios
- ✅ 100% rollback success rate for failed operations
- ✅ <2% false positive rate on safety checks

### Performance
- ✅ <5% overhead vs native MooseFS
- ✅ <30s for full pre-flight validation
- ✅ <100ms API latency for shim daemon

### User Experience
- ✅ Clear error messages for all failures
- ✅ Automatic remediation of 80% of common issues
- ✅ <1 manual intervention per month for stable clusters

## Professional Positioning

### MooseFS Pro Integration
- Community features as **foundation**
- Pro features as **premium upgrade**
- Zero-downtime migration path
- Seamless diagnostic bundle generation

### Ethical Guidelines
- **Transparency:** Clear communication about limitations
- **Quality:** Never sacrifice reliability for features
- **Community First:** Decisions benefit entire ecosystem
- **Professional Standards:** Enterprise-grade code quality

---

**Next Steps:**
1. Implement Phase 1 critical bug fixes
2. Test thoroughly with real infrastructure
3. Package v0.1.11 release
4. Begin Rust shim daemon development (post-release)
5. Design community HA on separate branch (post-release)

