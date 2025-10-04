# MooseFS Patch Generator

Automated tool to generate the pve-moosefs UI patch for Proxmox VE.

## Purpose

This Rust tool automatically generates `pve-moosefs.patch` by:
1. Downloading the clean pve-manager package from apt
2. Extracting `pvemanagerlib.js`
3. Applying MooseFS UI changes programmatically
4. Creating a unified diff patch
5. Validating the patch applies cleanly

## Why Rust?

- Reliable: Type-safe, no manual string manipulation errors
- Fast: Generates patch in seconds
- Maintainable: UI changes defined in code constants
- Testable: Validates patch before saving

## Usage

```bash
# Build the tool
cargo build --release

# Generate patch
./target/release/generate-patch
```

The tool will:
- Check pve-manager is installed
- Download the clean package
- Generate `pve-moosefs.patch`
- Verify it applies cleanly

## UI Changes Included

The generated patch adds MooseFS storage support to Proxmox:

### Storage Type Registration
- Adds `moosefs` storage type
- Enables backups
- Uses building icon

### Input Panel Fields

**Main Section:**
- Mount Point
- MooseFS Master (default: mfsmaster)
- Master Port (default: 9421)
- Content Types
- Shared checkbox
- Use Block Device checkbox

**Advanced Section:**
- Subfolder (optional)
- Password (optional)
- **NBD Socket** (NEW - for multiple cluster support)

## Modifying the UI

To add or change UI fields:

1. Edit the constants in `src/main.rs`:
   - `MOOSEFS_UI_PANEL` - The full UI panel definition
   - `STORAGE_TYPES_ADDITION` - Storage type registration

2. Rebuild and run:
   ```bash
   cargo build --release
   ./target/release/generate-patch
   ```

3. The new `pve-moosefs.patch` will be generated

4. Test it:
   ```bash
   # Apply to test file
   patch --dry-run pvemanagerlib.js < pve-moosefs.patch
   ```

## Integration

The patch is applied during package installation by `postinst`:
- Checks if MooseFS support already exists
- Creates backup: `pvemanagerlib.js.dpkg-backup`
- Applies patch using `patch -p1`
- Restarts `pveproxy` service

## Troubleshooting

If the patch doesn't apply:
1. Check pve-manager version changed
2. Re-run generate-patch to create new patch
3. Check for Proxmox UI changes in conflicting areas

If UI changes don't appear:
1. Clear browser cache
2. Restart pveproxy: `systemctl restart pveproxy`
3. Check browser console for JS errors
