#!/usr/bin/env bash
# Builds the Juniper layer. Runs once inside the Containerfile with /ctx mounted.
set -xeuo pipefail

: "${IMAGE_REF:?}" "${IMAGE_NAME:?}" "${IMAGE_VERSION:?}"

# --- repositories ---
dnf -y install dnf-plugins-core https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf config-manager --set-enabled crb
curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/rhel/10/tailscale.repo

# --- security updates ---
# AlmaLinux rebuilds the base image only every 1-4 weeks; errata land in the repos in
# between (a 2026-10-02 base had 14 Important security advisories pending 8 days later), so
# each weekly build applies them. The Pi kernel and firmware stay as the base built them:
# its initramfs and boot files are generated with them there.
dnf -y upgrade --exclude='raspberrypi2-kernel*' --exclude='raspberrypi2-firmware*'

# --- packages ---
# fzf is only a weak dependency of just (`just --choose`); juniper gets a current one from
# Homebrew, and an appliance doesn't need it.
dnf -y install --exclude=fzf \
  podman firewalld cloud-init cloud-utils-growpart zram-generator \
  jq rsync NetworkManager-wifi avahi just \
  tailscale rpi-eeprom rpi-eeprom-firmware binutils
dnf clean all

# cloud-init: /usr is read-only on bootc, so grow the filesystem holding /var instead.
resizefs=$(echo /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py)
sed -i 's@resize_what = "/"@resize_what = "/var"@' "$resizefs"
grep -q 'resize_what = "/var"' "$resizefs"
rm -f "$(dirname "$resizefs")"/__pycache__/cc_resizefs.*.pyc

# --- files (after packages so RPM payloads cannot overwrite what Juniper ships) ---
cp -a /ctx/system_files/. /
install -D -m 0644 -t /usr/share/licenses/juniper /ctx/LICENSE /ctx/THIRD_PARTY.md

# Initramfs: regenerate with 90-juniper.conf (system_files), dropping what a Pi never boots
# with (46 -> 29 MB, ~30% faster initrd stage on a Pi 5), and from this build's upgraded
# systemd/ostree instead of the base's. /root links to /var/roothome, which a build's /var
# lacks; dracut wants it to exist.
mkdir -p /var/roothome
for kdir in /usr/lib/modules/*/; do
  kver=$(basename "$kdir")
  dracut --no-hostonly --reproducible --kver "$kver" -f "$kdir/initramfs.img"
  chmod 0644 "$kdir/initramfs.img"
done

# Headless boot settings, per kernel: rpi-bootc-bootloader copies rpi-config.txt into each
# deployment's boot entry and includes it from the default and tryboot configs, so a bad
# setting falls back with the rest of the update.
for kdir in /usr/lib/modules/*/; do
  install -m 0644 /usr/share/juniper/rpi-config.txt "$kdir/rpi-config.txt"
done

# --- signature policy: every image under our namespace (juniper, juniper-minimal) must carry
# our cosign signature. Scoped to OS images only: a global reject would also stop podman
# pulling unsigned app images for quadlets.
namespace=${IMAGE_REF%/*}
jq --arg ns "$namespace" \
  '.transports.docker[$ns] = [{"type": "sigstoreSigned",
     "keyPath": "/usr/share/pki/containers/juniper.pub",
     "signedIdentity": {"type": "matchRepository"}}]' \
  /etc/containers/policy.json >/tmp/policy.json
mv /tmp/policy.json /etc/containers/policy.json
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$namespace" \
  >/etc/containers/registries.d/juniper.yaml

# --- identity ---
case $IMAGE_NAME in
  juniper-minimal) pretty="Juniper Minimal" ;;
  juniper) pretty="Juniper" ;;
  *)
    echo "unknown IMAGE_NAME: $IMAGE_NAME" >&2
    exit 1
    ;;
esac
# NAME is ours (a modified build isn't "AlmaLinux"); ID, VERSION_ID and ID_LIKE stay, as dnf,
# cloud-init and bootc key off them.
sed -i '/^\(NAME\|PRETTY_NAME\|VARIANT\|VARIANT_ID\|IMAGE_ID\|IMAGE_VERSION\)=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<EOT
NAME="Juniper"
PRETTY_NAME="${pretty} ${IMAGE_VERSION}"
VARIANT="${pretty}"
VARIANT_ID=${IMAGE_NAME}
IMAGE_ID=${IMAGE_NAME}
IMAGE_VERSION=${IMAGE_VERSION}
EOT

# --- units ---
systemctl enable tailscaled.service firewalld.service avahi-daemon.service \
  cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service \
  podman-auto-update.timer juniper-firstboot.service juniper-tailscale-join.service \
  juniper-lockdown.timer juniper-update.timer juniper-reboot.timer juniper-healthcheck.service juniper-wifi-import.service \
  juniper-firstboot-retry.service juniper-emergency-fallback.service
systemctl --global enable podman-auto-update.timer
systemctl mask bootc-fetch-apply-updates.timer

# --- layers: rpm-ostree's chunker gives each user.component its own layer, so a change to
# Juniper's files does not re-send the initramfs and the other unpackaged content.
tag() { python3 -c '
import os, sys
for p in sys.stdin.read().split("\0"):
    if p:
        os.setxattr(p, "user.component", sys.argv[1].encode(), follow_symlinks=False)
' "$1"; }
# regular files only: Linux rejects user.* xattrs on symlinks
find /ctx/system_files -type f -printf '/%P\0' | tag juniper
printf '%s\0' /usr/share/licenses/juniper/LICENSE /usr/share/licenses/juniper/THIRD_PARTY.md | tag juniper
# Its own layer: changes only when its inputs do (dracut --reproducible).
printf '%s\0' /usr/lib/modules/*/initramfs.img | tag initramfs
printf '%s\0' /usr/lib/os-release /etc/containers/policy.json /etc/containers/registries.d/juniper.yaml \
  /etc/yum.repos.d/tailscale.repo | tag juniper

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
/ctx/build_files/clean-runtime-dirs.sh
