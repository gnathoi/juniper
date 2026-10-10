#!/usr/bin/env bash
# Builds the Juniper layer. Runs once inside the Containerfile with /ctx mounted.
set -xeuo pipefail

: "${IMAGE_REF:?}" "${IMAGE_NAME:?}" "${IMAGE_VERSION:?}"

# --- repositories ---
dnf -y install dnf-plugins-core https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf config-manager --set-enabled crb
curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/rhel/10/tailscale.repo

# --- packages ---
dnf -y install \
  podman firewalld cloud-init cloud-utils-growpart zram-generator \
  jq rsync NetworkManager-wifi avahi just \
  tailscale
dnf clean all

# cloud-init: /usr is read-only on bootc, so grow the filesystem holding /var instead.
resizefs=$(echo /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py)
sed -i 's@resize_what = "/"@resize_what = "/var"@' "$resizefs"
grep -q 'resize_what = "/var"' "$resizefs"
rm -f "$(dirname "$resizefs")"/__pycache__/cc_resizefs.*.pyc

# --- files (after packages so RPM payloads cannot overwrite what Juniper ships) ---
cp -a /ctx/system_files/. /

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
sed -i '/^\(PRETTY_NAME\|VARIANT\|VARIANT_ID\|IMAGE_ID\|IMAGE_VERSION\)=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<EOT
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
  juniper-lockdown.timer juniper-update.timer juniper-reboot.timer juniper-healthcheck.service juniper-wifi-import.service
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
printf '%s\0' /usr/lib/os-release /etc/containers/policy.json /etc/containers/registries.d/juniper.yaml \
  /etc/yum.repos.d/tailscale.repo | tag juniper

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
rm -rf /run/cloud-init
