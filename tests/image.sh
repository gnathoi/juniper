#!/usr/bin/env bash
# Smoke test executed inside the built image (no systemd running):
#   just test-image
set -euo pipefail

grep -qx 'IMAGE_ID=juniper' /usr/lib/os-release
grep -q '^PRETTY_NAME="Juniper' /usr/lib/os-release

for cmd in tailscale tailscaled podman distrobox fastfetch just btop rg fzf nvim tmux jq rsync git firewall-cmd cloud-init; do
  command -v "$cmd" >/dev/null || {
    echo "missing: $cmd"
    exit 1
  }
done
for unit in tailscaled.service firewalld.service avahi-daemon.service cloud-init.service \
  cloud-final.service podman-auto-update.timer; do
  [[ $(systemctl is-enabled "$unit") == enabled ]] || {
    echo "not enabled: $unit"
    exit 1
  }
done
[[ $(systemctl is-enabled bootc-fetch-apply-updates.timer) == masked ]]
tar --zstd -tf /usr/share/juniper/homebrew.tar.zst .linuxbrew/bin/brew >/dev/null
grep -q 'resize_what = "/var"' /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py
grep -q 'rootflags=noatime' /usr/lib/bootc/kargs.d/10-juniper.toml

echo "image smoke test: OK"
