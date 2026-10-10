# Juniper Desktop — design (sub-project D)

Status: draft for owner review, 2026-10-10. A build spike (draft PR #40, branch
`spike/juniper-desktop`) backs the package and build claims below; nothing here has run on
hardware yet.

## Intent

An experimental third image, `juniper-desktop` = `juniper` + a [niri](https://github.com/YaLTeR/niri)
Wayland desktop, for people who would rather plug in a screen than work headless. It is an
on-ramp: develop on `juniper` or `juniper-desktop`, ship appliances on `juniper-minimal`
with quadlets. Everything that makes Juniper Juniper (Tailscale-first, lockdown, signed
updates, tryboot fallback) stays as it is.

Success looks like:

1. `ujust switch ghcr.io/gnathoi/juniper-desktop:latest` on a Pi 5 8 GB running `juniper`,
   reboot, and a niri session appears on HDMI with no further setup.
2. The update and rollback story is unchanged: a desktop update that breaks the boot falls
   back like any other.
3. The headless images are byte-for-byte unaffected by the desktop's existence (no new
   packages, no display settings, no new units).

## Non-goals

- A full desktop environment (no GNOME/KDE, no settings app, no software centre).
- Flatpak, a browser store, office apps. Users add apps with Homebrew, distrobox or quadlets.
- Pi 4 as a first-class target (best-effort; 4 GB is tight, see Risks).
- Remote desktop (VNC/RDP). Tailscale SSH remains the remote path.
- A flashable disk image in v1 (see CI).

## Decisions

| Topic | Decision |
|---|---|
| Layering | Stage `FROM juniper AS desktop` in the same Containerfile, running `build_files/desktop.sh` with `system_files_desktop/` (same pattern as `dev.sh` / `system_files_dev/`) |
| Image | `ghcr.io/gnathoi/juniper-desktop`, `IMAGE_ID`/`VARIANT_ID` `juniper-desktop`, `PRETTY_NAME` "Juniper Desktop …"; signed by the same key, covered by the existing namespace policy |
| Hardware | Pi 5 8 GB first; Pi 5 4 GB and Pi 4 4/8 GB best-effort |
| Compositor | niri, `niri-session` (systemd user units shipped by the package) |
| Session start | greetd, auto-login of uid 1000 by default; agreety (text) after logout or with auto-login off |
| Bar, launcher, terminal, notifications, lock | waybar, fuzzel, foot, SwayNotificationCenter, swaylock + swayidle |
| X11 apps | xwayland-satellite (niri starts it on demand) |
| Audio | PipeWire + WirePlumber (+ pipewire-pulseaudio) |
| Portals | xdg-desktop-portal-gnome (screencast) + -gtk (file chooser), as niri's `niri-portals.conf` expects |
| Boot settings | KMS overlay in the per-entry `rpi-config.txt` (tryboot covers it) |
| Reboot window | Kept, but deferred while someone is using the desktop (below) |

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

- **greetd** is enabled (`display-manager.service` alias) and the default target becomes
  `graphical.target`. The auto-login user only exists on the device (cloud-init creates it),
  so a `greetd.service` drop-in runs `/usr/libexec/juniper/greetd-config` as
  `ExecStartPre`, writing `/run/juniper/greetd.toml`: `initial_session` = `niri-session` as
  the uid-1000 user, `default_session` = `agreety --cmd niri-session`. With no uid 1000
  (flashed without a user) there is no auto-login. `/etc/greetd/config.toml` stays the
  package default. A tmpfiles line creates `/var/lib/greetd` (the package only fixes its
  ownership).
- **Auto-login by default, because Juniper users usually have no password.** cloud-init
  creates the user with SSH keys only; agreety and swaylock need a password. So:
  - `ujust desktop-autologin off` refuses until `passwd` has been run;
  - the default niri config does not auto-lock (swayidle only blanks the screen) until the
    user has a password; `ujust desktop-lock on` enables lock-on-idle after checking.
  - Physical access to an auto-login Pi is access to the session. Documented, and the
    greeter is one command away.
- **niri config.** niri reads `~/.config/niri/config.kdl`, else `/etc/niri/config.kdl`,
  else its built-in default. Juniper ships its defaults read-only at
  `/usr/share/juniper/niri/juniper.kdl` (keybinds, waybar/swaync/xwayland-satellite
  spawn, Juniper wallpaper). A first-login user unit (like `juniper-brew-tools`) creates
  `~/.config/niri/config.kdl` only if missing, containing `include
  "/usr/share/juniper/niri/juniper.kdl"` followed by a commented "your overrides below"
  section, the zirconium `local.kdl` idea turned around: image updates still change the
  defaults, user changes win. Needs niri's `include` (25.11+) and later-wins merging,
  to be confirmed on hardware.
- **Keyring.** gnome-keyring with the PAM lines the greetd package already has
  (`-auth optional pam_gnome_keyring.so`, `-session … auto_start`). With auto-login there is
  no password to unlock it; the first app that needs secrets prompts once. Acceptable for v1.
- **Waybar** gets a small Juniper module: Tailscale state and "update staged, reboot
  Tue 04:00" (reusing the MOTD's helpers).

## Interaction with the headless machinery

