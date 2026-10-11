# Allow (on) or block (off) SSH from the local network after Tailscale lockdown
lan-ssh state:
    #!/usr/bin/bash
    set -euo pipefail
    case {{ quote(state) }} in
      on) sudo firewall-cmd --permanent --zone=drop --add-service=ssh ;;
      off) sudo firewall-cmd --permanent --zone=drop --remove-service=ssh ;;
      *) echo "usage: ujust lan-ssh on|off" >&2; exit 2 ;;
    esac
    sudo firewall-cmd --reload

# Log in to Tailscale (prints a login URL), then lock the firewall down to it
tailscale-up:
    sudo tailscale up --ssh
    sudo rm -f /var/lib/juniper/tailscale-join-gave-up
    sudo systemctl start juniper-lockdown.service
    echo "Tip: disable key expiry for this machine in the Tailscale admin console."
    echo "Once locked down, an expired key cuts off access ('ujust lan-ssh on' only helps if you still have a way in)."

# Turn Tailscale SSH on or off
tailscale-ssh state:
    #!/usr/bin/bash
    set -euo pipefail
    case {{ quote(state) }} in
      on) sudo tailscale set --ssh=true ;;
      off) sudo tailscale set --ssh=false ;;
      *) echo "usage: ujust tailscale-ssh on|off" >&2; exit 2 ;;
    esac

# Show or hide the login status banner for your user
toggle-motd:
    #!/usr/bin/bash
    set -euo pipefail
    f="$HOME/.config/juniper/no-motd"
    if [[ -e $f ]]; then rm "$f"; echo "Login banner on."; else mkdir -p "${f%/*}"; touch "$f"; echo "Login banner off."; fi
