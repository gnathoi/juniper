Juniper for Raspberry Pi 4/5
============================

Easiest: flash with Raspberry Pi Imager using the Juniper OS list, which fills in your
user, SSH key, Wi-Fi and Tailscale key.

By hand: edit user-data on this partition (see the comments inside). For Wi-Fi, create a
file named network-config here:

  network:
    version: 2
    wifis:
      wlan0:
        dhcp4: true
        access-points:
          "MyNetwork":
            password: "secret"

Edits here apply only on the very first boot. Afterwards user-data is replaced by this
template and network-config is removed. To fix a Wi-Fi typo later, use Ethernet or re-flash.
