#!/bin/bash
# Build a Tart VM image of Omarchy 4 (Quattro) for Apple Silicon.
#
# Omarchy's official ISO is x86_64 and cannot boot under Tart, which only
# runs arm64 guests. This builds a native ARM64 image from upstream pieces:
#
#   Arch Linux ARM rootfs  ->  deployed to the VM disk by a bootstrap initramfs
#   omarchy-mac (quattro)  ->  their aarch64 Omarchy 4 installer (prebuilt
#                              aarch64 package repo, no x86 packages needed)
#
# The entire build runs unattended inside the VM (driven by an injected
# initramfs hook — no console interaction), then the VM powers itself off.
#
# Usage:
#   ./build-tart.sh              # full build from source (~30-45 min)
#   ./build-tart.sh --download   # instead: import the published ARM64
#                                # Omarchy image from archive.org (~3.6 GB)
set -euo pipefail

VM_NAME="${VM_NAME:-omarchy}"
WORK="$(pwd)/.build"
DL="$WORK/dl"
PAYLOAD="$WORK/payload"


say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for c in tart hdiutil python3 bsdtar; do
  command -v "$c" >/dev/null || die "$c is required (xcode-select --install / brew install tart)"
done
[[ $(uname -m) == arm64 ]] || die "this only runs on Apple Silicon"

if tart list 2>/dev/null | awk 'NR>1 && $1=="local" && $2=="'"$VM_NAME"'"' | grep -q .; then
  die "a local VM named '$VM_NAME' already exists (tart delete $VM_NAME to replace it)"
fi

mkdir -p "$WORK" "$DL" "$PAYLOAD" "$PAYLOAD/EFI/BOOT" "$PAYLOAD/loader/entries"

# ---------------------------------------------------------------- download --
fetch_rootfs() {
  local tgz="$DL/alarm-rootfs.tgz" md5f="$DL/alarm-rootfs.tgz.md5" want have
  if [[ -s $tgz && -s $md5f ]]; then
    want=$(awk '{print $1}' "$md5f")
    have=$(md5 -q "$tgz")
    [[ $want == "$have" ]] && return 0
  fi
  say "downloading Arch Linux ARM aarch64 rootfs (~830 MB)"
  curl -fsSL -o "$md5f" http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5
  curl -fL -o "$tgz" http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
  want=$(awk '{print $1}' "$md5f")
  have=$(md5 -q "$tgz")
  [[ $want == "$have" ]] || die "rootfs checksum mismatch"
}

# ------------------------------------------------------------------ payload --
make_payload() {
  local rootfs="$DL/alarm-rootfs.tgz" x="$WORK/x" kver

  say "extracting kernel, initramfs, bootloader and network module"
  rm -rf "$x"; mkdir -p "$x"
  bsdtar -xf "$rootfs" -C "$x" \
    ./boot/Image ./boot/initramfs-linux.img \
    ./usr/lib/systemd/boot/efi/systemd-bootaa64.efi
  kver=$(bsdtar -tf "$rootfs" | grep -oE 'usr/lib/modules/[^/]+/kernel/drivers/net/virtio_net\.ko' | head -1 | cut -d/ -f4)
  [[ -n $kver ]] || die "virtio_net.ko not found in rootfs"
  bsdtar -xf "$rootfs" -C "$x" "./usr/lib/modules/$kver/kernel/drivers/net/virtio_net.ko"
  bsdtar -xf "$rootfs" -C "$x" "./usr/lib/modules/$kver/kernel/drivers/block/loop.ko"

  say "injecting the builder /init into the initramfs"
  python3 builder/inject-initramfs.py \
    "$x/boot/initramfs-linux.img" "$PAYLOAD/initramfs-linux.img" \
    builder/init "$x/usr/lib/modules/$kver"

  cp "$x/boot/Image" "$PAYLOAD/Image"
  cp "$x/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "$PAYLOAD/EFI/BOOT/BOOTAA64.EFI"
  cp "$rootfs" "$PAYLOAD/alarm-rootfs.tgz"
  cp builder/stage1.sh builder/stage2.sh "$PAYLOAD/"

  cat > "$PAYLOAD/loader/loader.conf" <<'EOF'
default omarchy.conf
timeout 1
console-mode keep
EOF
  cat > "$PAYLOAD/loader/entries/omarchy.conf" <<'EOF'
title Omarchy builder
linux /Image
initrd /initramfs-linux.img
options console=hvc0
EOF
}

