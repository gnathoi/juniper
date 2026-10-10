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
grep -qx 'NAME="Juniper"' /usr/lib/os-release
grep -qx 'ID="almalinux"' /usr/lib/os-release # dnf, cloud-init and bootc key off ID
test -s /usr/share/licenses/juniper/LICENSE
test -s /usr/share/licenses/juniper/THIRD_PARTY.md
grep -q 'BSD 3-Clause' /usr/share/licenses/tailscale/LICENSE

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
for k in rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot; do
  grep -q "$k" /usr/lib/bootc/kargs.d/10-juniper.toml
done

need_enabled juniper-firstboot.service juniper-tailscale-join.service
need_enabled juniper-update.timer juniper-reboot.timer juniper-healthcheck.service
need_cmds rpi-bootc-bootloader
grep -qx 'TRYBOOT=1' /etc/rpi-bootc-bootloader/tryboot.conf
grep -qx 'OnCalendar=Tue \*-\*-\* 04:00:00' /usr/lib/systemd/system/juniper-reboot.timer || {
  echo "reboot timer default is not Tue 04:00" >&2
  exit 1
}
systemd-analyze verify /usr/lib/systemd/system/juniper-*.service /usr/lib/systemd/system/juniper-*.timer
# Ordering cycles only show up in a whole boot transaction (and verify still exits 0).
# cloud-init's generator adds cloud-init.target on first boot; cloud-final runs after
# multi-user.target, so nothing multi-user.target pulls in may order itself after it.
cycles=$(systemd-analyze verify multi-user.target cloud-init.target 2>&1 | grep 'ordering cycle' || true)
[[ -z $cycles ]] || {
  echo "$cycles"
  exit 1
}
need_cmds rpi-eeprom-update lspci
# Trimmed initramfs (90-juniper.conf): ostree and crypt in, network root/VM/RAID/TPM out.
for img in /usr/lib/modules/*/initramfs.img; do
  mods=$(lsinitrd "$img" | sed -n '/^dracut modules:/,/^=/p')
  for m in ostree crypt systemd-initrd rootfs-block; do grep -qx "$m" <<<"$mods"; done
  for m in nfs network-manager qemu lvm clevis fips btrfs; do
    if grep -qx "$m" <<<"$mods"; then
      echo "initramfs still has $m"
      exit 1
    fi
  done
  (($(stat -c %s "$img") < 35 * 1024 * 1024))
done
# rpi-eeprom ships only the tools; the bootloader images are in rpi-eeprom-firmware.
ls /usr/lib/firmware/raspberrypi/bootloader-2712/default/pieeprom-*.bin >/dev/null
ls /usr/lib/firmware/raspberrypi/bootloader-2711/default/pieeprom-*.bin >/dev/null
grep -qx 'BOOTFS=/boot/efi' /etc/default/rpi-eeprom-update
for kdir in /usr/lib/modules/*/; do grep -qx 'disable_splash=1' "$kdir/rpi-config.txt"; done
need_enabled juniper-wifi-import.service juniper-firstboot-retry.service juniper-emergency-fallback.service
grep -qx 'prefer_fqdn_over_hostname: false' /etc/cloud/cloud.cfg.d/10-juniper-hostname.cfg
test -f /usr/share/juniper/cidata/user-data
[[ $(systemctl is-enabled juniper-lockdown.timer) == enabled ]]
firewall-offline-cmd --get-default-zone | grep -qx public

recipes=$(ujust --summary | tr ' ' '\n')
for r in update switch update-schedule lan-ssh tailscale-up tailscale-ssh toggle-motd enable-metrics pi-status pi-eeprom; do
  grep -qx "$r" <<<"$recipes" || {
    echo "missing recipe: $r"
    exit 1
  }
done
# Capture first: `grep -q` exiting early would SIGPIPE motd under pipefail.
motd=$(HOME=/tmp /usr/libexec/juniper/motd)
grep -q 'Tailscale' <<<"$motd"

jq -e '[.transports.docker[][] | select(.type == "sigstoreSigned" and .keyPath == "/usr/share/pki/containers/juniper.pub")] | length == 1' /etc/containers/policy.json >/dev/null
# R8: scoped to the namespace, not one image, so juniper <-> juniper-minimal switches stay enforced.
jq -e '[.transports.docker | to_entries[] | select(.value[0].keyPath == "/usr/share/pki/containers/juniper.pub") | .key | contains("juniper") | not] == [true]' /etc/containers/policy.json >/dev/null
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/juniper.yaml

if [[ $IMAGE_ID == juniper ]]; then
  # --- full image only ---
  need_cmds distrobox fastfetch git zstd
  need_enabled brew-setup.service brew-update.timer brew-upgrade.timer
  # CLI tools come from Homebrew at first login, not the image.
  grep -qx 'brew "zellij"' /usr/share/juniper/Brewfile
  [[ $(systemctl --global is-enabled juniper-brew-tools.service) == enabled ]]
  test -s /usr/share/homebrew.tar.zst
  test -f /etc/profile.d/brew.sh
  grep -q 'Apache License' /usr/share/licenses/ublue-os-brew/LICENSE
  just --justfile /usr/share/juniper/just/dev.just --summary | tr ' ' '\n' | grep -qx devbox
  for r in devbox install-podlet brew-tools; do
    grep -qx "$r" <<<"$recipes" || {
      echo "missing recipe: $r"
      exit 1
    }
  done
  fastfetch --config /etc/xdg/fastfetch/config.jsonc --pipe >/dev/null
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
  if grep -qx devbox <<<"$recipes"; then
    echo "dev recipe in minimal: devbox"
    exit 1
  fi
fi

echo "image smoke test: OK ($IMAGE_ID)"
