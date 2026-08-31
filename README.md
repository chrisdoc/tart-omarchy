# tart-omarchy

Build and run native **ARM64 Tart VM images of Omarchy 4 (Quattro)** for Apple Silicon.

---

## Quick Start (Pre-built OCI Image)

You can pull and run the pre-built, ready-to-use OCI image directly from GitHub Container Registry:

```bash
# Clone the published image from GHCR
tart clone ghcr.io/chrisdoc/tart-omarchy:latest omarchy

# Run the desktop VM
tart run omarchy
```

**Login Credentials**: `omarchy` / `omarchy`

---

## Why This Exists

Omarchy officially publishes an **x86_64 ISO** without an official aarch64 image. Tart uses Apple's `Virtualization.framework`, which requires native **arm64** guests on Apple Silicon.

This repository builds a clean native ARM64 image from upstream components:
- **Arch Linux ARM (`aarch64`)**: Base Linux distribution, kernel (`Image`), and initramfs.
- **[omarchy-mac](https://github.com/omarchy-mac/omarchy-mac)** (Quattro branch): The community aarch64 port of Omarchy 4.0.2 with native ARM64 package builds.
- **Mesa `llvmpipe` Software Rendering**: Configured with `LIBGL_ALWAYS_SOFTWARE=1` and `WLR_RENDERER_ALLOW_SOFTWARE=1` to run Hyprland Wayland smoothly on Apple Virtualization.framework without requiring proprietary GPU pass-through drivers.
- **VirtioFS Package Caching**: Caches downloaded pacman packages in `.build/pkg-cache` on macOS across builds.

---

## Building From Source

### Prerequisites
- Apple Silicon Mac (M1/M2/M3/M4) running macOS 13+
- [Tart](https://tart.run/) and [Packer](https://www.packer.io/):
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

### Run the VM
```bash
tart run omarchy
```

---

## How the Build Works

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

This VM build is verified using [Cua Driver](https://cua.ai):
```bash
# Discover Tart window
cua-driver call --tool list_windows --args '{}'

# Inspect accessibility tree & display state
cua-driver call --tool get_window_state --args '{"pid": <PID>, "window_id": <WINDOW_ID>, "include_screenshot": false}'
```

---

## Publishing to GHCR

```bash
gh auth refresh -s write:packages
gh auth token | tart login ghcr.io --username <username> --password-stdin
tart push omarchy ghcr.io/<username>/tart-omarchy:4.0.2 ghcr.io/<username>/tart-omarchy:latest
```