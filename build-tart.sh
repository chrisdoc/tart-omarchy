#!/bin/bash
# Build a Tart VM image of Omarchy 4 (Quattro) for Apple Silicon.
#
# Why not the official ISO: it is x86_64, and Tart/Apple Virtualization.framework
# only runs arm64 guests. So we use an ARM64 Arch Linux + Omarchy image built by
# the omarchy-arm-utm project, and convert its qcow2 disk into a Tart raw disk.
#
# Usage:
#   ./build-tart.sh                # download the published image (recommended)
#   ./build-tart.sh --from-build   # build the image from source first (~80 min,
#                                  # needs brew qemu/expect/aria2, ~40 GB free)
set -euo pipefail

VM_NAME=omarchy
WORK="$(pwd)/.build"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- prereqs --------------------------------------------------------------
command -v tart >/dev/null || die "tart is not installed (brew install cirruslabs/cli/tart)"
command -v qemu-img >/dev/null || { say "qemu-img missing, installing qemu..."; brew install qemu; }
tart list | awk 'NR>1 && $1=="local" && $2=="'"$VM_NAME"'" {found=1} END {exit found?0:1}' \
  && die "a local VM named '$VM_NAME' already exists (tart delete $VM_NAME to replace it)"
mkdir -p "$WORK"

# --- obtain a qcow2 disk --------------------------------------------------
FROM_BUILD=0
[[ "${1:-}" == "--from-build" ]] && FROM_BUILD=1

QCOW=""
if (( FROM_BUILD )); then
  say "building the ARM64 Omarchy image from source (this takes ~80 minutes)"
  BUILD_DIR="$WORK/omarchy-arm-utm-src"
  [[ -d "$BUILD_DIR" ]] || git clone --depth 1 https://github.com/ggalancs/omarchy-arm-utm.git "$BUILD_DIR"
  cd "$BUILD_DIR"
  for f in qemu expect aria2; do brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"; done
  ./build-omarchy-arm.sh --yes --only fetch
  ./build-omarchy-arm.sh --yes --only prepare
  ./build-omarchy-arm.sh --yes --only build
  QCOW="$HOME/omarchy-arm-build/vm/omarchy-arm.qcow2"
else
  say "downloading the published Omarchy ARM64 image from archive.org (~3.6 GB)"
  cd "$WORK"
  [[ -s omarchy-arm-utm-v2.zip ]] || curl -fL -o omarchy-arm-utm-v2.zip \
    https://archive.org/download/omarchy-arm-utm/omarchy-arm-utm-v2.zip
  [[ -s omarchy-arm-utm-v2.zip.sha256 ]] || curl -fL -o omarchy-arm-utm-v2.zip.sha256 \
    https://archive.org/download/omarchy-arm-utm/omarchy-arm-utm-v2.zip.sha256
  (cd "$WORK" && shasum -a 256 -c omarchy-arm-utm-v2.zip.sha256) || die "checksum mismatch"
  unzip -oq omarchy-arm-utm-v2.zip -d extracted
  QCOW="$(find extracted -name '*.qcow2' -print -quit)"
  [[ -n "$QCOW" ]] || die "no qcow2 found in the archive"
fi

# --- install as a Tart VM -------------------------------------------------
SIZE_GB=$(qemu-img info --output json "$QCOW" | awk -F: '/"virtual-size"/ {printf "%d", $2/1073741824 + 1}')
say "creating Tart VM '$VM_NAME' with a $SIZE_GB GB disk"
tart create --linux "$VM_NAME" --disk-size "$SIZE_GB"
say "converting qcow2 -> raw into the VM disk"
rm ~/.tart/vms/"$VM_NAME"/disk.img
qemu-img convert -f qcow2 -O raw "$QCOW" ~/.tart/vms/"$VM_NAME"/disk.img

say "done. First boot:"
cat <<'EOF'
  tart run omarchy            # opens the VM window; login: omarchy / omarchy
  # inside the guest, enable SSH and set a password you actually use:
  #   sudo systemctl enable --now sshd
  #   passwd
  # then from the host:
  #   ssh omarchy@$(tart ip omarchy)

  optional: tart set omarchy --cpu 8 --memory 8192
EOF