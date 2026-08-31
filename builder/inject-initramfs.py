#!/usr/bin/env python3
"""Inject our /init and extra kernel modules into an ALARM initramfs.

ALARM initramfs layout (mkinitcpio):
  [small uncompressed cpio with an "early_cpio" marker, 10 KiB aligned]
  [gzip-compressed cpio with the real rootfs]

Usage:
  inject-initramfs.py <orig-initramfs> <out-initramfs> <init-file> <modules-dir>

<modules-dir> is the kernel modules tree of the SAME kernel as the
initramfs; the .ko files listed below are copied in so the builder /init
can insmod them (they were trimmed by autodetect on ALARM's build host).
"""
import gzip
import os
import shutil
import subprocess
import sys
import tempfile

MODULES = [
    "kernel/drivers/net/virtio_net.ko",
    "kernel/drivers/block/loop.ko",
]


def main() -> int:
    src, dest, init_file, modules_dir = sys.argv[1:5]

    data = open(src, "rb").read()
    gz = data.find(b"\x1f\x8b")
    if gz < 0:
        print("no gzip payload found in initramfs", file=sys.stderr)
        return 1
    early, payload = data[:gz], gzip.decompress(data[gz:])

    with tempfile.TemporaryDirectory() as td:
        cpio = os.path.join(td, "payload.cpio")
        open(cpio, "wb").write(payload)
        subprocess.run(["bsdtar", "-xf", cpio, "-C", td], check=True)

        shutil.copy(init_file, os.path.join(td, "init"))
        os.chmod(os.path.join(td, "init"), 0o755)

        kver = sorted(os.listdir(os.path.join(td, "usr/lib/modules")))[0]
        for rel in MODULES:
            src_mod = os.path.join(modules_dir, rel)
            if not os.path.isfile(src_mod):
                print(f"warning: {rel} not found in module tree", file=sys.stderr)
                continue
            dst_mod = os.path.join(td, "usr/lib/modules", kver, rel)
            os.makedirs(os.path.dirname(dst_mod), exist_ok=True)
            shutil.copy(src_mod, dst_mod)

        p = subprocess.run(
            ["bsdtar", "--format=newc", "-cf", "-", "-C", td, "."],
            check=True,
            stdout=subprocess.PIPE,
        )
        out = early + gzip.compress(p.stdout, mtime=0)
        open(dest, "wb").write(out)
        print(f"wrote {dest} ({len(out)} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())