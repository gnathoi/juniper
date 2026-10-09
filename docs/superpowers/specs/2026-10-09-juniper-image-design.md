# Juniper image core — design (sub-project A)

Status: approved in brainstorming 2026-10-09, awaiting written-spec review.

## Intent

A batteries-included, headless bootc image for Raspberry Pi 4/5-class hardware, in the
spirit of Bluefin/Bazzite, layered on top of the AlmaLinux RPi bootc image. It is a
development box: interactive work happens over SSH (via Tailscale), long-running
workloads run as Podman quadlets. Flash it, boot it, and it shows up on your tailnet with
everything else firewalled off.

Success looks like:

1. Flash with rpi-imager (sub-project B fork) giving user, SSH key, Wi-Fi, hostname,
   timezone and a Tailscale auth key; first boot joins the tailnet unattended.
2. After joining, only Tailscale traffic reaches the Pi.
3. The Pi keeps itself updated, rebooting in a randomised early-morning window, and
   rolls back on its own if an update breaks networking.
4. `ujust` exposes the common operations; login shows a MOTD and a juniper fastfetch.

Out of scope here: encryption at rest (sub-project C, after a feasibility spike) and the
rpi-imager changes (sub-project B, separate spec).

## Decisions

| Topic | Decision |
|---|---|
| Base | `quay.io/almalinuxorg/almalinux-bootc-rpi:10`, pinned by digest |
| Hardware | Pi 4, Pi 5, Pi 400/500, CM4/CM5. aarch64 only. Dev target: Pi 5 4GB |
| Disk image | GPT only (no FAT/MBR variant) |
| GUI | None |
| Layout | ublue image-template style: one Containerfile, `build_files/`, `system_files/` |
| License | Apache-2.0. Base image is GPL-3.0 but we only `FROM` it and copy none of its files; the raw-image CI step is re-implemented, not copied |
| Image ref | Always fully qualified: `${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/juniper`, GitHub repo variables, `IMAGE_REGISTRY` defaults to `quay.io` |
| Signing | cosign, key-based (`cosign.pub` in repo, private key as `SIGNING_SECRET`), as ublue does. Keyless needs Fulcio/Rekor material on-device — not worth it |
| Firewall | Open LAN SSH until Tailscale is up, then lock down (see First boot) |

## Immutability rule

- `/usr` is read-only on device. Everything Juniper ships goes there wherever the tool
  supports a vendor directory (`/usr/lib/systemd`, `/usr/lib/firewalld`, `/usr/lib/motd.d`,
  `/usr/share/…`, `/usr/libexec/juniper`).
- `/etc` is mutable machine config, 3-way-merged by bootc. We only ship files there when a
  tool has no `/usr` vendor dir (e.g. `/etc/profile.d`, `/etc/xdg/fastfetch`,
  `/etc/containers/registries.d`). Runtime changes (ujust toggles) land in `/etc`.
- `/var` is persistent state: Tailscale, container storage, homes, Homebrew.
- CI runs `bootc container lint --fatal-warnings`; nothing is written to `/var` at build time.

## Repository layout

```
juniper/
├── Containerfile                # FROM base@digest → RUN build.sh → bootc container lint
├── build_files/build.sh         # repos, dnf install, Homebrew tarball, enable units
├── system_files/                # copied verbatim to /
│   ├── usr/bin/ujust
│   ├── usr/lib/systemd/system/  # juniper-* units/timers + preset
│   ├── usr/lib/systemd/…        # zram-generator.conf, journald.conf.d, system.conf.d
│   ├── usr/lib/firewalld/       # zone/policy files
│   ├── usr/lib/bootc/kargs.d/   # juniper.toml
│   ├── usr/libexec/juniper/     # firstboot, lockdown, motd, update helpers
│   ├── usr/share/juniper/       # just recipes, logo, motd tips
│   └── etc/                     # profile.d, xdg/fastfetch, containers policy, cloud cfg
├── disk/bib-config.toml         # partition layout for the .raw
├── disk/cidata/                 # README.txt + template user-data shipped on CIDATA
├── imager/os-list.json.in       # rpi-imager OS list template, filled by release CI
├── Justfile                     # build, build-raw, lint, test
├── .github/workflows/build.yml
├── .github/dependabot.yml
├── .pre-commit-config.yaml
├── cosign.pub
├── LICENSE, THIRD_PARTY.md, README.md
```

## Contents

