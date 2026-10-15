# Lock the screen after 10 minutes idle: on (default) or off; no argument shows which
desktop-lock-idle state="":
    /usr/libexec/juniper/desktop-lock-idle {{ quote(state) }}

# Re-apply Juniper's desktop dotfiles now (files you changed are kept)
dots-update:
    /usr/libexec/juniper/dots update

# Put Juniper's niri config (niri) or all its desktop dotfiles (all) back; yours go to a backup
dots-reset scope="niri":
    /usr/libexec/juniper/dots reset {{ quote(scope) }}

# Turn the daily dotfiles refresh off or on
toggle-auto-dots:
    #!/usr/bin/bash
    set -euo pipefail
    f="$HOME/.config/juniper/no-auto-dots"
    if [[ -e $f ]]; then rm "$f"; echo "Daily dotfiles refresh on."; else mkdir -p "${f%/*}"; touch "$f"; echo "Daily dotfiles refresh off."; fi

# Install (or finish installing) Firefox and the Bazaar app store from Flathub
flatpak-setup:
    sudo /usr/libexec/juniper/flatpak-setup
