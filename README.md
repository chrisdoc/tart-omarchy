# tart-omarchy

Run [Omarchy 4 (Quattro)](https://omarchy.org) in a [Tart](https://tart.run) VM on Apple Silicon.

## Why this exists

Omarchy installs from an **x86_64 ISO** and its package mirror has no aarch64
tree. Tart uses Apple's Virtualization.framework, which only runs **arm64**
guests — so the official ISO cannot boot in Tart at all.

The working route is an ARM64 build: Arch Linux ARM + the actual Omarchy 4
source (the Omarchy tree is architecture-agnostic shell/Lua/QML; only its
package repo is x86-only). The [omarchy-arm-utm](https://github.com/ggalancs/omarchy-arm-utm)
project does this build and also publishes the finished image.

## Quick start (recommended)

```sh
brew install cirruslabs/cli/tart qemu
./build-tart.sh          # downloads the published image, converts it, installs it
tart run omarchy         # login: omarchy / omarchy
```

`build-tart.sh` verifies the download's sha256, converts the qcow2 disk to the
raw format Tart expects, and replaces the VM's disk. Inside the guest, enable
SSH and change the password:

```sh
sudo systemctl enable --now sshd
passwd
```

Then `ssh omarchy@$(tart ip omarchy)` from the Mac.

## Building a custom image from source

```sh
./build-tart.sh --from-build
```

This clones the upstream build, runs its fetch/prepare/build phases
(~80 minutes, ~40 GB free, installs `qemu expect aria2` via Homebrew) and
installs the result into Tart. To make it *your* Omarchy, fork
`ggalancs/omarchy-arm-utm` and edit:

- `provision/src/packages-extra.txt` — extra packages
- `provision/src/stage1.sh` … `stage3.sh` — install steps (dotfiles, configs)
- `fixes/` — the patch series applied on top

## Notes

- The published image is sanitised (no personal identity) — change the
  passwords before real use.
- Clipboard sharing works through Tart's spice-vdagent support.
- `tart run --rosetta` is not needed: the image is fully native arm64.
- Tart boots Linux guests via UEFI, so any arm64 disk with a UEFI bootloader
  (this image uses systemd-boot) works as a Tart disk.