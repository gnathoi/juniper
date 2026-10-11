# SSH from the local network after Tailscale lockdown: status | on [CIDR...] | for 2h [CIDR...] | off
[positional-arguments]
lan-ssh *args:
    @sudo /usr/libexec/juniper/lan-ssh "$@"

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
