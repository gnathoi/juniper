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
| Signed weekly updates, reboot window, firmware tryboot fallback | yes | yes |
| zram, journald cap, hardware watchdog, `noatime` | yes | yes |
| `ujust` core: update, update-schedule, lan-ssh, tailscale-*, pi-status, enable-metrics | yes | yes |
| Login status (Tailscale, update state) | yes | yes |
| Juniper logo + system summary at login |  | yes |
| Homebrew, distrobox, git, tmux, neovim, btop, ripgrep, fzf |  | yes |
| `ujust devbox`, `ujust install-podlet` |  | yes |

## Images

Dev box (minimal + developer tools):

```
ghcr.io/gnathoi/juniper:latest
```

Appliance base, to build `FROM`:

```
ghcr.io/gnathoi/juniper-minimal:latest
```

Every image, disk image and checksum is cosign-signed, and Pis only accept signed OS
updates (required for everything under `ghcr.io/gnathoi`). Verify with:

```
cosign verify --key system_files/usr/share/pki/containers/juniper.pub ghcr.io/gnathoi/juniper:latest
```

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
| `ujust switch IMAGE` | switch to another image and reboot into it now |
| `ujust update-schedule` | show the update and reboot timers |
| `ujust update-schedule tue 04:00` / `daily 03:30` / `05:00` / `off` | set day and time, change time only, or disable the weekly reboot window |
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

    cosign verify --key <juniper.pub> ghcr.io/gnathoi/juniper:latest
    sudo bootc switch ghcr.io/gnathoi/juniper:latest
    sudo /usr/libexec/juniper/apply-update   # only on a Juniper device: `ujust switch IMAGE` does both

The first switch is trust-on-first-use, so verify the image first with
[`juniper.pub`](system_files/usr/share/pki/containers/juniper.pub) (this repo). After the
switch, Juniper's policy enforces the signature on every later update. A plain reboot keeps
the current image; use `ujust switch`/`ujust update`.

## Build

    just check                                   # lint + unit tests
    just image=juniper-minimal build             # arm64 (arm64 host or qemu-user-static)
    just image=juniper-minimal test-image
    just bump-brew                               # move the Homebrew pin (verifies signature)
    sudo just build-raw ghcr.io/gnathoi/juniper:latest

## Release train

Dependabot PRs (checked Saturdays) merge themselves once CI is green, except major version
bumps, which wait for manual review. Merges are not rebuilt on `main`, so Monday's run is the
first full test of them (GitHub emails you if a scheduled run fails). Your pushes to `main`
build and test but do not publish. One weekly run (Monday 02:00 UTC) publishes both signed
images, the disk images and a release. Pis then reboot into it on Tuesday 04:00 local time,
plus up to 90 minutes of random delay; change that with `ujust update-schedule`. For
something urgent, run `gh workflow run build` on `main` to publish the images now (add
`-f build_raw=true` for disk images and a release), then `ujust update` on devices;
otherwise they apply it at the next Tuesday window. Each publish reports how many layers
and MiB a device downloads.

Note user-facing changes under Unreleased in [CHANGELOG.md](CHANGELOG.md) in the same PR.
Each release uses that section as its notes (plus the list of merged PRs), then moves it
under the release's tag on `main`.

## License

Apache-2.0. See THIRD_PARTY.md for bundled components.
