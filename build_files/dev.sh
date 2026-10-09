#!/usr/bin/env bash
# Developer layer on top of the minimal image (Containerfile stage "juniper").
# Homebrew's tarball and units were already copied from the pinned ublue-os/brew image.
set -xeuo pipefail

dnf -y install distrobox fastfetch btop ripgrep fzf neovim tmux git-core zstd
dnf clean all

cp -a /ctx/system_files_dev/. /

systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer

# --- layers: rpm-ostree's chunker gives each user.component its own layer, so a change to
# Juniper's files does not re-send the initramfs and the other unpackaged content.
tag() { python3 -c '
import os, sys
for p in sys.stdin.read().split("\0"):
    if p:
        os.setxattr(p, "user.component", sys.argv[1].encode(), follow_symlinks=False)
' "$1"; }
find /ctx/system_files_dev \( -type f -o -type l \) -printf '/%P\0' | tag juniper
# From ublue-os/brew (COPY --from=brew /system_files /, plus the tarball in its image)
printf '%s\0' /usr/share/homebrew.tar.zst \
  /etc/profile.d/brew-bash-completion.sh /etc/profile.d/brew.sh /etc/security/limits.d/30-brew-limits.conf \
  /usr/lib/systemd/system-preset/01-homebrew.preset /usr/lib/systemd/system/brew-{setup,update,upgrade}.service \
  /usr/lib/systemd/system/brew-{update,upgrade}.timer /usr/share/fish/vendor_conf.d/ublue-brew.fish | tag homebrew

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
rm -rf /tmp/nvim.*
