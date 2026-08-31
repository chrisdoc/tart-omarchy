packer {
  required_plugins {
    tart = {
      source  = "github.com/cirruslabs/tart"
      version = ">= 1.21.0"
    }
  }
}

# Build the Omarchy 4 (Quattro) Tart image the way CirrusLabs build their
# Linux images: clone an already-bootable Ubuntu ARM64 base VM (SSH access,
# no ISO boot gymnastics), then turn an attached raw disk into the Omarchy
# system:
#
#   /dev/vda = Ubuntu base (discarded afterwards)
#   /dev/vdb = root_disk: fresh GPT: 512 MB ESP + ext4 root, deployed with
#              Arch Linux ARM + omarchy-mac, GRUB bootloader, NVRAM entry
#
# After the build the VM's main disk is swapped for the built root disk
# (same ESP partition GUIDs, so the registered boot entry keeps working).

variable "vm_name" {
  type    = string
  default = "omarchy"
}
variable "omarchy_version" {
  type    = string
  default = "4.0.2"
}


variable "root_disk" {
  type    = string
  default = ".build/rootdisk.img"
}

variable "rootfs" {
  type    = string
  default = ".build/dl/alarm-rootfs.tgz"
}

variable "cpu" {
  type    = number
  default = 6
}

variable "memory" {
  type    = number
  default = 12
}

source "tart-cli" "omarchy" {
  vm_base_name = "ghcr.io/cirruslabs/ubuntu:latest"
  vm_name      = var.vm_name
  cpu_count    = var.cpu
  memory_gb    = var.memory
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "180s"
  ssh_keep_alive_interval = "5s"
}

build {
  sources = ["source.tart-cli.omarchy"]

  # phase 1 only: clone the bootable base VM and upload the build inputs.
  # The long provision runs in phase 2 (see build-tart.sh), detached from
  # any SSH session so a flaky connection cannot kill it.
  provisioner "file" {
    source      = var.rootfs
    destination = "/home/admin/alarm-rootfs.tgz"
  }

  provisioner "file" {
    source      = "${path.root}/provision.sh"
    destination = "/home/admin/provision.sh"
  }

  provisioner "shell" {
    inline      = ["sudo chmod +x /home/admin/provision.sh && sync"]
  }
}