| Source | Packages |
|---|---|
| AlmaLinux BaseOS/AppStream | podman, firewalld, cloud-init, cloud-utils-growpart, zram-generator, git, tmux, neovim, jq, rsync, NetworkManager-wifi, avahi |
| EPEL 10 | distrobox, fastfetch, just, btop, ripgrep, fzf, greenboot |
| pkgs.tailscale.com (RHEL 10 repo) | tailscale |
| Homebrew release tarball | Homebrew, staged as `/usr/share/juniper/homebrew.tar.zst`, extracted to `/var/home/linuxbrew/.linuxbrew` on first boot (Bluefin pattern) |

The first implementation task verifies every EPEL package exists for aarch64 on EL10. Any
that don't move to Homebrew (CLI tools) or a fallback (greenboot → see Updates).

Not baked in, offered as `ujust` recipes instead (containers-first, keeps image small):
Cockpit, restic, node_exporter, podlet.

## First boot

```
flash (user, ssh key, wifi, hostname, tz, TS key) → CIDATA/user-data + network-config
boot 1:
  cloud-init (NoCloud on CIDATA)
    user, ssh keys, NetworkManager wifi, hostname, tz, growpart
    write_files /etc/tailscale/authkey (0600) ; runcmd tailscale up --auth-key=file:…
  juniper-firstboot.service  (After=cloud-final.service, ConditionPathExists=!/var/lib/juniper/firstboot.done)
    1. if /etc/tailscale/authkey still exists: enable tailscaled, retry `tailscale up` with backoff (≤10 min)
    2. shred -u /etc/tailscale/authkey
    3. remove user-data and network-config from the CIDATA partition, replace user-data
       with the shipped template (secrets must not stay on unencrypted FAT)
    4. touch /etc/cloud/cloud-init.disabled   (cloud-init is first-boot only)
    5. extract Homebrew, chown to the first human user (uid 1000)
    6. touch /var/lib/juniper/firstboot.done
  juniper-lockdown.path/.service
    when `tailscale status --json` BackendState == Running (checked on boot and by
    tailscaled state changes): set firewalld default zone `drop`, add tailscale0 to
    `trusted`, allow 41641/udp (direct Tailscale peers). Records
    /var/lib/juniper/locked so it only happens automatically once.
```

- Before lockdown the default zone is stock `public` (ssh, mdns, dhcpv6-client).
- No key supplied → no lockdown; the Pi behaves as a normal LAN box.
- cloud-init's `package-update-upgrade-install` module is disabled via
  `/etc/cloud/cloud.cfg.d/90-juniper.cfg` (the imager asks it to apt-install avahi).
- `growpart` targets `/sysroot` as upstream's bootstrap layer does.
- Users of `dd`/other flashers edit `CIDATA/user-data`: the shipped template contains the
  same commented `write_files`/`runcmd` Tailscale block the imager generates, so there is one
  mechanism, not two.
- Default hostname `juniper`. No default user or password is baked in.

## Updates

- `juniper-update.timer` (daily, `RandomizedDelaySec=1h`) → `juniper-update.service`:
  `bootc upgrade` (download + stage only, no `--apply`), then `podman auto-update`.
- `juniper-reboot.timer` (`OnCalendar=*-*-* 04:00`, `RandomizedDelaySec=90min`, local
  time = timezone from first boot) → reboots only when `bootc status --json` shows
  `.status.staged` non-null.
- Health check + rollback: greenboot required checks for `tailscaled` active and a default
  route. If greenboot is unavailable on EL10, ship a ~20-line
  `juniper-healthcheck.service` that runs `bootc rollback && reboot` when the checks fail on
  the first boot of a new deployment.
- On-device signature enforcement: `/etc/containers/policy.json` +
  `registries.d/juniper.yaml` require the `cosign.pub` signature for the Juniper image ref.

ujust:

| Command | Effect |
|---|---|
| `ujust update` | stage + apply now (reboot) |
| `ujust update-schedule 03:30` | timer drop-in in `/etc/systemd/system/juniper-reboot.timer.d/` |
| `ujust update-schedule off` | disable auto-reboot (updates still stage) |
| `ujust update-schedule` | show next run |

## SD-card care and robustness

- zram swap via `/usr/lib/systemd/zram-generator.conf` (`zram-size = ram / 2`).
- journald `SystemMaxUse=200M` drop-in.
- `rootflags=noatime` via `/usr/lib/bootc/kargs.d/juniper.toml` (verify rpi-bootc-bootloader
  carries BLS options into `cmdline.txt`).
