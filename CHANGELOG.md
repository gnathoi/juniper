# Changelog

Changes that matter to someone running a Juniper image or building `FROM` one. Add an entry
under **Unreleased** in the same PR as the change, grouped as Added, Changed, Fixed or
Removed. Dependency bumps and docs-only changes don't need one; the release lists every PR
anyway.

Each release (the weekly train, a manual publish with disk images, or a `v*` tag) uses
Unreleased as its release notes, then moves those entries under the release's tag here.

## Unreleased

## build-20261010 (2026-10-10)

### Changed

- Smaller, Pi-specific initramfs (46 → 29 MB; the initrd stage of boot is about 30% faster
  on a Pi 5), regenerated each build from the image's own, updated systemd and ostree. It
  drops network root, VM, RAID/LVM, TPM/FIDO unlock, FIPS and btrfs support; LUKS (`crypt`)
  stays.

### Fixed

- `ujust pi-eeprom` works: the image now has `strings` (binutils), which `rpi-eeprom-update`
  needs but its package doesn't require.
- `just flash` checks a cached disk image against the release's signed `SHA256SUMS` on every
  run and downloads it again if it changed, so a same-day re-release never flashes the
  older image. `disk/flash.sh --fetch-only [TAG] [IMAGE]` downloads and verifies only.

### Added

- `ujust pi-eeprom` shows whether a newer Raspberry Pi bootloader EEPROM is available;
  `ujust pi-eeprom apply` stages it for the next reboot (manual only: EEPROM writes have
  no tryboot fallback).
- License texts for Juniper, Tailscale and ublue-os/brew under `/usr/share/licenses`, and
  a source-code section in THIRD_PARTY.md.

### Changed

- `juniper`: zellij, neovim, btop, ripgrep and fzf now come from Homebrew
  (`/usr/share/juniper/Brewfile`), installed at your first login and kept current by
  `brew-upgrade.timer`; `ujust brew-tools` re-runs it. tmux is no longer included
  (`brew install tmux` if you want it).
- Headless boot settings (no splash, no camera/display auto-detect) in each boot entry's
  `rpi-config.txt`, so they're covered by tryboot.
- `os-release` `NAME` is `Juniper` (`ID` stays `almalinux`).

### Fixed

- An update that drops into emergency mode (e.g. a mount that fails) now reboots after 60 s
  when it was booted via tryboot, so the Pi falls back to the previous image instead of
  waiting there.
- The boot health check accepts an IPv6-only network, and once the Pi is locked down it
  also requires SSH over the tailnet (Tailscale SSH, or sshd) to be up.
- First boot and the Wi-Fi import read the `CIDATA` partition of the disk the Pi booted
  from, never one on another attached disk.

### Added

- `just flash DEVICE CONFIG`: flash a signed release to an SD card or USB disk with
  first-boot settings (user, SSH keys, Tailscale key, Wi-Fi) from a YAML file
  (`examples/flash.yaml`).

### Changed

- Each build applies pending AlmaLinux package updates (security errata), so the weekly
  release carries them instead of waiting for the next base image. The Pi kernel and
  firmware still come with the base image.
- `ujust enable-metrics` runs node_exporter pinned to a released digest, without
  auto-updates, as an unprivileged user with no capabilities.

### Fixed

- An interrupted first boot (power cut mid-scrub) now finishes the secret scrub on the next
  boot; cloud-init is disabled last.
- `just flash` mounts the card's CIDATA partition root-only, always unmounts it, and checks
  the card is still the one you confirmed before writing.

### Fixed

- First boot on hardware: the Tailscale join, the CIDATA secret scrub and the boot health
  check never ran. They were ordered after cloud-init's final stage, which itself runs after
  `multi-user.target`, so systemd dropped them to break the ordering cycle. CI now checks
  the boot transaction for cycles.
- Wi-Fi from `network-config` (by hand or Raspberry Pi Imager) is now applied. cloud-init
  only renders `wifis:` through netplan, which AlmaLinux doesn't have, so Juniper imports
  them into NetworkManager itself before it starts.
- The hostname from `user-data` is used as given; cloud-init no longer swaps in a name the
  router's DNS has for the Pi's DHCP address.

## build-20261009 (2026-10-09)

### Added

- Release notes come from this changelog, and each release moves its entries under its tag.

First release.

### Added

- `juniper-minimal` (appliance base) and `juniper` (dev box) bootc images for Raspberry Pi
  4/5, layered on the AlmaLinux RPi bootc image.
- Tailscale with flash-time join and firewall lockdown once joined; `ujust lan-ssh`.
- cloud-init first boot that scrubs secrets from the boot partition.
- Signed weekly updates with a reboot window (Tuesday 04:00 local, `ujust update-schedule`)
  and firmware tryboot fallback when an update fails its health check.
- Flashable `.raw.xz` disk images and a Raspberry Pi Imager OS list, cosign-signed with
  `SHA256SUMS`.
- Homebrew, distrobox and developer tools in `juniper`; `ujust devbox`.
