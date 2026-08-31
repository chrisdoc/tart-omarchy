#!/bin/bash
# Runs INSIDE the Ubuntu builder VM (as root via sudo), orchestrated by
# Packer over SSH. Turns the attached /dev/vdb into a bootable Omarchy 4
# (Quattro) system:
#
#   /dev/vda = Ubuntu builder (discarded after the build)
#   /dev/vdb = fresh GPT: 512 MB ESP + ext4 root, deployed with
#              Arch Linux ARM + omarchy-mac, GRUB on the ESP, and a boot
#              entry registered in the firmware (persists in the VM NVRAM,
#              keyed by partition GUID so it survives the disk swap).
set -euo pipefail

# survive SSH session teardowns (mid-build disconnects must not kill us)
trap '' HUP

cleanup() {
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "OK" > /home/admin/provision-status
    echo "OK" > /target/boot/efi/BUILD-STATUS 2>/dev/null || true
    log "provision complete — shutting down"
  else
    echo "FAIL rc=$rc" > /home/admin/provision-status
    echo "FAIL rc=$rc" > /target/boot/efi/BUILD-STATUS 2>/dev/null || true
    log "provision failed with exit code $rc"
  fi
  sync
  umount -R /target 2>/dev/null || true
  shutdown -h now || poweroff -f || true
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*"; }
log "fixing builder hostname resolution for sudo"
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $(hostname)" >> /etc/hosts

log "network probes"
ip -4 addr show | grep -E 'inet |^[0-9]+:' | head -5
cat /etc/resolv.conf
getent hosts archive.ubuntu.com && echo "builder DNS: OK" || echo "builder DNS: FAIL"
curl -sI -m 8 https://archive.ubuntu.com/ubuntu/ | head -1 || echo "builder HTTPS: FAIL"

DEST=/dev/vdb
ESP="${DEST}1"
ROOT="${DEST}2"

log "partitioning $DEST (ESP + ext4 root)"
cat /proc/partitions
if ! sfdisk -f "$DEST" <<'EOF'
label: gpt
, 512M, U
, , L
EOF
then
  echo "!! sfdisk failed on $DEST"; lsblk 2>/dev/null || true; exit 1
fi
udevadm settle || true
mkfs.vfat -F 32 -n ESP "$ESP"
mkfs.ext4 -F -L OMARCHY "$ROOT"

log "mounting and extracting Arch Linux ARM rootfs"
mkdir -p /target
mount "$ROOT" /target
tar -xzpf /home/admin/alarm-rootfs.tgz -C /target --numeric-owner

log "mounting ESP partition to /target/boot/efi"
mkdir -p /target/boot/efi
mount "$ESP" /target/boot/efi


log "chroot bind mounts + DNS"
mkdir -p /target/dev /target/dev/pts /target/proc /target/sys /target/run
mount --bind /dev /target/dev
mount --bind /dev/pts /target/dev/pts
mount --bind /proc /target/proc
mount --bind /sys /target/sys
mount --bind /run /target/run
# real upstream nameservers, independent of the builder's DNS stack
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /target/etc/resolv.conf
log "chroot DNS probe"
chroot /target /bin/bash -c 'cat /etc/resolv.conf; getent hosts mirror.archlinuxarm.org && echo "chroot DNS: OK" || echo "chroot DNS: FAIL"'
log "mounting host pacman package cache (virtiofs)"
mkdir -p /mnt/pkg-cache
if mount -t virtiofs pkg-cache /mnt/pkg-cache 2>/dev/null; then
  mkdir -p /target/var/cache/pacman/pkg
  mount --bind /mnt/pkg-cache /target/var/cache/pacman/pkg
  log "host pacman cache mounted to /target/var/cache/pacman/pkg"
else
  log "virtiofs pkg-cache not available; proceeding without host cache"
fi


log "ALARM base setup (keyring, upgrade, identity, user, services)"
cat > /target/etc/pacman.d/mirrorlist <<'MIRRORS'
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://uk.mirror.archlinuxarm.org/$arch/$repo
MIRRORS
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT")
ESP_PARTUUID=$(blkid -s PARTUUID -o value "$ESP")

chroot /target /bin/bash -c '
set -euo pipefail
trap "" HUP

pacman-key --init
pacman-key --populate archlinuxarm
pacman_ok=0
for attempt in 1 2 3; do
  if pacman -Syu --noconfirm --needed dosfstools sudo openssh git base-devel efibootmgr; then
    pacman_ok=1
    break
  else
    echo "!! pacman attempt $attempt failed, retrying in 5s..."
  fi
  sleep 5
done
if [[ $pacman_ok -eq 0 ]]; then
  echo "!! pacman installation failed after 3 attempts" >&2
  exit 1
fi

systemd-machine-id-setup
sed -i "s/^#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
locale-gen >/dev/null
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "omarchy" > /etc/hostname
printf "127.0.0.1 localhost\n::1 localhost\n" > /etc/hosts
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

cat > /etc/systemd/network/20-wired.network <<"NET"
[Match]
Name=e*

[Network]
DHCP=yes
NET
systemctl enable systemd-networkd systemd-resolved

systemctl enable sshd
ssh-keygen -A

useradd -m -G wheel -s /bin/bash omarchy
echo "omarchy:omarchy" | chpasswd
echo "omarchy ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/omarchy
chmod 0440 /etc/sudoers.d/omarchy
passwd -l root

mkinitcpio -P
'

log "writing /etc/fstab"
cat > /target/etc/fstab <<EOF
PARTUUID=${ROOT_PARTUUID}  /         ext4  rw,relatime,errors=remount-ro  0 1
PARTUUID=${ESP_PARTUUID}   /boot/efi vfat  rw,relatime,fmask=0022,dmask=0022 0 2
EOF

log "installing GRUB on the ESP"
apt-get update -qq
apt-get install -y -q grub-efi-arm64-bin >/dev/null 2>&1 || apt-get install -y -q grub-efi-arm64 >/dev/null
grub-install --target=arm64-efi --efi-directory=/target/boot/efi \
  --boot-directory=/target/boot/efi --removable

mkdir -p /target/boot/efi/boot/grub /target/boot/efi/boot/efi/grub /target/boot/efi/EFI/BOOT /target/boot/efi/EFI/arch /target/boot/efi/EFI/ubuntu /target/boot/efi/grub
cat > /target/boot/efi/grub/grub.cfg <<EOF
insmod part_gpt
insmod ext2
insmod fat
insmod all_video
insmod gfxterm

set default=0
set timeout=1
menuentry "Omarchy" {
  set root=(hd0,gpt2)
  search --label --set=root OMARCHY
  linux /boot/Image root=LABEL=OMARCHY rw console=hvc0 console=tty0
  initrd /boot/initramfs-linux.img
}
EOF
for p in /target/boot/efi/grub.cfg /target/boot/efi/EFI/BOOT/grub.cfg /target/boot/efi/EFI/arch/grub.cfg /target/boot/efi/EFI/ubuntu/grub.cfg /target/boot/efi/boot/grub/grub.cfg /target/boot/efi/boot/efi/grub/grub.cfg; do
  cp /target/boot/efi/grub/grub.cfg "\$p"
done


log "installing Omarchy 4 (omarchy-mac) inside the chroot"
chroot /target /bin/su - omarchy -c '
set -euo pipefail

# survive SSH session teardowns (mid-build disconnects must not kill us)
trap '' HUP
export OMARCHY_TRY_UNAVAILABLE=0
mkdir -p "$HOME/.local/share"
git clone --depth 1 -b quattro --single-branch \
  https://github.com/omarchy-mac/omarchy-mac.git "$HOME/.local/share/omarchy"
cd "$HOME/.local/share/omarchy"
bash install.sh
' 2>&1 | sed 's/^/    /'

log "allow SSH through the firewall (ufw), if present"
chroot /target /usr/bin/ufw allow 22/tcp >/dev/null 2>&1 || true

log "finalizing systemd-resolved DNS symlink"
ln -sf /run/systemd/resolve/stub-resolv.conf /target/etc/resolv.conf

sync