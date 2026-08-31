# tart-omarchy

Native **ARM64 Tart VM image of Omarchy 4 (Quattro)** for Apple Silicon Macs (M1/M2/M3/M4).  
Boots directly into the Omarchy Hyprland Wayland desktop with full-width 16:10 display support.

---

## Quick Start (Run the Pre-built Image)

### 1. Install Tart
If you don't have [Tart](https://tart.run/) installed:
```bash
brew install cirruslabs/cli/tart
```

### 2. Pull and Clone the VM Image
Pull the pre-built, ready-to-run OCI image directly from GitHub Container Registry:
```bash
tart clone ghcr.io/chrisdoc/tart-omarchy:latest omarchy
```
*(Or pull a specific release tag, e.g. `ghcr.io/chrisdoc/tart-omarchy:4.0.2`)*

### 3. Launch the Desktop VM
```bash
tart run omarchy
```

---

## VM Credentials & Daily Use

- **Default User**: `omarchy`
- **Default Password**: `omarchy`
- **Root Access**: `sudo` (passwordless)

### Common Commands

#### SSH Access
Once you enable SSH in Omarchy (`omarchy-setup-security-sshd` or firewall settings):
```bash
ssh omarchy@$(tart ip omarchy)
```

#### Adjusting CPU & Memory
```bash
# Allocate 8 CPUs and 16 GB of RAM
tart set omarchy --cpu 8 --memory 16384
```

#### Changing Display Resolution
```bash
# Configure resolution with dynamic window refit
tart set omarchy --display 1512x982pt --display-refit
```

#### Stop or Delete the VM
```bash
tart stop omarchy
tart delete omarchy
```

---

## About Omarchy on Apple Silicon

Omarchy's official ISO is x86_64-only and cannot boot on Apple Silicon virtualization. This project provides a native ARM64 build running on Apple's `Virtualization.framework` using:
- **Arch Linux ARM (`aarch64`)**: Core base system, kernel (`Image`), and initramfs.
- **[omarchy-mac](https://github.com/omarchy-mac/omarchy-mac)** (Quattro branch): The community aarch64 port of Omarchy 4.0.2 with native ARM64 package builds.
- **Mesa `llvmpipe` Software Rendering**: Configured with `LIBGL_ALWAYS_SOFTWARE=1` and `WLR_RENDERER_ALLOW_SOFTWARE=1` to run Hyprland Wayland smoothly on Apple Virtualization.framework without requiring proprietary GPU drivers.
- **VirtioFS Package Caching**: Caches downloaded packages in `.build/pkg-cache` for instant rebuilds.

---

## Building From Source (Developers)

### Prerequisites
```bash
brew install cirruslabs/cli/tart hashicorp/tap/packer
```

### Build Command
```bash
# Build default version (Omarchy 4.0.2)
./build-tart.sh

# Or specify a custom version
OMARCHY_VERSION=4.0.2 ./build-tart.sh
```

### How the Build Pipeline Works

```
host (macOS Apple Silicon)                         Ubuntu Builder VM (/dev/vda)
──────────────────────────                         ────────────────────────────
1. Allocate 40 GB target disk (.build/rootdisk.img)
2. Download Arch Linux ARM rootfs (alarm-rootfs.tgz)
3. Clone Ubuntu base & upload assets via Packer ──> Boots headlessly with /dev/vdb attached
                                                    1. Partition /dev/vdb:
                                                       - /dev/vdb1: 512 MB ESP (FAT32, /boot/efi)
                                                       - /dev/vdb2: 40 GB Root (ext4, /)
                                                    2. Extract ALARM rootfs into ext4 root
                                                    3. Mount ESP to /target/boot/efi
                                                    4. Mount host pacman cache (VirtioFS)
                                                    5. Chroot: bootstrap keyring, base packages,
                                                       user setup, 0440 sudoers, systemd-networkd
                                                    6. Install GRUB EFI (\EFI\BOOT\BOOTAA64.EFI)
                                                    7. Set software rendering flags (llvmpipe)
                                                    8. Build & install Omarchy 4.0.2 via omarchy-mac
                                                    9. Write BUILD-STATUS to ESP and shutdown
4. Host mounts ESP, verifies BUILD-STATUS == OK <── VM powers down
5. Swap .build/rootdisk.img into ~/.tart/vms/omarchy/disk.img
6. Configure display: 1512x982pt, --display-refit, 6 CPUs, 12 GB RAM
```

---

## Verification with Cua Driver

The desktop environment and display state are verified using [Cua Driver](https://cua.ai):
```bash
# Discover running Tart window
cua-driver call --tool list_windows --args '{}'

# Inspect accessibility tree & layout
cua-driver call --tool get_window_state --args '{"pid": <PID>, "window_id": <WINDOW_ID>, "include_screenshot": false}'
```

---

## Publishing to GHCR (Maintainers)

```bash
gh auth refresh -s write:packages
gh auth token | tart login ghcr.io --username <username> --password-stdin
tart push omarchy ghcr.io/<username>/tart-omarchy:4.0.2 ghcr.io/<username>/tart-omarchy:latest
```