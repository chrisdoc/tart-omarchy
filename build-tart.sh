#!/bin/bash
# Build a Tart VM image of Omarchy 4 (Quattro) for Apple Silicon.
#
# Omarchy's official ISO is x86_64 and cannot boot under Tart, which only
# runs arm64 guests. This builds a native ARM64 image the same way
# CirrusLabs build their Linux images — with Packer and the tart plugin:
#
#   1. clone the already-bootable ghcr.io/cirruslabs/ubuntu arm64 base
#   2. attach a fresh raw disk (rootdisk.img) as /dev/vdb
#   3. provision over SSH (builder/provision.sh): partition vdb (ESP +
#      ext4), deploy Arch Linux ARM, install omarchy-mac (Quattro) in a
#      chroot, GRUB on the ESP, boot entry registered in the VM NVRAM
#   4. swap the built disk into the VM's main slot
#
# Usage:
#   ./build-tart.sh              # full build from source (~30-60 min, 4 GB dl)
#   ./build-tart.sh --download   # instead: import the published ARM64
#                                # Omarchy image from archive.org (~3.6 GB)

set -euo pipefail

VM_NAME="${VM_NAME:-omarchy}"
WORK="$(pwd)/.build"
DL="$WORK/dl"
ROOT_DISK="$WORK/rootdisk.img"
PKG_CACHE="$WORK/pkg-cache"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for c in tart packer; do
  command -v "$c" >/dev/null || die "$c is required (brew install tart packer)"
done
if tart list 2>/dev/null | awk 'NR>1 && $1=="local" && $2=="'"$VM_NAME"'"' | grep -q .; then
  die "a local VM named '$VM_NAME' already exists (tart delete $VM_NAME to replace it)"
fi

mkdir -p "$WORK" "$DL" "$WORK/packer" "$PKG_CACHE"

# ---------------------------------------------------------------- download --
fetch_alarm() {
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

# -------------------------------------------------------------- disk + run --
make_root_disk() {
  say "creating a sparse 40 GB target disk ($ROOT_DISK)"
  rm -f "$ROOT_DISK"
  mkfile -n 40g "$ROOT_DISK"
}

run_packer() {
  say "preparing the packer build dir"
  cp builder/omarchy.pkr.hcl builder/provision.sh "$WORK/packer/"
  (cd "$WORK/packer" && packer init . >/dev/null)
  say "packer: cloning the ubuntu arm64 base + uploading build inputs"
  (cd "$WORK/packer" && packer build \
    -var "vm_name=$VM_NAME" \
    -var "root_disk=$ROOT_DISK" \
    -var "rootfs=$DL/alarm-rootfs.tgz" \
    omarchy.pkr.hcl)
}

# The long install runs detached from any SSH session; progress is read
# back with `tart exec` (guest agent), as is the result.
run_provision() {
  say "booting the builder and starting the provision (detached)"
  nohup tart run --no-graphics --serial --disk "$ROOT_DISK" --dir "$PKG_CACHE:tag=pkg-cache" "$VM_NAME" \
    > "$WORK/console.log" 2>&1 &
  local tart_pid=$!
  local t=0
  until tart exec "$VM_NAME" true 2>/dev/null; do
    sleep 5; t=$((t + 5))
    (( t > 300 )) && die "builder VM did not come up (see $WORK/console.log)"
  done
  say "guest agent is up; launching the provision script"
  tart exec "$VM_NAME" sh -c 'sudo bash -c "setsid nohup bash /home/admin/provision.sh >/home/admin/provision.log 2>&1 &"' \
    || die "could not launch the provision script"
  say "provision running detached; polling progress (Ctrl-C to stop watching)"
  sleep 20
  local running_t=0
  while kill -0 "$tart_pid" 2>/dev/null; do
    tart exec "$VM_NAME" tail -n 2 /home/admin/provision.log 2>/dev/null | sed 's/^/    /' || true
    sleep 30
    running_t=$((running_t + 30))
    if (( running_t > 5400 )); then
      tart stop "$VM_NAME" 2>/dev/null || true
      die "provisioning timed out after 90 minutes"
    fi
  done
  wait "$tart_pid" 2>/dev/null || true
  say "builder VM powered off; verifying build status"
  local dev status="UNKNOWN"
  if command -v hdiutil >/dev/null && command -v diskutil >/dev/null; then
    dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$ROOT_DISK" 2>/dev/null | awk 'NR==1 {print $1}')
    if [[ -n $dev ]]; then
      diskutil mount "${dev}s1" >/dev/null 2>&1 || true
      status=$(cat /Volumes/ESP/BUILD-STATUS 2>/dev/null || echo "MISSING")
      diskutil unmount "${dev}s1" >/dev/null 2>&1 || true
      hdiutil detach "$dev" >/dev/null 2>&1 || true
    fi
  fi
  say "provision result: $status"
  if [[ $status != "OK" ]]; then
    die "provision failed (status: $status) — check $WORK/console.log"
  fi
}

swap_disk() {
  say "swapping the built disk into the VM"
  rm -f "$HOME/.tart/vms/$VM_NAME/disk.img"
  cp "$ROOT_DISK" "$HOME/.tart/vms/$VM_NAME/disk.img"
  tart set "$VM_NAME" --memory 12288 --cpu 6 --display 1512x982pt --display-refit
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
  fetch_alarm
  make_root_disk
  run_packer
  run_provision
  swap_disk
fi

cat <<EOF

Done. The '$VM_NAME' Tart VM is ready:

  tart run $VM_NAME            # first boot: SDDM autologin -> Omarchy desktop
  ssh omarchy@\$(tart ip $VM_NAME)   # after you run omarchy-setup-security-sshd
                                   #   (Omarchy turns SSH off by default)

  login: omarchy / omarchy   -- change it: passwd
  optional: tart set $VM_NAME --memory 16384 --cpu 8
EOF