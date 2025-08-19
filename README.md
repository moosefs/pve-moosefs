# pve-moosefs

**MooseFS integration for Proxmox VE**

This plugin enables native support for MooseFS as a storage backend in Proxmox VE.

## ⚠️ Disclaimer

**This project is highly experimental.**

> ⚠️ **Do NOT use snapshots in MooseFS block device (bdev) mode**. They are currently unsafe and may result in data loss. Snapshot support is still under active development and will remain experimental until this warning is removed.

## 📷 Preview

<img width="597" alt="image" src="https://github.com/user-attachments/assets/a3d13281-344e-4ec4-9ed8-7556582e5d5b" />

## ✨ Features

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Zorlin/pve-moosefs)

* Native MooseFS support in Proxmox VE
* Support for MooseFS clusters with passwords and subfolders
* Live VM migration across Proxmox hosts with MooseFS-backed storage
* Clean unmounting when MooseFS storage is removed
* MooseFS block device (`mfsbdev`) support for high performance

## 🚧 Planned Features

* Instant snapshots and rollbacks
* Instant cloning

## 🚀 Installation & Usage

### Prerequisites

* **Proxmox VE 8.4.1 or newer**

### Option 1: Easy Install

1. Upgrade to Proxmox 8.4.1
2. Download and install the `.deb` package from the [Releases](../../releases) page.

### Option 2: Manual Build

1. Upgrade to Proxmox 8.4.1
2. Clone this repository:

   ```bash
   git clone https://github.com/yourusername/pve-moosefs.git
   cd pve-moosefs
   ```
3. Build the package:

   ```bash
   make
   ```
4. Install it:

   ```bash
   dpkg -i *.deb
   ```

## 🖥️ Mounting MooseFS Storage

### Via GUI

1. Open the **Proxmox Web Interface**
2. Navigate to **Datacenter → Storage**
3. Click **Add → MooseFS** and complete the wizard

### Via Command Line

```bash
pvesm add moosefs moosefs-vm-storage --path /mnt/mfs
```

This command creates a custom storage named `moosefs-vm-storage` using the MooseFS plugin.

#### Optional parameters:

* `--mfsmaster <hostname>` — specify the MooseFS metadata server
* `--mfspassword <password>` — use if your MooseFS export requires authentication
* `--mfssubfolder <folder>` — mount a subfolder rather than the root of the MooseFS volume
* `--mfsport <port>` — coming soon 🚧

## 🙏 Credits

**Contributors:**

* [@anwright](https://github.com/anwright) — major fixes, snapshots, and cleanup
* [@pkonopelko](https://github.com/pkonopelko) — general advice and support

**Inspiration and references (for plugin skeleton and packaging):**

* [mityarzn/pve-storage-custom-mpnetapp](https://github.com/mityarzn/pve-storage-custom-mpnetapp)
* [ServeTheHome Forums](https://forums.servethehome.com/index.php?threads/custom-storage-plugins-for-proxmox.12558/)
* Official Proxmox GlusterFS and CephFS storage plugins

## 📝 Changelog

### v0.1.7 - Critical Bug Fixes

* Fixes rare but major crash condition for VMs and LXCs
* Adds support for Proxmox VE 9.0

### v0.1.5 - Bug Fixes

* Improvements to LXC snapshot support
* Reduced debugging log noise

### v0.1.4 – Bug Fixes

* Multiple small and defensive fixes
* Improved support for LXC
* Enhancements for live migration, unmapping, and cloning

### v0.1.3 – New Features

* Full support for MooseFS block device (`mfsbdev`)

### v0.1.2 – Initial Block Device Support

* Basic `mfsbdev` support added

### v0.1.1 – Enhancements

* GUI support for container storage
* Allowed leading `/` in `mfssubfolder` paths

### v0.1.0 – Initial Release

* Core features implemented
* MooseFS mount/unmount and shared storage setup
* **Snapshots not functional in this version**
