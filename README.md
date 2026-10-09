# Juniper

Batteries-included, headless [bootc](https://bootc-dev.github.io/bootc/) image for
Raspberry Pi 4/5, layered on the AlmaLinux RPi bootc image. Tailscale-first networking,
Podman quadlets, Distrobox, Homebrew, `ujust`, automatic updates with firmware rollback.

Status: under construction.

## fastfetch (`juniper` image)

Illustrative mock-up of a Pi 5 4GB; on a real Pi the foliage is green, the berries blue,
and the values are live. The login banner then adds Juniper's status block
(Tailscale IP + firewall state, pending update and reboot window, a tip).

```
               .               juniper@juniper
              /|\              ---------------
             //|\             OS: Juniper 20261009 (AlmaLinux 10 bootc) aarch64
        .   ///|\\   .        Host: Raspberry Pi 5 Model B Rev 1.0
       /|\   \|//   /|\       Kernel: Linux 6.12.47-v8.2.el10
      //|\ o  |  o //|\      Uptime: 3 days, 4 hours, 12 mins
     ///|\\  \|/  ///|\\     CPU: BCM2712 (4) @ 2.40 GHz - 51.6°C
        \\ o | o ////        Memory: 1.12 GiB / 3.95 GiB (28%)
     .   \\\|/////   .       Swap: 0 B / 1.97 GiB (0%)
    /|\  o \\|/// o  /|\      Disk (/var): 6.84 GiB / 57.3 GiB (12%) - xfs
   //|\\  o \|/ o  ////|\   Local IP (wlan0): 192.168.1.42/24
        \\\|//////
          o   |   o
              |
             _|_
```
