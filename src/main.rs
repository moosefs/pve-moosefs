use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

const MOOSEFS_UI_PANEL: &str = r#"Ext.define('PVE.storage.MooseFSController', {
    extend: 'Ext.app.ViewController',
    alias: 'controller.pve-storage-moosefs'
});
Ext.define('PVE.storage.MooseFSInputPanel', {
    extend: 'PVE.panel.StorageBase',
	controller: 'pve-storage-moosefs',

    onlineHelp: 'storage_moosefs',

    initComponent: function() {
        let me = this;

        me.column1 = [
            {
				xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'path',
                value: '',
                fieldLabel: gettext('Mount Point'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                name: 'mfsmaster',
                value: 'mfsmaster',
                fieldLabel: gettext('MooseFS Master'),
                allowBlank: true,
                emptyText: 'mfsmaster',
                submitEmpty: false,
            },
            {
                xtype: 'numberfield',
                name: 'mfsport',
                value: '9421',
                fieldLabel: gettext('Master Port'),
                allowBlank: true,
                emptyText: '9421',
                submitEmpty: false,
                minValue: 1,
                maxValue: 65535,
            },
            {
                xtype: 'pveContentTypeSelector',
                name: 'content',
                value: ['images', 'iso', 'vztmpl', 'backup', 'snippets', 'rootdir'],
                multiSelect: true,
                fieldLabel: gettext('Content'),
                allowBlank: false,
            },
        ];

        me.column2 = [
            {
                xtype: 'proxmoxcheckbox',
                name: 'shared',
                checked: true,
                uncheckedValue: 0,
                fieldLabel: gettext('Shared'),
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'mfsbdev',
                checked: false,
                uncheckedValue: 0,
                fieldLabel: gettext('Use Block Device'),
            },
        ];

        me.advancedColumn1 = [
            {
                xtype: 'textfield',
                name: 'mfssubfolder',
                fieldLabel: gettext('Subfolder'),
                allowBlank: true,
                submitEmpty: false,
                emptyText: '/',
                autoEl: {
                    tag: 'div',
                    'data-qtip': gettext('The subfolder to mount. Leave empty to mount the root directory.'),
                },
            },
        ];

        me.advancedColumn2 = [
            {
                xtype: 'textfield',
                name: 'mfspassword',
                fieldLabel: gettext('Password'),
                allowBlank: true,
                submitEmpty: false,
                inputType: 'password',
            },
            {
                xtype: 'textfield',
                name: 'mfsnbdlink',
                fieldLabel: gettext('NBD Socket'),
                allowBlank: true,
                submitEmpty: false,
                emptyText: '/dev/mfs/nbdsock',
            },
        ];

        me.callParent();
    },
});"#;

const STORAGE_TYPES_ADDITION: &str = r#"            moosefs: {
                name: 'MooseFS',
                ipanel: 'MooseFSInputPanel',
                faIcon: 'building',
                backups: true,
            },"#;

