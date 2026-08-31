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

```mermaid
flowchart TD
    subgraph Host["1. Host Preparation (macOS Apple Silicon)"]
        A[Download Arch Linux ARM Rootfs\nalarm-rootfs.tgz] --> B[Create 40 GB Sparse Disk\n.build/rootdisk.img]
        B --> C[Prepare VirtioFS Package Cache\n.build/pkg-cache]
    end

    subgraph Phase1["2. Phase 1 — Packer & Asset Staging"]
        C --> D[Packer Clones Base VM\nghcr.io/cirruslabs/ubuntu:latest]
        D --> E[Upload Rootfs & provision.sh\nover SSH into Builder VM]
    end

    subgraph Phase2["3. Phase 2 — In-Guest Provisioning (/dev/vdb)"]
        E --> F[Boot Builder VM Headless\nAttach /dev/vdb & VirtioFS Cache]
        F --> G[Partition /dev/vdb\nESP: 512MB FAT32 (/boot/efi)\nRoot: 40GB ext4 (/)]
        G --> H[Extract ALARM Rootfs & Bind Chroot\n/dev, /proc, /sys, /run, /dev/pts]
        H --> I[Bootstrap Base System & Keyring\nInstall GRUB EFI (\\EFI\\BOOT\\BOOTAA64.EFI)]
        I --> J[Configure Software Rendering (llvmpipe)\nLIBGL_ALWAYS_SOFTWARE=1]
        J --> K[Build & Install Omarchy 4.0.2\nvia omarchy-mac (quattro)]
        K --> L[Write BUILD-STATUS to ESP\nShutdown Builder VM]
    end

    subgraph PostBuild["4. Verification & Disk Swap"]
        L --> M[Host Verifies BUILD-STATUS == OK\nvia hdiutil / diskutil]
        M --> N[Swap Target Disk Image\n~/.tart/vms/omarchy/disk.img]
        N --> O[Configure Display & Hardware\n1512x982pt, --display-refit, 6 CPU, 12GB RAM]
    end

    O --> P([Ready-to-Run Tart VM])
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