| Mechanism | On the desktop |
|---|---|
| Lockdown (`drop` zone + tailscale0 trusted) | Unchanged; the desktop opens no ports |
| Health check | Unchanged in v1. Optional: also require `greetd.service` active, only under tryboot (needs a small `health.d/` hook in the shared script; open question) |
| Daily stage (`juniper-update`) | Unchanged |
| Weekly reboot window | Desktop-only drop-in adds `ExecCondition=/usr/libexec/juniper/desktop-idle` to `juniper-reboot.service`: skip the reboot while a seat0 session is active and not idle (logind `IdleHint`, set by swayidle after 30 min) unless the update has been staged for 7 days. A skipped reboot shows a swaync notification ("update ready, reboot when convenient"). The headless images don't ship the drop-in |
| `ujust update` | Unchanged (explicit, reboots now) |
| MOTD/fastfetch | Unchanged (SSH logins and foot) |

## ujust recipes (desktop.just, imported with `import?` like dev.just)

| Command | Effect |
|---|---|
| `ujust desktop-autologin [on\|off]` | Marker file in `/etc/juniper/`; `off` requires a password |
| `ujust desktop-lock [on\|off]` | Lock on idle (swaylock) in the user's niri config; `on` requires a password |
| `ujust desktop-reset-config` | Move `~/.config/niri` aside and recreate the include stub |
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
- CI: a third entry in the build matrix (~5 min arm64, like `juniper`), sign matrix +1 job.
  **No disk image in v1**: users switch from `juniper` (one command, and avoids a ~1.2 GB
  release asset and another `os-list.json` entry). Revisit when it leaves experimental.
- `tests/image.sh` treats `juniper-desktop` as `juniper` plus: desktop binaries present,
  greetd enabled, `graphical.target`, overlay line in every per-kernel `rpi-config.txt`,
  vc4/v3d DRI drivers and modules present, no COPR repo files left, greetd config
  generation. The headless images gain negative checks: no niri, no KMS overlay,
  `display_auto_detect=0`, not `graphical.target`.

## Shared hooks this needs (no behaviour change for the headless images)

- `build.sh`: knows `juniper-desktop` in the os-release `case` (the stage inherits
  `IMAGE_NAME` from the minimal stage).
- `main.just`: `import? "desktop.just"`.
- `Justfile`: `image=juniper-desktop` → `--target desktop`; `check-layers` expects the
  homebrew layer for it too.
- `build.yml`: matrix entries; README table column.
- Later, if chosen: a `health.d/` directory in the health check.

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
   (including the headless images' new negative checks), `tests/unit.sh` with a test for
   `greetd-config` and `desktop-idle`.
5. CHANGELOG entry under Unreleased (Added: experimental `juniper-desktop`).

## Hardware test plan (Pi 5 8 GB, then Pi 4)

1. `ujust switch` from `juniper`: boots via tryboot, healthy, niri on HDMI-A-1 at native
   resolution; `glxinfo -B`/`vulkaninfo --summary` show V3D, not llvmpipe.
2. Dual monitors (both micro-HDMI), hot-plug.
3. Audio over HDMI (PipeWire picks the vc4-hdmi sink); USB headset.
4. Xwayland app via xwayland-satellite; screencast via the GNOME portal; file chooser.
5. Logout → agreety; `passwd`, `desktop-autologin off`, reboot → agreety login works;
   `desktop-lock on` → swaylock unlocks. SELinux: no AVCs from greetd/xdm_t
   (`ausearch -m avc`).
6. Lockdown still applies; `ujust update` and a deliberately broken desktop update fall back.
7. Reboot window: active session defers, idle session reboots, 7-day cap reboots.
8. Thermals and memory under a browser-like load (`pi-status`, no throttling with the
   active cooler).
9. Switch back to `juniper`: overlay gone, multi-user target, no greetd.

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
2. **SELinux**: greetd-selinux is a third-party policy module; greetd reading a config from
   `/run/juniper` and starting a user session may need tweaks.
3. **GPU**: Mesa from RHEL is tuned for servers/VMs; v3d works but is untested here at
   desktop scale. 4 GB Pis may swap (zram helps).
4. **Pi 4 firmware**: the FAT partition's `start4.elf` is never updated after flashing
   (known follow-up); KMS mostly bypasses it, but a firmware/kernel mismatch is possible.
5. **No-password users** make lock screens and greeters a trap; mitigated by the recipe
   checks above.
6. **Scope creep**: every "small" desktop app request pulls GTK/Qt stacks into the image.
   Rule: apps come from Homebrew, distrobox or quadlets, not the image.

## Open questions for the owner

1. COPR trust: option 1 (pin + fence + lock file) now, or go straight to our own COPR?
2. Reboot window: defer while active with a 7-day cap (proposed), or never auto-reboot a
   desktop and only notify?
3. Auto-login by default (proposed, because users have no password) or greeter by default?
4. Browser in the image (Firefox ESR from AppStream, ~+250 MB) or "bring your own"
   (distrobox/Homebrew)?
5. Health check: should a dead greetd fail a tryboot on the desktop image?
6. Publish cadence: weekly with the others from day one, or build-only until hardware
   tests pass?
7. Disk image: confirm "switch from `juniper`" only for v1.
