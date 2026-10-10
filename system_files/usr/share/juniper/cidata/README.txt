Juniper for Raspberry Pi 4/5
============================

Easiest (Linux): flash with `just flash DEVICE CONFIG` from the Juniper repo
(https://github.com/gnathoi/juniper), which writes your user, SSH keys, Wi-Fi and
Tailscale key here for you.

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
