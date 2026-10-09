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
# regular files only: Linux rejects user.* xattrs on symlinks
find /ctx/system_files_dev -type f -printf '/%P\0' | tag juniper
# From ublue-os/brew (bind-mounted at /brew): everything COPY'd in, plus the tarball
find /brew -type f -printf '/%P\0' | tag homebrew

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
rm -rf /tmp/nvim.*
