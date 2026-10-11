# Juniper

[![build](https://github.com/gnathoi/juniper/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/gnathoi/juniper/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/gnathoi/juniper?label=release)](https://github.com/gnathoi/juniper/releases/latest)
[![license](https://img.shields.io/github/license/gnathoi/juniper)](LICENSE)
[![signed with cosign](https://img.shields.io/badge/signed-cosign-2a6db0?logo=sigstore)](system_files/usr/share/pki/containers/juniper.pub)
![Raspberry Pi 4 | 5](https://img.shields.io/badge/Raspberry%20Pi-4%20%7C%205-c51a4a?logo=raspberrypi&logoColor=white)
[![bootc on AlmaLinux 10](https://img.shields.io/badge/bootc-AlmaLinux%2010-0f4266)](https://github.com/AlmaLinux/bootc-images-rpi)

Opinionated [bootc](https://bootc-dev.github.io/bootc/) images for Raspberry Pi 4/5 (incl.
400/500, CM4/CM5), layered on the [AlmaLinux RPi bootc image](https://github.com/AlmaLinux/bootc-images-rpi) in the spirit of Bluefin and
Bazzite.

![Juniper login on a Raspberry Pi 5: berry logo, system summary, Tailscale and update status](docs/images/login.svg)

A Pi 5 running `juniper`. `juniper-minimal` shows just the status block.

| | `juniper-minimal` | `juniper` | `juniper-desktop` |
|---|---|---|---|
| Purpose | appliance base | dev box | dev box with a screen (experimental) |
| Interface | headless | headless | niri desktop |
| Tailscale, flash-time join, firewall lockdown, `ujust lan-ssh` | yes | yes | yes |
| Podman + quadlets, nightly `podman auto-update`, firewalld | yes | yes | yes |
| cloud-init first boot, secrets scrubbed from the boot partition | yes | yes | yes |
| Signed weekly updates, reboot window, firmware tryboot fallback | yes | yes | yes |
| zram, journald cap, hardware watchdog, `noatime` | yes | yes | yes |
| `ujust` core: update, update-schedule, lan-ssh, tailscale-*, pi-status, enable-metrics | yes | yes | yes |
| Login status (Tailscale, update state) | yes | yes | yes |
| Juniper logo + system summary at login | no | yes | yes |
| Homebrew, distrobox, git; zellij, neovim, btop, ripgrep, fzf via a Brewfile | no | yes | yes |
| `ujust devbox`, `ujust install-podlet` | no | yes | yes |
| Firefox and the Bazaar app store (Flathub) | no | no | yes |

## Images

Dev box (minimal + developer tools):

```
ghcr.io/gnathoi/juniper:latest
```

Appliance base, to build `FROM`:

```
ghcr.io/gnathoi/juniper-minimal:latest
```

Desktop (experimental, published but untested on hardware; `juniper` plus niri, Firefox and
Bazaar):

```
ghcr.io/gnathoi/juniper-desktop:latest
```

Every image, disk image and checksum is cosign-signed, and Pis only accept signed OS
updates (required for everything under `ghcr.io/gnathoi`). Verify with:

```
cosign verify --key system_files/usr/share/pki/containers/juniper.pub ghcr.io/gnathoi/juniper:latest
```

## Tested hardware

| Hardware | Boot media | `juniper-minimal` | `juniper` | `juniper-desktop` |
|---|---|---|---|---|
| Raspberry Pi 5 | microSD | ✅ tested 2026-10-10 | ✅ tested 2026-10-10 | untested |
| Raspberry Pi 5 | USB or NVMe | untested | untested | untested |
| Raspberry Pi 4, 400 | microSD or USB | untested | untested | untested |
| Raspberry Pi 500, CM4, CM5 | any | untested | untested | untested |

"Tested" means the full hardware acceptance run in [docs/acceptance.md](docs/acceptance.md):
first boot, the Tailscale join and lockdown, signed updates through tryboot, and falling back
from a broken update. The other boards should work, since the AlmaLinux base supports them,
but nobody has checked yet. **If you have one, please try an image and
[report how it went](https://github.com/gnathoi/juniper/issues/new?template=hardware-report.yml)**,
even if everything just worked.

## Install

1. Create a **tagged**, one-off, pre-approved auth key at
   <https://login.tailscale.com/admin/settings/keys>. Pick a short expiry that matches when you
   will deploy; the device deletes an unused key after 14 days or as soon as Tailscale rejects
   it. Tagged devices never expire, so the lockdown can't lock you out later. The key turns on Tailscale SSH, so your
   [tailnet policy](https://tailscale.com/kb/1337/policy-syntax) needs to let you in to that
   tag. Keep it narrow: an admin group, SSH as your login user only (no root: use `sudo`),
   and only the ports you use, in place of the default allow-all rule. For example
   (`you` is the `user` in your flash config):

   ```json
   {
     "groups": {"group:admins": ["alice@example.com"]},
     "tagOwners": {"tag:server": ["group:admins"], "tag:monitoring": ["group:admins"]},
     "grants": [
       {"src": ["group:admins"], "dst": ["tag:server"], "ip": ["tcp:22"]},
       {"src": ["tag:monitoring"], "dst": ["tag:server"], "ip": ["tcp:9100"]}
     ],
     "ssh": [
       {"action": "check", "src": ["group:admins"], "dst": ["tag:server"], "users": ["you"]}
     ]
   }
   ```

   `check` asks you to re-authenticate in the browser every 12 hours; use `accept` only for
   automation (a tagged CI or backup device) with its own narrow rule.
   `"users": ["autogroup:nonroot"]` also works, but lets the admin group log in as any
   non-root account on the Pi. The second grant is for `ujust enable-metrics`
   (node_exporter on :9100) from a monitoring host tagged `tag:monitoring`; drop it if you
   don't use it. See [grants](https://tailscale.com/kb/1324/grants) and
   [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh).
2. Flash an SD card or USB disk: with `just flash` on Linux (below), or by hand on any OS.
3. Boot. The Pi joins your tailnet; `ssh <user>@<hostname>` over Tailscale.

### Flash with `just flash` (Linux only, for now)

From a clone of this repo. Needs `just`, `cosign`, `curl`, `jq`, `xz`, Python 3 with PyYAML,
and `run0` or `sudo` for the write.

    install -Dm600 examples/flash.yaml ~/.config/juniper/flash.yaml   # fill it in
    just flash /dev/sdX ~/.config/juniper/flash.yaml

The config ([`examples/flash.yaml`](examples/flash.yaml)) holds the image (`juniper`,
`juniper-minimal` or the experimental `juniper-desktop`), hostname, user, SSH keys, timezone,
Tailscale key and Wi-Fi. `just flash` downloads the latest release (or pass a tag or a local
`.raw.xz` as a third argument), checks its cosign signature, refuses anything but a
removable, USB or SD card disk, shows what it will write and asks for a y/N before erasing
it. For `juniper-desktop` it also asks for a password, for logging in and for `sudo` (the
headless images ask only if the config has `password: prompt`); only a hash is written.
With a password, `sudo` asks for it; without one, `sudo` needs none (SSH is key-only on
every image either way).

### Flash by hand (any OS)

Download `juniper-*.raw.xz`, `juniper-minimal-*.raw.xz` or (experimental)
`juniper-desktop-*.raw.xz` and its `.bundle` from
[Releases](https://github.com/gnathoi/juniper/releases), verify it, and flash it with any
tool:

    cosign verify-blob --key system_files/usr/share/pki/containers/juniper.pub \
      --bundle juniper-YYYYMMDD.raw.xz.bundle juniper-YYYYMMDD.raw.xz

Then edit `user-data` on the small FAT partition and, for Wi-Fi, add `network-config` (see
`README.txt` there).

## On the Pi

Run `ujust` to list Juniper's commands (updates, reboot window, LAN SSH escape hatch,
Tailscale, metrics, Pi status, and on `juniper` the dev box).

The `juniper` image's Homebrew comes from Bluefin's `ublue-os/brew` and updates and
upgrades your brew packages automatically (`brew-update.timer`, `brew-upgrade.timer`).

### The experimental desktop

`juniper-desktop` is experimental: it is built, tested in CI and published (signed image and
disk image), but nobody has run it on hardware yet, and it isn't in Raspberry Pi Imager's
list.

It boots to a text login prompt (greetd's agreety); niri starts after you log in with your
password. Graphical greeter later. `just flash` and `ujust switch` both require a password
for the first user (uid 1000), and on a flashed desktop `sudo` asks for it too.

- `ujust desktop-config` writes a personal niri config that includes Juniper's defaults (bar,
  notifications, idle lock, key bindings).
- `ujust desktop-lock-idle on|off` turns the lock after 10 minutes idle on or off.
- `ujust flatpak-setup` retries the first-boot install of Firefox and Bazaar.

A pending update's reboot waits while the desktop is in use (not idle for 30 minutes), for at
most 7 days after the first deferral. A deferred update is retried hourly and applies once
the desktop is idle, which can be outside the reboot window; a notification says so, with the
deadline. `ujust update-schedule off` turns these reboots off too. Under tryboot the update
also needs greetd to be running, or it falls back.

## Build your own appliance

See [examples/appliance](examples/appliance): `FROM ghcr.io/gnathoi/juniper-minimal`, add
packages and quadlets, push, `bootc switch` the device to it.

## Switch an existing AlmaLinux RPi bootc system

The first switch is trust-on-first-use: the starting system doesn't check Juniper's signature
yet. So verify the image with [`juniper.pub`](system_files/usr/share/pki/containers/juniper.pub)
(this repo) and switch to exactly the digest that was verified, not the tag, which could
move in between:

    digest=$(cosign verify --key juniper.pub ghcr.io/gnathoi/juniper:latest \
      | jq -r '.[0].critical.image."docker-manifest-digest"')
    sudo bootc switch "ghcr.io/gnathoi/juniper@$digest"
    sudo reboot

That boot is pinned to the digest and would never update. Once it runs Juniper, whose policy
checks the signature on every pull, point it back at the tag:

    ujust switch ghcr.io/gnathoi/juniper:latest

On a Juniper device, `ujust switch IMAGE` switches and reboots in one step. A plain reboot
keeps the current image; use `ujust switch`/`ujust update`.

## Build

    just check                                   # lint + unit tests
    just image=juniper-minimal build             # arm64 (arm64 host or qemu-user-static)
    just image=juniper-minimal test-image
    just bump-brew                               # move the Homebrew pin (verifies signature)
    sudo just build-raw ghcr.io/gnathoi/juniper:latest

## Release schedule

A new release (both signed images, disk images and release notes) is published every
Monday at 02:00 UTC with that week's dependency and security updates. Pis download it daily
and reboot into it on Tuesday at 04:00 local time, within a 90-minute window; change that
with `ujust update-schedule`, or apply it now with `ujust update`.

## Acknowledgements

Juniper stands on other people's work:

- [AlmaLinux's bootc images for Raspberry Pi](https://github.com/AlmaLinux/bootc-images-rpi),
  the base image, and [bootc](https://github.com/bootc-dev/bootc) itself.
- [rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader), which makes Pi
  firmware tryboot and rollback work with bootc.
- [Universal Blue](https://universal-blue.org)'s [Bluefin](https://github.com/ublue-os/bluefin)
  and [Bazzite](https://github.com/ublue-os/bazzite), where the overall approach and `ujust`
  come from, and [ublue-os/brew](https://github.com/ublue-os/brew) for Homebrew on bootc.
- [Zirconium](https://github.com/zirconium-dev/zirconium), whose niri setup informs the
  desktop image.

## License

Apache-2.0. See [THIRD_PARTY.md](THIRD_PARTY.md) for bundled components and where to get
their source.

Raspberry Pi is a trademark of Raspberry Pi Ltd. AlmaLinux is a trademark of the AlmaLinux
OS Foundation. Juniper is an independent project, not affiliated with or endorsed by either.
