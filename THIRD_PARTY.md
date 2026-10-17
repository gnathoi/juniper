# Third-party components

Juniper's own files are Apache-2.0 ([LICENSE](LICENSE)). The images redistribute these
components, unmodified, under their own licenses. License texts are in the images under
`/usr/share/licenses` (Juniper's own under `/usr/share/licenses/juniper`).

| Component | License | Source |
|---|---|---|
| AlmaLinux RPi bootc base image: AlmaLinux 10 packages (kernel, systemd, coreutils, …) | per package (GPL-2.0, LGPL, MIT, …; see `rpm -qi`) | quay.io/almalinuxorg/almalinux-bootc-rpi, repo.almalinux.org |
| Raspberry Pi kernel (`raspberrypi2-kernel4`) | GPL-2.0 | AlmaLinux `raspberrypi` repo |
| Raspberry Pi boot firmware (`start*.elf`, `fixup*.dat`, `bootcode.bin`) | Broadcom redistributable, Raspberry Pi devices only (`LICENCE.broadcom`, shipped alongside) | AlmaLinux `raspberrypi` repo |
| `linux-firmware-raspberrypi` (Wi-Fi/Bluetooth) | redistributable, unmodified | AlmaLinux `raspberrypi` repo |
| `rpi-eeprom`, `rpi-eeprom-firmware` | BSD-3-Clause (tools); Raspberry Pi bootloader images | AlmaLinux `raspberrypi` repo |
| rpi-bootc-bootloader (in the base image) | BSD-2-Clause OR Apache-2.0 | github.com/kfox1111/rpi-bootc-bootloader |
| raspberrypi/utils `rpifwcrypto` (`rpi-fw-crypto`, `librpifwcrypto`), built from commit `61371fa6d93463c5451131f7bb68ae145aaf1e7a` | BSD-3-Clause | https://github.com/raspberrypi/utils |
| Tailscale | BSD-3-Clause (the RPM's tag says MIT; upstream is BSD-3) | pkgs.tailscale.com, github.com/tailscale/tailscale |
| EPEL packages: age (BSD-3-Clause), distrobox (GPL-3.0), fastfetch (MIT), just (CC0-1.0) | as listed | EPEL 10 |
| podman, firewalld, cloud-init, avahi, NetworkManager, … | per package | AlmaLinux AppStream/BaseOS |
| ublue-os/brew: Homebrew tarball, profile scripts and units (`juniper` image) | Apache-2.0 | github.com/ublue-os/brew |
| Homebrew | BSD-2-Clause | github.com/Homebrew/brew |
| starship's `plain-text-symbols` preset, as `/usr/share/juniper/starship.toml` (`juniper` image) | ISC | github.com/starship/starship |
| node_exporter (only if you run `ujust enable-metrics`; pulled on the device) | Apache-2.0 | quay.io/prometheus/node-exporter |
| DankMaterialShell (dms, dms-cli), dms-greeter, dgop (`juniper-desktop`) | MIT | COPRs avengemedia/dms, avengemedia/danklinux |
| quickshell (`juniper-desktop`) | LGPL-3.0-only AND GPL-3.0-only | COPR avengemedia/danklinux |
| matugen (`juniper-desktop`) | GPL-2.0-or-later | COPR avengemedia/danklinux |
| cliphist (`juniper-desktop`) | GPL-3.0-or-later | COPR avengemedia/danklinux |
| Material Symbols fonts (`juniper-desktop`) | Apache-2.0 | COPR avengemedia/danklinux |
| zirconium/zdots: niri key bindings, DMS integration, `dms.kdl`, greeter wiring, cli-policy (adapted) | Apache-2.0 | github.com/zirconium-dev/zdots |

The juniper-berry wallpaper (`juniper-desktop`) is original artwork, CC0-1.0.

Juniper builds `FROM` the AlmaLinux image; no files from AlmaLinux/bootc-images-rpi
(GPL-3.0 build tooling) are copied. Tools installed later by Homebrew (`Brewfile`) or
inside distrobox containers are downloaded on the device under their own licenses.

## Source code

Juniper's source is this repository. The images contain only unmodified upstream binaries
besides it (rpi-fw-crypto is built from unmodified upstream source); their corresponding
source is available from:

- AlmaLinux packages (including the Raspberry Pi kernel and firmware): source RPMs at
  [vault.almalinux.org](https://vault.almalinux.org/) and
  [git.almalinux.org](https://git.almalinux.org/).
- EPEL packages: [Fedora Koji](https://koji.fedoraproject.org/) (`epel10` builds).
- Tailscale: [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) at the
  shipped version's tag.
- rpi-fw-crypto: [github.com/raspberrypi/utils](https://github.com/raspberrypi/utils) at the
  commit pinned in `build_files/fwcrypto.lock` (built unmodified, `rpifwcrypto/`).
- ublue-os/brew and Homebrew: the repositories above; the pinned image digest is in the
  `Containerfile`.

Each published image carries a signed SPDX SBOM attestation listing the exact package
versions (`cosign verify-attestation --type spdxjson`). If you need the source for a
specific release and can't find it upstream, open an issue and it will be provided, for at
least three years after that release.
