#!/usr/bin/env bash
# Desktop layer on top of juniper (Containerfile stage "desktop"): niri Wayland session.
# Experimental (sub-project D): built and tested in CI, never published.
set -xeuo pipefail

# --- repositories: COPRs for what EPEL 10 lacks. Fetched only for this build and removed
# afterwards, so devices never pull from them. Each COPR may only supply the packages it is
# here for (includepkgs), so a compromised or careless COPR cannot replace system packages.
copr() { # copr OWNER/PROJECT PACKAGE...
  local f=/etc/yum.repos.d/juniper-copr-${1/\//-}.repo
  curl -fsSLo "$f" "https://copr.fedorainfracloud.org/coprs/$1/repo/epel-10/x.repo"
  sed -i -e 's/^skip_if_unavailable=True/skip_if_unavailable=False/' "$f"
  shift
  echo "includepkgs=$*" >>"$f"
}
copr yalter/niri niri
copr yselkowitz/wlroots-epel xwayland-satellite foot foot-terminfo waybar fuzzel swaylock \
  swayidle swaybg SwayNotificationCenter brightnessctl \
  playerctl-libs nanosvg fcft gtk-layer-shell # their dependencies from the same COPR
copr yselkowitz/cosmic-epel greetd greetd-selinux

# --- packages ---
dnf -y install --exclude=fzf \
  niri xwayland-satellite xorg-x11-server-Xwayland \
  greetd greetd-selinux \
  foot waybar fuzzel swaylock swayidle swaybg SwayNotificationCenter brightnessctl wl-clipboard \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring \
  pipewire wireplumber pipewire-pulseaudio \
  mesa-dri-drivers mesa-vulkan-drivers \
  google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts
dnf clean all
rm -f /etc/yum.repos.d/juniper-copr-*.repo

cp -a /ctx/system_files_desktop/. /

# KMS graphics, per kernel (replaces the headless rpi-config.txt build.sh installed).
for kdir in /usr/lib/modules/*/; do
  install -m 0644 /usr/share/juniper/rpi-config.txt "$kdir/rpi-config.txt"
done

# --- units ---
systemctl enable greetd.service
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
