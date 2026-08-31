# tart-omarchy

Build a **Tart VM image of Omarchy 4 (Quattro)** for Apple Silicon.

## Why this exists

Omarchy installs from an **x86_64 ISO** and its package repository has no
aarch64 tree. Tart uses Apple's Virtualization.framework, which only runs
**arm64** guests — so the official ISO cannot boot in Tart at all.

The route that works is a native ARM64 build:

- **Arch Linux ARM** rootfs as the base system
- **[omarchy-mac](https://github.com/omarchy-mac/omarchy-mac)** (Quattro
  branch): the community-maintained aarch64 port of Omarchy 4, with its own
  prebuilt aarch64 package repository — its `install.sh` is the installer,
  designed to run in a chroot

The whole build runs **unattended inside the VM** — no console interaction,
no manual steps.

## How the build works

```
host                                              VM guest
────                                              ────────
tart create --linux omarchy                       firmware boots the attached
                                                  El Torito ISO (documented
xorriso ISO with an embedded FAT                   tart path)
  └ systemd-boot + ALARM kernel                   systemd-boot -> kernel ->
    + initramfs with an injected                  injected /init (PID 1):
      builder /init                                 1. DHCP, mount the FAT boot
  └ alarm-rootfs.tgz, stage1.sh,                      image (El Torito catalog
    stage2.sh                                         parsed at runtime)
                                                    2. unpack ALARM rootfs into
                                                       tmpfs, chroot
                                                    3. stage1: pacman keyring +
                                                       full upgrade, partition
                                                       /dev/vda (512MB ESP +
                                                       ext4 root), deploy the
                                                       rootfs to disk, chroot
                                                       into the disk copy
                                                    4. bootctl (systemd-boot)
                                                       + efibootmgr (registers
                                                       the ESP in the VM's
                                                       NVRAM so later boots
                                                       need no ISO)
                                                    5. stage2: omarchy-mac
                                                       install.sh as user
                                                       omarchy
                                                    6. BUILD-STATUS on the
                                                       ESP, poweroff
host reads BUILD-STATUS back from the ESP
```

All the boot pieces (kernel `Image`, initramfs, `systemd-bootaa64.efi`) are
taken from the ALARM rootfs itself, so nothing foreign enters the image.

## Usage

```sh
brew install cirruslabs/cli/tart xorriso
./build-tart.sh              # full build from source (~30-45 min, ~2.5 GB dl)
```

Then:

```sh
tart run omarchy             # first boot: SDDM autologin -> Omarchy desktop
```

`omarchy` / `omarchy` (change it: `passwd`). SSH is firewalled off by
default, re-enable with `omarchy-setup-security-sshd` inside the guest.

Alternative convenience path (skips the build, imports the published ARM64
image from archive.org):

```sh
brew install qemu            # for qemu-img
./build-tart.sh --download   # ~3.6 GB
```

## Files

| File | Role |
|------|------|
| `build-tart.sh` | orchestrator: fetch, payload, ISO, VM run, status |
| `builder/init` | injected initramfs `/init` — the unattended driver |
| `builder/stage1.sh` | partition + deploy + bootloader + NVRAM + user |
| `builder/stage2.sh` | omarchy-mac install (as user `omarchy`) |
| `builder/inject-initramfs.py` | initramfs surgery (init + kernel modules) |

## Status

Layers verified: rootfs checksums, initramfs injection (init + injected
`virtio_net.ko`/`loop.ko` load), El Torito ISO boots under Tart (control
test with the alpine-virt ISO), ESP/GPT layout mounts from the host, the
VM survives a full boot cycle with the builder ISO attached.

Still in flight at last session: confirming the builder chain end-to-end
(the guest's serial console stays silent — the kernel console is set to
`hvc0`, and a full run had not yet been observed to completion). Debugging
continues from `build-tart.sh`; the full console transcript is written to
`.build/console.log` and the build result to the ESP's `BUILD-STATUS`.

## Notes

- x86_64-only Omarchy packages (obs-studio, pinta, obsidian …) are skipped
  by the aarch64 installer by design.
- The final image is a plain ext4 root + systemd-boot; no LUKS (it is a
  VM disk, not a laptop), no snapper baselines.
- `tart set omarchy --memory 16384 --cpu 8` to give it more room.