- Hardware watchdog: `RuntimeWatchdogSec=30s` system.conf drop-in (`bcm2835_wdt`).

## UX: ujust, MOTD, fastfetch

- `/usr/bin/ujust`: `exec just --justfile /usr/share/juniper/just/main.just --working-directory "$HOME" "$@"`;
  `main.just` imports one file per topic (`update.just`, `network.just`, `apps.just`, `pi.just`).
- Recipes (beyond Updates): `lan-ssh on|off`, `tailscale-up` (re-auth with new key),
  `toggle-motd`, `devbox` (distrobox Fedora toolbox with common dev tools),
  `install-cockpit` (quadlet, exposed only via `tailscale serve`), `install-podlet`,
  `setup-backup` (restic via brew + user timer), `enable-metrics` (node_exporter quadlet),
  `pi-status` (temp, throttling, clocks via vcgencmd).
- MOTD: `/etc/profile.d/juniper-motd.sh` for interactive SSH logins prints image
  version/date, Tailscale IP + state, lockdown state, staged update + scheduled reboot
  time, and one random tip from `/usr/share/juniper/tips.txt`. Disabled per-user by
  `ujust toggle-motd` (marker file in `~/.config/juniper/`).
- fastfetch: `/etc/xdg/fastfetch/config.jsonc` with a custom logo
  `/usr/share/juniper/logo.txt` — an original juniper sprig (scale-like green foliage,
  dusky blue berries), ≤ 20 lines × 40 cols, two colours. Modules: OS/image, host (Pi
  model), kernel, uptime, CPU temp, memory, disk, Tailscale IP.

## CI / release

`.github/workflows/build.yml` triggers: `pull_request`, `push` to main, weekly
`schedule` (Mon 02:00 UTC), `workflow_dispatch` (input `build_raw: bool`), tag `v*`.

| Job | Runs on | Steps |
|---|---|---|
| lint | every trigger | pre-commit: shellcheck, shfmt, hadolint, actionlint, yamllint, `just --fmt --check --unstable`; `systemd-analyze verify` on our units |
| build | `ubuntu-24.04-arm` | podman build, `bootc container lint`, rechunk (`bootc-base-imagectl rechunk`) |
| test | after build | in the built image: `tailscale version`, `distrobox --version`, `fastfetch --config … --pipe`, `ujust --list`, `firewall-offline-cmd --check-config`, `systemctl is-enabled` for each juniper unit |
| publish | push/schedule/dispatch/tag only | push `:latest`, `:YYYYMMDD`, `:sha-…`; cosign sign; syft SBOM attached |
| disk | dispatch with `build_raw`, or tag | pull the pushed ref, bootc-image-builder raw with `disk/bib-config.toml`, `rpi-bootc-bootloader sync` into CIDATA, copy `disk/cidata/*`, xz, sha256, GitHub Release, render `os-list.json` (sizes, sha256, url) and attach it |

`.github/dependabot.yml`: weekly `github-actions` and `docker` (base image digest in
`Containerfile`). Merged updates rebuild via the push trigger. Homebrew is fetched at its
latest release tag during build (it self-updates on device); Dependabot cannot bump
tarball URLs — adopt Renovate later if more pins appear.

## Risks to resolve during implementation

1. EPEL 10 aarch64 availability of distrobox/fastfetch/just/btop/ripgrep/fzf/greenboot.
2. Tailscale vs firewalld (nftables) interaction: confirm `tailscale0` traffic passes in
   `trusted` and Tailscale's own netfilter rules don't conflict with the `drop` zone.
3. Whether `kargs.d` entries reach `cmdline.txt` via rpi-bootc-bootloader.
4. Raw image origin must point at the registry ref so `bootc upgrade` works out of the box.
5. Name: "Juniper" overlaps Juniper Networks' trademark (networking gear). Fine for a
   personal project; reconsider before wider promotion.

## Changes made during planning (2026-10-09)

- Rollback uses rpi-bootc-bootloader firmware tryboot (`TRYBOOT=1`) instead of greenboot,
  which needs GRUB boot counting. Updates reboot with `rpi-bootc-bootloader tryreboot`;
  `juniper-healthcheck` runs `rpi-bootc-bootloader sync` on a healthy boot and reboots an
  unhealthy tryboot so the firmware falls back.
- No `90-juniper.cfg` cloud-init module override: the imager's apt package request fails
  fast and harmlessly on bootc.
- Tailscale join is `juniper-tailscale-join.service` (runs while `/etc/tailscale/authkey`
  exists, retries every 60 s); the CIDATA template only needs `write_files`.
