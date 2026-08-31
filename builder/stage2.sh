#!/bin/bash
# stage2: install Omarchy 4 (Quattro) from omarchy-mac, as user omarchy.
# Runs inside the deployed system's chroot; console output goes to the host
# through the VM serial console.

set -euo pipefail

log() { printf '==> %s\n' "$*"; }

log "cloning omarchy-mac (quattro branch)"
mkdir -p "$HOME/.local/share"
git clone --depth 1 -b quattro --single-branch \
  https://github.com/omarchy-mac/omarchy-mac.git "$HOME/.local/share/omarchy"
cd "$HOME/.local/share/omarchy"
git log -1 --oneline
cat version

log "running omarchy-mac install.sh"
OMARCHY_TRY_UNAVAILABLE=0 bash install.sh

log "allow SSH through the firewall (ufw), if present"
sudo ufw allow 22/tcp >/dev/null 2>&1 || true

echo "==> stage2 done: Omarchy installed"
exit 0