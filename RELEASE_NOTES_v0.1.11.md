# Release Notes: pve-moosefs v0.1.11

**Release Date:** 2025-11-07
**Focus:** Migration Reliability & Windows TPM Support

## Overview

Version 0.1.11 represents a focused effort on improving reliability for common production scenarios: multi-disk VM migrations and Windows 11 VM support. While we've made significant progress, we remain committed to transparent communication about what's fixed and what's still in progress.

## What's Fixed

### Issue #54: Multi-Disk Hot Migration

**Problem:** VMs with multiple disks would fail during hot migration with cryptic "mfsbdev map failed: link exists" errors.

**Root Cause:** When migrating VMs with multiple disks simultaneously, NBD device mapping operations could collide, creating race conditions that the previous implementation didn't handle gracefully.

**Solution Implemented:**
- **Intelligent retry logic** with up to 5 attempts and exponential backoff (starting at 100ms, scaling to ~760ms)
- **Pre-mapping checks** that detect if a volume is already mapped before attempting new mapping
- **Graceful degradation** to filesystem paths if NBD mapping repeatedly fails

**What This Means for You:**
Hot migration of multi-disk VMs should now complete successfully in most cases. The retry logic gives the system time to resolve temporary resource contention. If you're migrating VMs with 3+ large disks, you may still see slight delays, but operations should complete rather than fail.

**Testing Recommendation:**
Test with a 2-disk VM in a non-production environment first. The fix has been validated synthetically but benefits from real-world testing across different disk sizes and network conditions.

### Issue #51: Windows TPM 2.0 Support

**Problem:** Windows 11 VMs (which require TPM 2.0) would fail to start on MooseFS storage with obscure path-related errors from `swtpm_setup`.

**Root Cause:** TPM state files require specific directory structures and absolute paths. The plugin wasn't ensuring these directories existed before Proxmox's TPM subsystem tried to use them.

**Solution Implemented:**
- **Early TPM volume detection** via pattern matching on volume names
- **Automatic directory creation** with proper permissions (mode 0700)
- **Absolute path resolution** to satisfy `swtpm_setup` requirements
- **Robust error handling** with detailed logging for troubleshooting

**What This Means for You:**
Windows 11 VMs should now start reliably on MooseFS storage. The TPM state directory is created automatically with the correct permissions, and the plugin ensures paths are in the format Windows TPM expects.

**Important Note:**
TPM state files are **not** stored via NBD block devices—they remain on the MooseFS filesystem mount. This is intentional and follows Proxmox's TPM design.

## Technical Improvements

### Enhanced Error Handling

The retry logic doesn't just blindly repeat operations—it distinguishes between:
- **Transient errors** (like "link exists" during races) → retry with backoff
- **Resource exhaustion** (like "can't find free NBD device") → log detailed error, fallback gracefully
- **Fatal errors** (like missing volumes) → fail fast with clear messages

### Improved Logging

All operations now log their attempt number and backoff delays, making it much easier to diagnose issues in production:

```
Volume vm-100-disk-0 not yet mapped, retrying in 0.5s (attempt 0)
Link exists error detected, waiting 0.1s before retry 1
Found existing NBD device /dev/nbd3 for volume vm-100-disk-1 (attempt 2)
```

### Concurrent Operation Safety

The multi-step checking process (list existing mappings → retry if needed → map with retry) significantly reduces the window for race conditions, though it doesn't eliminate them entirely. True atomic NBD device allocation would require changes to `mfsbdev` itself.

## What's Still In Progress

We believe in transparency about limitations and ongoing work:

### Issue #50: LXC Storage Migration Safety

**Status:** Under active investigation
**Impact:** LXC storage migrations can potentially lose data if operations timeout during unmapping

**Current State:** The plugin doesn't have two-phase commit logic for storage migrations yet. If an operation times out during the unmap phase, the source might be deleted before the target is fully verified.

**Planned Fix:** Implementing proper transaction semantics with rollback capability. This is complex work that needs careful design to avoid making things worse.

**Workaround:** Take manual snapshots before migrating LXC storage, and avoid the "delete source" option for critical containers.

