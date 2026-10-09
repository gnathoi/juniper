#!/usr/bin/env bash
# Builds the Juniper layer. Runs once inside the Containerfile with /ctx mounted.
set -xeuo pipefail

: "${IMAGE_REF:?}" "${IMAGE_VERSION:?}"

# --- repositories ---
dnf -y install dnf-plugins-core https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf config-manager --set-enabled crb
curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/rhel/10/tailscale.repo

# --- packages ---
dnf -y install \
  podman firewalld cloud-init cloud-utils-growpart zram-generator \
  git-core tmux jq rsync zstd NetworkManager-wifi avahi \
  distrobox fastfetch just btop ripgrep fzf neovim \
  tailscale
dnf clean all

# cloud-init: /usr is read-only on bootc, so grow the filesystem holding /var instead.
resizefs=$(echo /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py)
sed -i 's@resize_what = "/"@resize_what = "/var"@' "$resizefs"
grep -q 'resize_what = "/var"' "$resizefs"
rm -f "$(dirname "$resizefs")"/__pycache__/cc_resizefs.*.pyc

# --- Homebrew: staged here, extracted to /var/home/linuxbrew by juniper-firstboot ---
# Full clone, not --depth 1: `brew update` needs history.
brew_tag=$(curl -fsSL https://api.github.com/repos/Homebrew/brew/releases/latest | jq -r .tag_name)
mkdir -p /tmp/linuxbrew/.linuxbrew/bin
git clone --branch "$brew_tag" https://github.com/Homebrew/brew /tmp/linuxbrew/.linuxbrew/Homebrew
ln -s ../Homebrew/bin/brew /tmp/linuxbrew/.linuxbrew/bin/brew
mkdir -p /usr/share/juniper
tar --zstd -cf /usr/share/juniper/homebrew.tar.zst -C /tmp/linuxbrew .linuxbrew
rm -rf /tmp/linuxbrew

# --- files (after packages so RPM payloads cannot overwrite what Juniper ships) ---
cp -a /ctx/system_files/. /

# --- identity ---
sed -i '/^\(PRETTY_NAME\|VARIANT\|VARIANT_ID\|IMAGE_ID\|IMAGE_VERSION\)=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<EOT
PRETTY_NAME="Juniper ${IMAGE_VERSION} (AlmaLinux 10 bootc)"
VARIANT="Juniper"
VARIANT_ID=juniper
IMAGE_ID=juniper
IMAGE_VERSION=${IMAGE_VERSION}
EOT

# --- units ---
systemctl enable tailscaled.service firewalld.service avahi-daemon.service \
  cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service \
  podman-auto-update.timer
systemctl --global enable podman-auto-update.timer
systemctl mask bootc-fetch-apply-updates.timer
