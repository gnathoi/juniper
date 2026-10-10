# Desktop log-in: `on` logs the first user straight into niri at boot, `off` asks for a password
desktop-autologin state="":
    #!/usr/bin/bash
    set -euo pipefail
    m=/etc/juniper/desktop-no-autologin
    case {{ quote(state) }} in
      on) sudo rm -f "$m" ;;
      off) sudo mkdir -p /etc/juniper && sudo touch "$m" ;;
      "") if [[ -e $m ]]; then echo "auto-login: off"; else echo "auto-login: on"; fi; exit 0 ;;
      *) echo "usage: ujust desktop-autologin [on|off]" >&2; exit 2 ;;
    esac
    echo "Takes effect the next time greetd starts (reboot)."
