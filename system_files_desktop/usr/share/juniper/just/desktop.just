# Create your own niri config (~/.config/niri/config.kdl) that includes Juniper's defaults
desktop-config:
    #!/usr/bin/bash
    set -euo pipefail
    f=$HOME/.config/niri/config.kdl
    if [[ -e $f ]]; then echo "$f exists; leaving it alone."; exit 0; fi
    mkdir -p "${f%/*}"
    printf '%s\n' '// Juniper defaults first: they lock the screen at login. Keep this line.' \
      'include "/usr/share/juniper/niri/juniper.kdl"' '' '// Your settings below override the defaults.' >"$f"
    niri validate -c "$f" && echo "Created $f"

# Lock the screen after 10 minutes idle: on (default) or off
desktop-lock-idle state="":
    #!/usr/bin/bash
    set -euo pipefail
    f=$HOME/.config/juniper/no-idle-lock
    case {{ quote(state) }} in
      on) rm -f "$f"; echo "Lock on idle: on (from your next login)." ;;
      off) mkdir -p "${f%/*}"; touch "$f"; echo "Lock on idle: off (from your next login)." ;;
      "") [[ -e $f ]] && echo "Lock on idle: off" || echo "Lock on idle: on" ;;
      *) echo "usage: ujust desktop-lock-idle [on|off]" >&2; exit 2 ;;
    esac

# Install (or finish installing) Firefox and the Bazaar app store from Flathub
flatpak-setup:
    sudo /usr/libexec/juniper/flatpak-setup