- Lockdown is triggered by a 5-minute `juniper-lockdown.timer` that disables itself once
  locked, not a path unit.
- `install-cockpit` and `setup-backup` recipes dropped for v1.
- Tailscale IP shown in the MOTD status block, not in fastfetch.
- Firewall uses stock `drop`/`trusted` zones; no vendor zone files.
- Registry is `ghcr.io/gnathoi/juniper` (pushed with `GITHUB_TOKEN`, package public, repo
  private for now) instead of quay.io. The Containerfile's base image ref stays fully
  qualified (`quay.io/almalinuxorg/...`).
- CI triggers on pushes to any branch (build + test) instead of pull requests; publishing
  happens on main, tags, the weekly cron and manual runs.

## Image variants (added 2026-10-09, user-approved)

One Containerfile, two published images:

```
quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:…
  └─ stage "minimal"  → ghcr.io/gnathoi/juniper-minimal   (appliance base: build FROM this)
       └─ stage "juniper" → ghcr.io/gnathoi/juniper         (dev box = minimal + user tools)
```

| | minimal | juniper (full) |
|---|---|---|
| Tailscale, flash-time join, lockdown, `lan-ssh` | ✅ | ✅ |
| podman, quadlets, `podman auto-update`, firewalld | ✅ | ✅ |
| cloud-init first boot, CIDATA scrub | ✅ | ✅ |
| Updates, tryboot fallback, health check, signing | ✅ | ✅ |
| zram, journald cap, watchdog, noatime | ✅ | ✅ |
| `ujust` core: update, update-schedule, lan-ssh, tailscale-*, pi-status, enable-metrics | ✅ | ✅ |
| MOTD status block (Tailscale, update state) | ✅ | ✅ |
| fastfetch with the juniper logo | — | ✅ |
| Homebrew, distrobox, git, tmux, neovim, btop, ripgrep, fzf | — | ✅ |
| `ujust devbox`, `install-podlet` | — | ✅ |

- Shared content: `system_files/` + `build_files/build.sh`. Dev-only: `system_files_dev/` +
  `build_files/dev.sh`; `main.just` uses `import? "dev.just"`.
- os-release `IMAGE_ID`/`VARIANT_ID` = `juniper-minimal` | `juniper`.
- CI builds, tests, publishes, signs and reports update size per image (matrix); releases
  carry a disk image per image and one `os-list.json` with both.
- `examples/appliance/` shows building on minimal (package + quadlet) and adding your own
  signing policy; devices follow whatever image they were switched to.

## Homebrew (supersedes the earlier "baked tarball" line, 2026-10-09)

Full image only. Copied from `ghcr.io/ublue-os/brew`, pinned by digest, its cosign
signature verified in CI against ublue's key (`ci/ublue-brew.pub`). ublue's
`brew-setup.service` extracts it to `/var/home/linuxbrew` on first boot (offline-capable);
their `brew-update`/`brew-upgrade` timers keep it current. Dependabot ignores the pin;
`just bump-brew` moves it deliberately, so the ~150 MB tarball never rides along in routine
updates.

## Changes after final review (2026-10-09)

- **F1:** `firstboot` no longer runs `bootc switch --enforce-container-sigpolicy` (it made
  every later pull fail against the base `insecureAcceptAnything` default). The namespace
  `sigstoreSigned` entry in `policy.json` is applied to every pull, so signatures are
  enforced on all updates without it. First `bootc switch` from another system is TOFU.
- **F15:** `PRETTY_NAME` is `Juniper <version>` (no "AlmaLinux 10 bootc" suffix).

## Weekly release train (2026-10-09)

- Dependabot PRs auto-merge (squash) via `dependabot-automerge.yml`, triggered by a
  successful `build` run (`workflow_run`) on a `dependabot/*` push, because branch
  protection and native auto-merge are unavailable on this private repo's plan.
- Pushes to `main` build and test only. `PUBLISH` is true for the weekly schedule
  (Monday 02:00 UTC), `v*` tags, and manual runs on `main`. The schedule also builds the
  disk images and a `build-<version>` release.
- Devices: `juniper-update.timer` stays daily (stages, no-op when nothing new).
  `juniper-reboot.timer` defaults to `Tue *-*-* 04:00:00` with 90 min random delay.
  `ujust update-schedule [DAY] HH:MM | off` rewrites a drop-in (DAY: mon..sun or daily;
  a bare HH:MM keeps the current day, default Tue).
