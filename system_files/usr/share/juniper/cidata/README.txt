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

Both files are wiped from this partition after first boot.