fn main() -> Result<()> {
    println!("MooseFS Patch Generator for Proxmox VE");
    println!("========================================\n");

    // Get the currently installed pvemanagerlib.js
    let current_js = Path::new("/usr/share/pve-manager/js/pvemanagerlib.js");

    if !current_js.exists() {
        anyhow::bail!("pvemanagerlib.js not found. Is pve-manager installed?");
    }

    println!("✓ Found installed pvemanagerlib.js");

    // Get pve-manager version
    let version_output = Command::new("dpkg-query")
        .args(&["-W", "-f=${Version}", "pve-manager"])
        .output()
        .context("Failed to get pve-manager version")?;

    let version = String::from_utf8_lossy(&version_output.stdout);
    println!("✓ pve-manager version: {}", version);

    // Create temp directory
    let temp_dir = TempDir::new().context("Failed to create temp directory")?;
    let temp_path = temp_dir.path();

    // Download clean pve-manager deb
    println!("\nDownloading clean pve-manager package...");

    let download_result = Command::new("apt-get")
        .args(&["download", "pve-manager"])
        .current_dir(temp_path)
        .output()
        .context("Failed to download pve-manager package")?;

    if !download_result.status.success() {
        anyhow::bail!("Failed to download pve-manager: {}",
            String::from_utf8_lossy(&download_result.stderr));
    }

    // Find the downloaded .deb file
    let deb_file = fs::read_dir(temp_path)?
        .filter_map(|e| e.ok())
        .find(|e| e.path().extension().map_or(false, |ext| ext == "deb"))
        .context("No .deb file found after download")?
        .path();

    println!("✓ Downloaded: {}", deb_file.file_name().unwrap().to_string_lossy());

    // Extract the .deb
    println!("\nExtracting package...");
    let extract_dir = temp_path.join("extracted");
    fs::create_dir(&extract_dir)?;

    Command::new("dpkg-deb")
        .args(&["-x", deb_file.to_str().unwrap(), extract_dir.to_str().unwrap()])
        .output()
        .context("Failed to extract deb package")?;

    let clean_js = extract_dir.join("usr/share/pve-manager/js/pvemanagerlib.js");

    if !clean_js.exists() {
        anyhow::bail!("pvemanagerlib.js not found in extracted package");
    }

    println!("✓ Extracted pvemanagerlib.js");

    // Read clean file
    let clean_content = fs::read_to_string(&clean_js)
        .context("Failed to read clean pvemanagerlib.js")?;

    // Generate modified version
    println!("\nGenerating patched version...");
    let modified_content = apply_moosefs_changes(&clean_content)?;

    // Write modified version
    let modified_js = temp_path.join("pvemanagerlib.patched.js");
    fs::write(&modified_js, &modified_content)
        .context("Failed to write modified pvemanagerlib.js")?;

    println!("✓ Created patched version");

    // Generate unified diff
    println!("\nGenerating patch file...");
    let diff_output = Command::new("diff")
        .args(&[
            "-u",
            "--label", "pvemanagerlib.js",
            "--label", "pvemanagerlib.patched.js",
            clean_js.to_str().unwrap(),
            modified_js.to_str().unwrap(),
        ])
        .output()
        .context("Failed to generate diff")?;

    let patch_content = String::from_utf8(diff_output.stdout)
        .context("Diff output is not valid UTF-8")?;

    // Write patch file
    let patch_path = PathBuf::from("pve-moosefs.patch");
    fs::write(&patch_path, patch_content)
        .context("Failed to write patch file")?;

    println!("✓ Generated pve-moosefs.patch");

    // Test the patch
    println!("\nTesting patch...");
    let test_result = Command::new("patch")
        .args(&[
            "-p0",
            "--dry-run",
            "-i", "pve-moosefs.patch",
            clean_js.to_str().unwrap(),
        ])
        .output()
        .context("Failed to test patch")?;

    if test_result.status.success() {
        println!("✓ Patch applies cleanly");
    } else {
        eprintln!("⚠ Warning: Patch may not apply cleanly:");
        eprintln!("{}", String::from_utf8_lossy(&test_result.stderr));
    }

    println!("\n✅ Patch generation complete: pve-moosefs.patch");

    Ok(())
}

fn apply_moosefs_changes(content: &str) -> Result<String> {
    let lines: Vec<&str> = content.lines().collect();
    let mut result = Vec::new();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i];

        // Insert storage type after the last storage before 'cephfs'
        if line.trim().starts_with("cephfs: {") {
            // Add MooseFS storage type before CephFS
            for moosefs_line in STORAGE_TYPES_ADDITION.lines() {
                result.push(moosefs_line.to_string());
            }
        }

        // Insert UI panel definition before BTRFSInputPanel
        if line.contains("Ext.define('PVE.storage.BTRFSInputPanel'") {
            // Add MooseFS UI panel before BTRFS
            for panel_line in MOOSEFS_UI_PANEL.lines() {
                result.push(panel_line.to_string());
            }
            result.push(String::new()); // Add blank line
        }

        result.push(line.to_string());
        i += 1;
    }

    Ok(result.join("\n"))
}
