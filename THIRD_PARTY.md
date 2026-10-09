# Third-party components

Juniper's own files are Apache-2.0. The image redistributes these components under their
own licenses (full texts in the image under /usr/share/licenses):

| Component | License | Source |
|---|---|---|
| AlmaLinux RPi bootc base image | various (RPM licenses); build tooling GPL-3.0 | quay.io/almalinuxorg/almalinux-bootc-rpi |
| rpi-bootc-bootloader (in base) | see upstream | github.com/kfox1111/rpi-bootc-bootloader |
| Tailscale | BSD-3-Clause | pkgs.tailscale.com |
| Homebrew | BSD-2-Clause | github.com/Homebrew/brew |
| fastfetch | MIT | EPEL |
| distrobox | GPL-3.0 | EPEL |
| just | CC0-1.0 | EPEL |
| podman | Apache-2.0 | AlmaLinux AppStream |

Juniper only builds `FROM` the AlmaLinux image; no files from bootc-images-rpi are copied.
