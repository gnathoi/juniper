# Show Pi temperature, throttling and clock speed, and whether the Tailscale join gave up
pi-status:
    sudo vcgencmd measure_temp
    sudo vcgencmd get_throttled
    sudo vcgencmd measure_clock arm
    @if [ -e /var/lib/juniper/tailscale-join-gave-up ] && ! tailscale ip -4 >/dev/null 2>&1; then echo "Tailscale: gave up joining ($(cat /var/lib/juniper/tailscale-join-gave-up)); key deleted. Run: ujust tailscale-up"; fi

# Bootloader EEPROM: show status, or `apply` to stage the latest default release for the next
# reboot. Manual on purpose: EEPROM writes have no tryboot fallback.
pi-eeprom action="status":
    #!/usr/bin/bash
    set -euo pipefail
    # rpi-eeprom-update exits 1 when an update is available, which isn't an error here.
    case {{ quote(action) }} in
      status) sudo rpi-eeprom-update || true ;;
      apply)
        sudo rpi-eeprom-update || true
        read -rp "Stage this bootloader update for the next reboot? Don't cut power during it. [y/N] " a
        [[ $a == [yY] ]] || { echo "Nothing staged."; exit 0; }
        sudo rpi-eeprom-update -a
        echo "Reboot when convenient (sudo reboot) to apply it." ;;
      *) echo "usage: ujust pi-eeprom [status|apply]" >&2; exit 2 ;;
    esac
