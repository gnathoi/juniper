#!/usr/bin/env bash
# Smoke test executed inside a built image (no systemd running):
#   just image=juniper test-image   /   just image=juniper-minimal test-image
#   just image=juniper-desktop test-image
set -euo pipefail

# shellcheck source=/dev/null
. /usr/lib/os-release
[[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-minimal || $IMAGE_ID == juniper-desktop ]] || {
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
# fzf comes from Homebrew on juniper (Brewfile), not the image (it's just's weak dependency).
if rpm -q fzf >/dev/null; then
  echo "fzf is in the image"
  exit 1
fi
need_enabled tailscaled.service firewalld.service avahi-daemon.service cloud-init.service \
  cloud-final.service podman-auto-update.timer
[[ $(systemctl is-enabled bootc-fetch-apply-updates.timer) == masked ]]
grep -q 'resize_what = "/var"' /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py
for k in rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot; do
  grep -q "$k" /usr/lib/bootc/kargs.d/10-juniper.toml
done

# Key-only SSH on every image, whatever cloud-init writes later (40-juniper.conf comes first,
# and sshd keeps the first value). sshd -T needs a host key: use a throwaway one.
t=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -f "$t/hostkey"
sshd_eff=$(sshd -T -h "$t/hostkey")
rm -rf "$t"
for opt in passwordauthentication kbdinteractiveauthentication; do
  grep -qx "$opt no" <<<"$sshd_eff" || {
    echo "sshd: $opt is not off"
    exit 1
  }
done

# Package repos trust only local keys (build_files/keys): no gpgkey= over HTTPS, signatures
# on, and the EPEL and Tailscale keys are the pinned ones.
if grep -H '^gpgkey=' /etc/yum.repos.d/*.repo | grep -v '=file:///etc/pki/rpm-gpg/'; then
  echo "repo key not a local file"
  exit 1
fi
if grep -H '^gpgcheck=0' /etc/yum.repos.d/*.repo; then
  echo "repo with signature checks off"
  exit 1
fi
for want in gpgcheck=1 repo_gpgcheck=1 gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale; do
  grep -qx "$want" /etc/yum.repos.d/tailscale.repo
done
# shellcheck disable=SC2016 # a literal dnf variable
grep -qxF 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-$releasever_major' /etc/yum.repos.d/epel.repo
key_fpr() { GNUPGHOME=$(mktemp -d) gpg --show-keys --with-colons "$1" | awk -F: '$1 == "fpr" {print $10; exit}'; }
[[ $(key_fpr /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-10) == 7D8D15CBFC4E62688591FB2633D98517E37ED158 ]]
[[ $(key_fpr /etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale) == 2596A99EAAB33821893C0A79458CA832957F5868 ]]

need_enabled juniper-firstboot.service juniper-tailscale-join.service
test -x /usr/libexec/juniper/tailscale-join
test -x /usr/libexec/juniper/lan-ssh
need_enabled juniper-update.timer juniper-reboot.timer juniper-healthcheck.service juniper-lan-ssh-status.service
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
# rpi-eeprom-update also needs strings (binutils), which rpi-eeprom does not require.
need_cmds rpi-eeprom-update lspci strings
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
for kdir in /usr/lib/modules/*/; do
  grep -qx 'disable_splash=1' "$kdir/rpi-config.txt"
  # KMS graphics only on the desktop; the headless images keep displays off.
  if [[ $IMAGE_ID == juniper-desktop ]]; then
    grep -qx 'dtoverlay=vc4-kms-v3d' "$kdir/rpi-config.txt"
    grep -qx 'display_auto_detect=1' "$kdir/rpi-config.txt"
  else
    grep -qx 'display_auto_detect=0' "$kdir/rpi-config.txt"
    if grep -q 'vc4-kms' "$kdir/rpi-config.txt"; then
      echo "KMS overlay in a headless image"
      exit 1
    fi
  fi
done
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
test -f /usr/share/bash-completion/completions/ujust
bash -c 'source /usr/share/bash-completion/bash_completion && _completion_loader ujust; complete -p ujust' | grep -q _ujust
# Capture first: `grep -q` exiting early would SIGPIPE motd under pipefail.
motd=$(HOME=/tmp /usr/libexec/juniper/motd)
grep -q 'Tailscale' <<<"$motd"

jq -e '[.transports.docker[][] | select(.type == "sigstoreSigned" and .keyPath == "/usr/share/pki/containers/juniper.pub")] | length == 1' /etc/containers/policy.json >/dev/null
# R8: scoped to the namespace, not one image, so juniper <-> juniper-minimal switches stay enforced.
jq -e '[.transports.docker | to_entries[] | select(.value[0].keyPath == "/usr/share/pki/containers/juniper.pub") | .key | contains("juniper") | not] == [true]' /etc/containers/policy.json >/dev/null
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/juniper.yaml

if [[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-desktop ]]; then
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

if [[ $IMAGE_ID == juniper-desktop ]]; then
  # --- desktop only ---
  need_cmds niri niri-session xwayland-satellite Xwayland greetd agreety foot waybar fuzzel \
    swaylock swayidle swaync pipewire wireplumber flatpak notify-send
  need_enabled greetd.service
  systemd-analyze verify greetd.service
  # Login prompt first: agreety, then niri only after PAM authentication; never auto-login.
  grep -qx 'command = "agreety --cmd niri-session"' /etc/greetd/config.toml
  if grep -q initial_session /etc/greetd/config.toml ||
    compgen -G '/usr/lib/systemd/system/greetd.service.d/*' >/dev/null ||
    compgen -G '/etc/systemd/system/greetd.service.d/*' >/dev/null; then
    echo "greetd auto-login, or a drop-in overriding /etc/greetd/config.toml"
    exit 1
  fi
  # An update that doesn't bring greetd up is rolled back under tryboot (healthcheck hook).
  test -x /usr/lib/juniper/health.d/10-greetd
  grep -q '^GPGKey=' /etc/flatpak/remotes.d/flathub.flatpakrepo
  need_enabled juniper-flatpak-setup.timer juniper-flatpak-update.timer
  systemd-analyze verify juniper-flatpak-setup.timer juniper-flatpak-setup.service juniper-flatpak-update.service
  # The app download runs from its timer, outside the boot transaction: it must not delay
  # multi-user.target (cloud-final, then the first-boot secret scrub, wait for it).
  [[ $(systemctl is-enabled juniper-flatpak-setup.service) == static ]] || {
    echo "juniper-flatpak-setup.service is wanted by a boot target"
    exit 1
  }
  # The reboot window waits for an idle desktop (checked by file: no running systemd in CI).
  test -e /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf
  grep -q '^ExecCondition=/usr/libexec/juniper/desktop-idle$' \
    /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf
  test -x /usr/libexec/juniper/desktop-idle
  need_enabled juniper-reboot-retry.timer
  systemd-analyze verify juniper-reboot-retry.service
  # ...and only while automatic reboots are on (`ujust update-schedule off` disables the timer).
  grep -qx 'ExecCondition=/usr/bin/systemctl is-enabled --quiet juniper-reboot.timer' \
    /usr/lib/systemd/system/juniper-reboot-retry.service
  # niri accepts Juniper's defaults, the /etc config, and the stub desktop-config writes.
  niri validate -c /usr/share/juniper/niri/juniper.kdl
  niri validate -c /etc/niri/config.kdl
  t=$(mktemp -d)
  HOME=$t just --justfile /usr/share/juniper/just/desktop.just desktop-config
  head -2 "$t/.config/niri/config.kdl" | grep -q '^include "/usr/share/juniper/niri/juniper.kdl"'
  rm -rf "$t"
  grep -qx 'desktop-config' <<<"$recipes"
  grep -qx 'flatpak-setup' <<<"$recipes"
  ls /usr/lib64/dri/v3d_dri.so /usr/lib64/dri/vc4_dri.so >/dev/null
  ls /usr/lib/modules/*/kernel/drivers/gpu/drm/v3d/v3d.ko* >/dev/null
  # The COPRs are build-time only: devices never pull from them.
  if ls /etc/yum.repos.d/*copr* 2>/dev/null; then
    echo "COPR repo left in the image"
    exit 1
  fi
  # Every COPR package is exactly the version in the lock file.
  test -s /usr/share/juniper/desktop.lock
  while read -r nvr; do
    rpm -q "$nvr" >/dev/null || {
      echo "not the locked version: $nvr"
      exit 1
    }
  done </usr/share/juniper/desktop.lock
  cycles=$(systemd-analyze verify graphical.target cloud-init.target 2>&1 | grep 'ordering cycle' || true)
  [[ -z $cycles ]] || {
    echo "$cycles"
    exit 1
  }
else
  if command -v niri >/dev/null || [[ -e /usr/share/juniper/just/desktop.just ]]; then
    echo "desktop content in a headless image"
    exit 1
  fi
  if ls /etc/flatpak/remotes.d/flathub.flatpakrepo /usr/lib/systemd/system/juniper-flatpak-* 2>/dev/null; then
    echo "flatpak units or remote in a headless image"
    exit 1
  fi
  if [[ -e /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf ||
    -e /usr/libexec/juniper/desktop-idle ||
    -e /usr/lib/systemd/system/juniper-reboot-retry.timer ||
    -e /usr/lib/systemd/system/juniper-reboot-retry.service ]]; then
    echo "desktop idle-reboot gate in a headless image"
    exit 1
  fi
  # The base defaults to graphical.target; nothing graphical starts without a display manager.
  if [[ -e /etc/systemd/system/display-manager.service ]]; then
    echo "display manager enabled in a headless image"
    exit 1
  fi
  if [[ -e /usr/lib/juniper/health.d ]]; then
    echo "health hooks in a headless image"
    exit 1
  fi
fi

echo "image smoke test: OK ($IMAGE_ID)"
