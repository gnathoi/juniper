#!/usr/bin/env bash
# Desktop layer on top of juniper (Containerfile stage "desktop"): niri Wayland session.
set -xeuo pipefail

# --- repositories: COPRs for what EPEL 10 lacks, used for this build only and removed after.
# Pinned: our copy of each project's key (build_files/copr-keys), includepkgs fences so a COPR
# can't replace system packages (build_files/desktop-copr.txt), and exact versions from
# build_files/desktop.lock (just bump-desktop).
while read -r proj pkgs; do
  [[ -z $proj || $proj == "#"* ]] && continue
  id=${proj/\//-}
  cat >"/etc/yum.repos.d/juniper-copr-$id.repo" <<EOF
[juniper-copr-$id]
name=COPR $proj (build-time only)
baseurl=https://download.copr.fedorainfracloud.org/results/$proj/epel-10-\$basearch/
gpgcheck=1
gpgkey=file:///ctx/build_files/copr-keys/$id.gpg
skip_if_unavailable=False
includepkgs=$pkgs
EOF
done </ctx/build_files/desktop-copr.txt

# --- packages ---
mapfile -t locked </ctx/build_files/desktop.lock
dnf -y install --exclude=fzf "${locked[@]}" \
  xorg-x11-server-Xwayland wl-clipboard libnotify flatpak \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring \
  pipewire wireplumber pipewire-pulseaudio \
  mesa-dri-drivers mesa-vulkan-drivers \
  google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts
dnf clean all
rm -f /etc/yum.repos.d/juniper-copr-*.repo
install -D -m 0644 /ctx/build_files/desktop.lock /usr/share/juniper/desktop.lock

cp -a /ctx/system_files_desktop/. /

# KMS graphics, per kernel (replaces the headless rpi-config.txt build.sh installed).
for kdir in /usr/lib/modules/*/; do
  install -m 0644 /usr/share/juniper/rpi-config.txt "$kdir/rpi-config.txt"
done

# --- units ---
systemctl enable greetd.service
systemctl enable juniper-flatpak-setup.service juniper-flatpak-update.timer juniper-reboot-retry.timer
systemctl set-default graphical.target

# --- layers ---
tag() { python3 -c '
import os, sys
for p in sys.stdin.read().split("\0"):
    if p:
        os.setxattr(p, "user.component", sys.argv[1].encode(), follow_symlinks=False)
' "$1"; }
find /ctx/system_files_desktop -type f -printf '/%P\0' | tag juniper
printf '%s\0' /usr/lib/modules/*/rpi-config.txt | tag juniper

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
/ctx/build_files/clean-runtime-dirs.sh