# ---------------------------------------------------------- builder iso --
make_builder_iso() {
  local fat="$WORK/boot.fat" isodir="$WORK/iso-src" off
  say "building the El Torito builder ISO"
  rm -f "$WORK/boot.fat.cdr" "$fat" "$WORK/builder.iso"
  rm -rf "$isodir"; mkdir -p "$isodir"
  hdiutil create -fs MS-DOS -volname ESP -srcfolder "$PAYLOAD" \
    -format UDTO -size 2g -o "$WORK/boot.fat.cdr" >/dev/null
  mv "$WORK/boot.fat.cdr" "$fat"
  cp -R "$PAYLOAD/." "$isodir/"
  cp "$fat" "$isodir/esp.fat"
  xorriso -as mkisofs -quiet -o "$WORK/builder.iso" -V TART-OMARCHY \
    -e esp.fat -no-emul-boot -boot-load-size 4 "$isodir"
  off=$(xorriso -indev "$WORK/builder.iso" -report_el_torito plain 2>/dev/null \
    | awk '/El Torito boot img/ {print $NF; exit}')
  [[ -n $off ]] || die "could not read the boot image offset"
  say "builder ISO ready (EFI boot image at LBA $off)"
}

# ------------------------------------------------------------ boot+install --
run_builder() {
  say "booting the builder (unattended, ~30-45 min)"
  tart run --no-graphics --serial --disk "$WORK/builder.iso" "$VM_NAME" \
    > "$WORK/console.log" 2>&1 || die "tart run failed; see $WORK/console.log"
  say "VM powered off; reading build status from the ESP"
  local dev
  dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$HOME/.tart/vms/$VM_NAME/disk.img" | awk '{print $1}')
  diskutil mount "${dev}s1" >/dev/null
  local status
  status=$(cat /Volumes/ESP/BUILD-STATUS 2>/dev/null || echo "status file missing")
  diskutil unmount "${dev}s1" >/dev/null
  hdiutil detach "$dev" >/dev/null
  echo "build status: $status"
  if [[ $status != OK ]]; then
    echo "--- last 60 lines of the build console ---"
    tail -60 "$WORK/console.log" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'
    die "build failed — full log: $WORK/console.log"
  fi
}

# ------------------------------------------------------------------- main --
if [[ ${1:-} == --download ]]; then
  say "downloading the published ARM64 Omarchy image from archive.org (~3.6 GB)"
  cd "$WORK"
  [[ -s omarchy-arm-utm-v2.zip ]] || curl -fL -o omarchy-arm-utm-v2.zip \
    https://archive.org/download/omarchy-arm-utm/omarchy-arm-utm-v2.zip
  [[ -s omarchy-arm-utm-v2.zip.sha256 ]] || curl -fL -o omarchy-arm-utm-v2.zip.sha256 \
    https://archive.org/download/omarchy-arm-utm/omarchy-arm-utm-v2.zip.sha256
  shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256 || die "checksum mismatch"
  unzip -oq omarchy-arm-utm-v2.zip -d extracted
  qcow=$(find extracted -name '*.qcow2' -print -quit)
  [[ -n $qcow ]] || die "no qcow2 found in the archive"
  command -v qemu-img >/dev/null || { say "installing qemu (for qemu-img)..."; brew install qemu; }
else
  [[ ${1:-} == "" || ${1:-} == --source ]] || die "unknown option: $1"
  fetch_rootfs
  make_payload
  make_builder_iso
  say "creating the VM"
  tart create --linux "$VM_NAME" --disk-size 40
  tart set "$VM_NAME" --memory 12288 --cpu 6
  run_builder
fi

cat <<EOF

Done. The '$VM_NAME' Tart VM is ready:

  tart run $VM_NAME            # first boot: SDDM autologin -> Omarchy desktop
  ssh omarchy@\$(tart ip $VM_NAME)   # after you run omarchy-setup-security-sshd
                                   #   (omnarchy turns SSH off by default)

  login: omarchy / omarchy   -- change it: passwd
  optional: tart set $VM_NAME --memory 16384 --cpu 8
EOF