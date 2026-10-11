# Juniper Desktop — design (sub-project D)

Status: decisions taken by the owner on 2026-10-10, revised on 2026-10-11 (login prompt
first, sudo asks for the password, published as experimental; see "Owner decisions"). A build spike (draft PR #40, branch
`spike/juniper-desktop`) backs the package and build claims below; nothing here has run on
hardware yet.

## Intent

An experimental third image, `juniper-desktop` = `juniper` + a [niri](https://github.com/YaLTeR/niri)
Wayland desktop, for people who would rather plug in a screen than work headless. It is an
on-ramp: develop on `juniper` or `juniper-desktop`, ship appliances on `juniper-minimal`
with quadlets. Everything that makes Juniper Juniper (Tailscale-first, lockdown, signed
updates, tryboot fallback) stays as it is.

Success looks like:

1. Flash `juniper-desktop` with `just flash` (which asks for a password), plug in a screen,
   and the first boot ends at a login prompt; log in with that password, niri starts, and
   Firefox and the Bazaar app store are there. Or `ujust switch ghcr.io/gnathoi/juniper-desktop:latest`
   from `juniper`, which asks you to set a password first if you have none.
2. The update and rollback story is unchanged: a desktop update that breaks the boot falls
   back like any other.
3. The headless images are byte-for-byte unaffected by the desktop's existence (no new
   packages, no display settings, no new units).

## Non-goals

- A full desktop environment (no GNOME/KDE session, no settings app).
- Apps baked into the image. The OS comes from the image; apps come from Flatpak (Flathub),
  Homebrew, distrobox or quadlets.
- Pi 4 as a first-class target (best-effort; 4 GB is tight, see Risks).
- Remote desktop (VNC/RDP). Tailscale SSH remains the remote path.

## Decisions

