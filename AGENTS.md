# Repository Guidelines

## Project Overview
`tart-omarchy` builds and packages native **ARM64 Tart VM images of Omarchy 4 (Quattro)** for Apple Silicon Macs. Because official Omarchy ISO releases are x86_64-only and cannot boot directly in Apple Silicon virtualization, this repository orchestrates a two-phase native build pipeline using Packer, an Ubuntu ARM64 base VM, Arch Linux ARM (`aarch64`), and the official `omarchy-mac` (quattro) installer.

---

## Architecture & Data Flow

```
[Host: macOS Apple Silicon]
  ├── 1. Download & Verify ALARM rootfs (alarm-rootfs.tgz)
  ├── 2. Allocate 40 GB sparse target disk (.build/rootdisk.img)
  ├── 3. Create host package cache (.build/pkg-cache)
  │
  ├── 4. Phase 1 — Packer & Base VM Setup (builder/omarchy.pkr.hcl)
  │      └── Clone ghcr.io/cirruslabs/ubuntu:latest -> Upload rootfs & provision.sh over SSH
  │
  ├── 5. Phase 2 — Detached Guest Provisioning (builder/provision.sh)
  │      ├── Boot builder VM headlessly with target disk (/dev/vdb) & VirtioFS cache
  │      ├── Partition /dev/vdb: 512 MB ESP (/dev/vdb1) + 40 GB ext4 root (/dev/vdb2)
  │      ├── Extract ALARM rootfs into ext4 root (preserving numeric ownership)
  │      ├── Mount ESP to /target/boot/efi (leaving /boot on ext4 root)
  │      ├── Chroot: initialize keyring, upgrade base packages, configure networking/user
  │      ├── Install GRUB EFI removable loader (\EFI\BOOT\BOOTAA64.EFI)
  │      ├── Set Apple Virtualization.framework software-rendering flags (llvmpipe)
  │      ├── Run omarchy-mac (quattro) install.sh to build & install Omarchy 4.0.2
  │      └── Write BUILD-STATUS to ESP and shutdown VM
  │
  └── 6. Verification & Disk Swap (build-tart.sh)
         ├── Inspect BUILD-STATUS on ESP via host hdiutil/diskutil
         ├── Swap .build/rootdisk.img into ~/.tart/vms/omarchy/disk.img
         └── Tune VM hardware: 6 vCPUs, 12 GB RAM, 1512x982pt display, --display-refit
```

---

## Key Directories

- `builder/`: Packer templates and in-guest provisioning scripts.
  - `builder/omarchy.pkr.hcl`: Packer HCL template defining Tart builder and asset upload provisioners.
  - `builder/provision.sh`: In-guest provisioning script executed inside the Ubuntu builder VM.
- `.build/`: Transient build directory (git-ignored).
  - `.build/dl/`: Downloaded base rootfs tarball and checksums.
  - `.build/pkg-cache/`: Host-shared VirtioFS pacman package cache.
  - `.build/rootdisk.img`: The 40 GB sparse target disk image.
  - `.build/console.log`, `.build/build.log`: Serial and host orchestration logs.
- `.github/workflows/`: CI/CD automation.
  - `.github/workflows/build-and-publish.yml`: Automated GitHub Actions workflow to build and push Tart OCI images to GHCR.

---

## Development Commands

### Building & Running the VM
```bash
# Build the native ARM64 Omarchy VM from source (~30-45 min, cached subsequent runs)
./build-tart.sh

# Run the graphical Omarchy VM in Tart (opens GUI window)
tart run omarchy

# Run headless with serial console logging
tart run --serial omarchy

# Stop or delete the local VM
tart stop omarchy
tart delete omarchy
```

### Static Validation & Linting
```bash
# Check bash script syntax
bash -n build-tart.sh builder/provision.sh

# Validate Packer HCL template
packer validate builder/omarchy.pkr.hcl
```

### GUI Inspection & Verification (Cua Driver)
```bash
# List active GUI windows to find Tart window ID and PID
cua-driver call --tool list_windows --args '{}'

# Inspect accessibility tree and window layout of running Tart VM
cua-driver call --tool get_window_state --args '{"pid": <PID>, "window_id": <WINDOW_ID>, "include_screenshot": false}'
```

---

## Code Conventions & Common Patterns

