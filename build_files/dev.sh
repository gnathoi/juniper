#!/usr/bin/env bash
# Developer layer on top of the minimal image (Containerfile stage "juniper").
# Homebrew's tarball and units were already copied from the pinned ublue-os/brew image.
set -xeuo pipefail

dnf -y install distrobox fastfetch btop ripgrep fzf neovim tmux git-core zstd
dnf clean all

cp -a /ctx/system_files_dev/. /

systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
rm -rf /tmp/nvim.*
