# Hardware acceptance (Pi 5)

Results of the image-core plan's Task 11 on real hardware: a Raspberry Pi 5 with a 128 GB
SD card (SM128), Ethernet plus Wi-Fi, a tailnet with the `tag:edge-server` tag and an `ssh`
policy rule allowing members into it.

## 2026-10-10, first attempt: `build-20261009` (failed, fixed in #22)

Flashed with `dd`, `user-data`/`network-config` written by hand.

| Check | Result |
|---|---|
| Boots, user and SSH keys work (over the LAN) | pass |
| Tailscale join | **fail**: never ran |
| CIDATA and cloud-init cache scrub, health check | **fail**: never ran |
| Wi-Fi from `network-config` | **fail**: not configured |
| Hostname from `user-data` | **fail**: `pi5.lan` (the router's DNS name for the IP) |

Causes and fixes (#22):

- `juniper-tailscale-join`, `juniper-firstboot` and `juniper-healthcheck` were ordered
  `After=cloud-final.service`, which in cloud-init 24.4 runs `After=multi-user.target`;
  `multi-user.target` also pulled them in, so systemd deleted the jobs to break the cycle.
  CI now runs `systemd-analyze verify multi-user.target cloud-init.target` and fails on any
  ordering cycle (verify itself exits 0 on cycles).
- cloud-init 24.4 renders netplan v2 `wifis:` only through netplan, which AlmaLinux lacks:
  `juniper-wifi-import` converts them into NetworkManager keyfiles before NetworkManager.
- AlmaLinux's `prefer_fqdn_over_hostname` default: set to `false`.

A rehearsal first boot on the same Pi (`cloud-init clean`, fixed units under `/etc`) passed
before the image was rebuilt.

## 2026-10-10, second attempt: `build-20261010`

Flashed with `just flash /dev/mmcblk0 ~/.config/juniper/flash.yaml` (run0 for the write).

| Step | Check | Result |
|---|---|---|
| 1 | Flash, first boot, joins the tailnet | pass: joined ~90 s after power-on, tagged `tag:edge-server` (tagged devices have key expiry off) |
| 2 | `/etc/tailscale/authkey` gone | pass |
| 2 | CIDATA `user-data` is the secret-free template; `network-config` gone | pass (byte-identical to `/usr/share/juniper/cidata/user-data`) |
| 2 | cloud-init disabled; `firstboot.done`; no `tskey` in `/var/lib/cloud` | pass |
| 2 | `rootflags=noatime`; zram swap; watchdog 15 s; timezone | pass |
| 2 | Hostname `juniper`; 3 SSH keys; Wi-Fi and Ethernet both up | pass |
| 2 | No ordering cycles in the boot journal | pass |
| 3 | Lockdown: default zone `drop` on `end0` and `wlan0` (only 41641/udp), `tailscale0` trusted | pass |
| 3 | From the LAN: SSH and ping to both addresses time out | pass |
| 3 | `ujust lan-ssh on` opens LAN SSH; `off` closes it again | pass |
| 3 | No NetworkManager profile pins a firewall zone | pass |
| 3 | Tailscale's nftables rules coexist with firewalld | pass (12 `ts-` rules) |
| 3 | Tailscale SSH works through the policy's `ssh` rule | pass |
| — | **Unsigned image under `ghcr.io/gnathoi` rejected** | pass: `podman pull` and `bootc switch` both fail with "A signature was required, but no signature exists"; nothing staged; a signed `juniper-minimal` pulls fine |
| 6 | `ujust update-schedule 03:30` names the Pi's timezone; timer in the 03:30–05:00 window; restored to Tue 04:00 | pass |
| 7 | Login banner (Tailscale, Update, Tip); `ujust` recipes; `pi-status` | pass |
| 7 | `brew --version` in an interactive login shell; `distrobox`, `fastfetch` | pass |
| 7 | Hardened `enable-metrics` quadlet (from #30): runs as nobody, `CapEff` 0, `NoNewPrivs`; `:9100/metrics` over the tailnet | pass (installed by hand; recheck via `ujust` after #30 ships) |
| 4 | Update + tryboot | pass: `juniper-update.service` staged `build-20261010` (33 layers, 534 MB: the first build with `dnf upgrade`); `ujust update` booted it with `tryboot=1`; health check made `ostree-2` the default; a plain reboot stayed on it |
| 5 | Deliberately broken update falls back | pass: image built on the Pi with `tailscaled` masked, staged from containers-storage, booted via tryboot; health check failed after 20 tries (~5 m 40 s) and rebooted; firmware booted the previous image (`tryboot=0`, Tailscale up) 20 s later |
| 7 | `ujust devbox`, `ujust install-podlet` | pass (after switching minimal → juniper): podlet 0.3.2; Fedora 44 toolbox `devbox` created and entered in 2 m 45 s |
| 7b | `juniper-minimal` | pass on the second attempt (Wi-Fi only, serial console on the debug UART): first boot 52.6 s, `NAME="Juniper"`, key/`network-config` scrubbed, CIDATA == template, cloud-init disabled, `tag:edge-server`, no distrobox/brew/fastfetch/zellij, no `devbox`/`brew-tools` recipes, status-only login banner; lockdown to `drop` at 19:34, LAN SSH and ping blocked. `ujust pi-eeprom` needed binutils (fixed in #37) |
| 7b′ | First `juniper-minimal` attempt | **unexplained hang**: Ethernet + Wi-Fi configured; no network at all; root partition never grown, CIDATA untouched, root XFS log dirty (so root was mounted), no persistent journal (stopped before `systemd-journal-flush`). The same image booted fine on the next attempt (Wi-Fi only, fresh flash). Open: retry with Ethernet and `console=ttyAMA10,115200` to capture it |
| — | Final release (`3a67395`: #35 initramfs + #37) via tryboot on `juniper-minimal` | pass: CI-built initrd 28.7 MB, initrd stage 2.97 s, `ujust pi-eeprom` works (update available, not applied), no failed units |
| — | `ujust switch ghcr.io/gnathoi/juniper:latest` from `juniper-minimal` | pass: tryboot, health check, `brew-setup` unpacked Homebrew, `juniper-brew-tools` installed the Brewfile at first login (zellij, nvim, btop, rg; `fzf` also comes from an image package and wins on PATH) |
| — | `just flash` on real cards (#37) | three bugs found and fixed: EXIT trap's `umount` turned success into exit 32 (`set -e` applies in traps); stale same-tag cache; races with the desktop automounter. `run0` needs `/usr/bin/bash` (SELinux denies exec of `user_home_t`) |
| 5b | Update that drops into real-root emergency mode falls back (#32) | pass: required mount of a missing device → 90 s device timeout → `local-fs.target` failed → emergency → `juniper-emergency-fallback` "rebooting … in 60s" → back on the previous image (17:43 → 17:46) |
| — | Health check (#32): locked + Tailscale SSH → healthy; IPv6 route accepted | pass (Pi run of the new script; unit tests for the rest) |
| — | `cidata-device` on the Pi | pass: `/dev/mmcblk0p1` |
| — | `ujust pi-eeprom` (#34), check only | pass: "update available", CURRENT 2025-11-05, LATEST 2026-05-11 (not applied) |
| — | Brewfile tools (#34) via `brew bundle` | pass: zellij 0.45.1, neovim 0.12.6, btop, ripgrep, fzf in 25 s |
| — | Trimmed initramfs (#35) via tryboot | pass: entry initrd 28.8 MB (was 45.8 MB); initrd stage 3.00 s (was 4.28 s); no failed units |
| — | Release pipeline (#33) | pass: `sign` jobs in the `release` environment; `:latest` == `:sha-531a840` digest; disks from their run's digest; changelog pushed with the environment deploy key through the `main` ruleset |

Notes:

- `bootc status` shows the origin as `ostree-unverified-registry:`; enforcement comes from
  `/etc/containers/policy.json`, as the unsigned-image test shows.
- `ip`, `swapon` and similar live in `/usr/sbin`, which isn't on a normal user's `PATH` in
  Tailscale SSH sessions; root and the services have it.
- On the device, `dnf check-update` stops at the Tailscale repo ("Signing key not found")
  until its key is imported; it doesn't affect image updates.
- The base image (built 2026-10-02) had 66 package updates pending on 2026-10-10, 14
  Important and 19 Moderate security advisories; #30 applies them at build time.

## 2026-10-11, second release: `build-20261011` (#79)

Run over the serial console and SSH through a tailnet probe, on the same Pi 5. All sections
passed.

| Section | Check | Result |
|---|---|---|
| 1 | First boot to login in ~42 s, no failed units; Tailscale joined, authkey gone, locked; sshd key-only (password and keyboard-interactive refused) | pass |
| 2 | Banner clean; `ujust` completion; `pi-status` kernel age (built 72 days ago); timers scheduled; metrics file complete | pass |
| 3 | node_exporter serves all 11 `juniper_*` metrics, `textfile_scrape_error` 0 (SELinux fine with `SecurityLabelDisable`) | pass |
| 4 | `lan-ssh` off/on/for/off: on-link prefixes only, LAN SSH opens and closes, a 1-minute window expires on its own, no legacy warning | pass |
| 5 | `policy.json` equals the base; `trust-images` lists the protected namespaces; signed pull works | pass |
| 6 | Real tryboot update `juniper` to `juniper-minimal`: health check succeeded, firmware default synced (#75 wrapper on a plain root) | pass |
| 6 | Two-strike quarantine, with a forced-failing local hook: tryboot fails, fallback, strike 1 (no reboot on the normal boot; `OnFailure` fallback correctly idle); second attempt "trying it once more", fallback, strike 2; the re-offered image is refused ("failed its health check twice"), banner and `juniper_update_held 1` | pass |
| 6 | A plain reboot with the held image staged still boots the previous deployment (firmware default unchanged); restored to `juniper`, healthy | pass |
| 7 | Free-space skip: marker, log and banner warning; cleared by the next normal stage | pass |

Follow-up: #81, fixed in #82.

## 2026-10-11, opt-in root encryption (#78, #84)

Same Pi 5, EEPROM updated to 2026-05-11 during the run (it reported 2025-11-05 before).
Serial console plus SSH.

| Step | Check | Result |
|---|---|---|
| 1 | First attempt, release as published | **fail, open as designed**: `genkey failed (firmware error 4)` = KEY_LOCKED. `lock_device_private_key=1` in `rpi-config.txt` sets the old global lock, which on EEPROM 2026-05-11 also blocks genkey. The card booted plain; motd, `pi-status` and metrics showed NOT ENCRYPTED loudly. Fixed by dropping the config lock (#86) |
| 2 | Second attempt, same release, lock line removed by hand from the card's boot entry before first boot | pass: genkey, in-place LUKS2 conversion of the 6 GB root (~3.5 min, silent), grow to 117.2 GB, `unlocked /dev/mmcblk0p3`, boot. `luksDump`: keyslots 0 and 1; tokens `juniper`, `juniper-recovery`; aes-xts-plain64. State: encrypted, binding board+mmc, recovery sealed:3, key_lock unavailable (firmware before 2026-06-17). `pi-status` and metrics correct, no NOT ENCRYPTED warning |
| 2 | Plain reboot | pass: unlocks unattended in ~4 s, no failed units |
| 3 | Laptop recovery | pass via a root shell: the recovery keyslot opens with the owner's laptop SSH key (`age -d -i ~/.ssh/id_ed25519` on CIDATA's `juniper-recovery.age`, piped into `cryptsetup open --readonly`); mounted read-only showing `/boot`, `ostree` and hostname `juniper`. `just unlock-card` itself **failed**: run0 doesn't forward piped stdin to cryptsetup, and Homebrew's age isn't on root's PATH. Fixed in #87 (one root shell) |
| 4 | Final clean flash (22:16 release, config lock removed, no hand edits) | pass: "encrypting the root partition ... don't cut power", done at 213 s, token imported, grown to 117.2 GB, unlocked; joined Tailscale and locked down at the next lockdown timer tick. keyslots 0 and 1; tokens `juniper`, `juniper-recovery`; binding board+mmc; recovery sealed:3; no failed units. The board reused its OTP key from the earlier attempt. This is now the owner's everyday card |
| 5 | Tryboot update `juniper` to `juniper-minimal` and back | pass: both deployments unlocked; header and CIDATA unchanged |

Remaining (moved to #83): the single-command `just unlock-card` re-test and an optional clone check.

Side finding: on first boot, `juniper-update`'s catch-up run (after the clock jump) ran before
DNS was up and failed; it retries daily.

### Firmware findings

- `rpi-fw-crypto hmac` locks up on EEPROM 2025-11-05 (a known bug, fixed in pieeprom-2026-01-21); after updating to 2026-05-11 with `sudo rpi-eeprom-update -a`, hmac works (the encrypted card unlocks with it on every boot). fwkey refuses firmware older than 2026-01-21.
- `lock_device_private_key=1` blocks genkey on firmware before 2026-06-17, because it is the old global lock; per-operation locks (`set-key-status`) exist only from that release. The config lock is therefore no longer set (#86).
- Thermals (Pi 5): idle 44 C; the fan starts at the 50 C trip point; peak 59.5 C under full load; never throttled.

## 2026-10-17, `juniper-desktop` on a Pi 5 (#58, #109–#120)

Pi 5 (4 GB), encrypted root, the everyday card from 2026-10-11, switched from `juniper` with
`ujust switch`; micro-HDMI to a 1080p screen, USB keyboard and mouse; checks over Tailscale SSH.

| Step | Check | Result |
|---|---|---|
| 1 | `ujust switch ghcr.io/gnathoi/juniper-desktop:latest` from `juniper` over Tailscale SSH | **fail**: `fsetxattr(security.selinux): Invalid argument` on `flatpak-system-helper`. The desktop adds SELinux policy modules (flatpak, greetd) and bootc, run from a script or Tailscale SSH (`unconfined_service_t`), isn't in `install_t`, the one domain that may set labels the running policy doesn't know. Completed once with `setenforce 0` around the pull (enforcing again after the reboot). Fixed in #112 (`bootc-run`: pulls as a transient systemd unit) |
| 2 | Boot, greeter | pass: tryboot, health check, greeter on HDMI; SELinux enforcing, no AVCs; `/var/lib/greeter` `user_home_dir_t`, `/var/cache/dms-greeter` `cache_home_t`; `greeter` and `greetd` users from sysusers; no failed units |
| 3 | Login, session | pass: password login; session `Type=wayland`, `Class=user` (the greeter's is `wayland`, `Class=greeter`, which `desktop-idle` ignores); DMS bar, launcher, terminal, wallpaper theme; dotfiles applied at first login (none pre-existing, `dots-kept` empty) |
| 4 | Memory, idle | ~450 MB used at the greeter; ~1.0–1.1 GB in a session (quickshell 280–400 MB, niri ~100 MB); 2–9 % CPU and ~46 °C idle |
| 5 | Privacy | **fail**: each DMS start made geoclue look up the location online (HTTPS to a location service) though DMS's location and weather are off. Fixed in #111 (geoclue's IP and Wi-Fi sources off; nothing left the Pi after) |
| 6 | Daily dotfiles timer | **fail**: `juniper-dots-update.timer` never armed at the first login (its condition was checked before `dots init`). Fixed in #110 |
| 7 | `ujust update` to a build with #110–#117, then to one with #119 | pass: both updates staged and rebooted through tryboot, health check passed, previous build kept as rollback. The second pull ran as `juniper-bootc-*.service` (#112's path) |
| 8 | Default user picture | pass: set through AccountsService from a user unit (polkit allows it), copied to `/var/lib/AccountsService/icons/nat`, readable by the greeter |

Not checked on this run: the reboot deferral after 30 minutes idle, gnome-keyring unlocking at
login, the first-boot Flathub install of Firefox and Bazaar, a flashed (rather than switched)
desktop card, and falling back from a broken desktop update. Performance measurements: #118.
