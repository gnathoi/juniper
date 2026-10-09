#!/usr/bin/env bash
# Smoke test executed inside a built image (no systemd running):
#   just image=juniper test-image   /   just image=juniper-minimal test-image
set -euo pipefail

# shellcheck source=/dev/null
. /usr/lib/os-release
[[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-minimal ]] || {
  echo "unexpected IMAGE_ID: $IMAGE_ID"
  exit 1
}
grep -q '^PRETTY_NAME="Juniper' /usr/lib/os-release

need_cmds() {
  for cmd; do
    command -v "$cmd" >/dev/null || {
      echo "missing: $cmd"
      exit 1
    }
  done
}
need_enabled() {
  for unit; do
    [[ $(systemctl is-enabled "$unit") == enabled ]] || {
      echo "not enabled: $unit"
      exit 1
    }
  done
}

# --- shared (both images) ---
need_cmds tailscale tailscaled podman just jq rsync firewall-cmd cloud-init
need_enabled tailscaled.service firewalld.service avahi-daemon.service cloud-init.service \
  cloud-final.service podman-auto-update.timer
[[ $(systemctl is-enabled bootc-fetch-apply-updates.timer) == masked ]]
grep -q 'resize_what = "/var"' /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py
grep -q 'rootflags=noatime' /usr/lib/bootc/kargs.d/10-juniper.toml

need_enabled juniper-firstboot.service juniper-tailscale-join.service
systemd-analyze verify /usr/lib/systemd/system/juniper-*.service
test -f /usr/share/juniper/cidata/user-data
[[ $(systemctl is-enabled juniper-lockdown.timer) == enabled ]]
firewall-offline-cmd --get-default-zone | grep -qx public

if [[ $IMAGE_ID == juniper ]]; then
  # --- full image only ---
  need_cmds distrobox fastfetch btop rg fzf nvim tmux git zstd
  need_enabled brew-setup.service brew-update.timer brew-upgrade.timer
  test -s /usr/share/homebrew.tar.zst
  test -f /etc/profile.d/brew.sh
  just --justfile /usr/share/juniper/just/dev.just --summary | tr ' ' '\n' | grep -qx devbox
else
  # --- minimal only: no developer tooling ---
  for cmd in distrobox fastfetch nvim tmux btop git; do
    if command -v "$cmd" >/dev/null; then
      echo "dev tool in minimal: $cmd"
      exit 1
    fi
  done
  test ! -e /usr/share/homebrew.tar.zst
  test ! -e /usr/share/juniper/just/dev.just
fi

echo "image smoke test: OK ($IMAGE_ID)"
