# Juniper

Headless [bootc](https://bootc-dev.github.io/bootc/) images for Raspberry Pi 4/5 (incl.
400/500, CM4/CM5), layered on the AlmaLinux RPi bootc image in the spirit of Bluefin and
Bazzite.

| | `juniper-minimal` | `juniper` |
|---|---|---|
| Purpose | appliance base — build `FROM` it | dev box |
| Tailscale, flash-time join, firewall lockdown, `ujust lan-ssh` | yes | yes |
| Podman + quadlets, nightly `podman auto-update`, firewalld | yes | yes |
| cloud-init first boot, secrets scrubbed from the boot partition | yes | yes |
| Signed nightly updates, reboot window, firmware tryboot fallback | yes | yes |
| zram, journald cap, hardware watchdog, `noatime` | yes | yes |
| `ujust` core: update, update-schedule, lan-ssh, tailscale-*, pi-status, enable-metrics | yes | yes |
| Login status (Tailscale, update state) | yes | yes |
| Juniper logo + system summary at login |  | yes |
| Homebrew, distrobox, git, tmux, neovim, btop, ripgrep, fzf |  | yes |
| `ujust devbox`, `ujust install-podlet` |  | yes |

Images: `ghcr.io/gnathoi/juniper-minimal` and `ghcr.io/gnathoi/juniper`. Every image,
disk image and checksum file is cosign-signed; devices only accept signed OS updates
(`cosign verify --key system_files/usr/share/pki/containers/juniper.pub ghcr.io/gnathoi/juniper:latest`).
Signatures are enforced for everything under `ghcr.io/gnathoi`, so any future image published
there must be signed with the same key.

## On login

![Juniper login on a Raspberry Pi 5: berry logo, system summary, Tailscale and update status](docs/images/login.svg)

Mock-up of a Pi 5 4GB running the `juniper` image. `juniper-minimal` shows just the status
block (Image, Tailscale, Update, Tip), without the logo and system summary.

## Install

1. Create a **tagged**, one-off, pre-approved auth key at
   <https://login.tailscale.com/admin/settings/keys>. Tagged devices never expire, so the
   lockdown can't lock you out later.
2. Flash with Raspberry Pi Imager (Juniper build) using our OS list:
   `rpi-imager --repo https://github.com/gnathoi/juniper/releases/latest/download/os-list.json`
   and fill in user, SSH key, Wi-Fi, timezone and the Tailscale key.
   Or download `juniper-*.raw.xz` / `juniper-minimal-*.raw.xz` (+ its `.bundle`) from
   Releases, verify it, flash it with any tool, and edit `user-data` on the small FAT
   partition (see `README.txt` there):

       cosign verify-blob --key system_files/usr/share/pki/containers/juniper.pub \
         --bundle juniper-YYYYMMDD.raw.xz.bundle juniper-YYYYMMDD.raw.xz
3. Boot. The Pi joins your tailnet; `ssh <user>@<hostname>` over Tailscale.

## Everyday commands

| Command | What it does |
|---|---|
| `ujust` | list everything |
| `ujust update` | update and reboot now |
| `ujust update-schedule 03:30` / `off` | move or disable the reboot window |
| `ujust lan-ssh on` / `off` | re-open SSH on the local network (escape hatch) |
| `ujust tailscale-up` | log in to Tailscale interactively |
| `ujust enable-metrics` | node_exporter on :9100 over Tailscale |
| `ujust pi-status` | temperature and throttling |
| `ujust devbox` (juniper) | mutable Fedora dev container |

The `juniper` image's Homebrew comes from Bluefin's `ublue-os/brew` and updates and
upgrades your brew packages automatically (`brew-update.timer`, `brew-upgrade.timer`).

## Build your own appliance

See [examples/appliance](examples/appliance): `FROM ghcr.io/gnathoi/juniper-minimal`, add
packages and quadlets, push, `bootc switch` the device to it.

## Switch an existing AlmaLinux RPi bootc system

    sudo bootc switch --enforce-container-sigpolicy ghcr.io/gnathoi/juniper:latest

## Build

    just check                                   # lint + unit tests
    just image=juniper-minimal build             # arm64 (arm64 host or qemu-user-static)
    just image=juniper-minimal test-image
    just bump-brew                               # move the Homebrew pin (verifies signature)
    sudo just build-raw ghcr.io/gnathoi/juniper:latest

CI builds both images on every push, publishes from `main` weekly (Monday 02:00 UTC) and
on demand (Actions → build → Run workflow; tick "build_raw" for disk images + a release).
Each publish reports how many layers and MiB a device downloads.

## License

Apache-2.0. See THIRD_PARTY.md for bundled components.
