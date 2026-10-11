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
   and only the ports you use, in place of the default allow-all rule (a `tcp:22`-only grant
   also blocks ICMP and every other port, so add the ports for the services you run). For example
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
Tailscale, metrics, Pi status, and on `juniper` the dev box). Press Tab after `ujust` to
complete recipe names and their fixed arguments (`on`/`off`, ...) in bash.

### Lockdown and LAN SSH

Until the Pi has joined your tailnet, SSH is open on whatever network it is on. That is a
deliberate choice: if the Tailscale join fails, you can still reach the Pi over the LAN to
fix it. Once it joins, a lockdown makes the firewall drop everything except Tailscale, and
LAN SSH is closed. `ujust lan-ssh` only matters after lockdown.

If Tailscale ever goes away, re-open SSH without exposing it to the internet:

    ujust lan-ssh                       # show the state: off, scoped, or legacy-unscoped
    ujust lan-ssh on                    # allow SSH from the networks this Pi is directly on
    ujust lan-ssh on 192.168.1.0/24     # or only from the CIDRs you give (IPv4 or IPv6)
    ujust lan-ssh for 2h                # same, but runtime only: expires after 2h or on reboot
    ujust lan-ssh off                   # close it again

By default `on` and `for` allow the on-link prefixes of every non-Tailscale interface (IPv4
and IPv6, including link-local and your router-advertised global /64), never the internet.
Container and VM bridges (`podman*`, `docker*`, `veth*`, `cni*`, `cali*`, `flannel*`,
`virbr*`) are skipped: local containers don't need the Pi's sshd.
Sources are fixed at the moment you run it: re-run it after moving the Pi to another
network. `for` needs a unit (`30s`, `30m`, `2h`); `on` and `off` cancel an active `for`
window (a network that is already open keeps its original expiry if you run `for` again).
CIDRs broader than /8 (IPv4) or /16 (IPv6), including `0.0.0.0/0` and `::/0`, are
refused unless you add `--force`. Older images' `ujust lan-ssh on` opened SSH to every
network; the login banner and `ujust pi-status` warn while that rule is still there, and
`ujust lan-ssh on` or `off` removes it. Nothing changes it automatically on update.

The `juniper` image's Homebrew comes from Bluefin's `ublue-os/brew` and updates and
upgrades your brew packages automatically (`brew-update.timer`, `brew-upgrade.timer`).

### If a device is lost or stolen

