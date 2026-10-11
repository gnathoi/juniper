# Changelog

Changes that matter to someone running a Juniper image or building `FROM` one. Add an entry
under **Unreleased** in the same PR as the change, grouped as Added, Changed, Fixed or
Removed. Dependency bumps and docs-only changes don't need one; the release lists every PR
anyway.

Each release (the weekly train, a manual publish with disk images, or a `v*` tag) uses
Unreleased as its release notes, then moves those entries under the release's tag here.

## Unreleased

## build-20261011 (2026-10-11)

### Added

- `ujust trust-images NAMESPACE PUBKEY_FILE` requires your cosign signature for every image under a namespace (derived OS images via `bootc switch`/updates, and podman workload pulls including `podman auto-update`); `ujust trust-images` lists, `ujust untrust-images` removes. Juniper's own namespace can't be changed. The appliance example now pins its workload by digest and documents signed auto-update, readiness and keeping app data safe across a rollback (part of #55)
- Status metrics for node_exporter: every image writes `juniper_*` metrics (booted and staged image digest, image build time, last healthy boot, update held or skipped, lockdown state, clock sync, kernel build time) to a textfile every 5 minutes. Re-run `ujust enable-metrics` on an existing device to serve them. README section "Monitoring" lists them with example alerts
- The login banner warns "Clock not synchronised (NTP)" when the clock is not synced
- The Pi kernel's age is now visible: release notes and the CI step summary state its build date (and any newer kernel waiting in AlmaLinux's Pi repo, with escalated wording past 14 days), and `ujust pi-status` shows the running kernel and how many days ago it was built. It never fails a release
- Tab completion for `ujust` in bash: recipe names (including image-specific ones) and fixed arguments like `lan-ssh on|off|for|status`. Adds the small `bash-completion` package to every image
- README section "If a device is lost or stolen": what a stolen card or board exposes today
  (nothing is encrypted at rest; the boot partition is unsigned) and the revocation steps.
- Local health hooks: executables in `/etc/juniper/health.d` (root-owned, not group- or
  world-writable) run with the image's hooks, so a quadlet appliance can require its
  workload to be ready (e.g. a sample stored in the last 10 minutes) before an update is
  kept. Example in `examples/appliance/health.d/`.
- An update that fails its health check under tryboot is retried at the next window; if the
  same image fails a second time it is held (recorded in `/var/lib/juniper/bad-digests`) and
  not booted again, while a newer image proceeds. The login status and `ujust pi-status` show
  a held update, and on `juniper-desktop` it gets no "Update ready" notice or deferral.
- Storage budgets for unattended devices (part of #54): the daily download skips an update
  (and says so) when under 2048 MiB is free (`MIN_FREE_MB` in `/etc/juniper/update.conf`),
  after pruning dangling images; `juniper-image-prune.timer` prunes dangling podman images
  weekly; the journal keeps 1G free; the login banner and `ujust pi-status` warn about a
  skipped update and about under 10% or 1 GiB free on `/`. README: "Storage on long-running
  devices".

### Changed

- `/etc/containers/policy.json` is now generated at every boot (`juniper-containers-policy.service`) from Juniper's base policy in `/usr/share/juniper/containers/policy.json`, which updates with the image, plus drop-ins: a derived image's in `/usr/lib/juniper/trusted-images.d`, then the local `trust-images` ones in `/etc/juniper/trusted-images.d`. No drop-in can touch a scope the base sets or anything under it. Hand edits to `policy.json`, including ones a derived image baked in, are dropped and logged: use `trust-images` on the device, or ship drop-ins under `/usr/lib/juniper/trusted-images.d` in your image (which may also tighten `default` to reject)
- `ujust lan-ssh on` now allows SSH only from the networks the Pi is directly connected to
  (IPv4 and IPv6, link-local included), or from CIDRs you give it, instead of every source.
  New: `ujust lan-ssh for 2h` (temporary, gone on reboot), `ujust lan-ssh status`, and
  validation that refuses `0.0.0.0/0`, `::/0` and other very broad prefixes without
  `--force`. Devices that ran the old command keep working, but the login banner and
  `ujust pi-status` warn that SSH is open to every network; `ujust lan-ssh on` or `off`
  removes that rule.
- Once locked down, the health check also requires Tailscale to be connected to its control
  plane: a locked device that can't reach Tailscale after an update falls back to the
  previous image.

### Fixed

- A hung `tailscale`, `ip` or `systemctl` call can no longer stall the health check: each
  probe is stopped after 10 seconds and counts as unhealthy.
- If the health check itself fails (killed at its timeout, crashed, out of memory), a tryboot
  update still falls back (`juniper-healthcheck-fallback.service`); a normal boot is left
  alone.
- `wifi.country` must be a two-letter country code: `just flash` refuses anything else, and
  the image ignores (and logs) a malformed Wi-Fi regulatory domain or interface name in
  CIDATA instead of writing it into system configuration.
- The EPEL and Tailscale package signing keys are pinned in the repository instead of
  trusted from HTTPS at every build: `epel-release` is signature-checked before it's
  installed, and `/etc/yum.repos.d/tailscale.repo` uses a local key
  (`/etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale`).

### Added

- Experimental `juniper-desktop` image (niri, Firefox and Bazaar from Flathub), published
  (signed image and disk image) but untested on hardware, and not in Raspberry Pi Imager's
  list. It boots to a text login prompt; niri starts after you log in. `just flash` can set
  a password (required for the desktop), and `sudo` then asks for it; `ujust switch` to the
  desktop asks for one. On it, a pending update's reboot waits while the desktop is in use,
  at most 7 days.

### Changed

- SSH is explicitly key-only on every image (`/etc/ssh/sshd_config.d/40-juniper.conf`), now
  that accounts can have a password.
- The health check names a failing image health hook and stops a hung one after 15 seconds
  (killed 5 seconds later if it ignores that).

## build-20261010 (2026-10-10)

### Removed

- `fzf` from both images (it came in as a weak dependency of `just`). On `juniper` it comes
  from the Brewfile, so the newer Homebrew build is the one on PATH.

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