### Issue #47: Post-Migration NBD State Preservation

**Status:** Root cause identified, fix in design phase
**Impact:** After live migration, VMs sometimes revert from NBD block device to regular filesystem mounts, degrading performance

**Current State:** The target host doesn't always remap volumes via NBD after receiving a migrated VM.

**Planned Fix:** Post-migration hooks to verify and restore NBD mappings automatically.

**Workaround:** If you notice degraded performance after migration, check `/var/log/mfsplugindebug.log` for NBD mapping status. Manual VM restart on the target host will restore NBD mapping.

## Compatibility & Requirements

- **Proxmox VE:** 9.0 or newer (unchanged)
- **MooseFS:** Community Edition 4.0+ or MooseFS Pro 4.0+
- **Kernel Modules:** NBD module with `max_part=16` or higher

## Installation

### Fresh Installation

```bash
wget https://github.com/moosefs/pve-moosefs/releases/download/v0.1.11/libpve-storage-custom-moosefs-perl_0.1.11-1_all.deb
dpkg -i libpve-storage-custom-moosefs-perl_0.1.11-1_all.deb
systemctl restart pvedaemon pveproxy pvestatd
```

### Upgrade from v0.1.10

```bash
wget https://github.com/moosefs/pve-moosefs/releases/download/v0.1.11/libpve-storage-custom-moosefs-perl_0.1.11-1_all.deb
dpkg -i libpve-storage-custom-moosefs-perl_0.1.11-1_all.deb
systemctl restart pvedaemon pveproxy pvestatd
```

**Note:** Active VMs and LXCs don't need to be restarted—the plugin changes take effect for new operations immediately after the Proxmox services restart.

## Testing & Validation

We recommend this testing sequence for production deployments:

1. **Multi-Disk Migration Test:**
   - Create a test VM with 2 disks on MooseFS storage (mfsbdev enabled)
   - Perform hot migration while VM is running
   - Verify both disks are accessible on target host
   - Check `/var/log/mfsplugindebug.log` for clean mapping logs

2. **Windows TPM Test:**
   - Create a Windows 11 VM on MooseFS storage
   - Enable TPM 2.0 in VM hardware settings
   - Start the VM and verify TPM is available in Windows
   - Check that TPM state persists across VM restarts

3. **Regular Operation Verification:**
   - Test snapshot creation (still experimental, keep backups!)
   - Verify VM/LXC creation and deletion
   - Check that existing workloads continue functioning normally

## Known Limitations

- **Snapshot safety:** Still experimental. Data loss is possible. Keep backups.
- **Performance during migration:** Multi-disk migrations with large datasets may be slower due to retry logic overhead
- **NBD device exhaustion:** Hosts with many concurrent VM startups might exhaust NBD devices temporarily—increase `max_part` if needed
- **TPM migration:** TPM state directories are per-host, not automatically synced during live migration (this is a Proxmox limitation, not specific to MooseFS)

## Future Roadmap

Based on community feedback and ongoing work:

- **v0.1.12:** LXC migration safety improvements (Issue #50)
- **v0.1.13:** Post-migration NBD state preservation (Issue #47)
- **v0.2.0:** Production-grade snapshot support with safety guarantees
- **v0.3.0:** Autonomous management capabilities (self-healing, cluster health monitoring)

## Support & Contribution

- **Report Issues:** [GitHub Issues](https://github.com/moosefs/pve-moosefs/issues)
- **Professional Support:** For enterprise deployments, consider [MooseFS Pro](https://moosefs.com/products) which includes production-grade HA and dedicated support

## Acknowledgments

- **Testing:** Community members who reported #54 and #51 with detailed error logs
- **MooseFS Team:** [@pkonopelko](https://github.com/pkonopelko) for guidance on mfsbdev internals
- **Palace Automation:** Architecture and autonomous systems design framework

---

**Final Note:** We're committed to building production-ready MooseFS integration for Proxmox, but we're not there yet. This release makes meaningful progress on reliability, but we won't claim perfection. Test thoroughly, maintain backups, and report issues. We're listening and improving with every release.