| Topic | Decision |
|---|---|
| Layering | Stage `FROM juniper AS desktop` in the same Containerfile, running `build_files/desktop.sh` with `system_files_desktop/` (same pattern as `dev.sh` / `system_files_dev/`) |
| Image | `ghcr.io/gnathoi/juniper-desktop`, `IMAGE_ID`/`VARIANT_ID` `juniper-desktop`, `PRETTY_NAME` "Juniper Desktop …"; signed by the same key, covered by the existing namespace policy |
| Hardware | Pi 5 first (the owner's 4 GB board); Pi 4 best-effort |
| Compositor | niri, `niri-session` (systemd user units shipped by the package) |
| Session start | greetd shows its text login (agreety); niri starts only after PAM accepts the password. No auto-login (owner decision 2026-10-11; a graphical greeter later) |
| Password | **Required** for `juniper-desktop`: `just flash` prompts for it; `ujust switch` to the desktop asks you to set one first (for uid 1000). With a password set at flash time, `sudo` asks for it |
| Bar, launcher, terminal, notifications, lock | waybar, fuzzel, foot, SwayNotificationCenter, swaylock + swayidle (lock on idle) |
| Apps | Flatpak with Flathub; **Firefox** (`org.mozilla.firefox`) and the **Bazaar** app store (`io.github.kolunmi.Bazaar`) installed from Flathub on first boot; Flatpaks updated daily |
| X11 apps | xwayland-satellite (niri starts it on demand) |
| Audio | PipeWire + WirePlumber (+ pipewire-pulseaudio) |
| Portals | xdg-desktop-portal-gnome (screencast) + -gtk (file chooser), as niri's `niri-portals.conf` expects |
| Boot settings | KMS overlay in the per-entry `rpi-config.txt` (tryboot covers it) |
| Reboot window | Kept, but deferred while someone is using the desktop, at most 7 days (below) |
| Health check | Under tryboot, the desktop image also requires `greetd.service` active (a `health.d/` hook) |
| COPRs | Option 1 below: pinned keys, `includepkgs` fences, exact versions from a lock file, `just bump-desktop` |
| Distribution | Built in CI in its own job chain; **published as experimental** (signed image, disk image, release assets; not in `os-list.json`) when its own build and tests pass. Untested on hardware until the owner's Pi 5 run (owner decision 2026-10-11) |

## Package sources and trust

| Source | Packages |
|---|---|
| AlmaLinux AppStream/BaseOS | xorg-x11-server-Xwayland, pipewire, wireplumber, xdg-desktop-portal-gnome/-gtk, gnome-keyring, mesa-dri-drivers (ships `vc4_dri.so`, `v3d_dri.so`), mesa-vulkan-drivers, Noto fonts |
| EPEL 10 | wl-clipboard |
| COPR `yalter/niri` (niri upstream's own) | niri |
| COPR `yselkowitz/wlroots-epel` | xwayland-satellite, foot, waybar, fuzzel, swaylock, swayidle, swaybg, SwayNotificationCenter, brightnessctl (also carries niri; we take niri from upstream's COPR) |
| COPR `yselkowitz/cosmic-epel` | greetd, greetd-selinux |

COPRs are GPG-signed per project, but the key is fetched over HTTPS from COPR itself
(trust on first use), anyone can push a new build at any time, and nothing is reviewed. Each
weekly Juniper build would silently pick up whatever is there. Options:

1. **Pin and fence (recommended for v1).** Commit each COPR's public key under
   `ci/copr/` and point `gpgkey=` at it; restrict each repo with `includepkgs=` to exactly the
   packages it is there for (so a COPR can never replace a system package); install exact
   NEVRAs from a lock file `build_files/desktop.lock`; drop the repo files after install so
   devices never see them. `just bump-desktop` (like `bump-brew`) refreshes the lock and
   prints the diff; Dependabot can't. Cost: a manual bump now and then; security fixes in
   those packages wait for a bump.
2. **Mirror** the pinned RPMs (e.g. as an OCI artifact on GHCR) and install from there.
   Survives COPR deleting old builds (COPR keeps only recent ones), but more CI and storage.
3. **Rebuild the SRPMs in our own COPR** (`gnathoi/juniper-desktop`). Full control and
   reviewable spec bumps, but we become the packager for niri and friends.

Recommendation: option 1 now; move to 3 if the desktop graduates from experimental or a
pinned build disappears from COPR. The spike already does the `includepkgs` fence and the
repo removal; the pinned keys and lock file are the real implementation's job.
`install_weak_deps=False` is worth trying for size once the package set settles.

## GPU and boot settings

`build.sh` already installs `/usr/share/juniper/rpi-config.txt` into
`/usr/lib/modules/*/rpi-config.txt`, which rpi-bootc-bootloader copies into each
deployment's boot entry and includes from both the default and tryboot configs. The base
`config.txt` sets no display overlay. `desktop.sh` overwrites the per-kernel file for this
image only:

```
disable_splash=1
camera_auto_detect=0
display_auto_detect=1     # headless images: 0
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
```

The kernel already ships `vc4.ko`/`v3d.ko` and the `vc4-kms-v3d*.dtbo` overlays (checked in
the base image), so no kernel work is needed. Because the overlay lives in the boot entry,
switching `juniper` ↔ `juniper-desktop` turns the GPU on and off with the deployment, and a
bad graphics setting falls back with the rest of the update. CMA size stays at the overlay's
default unless hardware testing shows otherwise.

## Session

- **Login prompt first** (owner decision 2026-10-11, replacing auto-login + lock-first).
  greetd (`display-manager.service`) runs its text greeter, agreety, on tty1:
  `/etc/greetd/config.toml` (Juniper's, replacing the package default) has only a
  `default_session` of `agreety --cmd niri-session` as the `greetd` user, and no
  `initial_session`. niri starts only after PAM accepts the password, so no session exists
  before authentication; after logout, agreety asks again. A tmpfiles line creates
  `/var/lib/greetd`.
- **Why not auto-start + lock:** reviews found it fails open: the session exists before
  swaylock maps its surface (a HID device can type into it), a personal niri config without
  Juniper's include skips the lock, and swaylock failing to start leaves the session
  unlocked. The only greeter in EL10 and these COPRs is agreety; a graphical greeter
  (packaging one, or GDM/SDDM) comes later.
- **Lock on idle** (swayidle, 10 min) is on by default (`ujust desktop-lock-idle on|off`);
  everyone who logs in has a password. swayidle also sets logind's idle hint after 30 min,
  which the reboot window uses.
- **niri config.** niri reads `~/.config/niri/config.kdl`, else `/etc/niri/config.kdl`,
  else its built-in default. Juniper ships its defaults read-only at
  `/usr/share/juniper/niri/juniper.kdl` (keybinds, waybar/swaync/idle-lock spawn,
  xwayland-satellite), and `/etc/niri/config.kdl` contains only an include of it. No user
  config is created automatically: `ujust desktop-config` creates `~/.config/niri/config.kdl`
  only if missing, containing `include "/usr/share/juniper/niri/juniper.kdl"` followed by a
  commented "your settings below" section: image updates still change the defaults, user
  changes win. Needs niri's
  `include` (25.11+) and later-wins merging, to be confirmed on hardware. Security doesn't
  depend on the user's config: authentication happens at greetd, before niri starts.
- **Keyring.** gnome-keyring with the PAM lines the greetd package already has
  (`pam_gnome_keyring`), so logging in at agreety should unlock it; check on hardware.
- **Waybar** gets a small Juniper module: Tailscale state and "update staged, reboot
  Tue 04:00" (reusing the MOTD's helpers).

## Apps: Flatpak, Flathub, Bazaar, Firefox

- The image ships `flatpak` (AppStream) and Flathub as a system remote
  (`/etc/flatpak/remotes.d/flathub.flatpakrepo`, which carries Flathub's GPG key). Flatpaks
  live under `/var/lib/flatpak`, outside the image: they survive OS updates and are not
  rolled back with them.
- `juniper-flatpak-setup.service` (system, `After=network-online.target`, marked done only
  on success) installs `org.mozilla.firefox` and `io.github.kolunmi.Bazaar` system-wide. Its
  timer starts it 3 minutes after boot, outside the boot transaction, so a slow download never
  holds up `multi-user.target` (cloud-final and the first-boot secret scrub wait for that);
  it retries every 30 minutes on failure, and on the next boot, until done. Both publish aarch64 builds (Flathub, checked
  2026-10-10). First boot downloads their runtimes (several hundred MB), so the apps appear
  a few minutes after the desktop on a slow link; a swaync notification says when they're
  ready.
- `juniper-flatpak-update.timer` runs `flatpak update -y --noninteractive` daily (randomised
  delay) and removes unused runtimes weekly.
- Firefox from Flathub is Mozilla's official build, current release, sandboxed, and updates
  independently of the image. Trade-off accepted by the owner: it isn't there offline on the
  very first boot, and it doesn't roll back with the OS.

## Passwords

- **`just flash`** gains password support: for `juniper-desktop` it **requires** a password,
  prompted twice on the terminal (never stored in `flash.yaml`), hashed with
  `openssl passwd -6 -stdin` (SHA-512 crypt), and written into `user-data` as the user's
  `passwd` with `lock_passwd: false`. For the headless images it stays optional
  (`password: prompt` in the config asks for one). The hash lives on CIDATA only until the
  first-boot scrub, like the other secrets. `render-cidata` refuses a plain-text password in
  the config.
- **`ujust switch IMAGE`**: if `IMAGE` is `juniper-desktop` and the first human user (uid
  1000, the account that logs in at the screen) has no usable password (`passwd -S` reports
  locked or none), it explains why, runs `passwd` for that user, and only then switches. This
  holds whoever runs it, root included; with no uid-1000 user it refuses. Switching to the
  headless images is unchanged.
- **sudo** (owner decision 2026-10-11): when `just flash` writes a password hash,
  `render-cidata` gives the user `ALL=(ALL) ALL`, so sudo asks for the password; key-only
  accounts keep `NOPASSWD:ALL`. Devices that switched from `juniper` keep their flashed rule.
- SSH is key-only on every image: `/etc/ssh/sshd_config.d/40-juniper.conf` sets
  `PasswordAuthentication no` and `KbdInteractiveAuthentication no`, before cloud-init's
  `50-cloud-init.conf` (sshd keeps the first value). The password is for the local login and
  `sudo`.

## Interaction with the headless machinery

| Mechanism | On the desktop |
|---|---|
| Lockdown (`drop` zone + tailscale0 trusted) | Unchanged; the desktop opens no ports |
| Health check | Under tryboot, also require `greetd.service` active (desktop-only `health.d/` hook; the headless images ship no hook) |
| Daily stage (`juniper-update`) | Unchanged |
| Weekly reboot window | Desktop-only drop-in adds `ExecCondition=/usr/libexec/juniper/desktop-idle` to `juniper-reboot.service`: skip the reboot while a logind session of `Type=wayland` is active and not idle (`IdleHint`, set by swayidle after 30 min) unless the update has been staged for 7 days. A deferral shows a swaync notification ("update ready", with the deadline) when it starts and at most once a day after. An hourly timer retries a deferred reboot once the desktop is idle, only while automatic reboots are on (`ujust update-schedule off` stops it too). The headless images don't ship either |
| `ujust update` | Unchanged (explicit, reboots now) |
| MOTD/fastfetch | Unchanged (SSH logins and foot) |

## ujust recipes (desktop.just, imported with `import?` like dev.just)

| Command | Effect |
|---|---|
| `ujust switch IMAGE` (shared) | Asks for a password first when switching to `juniper-desktop` without one |
| `ujust desktop-lock-idle [on\|off]` | Lock on idle (default on) |
| `ujust desktop-reset-config` | Move `~/.config/niri` aside and recreate the include stub |
| `ujust flatpak-setup` | Re-run the Firefox/Bazaar install (e.g. after a failed first boot offline) |
| `ujust headless` | `bootc switch` to the same tag of `juniper` (and back with `ujust switch`) |

## Size, updates and CI

- Image: the spike's desktop layer installs 244 packages, 172 MB download, 733 MB
  installed, on top of `juniper`. Uncompressed after rechunking (spike run 38081217217):
  `juniper-minimal` 1544 MiB, `juniper` 1720 MiB, `juniper-desktop` 2483 MiB (+763 MiB,
  +44 %). `juniper` is 941 MiB compressed on GHCR; expect the desktop around 1.3 GB. Mesa, PipeWire, Xwayland and the GTK
  stack the GNOME portal pulls in (gvfs, tracker, adwaita themes) dominate. Weak
  dependencies include Pi-irrelevant items (intel-vsc-firmware, libcamera IPA, tracker
  miners); `install_weak_deps=False` plus an explicit list should trim it.
- Updates: rechunking gives the new RPMs their own layers, so the weekly delta is still
  "what changed"; the desktop adds AppStream errata for Mesa/GTK/PipeWire, which change more
  often than the headless set. CI's update-size report covers it once it publishes.
- CI: its own job chain (`build-desktop` → `sign-desktop` → `disk-desktop`, ~6.5 min arm64
  build), with the same steps as the headless jobs, so a desktop failure never blocks the
  headless images' signing, disk images or release. Owner decision 2026-10-11: published now
  as experimental, when its own build and tests pass: a signed image and a
  `juniper-desktop-*.raw.xz` disk image (~1.3 GB compressed) in the release, but no
  `os-list.json` entry. `just flash` handles `image: juniper-desktop`.
- First boot of the desktop also downloads the Flatpak runtimes for Firefox and Bazaar
  (several hundred MB, not part of the image or its updates).
- `tests/image.sh` treats `juniper-desktop` as `juniper` plus: desktop binaries present,
  greetd enabled, `graphical.target`, overlay line in every per-kernel `rpi-config.txt`,
  vc4/v3d DRI drivers and modules present, no COPR repo files left, greetd's config (agreety
  starts niri-session; no `initial_session`). The headless images gain negative checks: no
  niri, no KMS overlay, `display_auto_detect=0`, not `graphical.target`.

## Shared hooks this needs (no behaviour change for the headless images)

- `build.sh`: knows `juniper-desktop` in the os-release `case` (the stage inherits
  `IMAGE_NAME` from the minimal stage).
- `main.just`: `import? "desktop.just"`.
- `Justfile`: `image=juniper-desktop` → `--target desktop`; `check-layers` expects the
  homebrew layer for it too.
- `build.yml`: matrix entries; README table column.
- `healthcheck`: runs executables in `/usr/lib/juniper/health.d/` (none on the headless
  images); the desktop ships one that requires `greetd.service` active.
- `ujust switch` (update.just): the password check for `juniper-desktop`.
- `disk/render-cidata` and `disk/flash.sh`: the password field and prompt.

## Deliverables and acceptance (the implementation PR, not the spike)

The PR that ships `juniper-desktop` must, in that same PR:

1. Add a `juniper-desktop` column to the README **Tested hardware** table (rows: Raspberry
   Pi 5 / microSD; Raspberry Pi 5 / USB or NVMe; Raspberry Pi 4, 400; Raspberry Pi 500,
   CM4, CM5), every cell starting as "untested". The Pi 5 / microSD cell switches to
   "✅ tested <date>" once the hardware test plan below passes on a Pi 5, as soon as
   possible after merge; other cells follow hardware reports.
2. Add a `juniper-desktop` column and an **Interface** row (`headless` | `headless` |
   `niri desktop`) to the README image comparison table (the spike branch already carries
   this).
3. Add `juniper-desktop` to the image dropdown of
   `.github/ISSUE_TEMPLATE/hardware-report.yml`.
4. Pass CI: `bootc container lint --fatal-warnings`, `tests/image.sh` for all three images
   (including the headless images' new negative checks), `tests/unit.sh` with tests for
   the greetd config and `desktop-idle`.
5. `just flash` password support (required for `juniper-desktop`, prompted, hashed) and
   the `ujust switch` password check, with unit tests (`render-cidata` hash handling and
   plain-text refusal; the switch check against a stubbed `passwd -S`).
6. Flatpak: Flathub remote, `juniper-flatpak-setup.service` and its timer, the update timer, and image
   tests (remote present, units enabled); the install itself is checked on hardware.
7. CHANGELOG entry under Unreleased (Added: experimental `juniper-desktop`).
8. Publishing as experimental (owner decision 2026-10-11, in this PR): signed image, disk
   image and release assets; no os-list entry. After the hardware run: the Tested-hardware
   cell (and, if wanted, the os-list entry).

## Hardware test plan (owner's Pi 5, micro-HDMI; then Pi 4)

1. `just flash` `juniper-desktop` (built locally or from a branch build) with a password:
   first boot shows greetd's login prompt on HDMI; logging in with the password starts niri; Firefox and Bazaar appear once online; a Flatpak installs
   from Bazaar.
2. GPU: `glxinfo -B` / `vulkaninfo --summary` show V3D, not llvmpipe; Firefox video plays.
3. `ujust switch` from `juniper` without a password: the recipe makes you set one, then
   switches; boots via tryboot, healthy, login prompt first.
4. Dual monitors (both micro-HDMI), hot-plug; audio over HDMI (PipeWire picks the vc4-hdmi
   sink); USB headset.
5. Xwayland app via xwayland-satellite; screencast via the GNOME portal; file chooser.
6. Lock on idle; logout → agreety; SELinux: no AVCs from greetd/xdm_t (`ausearch -m avc`);
   `sshd -T` shows `passwordauthentication no`; sudo asks for the password.
7. Lockdown still applies; `ujust update` and a deliberately broken desktop update fall back;
   killing greetd under tryboot fails the health check.
8. Reboot window: active session defers, idle session reboots, 7-day cap reboots.
9. Thermals and memory with Firefox open (`pi-status`, no throttling with the active cooler).
10. Switch back to `juniper`: overlay gone, no greetd; Flatpaks remain under `/var` but
    nothing starts them.

## Spike findings (PR #40)

- `includepkgs` fencing works but must list each COPR's own dependencies: wlroots-epel also
  supplies playerctl(-libs), nanosvg, fcft, gtk-layer-shell, gtk4-layer-shell, libmpdclient,
  granite, jsoncpp, libsfdo. niri itself needs only base/AppStream libraries.
- gvfs (via xdg-desktop-portal-gnome) hard-requires **wsdd**, whose scriptlet adds a user
  without a sysusers.d entry; bootc lint fails until we ship one. The service stays disabled
  (and the `drop` zone would block it anyway).
- The base image already defaults to `graphical.target` (systemd's default), so the
  headless images are "graphical" with nothing graphical in it; the smoke test checks for
  an enabled display manager instead.
- No tuigreet/regreet/gtkgreet in EL10 repos or these COPRs; the greeter is agreety (text)
  unless we package one (cosmic-greeter exists in cosmic-epel but pulls COSMIC).

## Risks

1. **COPR availability and trust** (above). COPR also prunes old builds, which breaks an
   exact-NEVRA lock until bumped.
2. **SELinux**: greetd-selinux is a third-party policy module; starting a user session from
   agreety may need tweaks.
3. **GPU**: Mesa from RHEL is tuned for servers/VMs; v3d works but is untested here at
   desktop scale. 4 GB Pis may swap (zram helps).
4. **Pi 4 firmware**: the FAT partition's `start4.elf` is never updated after flashing
   (known follow-up); KMS mostly bypasses it, but a firmware/kernel mismatch is possible.
5. **A user without a password** can't log in at the screen. Prevented at both entry points
   (`just flash` requires one; `ujust switch` asks for one); a desktop installed some other
   way without a password needs SSH (key) access to run `passwd`.
6. **Scope creep**: every "small" desktop app request pulls GTK/Qt stacks into the image.
   Rule: apps come from Flatpak (Flathub), Homebrew, distrobox or quadlets, not the image.
7. **Flathub dependency**: first-boot apps need Flathub reachable; Flatpaks don't roll back
   with the OS.

## Owner decisions (2026-10-10)

1. COPRs: option 1 (pin, fence, lock file).
2. Reboot window: defer while the desktop is in use, 7-day cap.
3. Password required; lock screen first on every boot (auto-start + immediate swaylock).
   Superseded on 2026-10-11 (decision 8).
4. Browser: Firefox from Flathub, with the Bazaar store and Flathub set up (not Firefox ESR in
   the image).
5. Health check: a dead greetd fails a tryboot on the desktop image.
6. Built in CI now; published, including a disk image, only after it works on the owner's
   Pi 5. Superseded on 2026-10-11 (decision 10).
7. `just flash` sets the password; `ujust switch` to the desktop requires one.

## Owner decisions (2026-10-11), after the whole-branch reviews

8. Boots to a login prompt; niri after authentication; graphical greeter later. No
   auto-login, no lock-first.
9. With a password set at flash time, sudo asks for it (`ALL=(ALL) ALL`); key-only accounts
   keep NOPASSWD.
10. Publish `juniper-desktop` now as experimental: signed image, disk image and release
    assets, not `os-list.json`; only when its own build and tests pass, and never blocking
    the headless images. Untested on hardware until the Pi 5 run.
11. Key-only SSH, explicitly, on all images (`sshd_config.d/40-juniper.conf`).

## Still to confirm on hardware

- agreety starts `niri-session` after login, and logind registers it as a `wayland` session
  on seat0 (the reboot window's in-use check needs that).
- greetd's third-party SELinux policy lets agreety start the session.
- niri's `include` + later-wins merging lets user overrides win.
- First-boot Flatpak install time on a Pi 5 over Wi-Fi.
