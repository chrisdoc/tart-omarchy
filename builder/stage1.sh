#!/bin/bash
# stage1: bootstrap Arch Linux ARM onto /dev/vda, then install Omarchy 4
# (quattro) from the omarchy-mac project. Runs inside the deployed root.
#
# Phase "bootstrap" runs in the tmpfs root (extracted by the initramfs /init):
#   keyring, system upgrade, partition /dev/vda, deploy rootfs to disk.
# Phase "deploy" runs chrooted into the disk copy: bootloader, initramfs,
#   system config, user, then stage2.sh (the Omarchy install) as that user.
#
# Console output is captured by the host via the VM serial console; the
# result is also written to /bootdev/BUILD-STATUS (the FAT boot disk).

set -euo pipefail

log() { printf '==> %s\n' "$*"; }

trap 'rc=$?; if [ "$rc" -eq 0 ]; then echo "OK" > /bootstatus/BUILD-STATUS 2>/dev/null || true; else echo "FAIL rc=$rc" > /bootstatus/BUILD-STATUS 2>/dev/null || true; fi' EXIT

bootstrap() {
  log "pacman keyring"
  pacman-key --init
  pacman-key --populate archlinuxarm

  log "full system upgrade + base tools (this downloads a lot)"
  pacman -Syu --noconfirm --needed dosfstools sudo openssh git base-devel efibootmgr

  log "repartitioning /dev/vda (GPT: 512M ESP + ext4 root)"
  sfdisk -f /dev/vda <<'EOF'
label: gpt
, 512M, U
, , L
EOF
  udevadm settle || true
  mkfs.vfat -F 32 -n ESP /dev/vda1
  mkfs.ext4 -F -L OMARCHY /dev/vda2

  log "deploying rootfs onto /dev/vda2"
  mkdir -p /target
  mount /dev/vda2 /target
  mkdir -p /target/boot
  mount /dev/vda1 /target/boot
  tar -C / --one-file-system -cf - . | tar -C /target -xf -
  sync

  log "chrooting into the deployed system"
  mount --bind /dev /target/dev
  mount --bind /proc /target/proc
  mount --bind /sys /target/sys
  cp /etc/resolv.conf /target/etc/resolv.conf
  cp /stage1.sh /target/stage1.sh
  cp /stage2.sh /target/stage2.sh
  exec chroot /target /bin/bash /stage1.sh deploy
}

deploy() {
  local root_partuuid esp_partuuid
  root_partuuid=$(blkid -s PARTUUID -o value /dev/vda2)
  esp_partuuid=$(blkid -s PARTUUID -o value /dev/vda1)

  log "machine-id"
  systemd-machine-id-setup

  log "systemd-boot on the ESP"
  bootctl --no-variables --esp-path=/boot install
  cat > /boot/loader/loader.conf <<'EOF'
default omarchy.conf
timeout 1
console-mode keep
EOF
  cat > /boot/loader/entries/omarchy.conf <<EOF
title Omarchy (Tart)
linux /Image
initrd /initramfs-linux.img
options root=PARTUUID=$root_partuuid rw console=hvc0
EOF

  log "registering the ESP in the firmware (NVRAM) so it boots on its own"
  mkdir -p /sys/firmware/efi/efivars
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
  if mountpoint -q /sys/firmware/efi/efivars; then
    efibootmgr -c -d /dev/vda -p 1 -L Omarchy -l '\EFI\BOOT\BOOTAA64.EFI' \
      || echo "!! efibootmgr failed"
    efibootmgr -o 0 || true
  else
    log "efivarfs unavailable; relying on the firmware's ESP scan"
  fi

  log "regenerating the initramfs for this hardware (virtio)"
  mkinitcpio -P

  log "locale / hostname / timezone"
  sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen >/dev/null
  echo 'LANG=en_US.UTF-8' > /etc/locale.conf
  echo 'omarchy' > /etc/hostname
  printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts
  ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

  log "FAT ESP fstab entry"
  printf 'PARTUUID=%s  /boot  vfat  rw,relatime,fmask=0022,dmask=0022  0 2\n' "$esp_partuuid" > /etc/fstab

  log "wired networking (DHCP via systemd-networkd)"
  cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=e*

[Network]
DHCP=yes
EOF
  systemctl enable systemd-networkd systemd-resolved
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  log "SSH server"
  systemctl enable sshd
  ssh-keygen -A

  log "user omarchy (password omarchy, passwordless sudo)"
  useradd -m -G wheel -s /bin/bash omarchy
  echo 'omarchy:omarchy' | chpasswd
  echo 'omarchy ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/omarchy
  passwd -l root

  log "Omarchy 4 install (omarchy-mac, as user omarchy; takes a while)"
  chroot --userspec=omarchy / \
    env HOME=/home/omarchy USER=omarchy TERM=linux LANG=en_US.UTF-8 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /stage2.sh

  # remount the fresh ESP here so the EXIT trap can write BUILD-STATUS
  mkdir -p /bootstatus
  mount /dev/vda1 /bootstatus || true

  sync
}

case "${1:-bootstrap}" in
  bootstrap) bootstrap ;;
  deploy) deploy ;;
  *) echo "unknown phase: $1" >&2; exit 1 ;;
esac