The root filesystem is not encrypted (encryption is tracked in #50). Whoever holds the card
can read the Tailscale node state (a working tailnet node), SSH host keys, Wi-Fi passwords,
password hashes and workload data. The boot partition is unsigned too, so a card that comes
back may have been modified. Revoke in this order:

1. Remove the device in the Tailscale admin console. That revokes its node key. Devices
   that joined with a tagged auth key never expire on their own.
2. Revoking or expiring the auth key does not remove nodes that already joined with it.
   Revoke it too if the card never booted: its auth key is still on the FAT partition.
3. Change the Wi-Fi password, and any workload or API secrets the device held.
4. Remove its SSH host key from your `known_hosts`.
5. Reflash any card that comes back instead of trusting it.

What is verified: OS updates are signature-checked before they install. Nothing verifies
the boot chain on the card itself.

### Storage on long-running devices

A full card is how an unattended device dies, so Juniper reserves some room and watches it:

- **Update check.** Before staging an update, the daily download checks that the filesystem
  holding the ostree repo has at least 2048 MiB free (override with `MIN_FREE_MB=<MiB>` in
  `/etc/juniper/update.conf`). If not, it prunes dangling podman images and checks again;
  if still short it skips that day's update (not a failure) and the next run retries. The
  login banner and `ujust pi-status` say so.
- **Weekly prune.** `juniper-image-prune.timer` runs `podman image prune -f` as root:
  dangling images only. It never touches volumes, containers or tagged images.
- **Journal.** Capped at 200M (`SystemMaxUse`), and it leaves the last 1G free
  (`SystemKeepFree`).
- **Warning.** The login banner and `ujust pi-status` warn when `/` has under 10% or 1 GiB
  free.

What the workload has to do itself: keep its data under `/var/lib/<app>`, apply retention
in the app (rotate or expire old data; Juniper never deletes it), and put high-volume data
(video, sensor logs, databases that grow without bound) on a separate USB disk.

### Monitoring

`ujust enable-metrics` runs Prometheus node_exporter as a quadlet on :9100, reachable over
Tailscale only as before (the access rules are unchanged; nothing new is exposed). Re-running
it on a device that already has it updates the existing quadlet and restarts the exporter,
which is how an existing device picks up the Juniper metrics below.

Every image writes `/var/lib/juniper/metrics/juniper.prom` every 5 minutes
(`juniper-metrics.timer`), and node_exporter serves it through its textfile collector. A
metric whose input is missing is left out rather than reported wrong.

| Metric | Meaning |
| --- | --- |
| `juniper_image_info{image,digest,version}` | 1 for the booted image |
| `juniper_staged_image_info{digest}` | 1 while an update is staged for the next reboot |
| `juniper_image_timestamp_seconds` | build time of the booted image |
| `juniper_healthy` | 1 if the health check passes right now (same probes as at boot, no side effects) |
| `juniper_health_last_ok_timestamp_seconds` | last boot whose health check confirmed the deployment |
| `juniper_update_held` | 1 if the staged update failed its health check twice and is held |
| `juniper_update_skipped_space` | 1 if the last update was skipped for lack of disk space |
| `juniper_tailscale_join_gave_up` | 1 if the first-boot Tailscale join gave up |
| `juniper_lan_ssh_legacy` | 1 if locked down but SSH is still open to every network |
| `juniper_locked` | 1 once locked down to Tailscale only |
| `juniper_time_synced` | 1 if the clock is NTP-synchronised |
| `juniper_kernel_build_timestamp_seconds` | build time of the installed Pi kernel |

Example alert conditions:

- Node down or offline: `up{job="juniper"} == 0` (use the job name from your own scrape config). A device that is off, or off the tailnet,
  silently misses updates; this is how it shows up.
- Update stuck: `juniper_update_held == 1`.
- Clock wrong: `juniper_time_synced == 0` for 30 minutes.
- Unhealthy: `juniper_healthy == 0` for 30 minutes.
- Image out of date: `time() - juniper_image_timestamp_seconds > 21 * 86400` (pick your N).

The login banner and `ujust pi-status` also warn "Clock not synchronised (NTP)" when the
clock is not synced, since a Pi has no battery-backed clock.

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

### Your own images

Juniper only enforces signatures on its own namespace, so your images (a derived OS image or a
workload) are accepted unsigned until you say otherwise. Sign them with cosign and trust your
key on the device:

    ujust trust-images ghcr.io/you ~/cosign.pub    # images under ghcr.io/you need your signature
    ujust trust-images                             # list trusted namespaces and keys
    ujust untrust-images ghcr.io/you               # stop requiring it

From then on `bootc switch`, OS updates, podman pulls and `podman auto-update` refuse any image
under that namespace without your signature. Run it before switching to a derived image and the
first switch is verified too.

Where it lives: each trusted namespace is a small drop-in in `/etc/juniper/trusted-images.d/`,
its key in `/etc/pki/containers/`, and its `use-sigstore-attachments` setting in
`/etc/containers/registries.d/`. Juniper's own policy ships read-only in the image
(`/usr/share/juniper/containers/policy.json`), so it updates with every image, key rotations
included. At every boot, before anything pulls, `juniper-containers-policy.service` rebuilds
`/etc/containers/policy.json` from that base plus the drop-ins (validated first, previous copy
kept as `policy.json.bak`). If that fails at boot, the previous policy stays in force (it fails
closed). No drop-in can change a scope the base policy sets (Juniper's own namespace, vendor
entries) or anything under one; one that tries, or is invalid, is skipped and logged
(`journalctl -u juniper-containers-policy`). Don't edit `policy.json` by hand: it is rebuilt at
boot. A derived image ships its trust as files instead: drop-ins and keys under
`/usr/lib/juniper/trusted-images.d/`, merged before the local ones (a local drop-in for the same
namespace wins), never `RUN trust-images` in the Containerfile. See
[the appliance example](examples/appliance#signatures). For workloads, sign and
auto-update on a fleet, or pin by digest on a one-off: see
[the appliance example](examples/appliance#workload-images-signed-or-pinned), which also covers
keeping app data safe across a rollback.

### Readiness checks for your workload

After an update, the boot health check keeps the new image only if the device is reachable
(a default route; once locked, Tailscale connected to its control plane and SSH over it) and
every health hook passes; under tryboot, anything else falls back to the previous image. Add
your own check, such as "a sample was stored in the last 10 minutes", as an executable that
exits 0 when ready:

- in your image: `/usr/lib/juniper/health.d/`
- on a device running plain quadlets: `/etc/juniper/health.d/`; only root-owned files that
  aren't group- or world-writable run, anything else is skipped and logged

Hooks run in name order at every boot, 15 seconds at most each, retried for about 7 minutes.
See [the example](examples/appliance/health.d/50-sensor-sample).

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

The new image boots once through firmware tryboot and is kept only if the boot health check
passes (see [readiness checks](#readiness-checks-for-your-workload)); otherwise, or if the
check itself fails, the Pi falls back to the previous image. A locked device that can't reach
Tailscale's control plane after an update falls back too. An image that fell back once is
retried at the next window; one that fails twice is held: the login status and
`ujust pi-status` say "update … failed its health check twice; waiting for a newer image",
and the next release proceeds as usual. To retry a held image anyway, run `ujust update-unhold`: it
prints the digests it cleared (or "nothing held") and the image is tried again at the next window
or by `ujust update`. The hold shows right away after the second failed boot.

The kernel and Pi firmware arrive only when AlmaLinux rebuilds its base image, not with the
weekly updates; each release's notes state the kernel's build date and whether a newer one
is waiting, and `ujust pi-status` shows the running kernel's age.

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
