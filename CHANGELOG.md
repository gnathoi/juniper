# Changelog

Changes that matter to someone running a Juniper image or building `FROM` one. Add an entry
under **Unreleased** in the same PR as the change, grouped as Added, Changed, Fixed or
Removed. Dependency bumps and docs-only changes don't need one; the release lists every PR
anyway.

Each release (the weekly train, a manual publish with disk images, or a `v*` tag) uses
Unreleased as its release notes, then moves those entries under the release's tag here.

## Unreleased

### Added

- `just flash DEVICE CONFIG`: flash a signed release to an SD card or USB disk with
  first-boot settings (user, SSH keys, Tailscale key, Wi-Fi) from a YAML file
  (`examples/flash.yaml`).

## build-20261010 (2026-10-10)

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