### 1. Bash Standards
- **Strict Error Handling**: Scripts start with `set -euo pipefail`.
- **Signal Handling & Traps**:
  - `trap '' HUP` ensures long-running provisioning survives mid-build SSH disconnects.
  - `trap cleanup EXIT` guarantees `BUILD-STATUS` is written and the VM is powered down on error or success.
- **Logging Helpers**:
  - `say()`: Green-accented host status messages (`\033[1;32m==>\033[0m`).
  - `die()`: Red-accented fatal error messages (`\033[1;31merror:\033[0m`) followed by `exit 1`.
  - `log()`: In-guest progress timestamps.

### 2. Filesystem & Bootloader Architecture
- **Root & Boot Separation**:
  - `/dev/vdb2` (`ext4`, labeled `OMARCHY`) is mounted at `/` and contains `/boot` (where the kernel `Image`, `initramfs`, and all device tree binaries reside with ample space).
  - `/dev/vdb1` (`FAT32`, labeled `ESP`) is mounted at `/boot/efi` exclusively for GRUB EFI binaries and `grub.cfg`.
- **Rootfs Extraction**:
  - Always use `tar -xzpf ... --numeric-owner` to prevent host user ID mappings from corrupting Arch Linux system ownership.
- **Sudoers Permissions**:
  - Sudo drop-ins in `/etc/sudoers.d/` must be set to `chmod 0440` (or `0400`).
- **GRUB Boot Discovery**:
  - `grub.cfg` uses `search --no-floppy --set=root --file /boot/Image` and `search --label --set=root OMARCHY` to locate the kernel dynamically.

### 3. Apple Virtualization.framework Compatibility
- **Software Rendering (llvmpipe)**:
  Because Apple VZ does not expose a 3D GPU render node to Linux guests, the Wayland compositor (Hyprland) must be forced to software rendering in `/etc/environment.d/90-omarchy-tart.conf`:
  ```ini
  LIBGL_ALWAYS_SOFTWARE=1
  WLR_RENDERER_ALLOW_SOFTWARE=1
  AQ_NO_MODIFIERS=1
  ```
- **Display Aspect Ratio & Refit**:
  VM display must be configured with `--display 1512x982pt --display-refit` to prevent 4:3 letterboxing on 16:10 MacBook screens.

---

## Important Files

| File | Purpose |
| :--- | :--- |
| `build-tart.sh` | Main host orchestration script: manages inputs, runs Packer, monitors detached provisioning, checks `BUILD-STATUS`, and swaps disks. |
| `builder/omarchy.pkr.hcl` | Packer template for cloning `ghcr.io/cirruslabs/ubuntu:latest` and uploading assets. |
| `builder/provision.sh` | In-guest script that formats disks, unpacks ALARM, configures chroot, installs GRUB, and builds Omarchy packages. |
| `.github/workflows/build-and-publish.yml` | GitHub Actions workflow for building and publishing Tart OCI images to GHCR with semantic tags. |
| `README.md` | User-facing documentation with prerequisites, architecture overview, and operational commands. |

---

## Runtime & Tooling Preferences

- **Host Environment**: macOS 13+ (Ventura, Sonoma, Sequoia) running on Apple Silicon (`arm64`).
- **Required Host Binaries**:
  - `tart` (>= 2.0.0, available via `brew install cirruslabs/cli/tart`)
  - `packer` (>= 1.10.0, available via `brew install hashicorp/tap/packer`)
  - macOS native utilities: `hdiutil`, `diskutil`, `mkfile`, `curl`, `md5`/`shasum`.
- **Optional Tools**:
  - `cua-driver`: For programmatic desktop window discovery, state inspection, and automated GUI QA.
  - `qemu-img`: For importing published QCOW2 images (`--download` mode).

---

## Testing & QA

1. **Static Quality Gates**:
   - Run `bash -n` on all shell scripts.
   - Run `packer validate` on all HCL templates.
2. **Build Integrity Verification**:
   - `build-tart.sh` mounts the ESP partition out-of-band via `hdiutil attach` and validates that `BUILD-STATUS` contains `OK` before performing the disk swap.
3. **End-to-End Visual / GUI QA**:
   - Launch the VM with `tart run omarchy`.
   - Verify SDDM renders the Omarchy lock screen and accepts password `omarchy`.
   - Confirm the Hyprland Wayland compositor, top status bar (workspaces, live clock, network tray), and first-run welcome widget render without letterboxing or artifacts.
