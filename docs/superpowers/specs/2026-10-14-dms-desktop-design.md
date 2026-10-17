# juniper-desktop on DankMaterialShell: design

Date: 2026-10-14. Status: approved in conversation, awaiting written-spec review.
Supersedes, for `juniper-desktop`, the bar/launcher/notification/lock/greeter rows of
`2026-10-10-juniper-desktop-design.md`; everything else there (layering, KMS, Flatpak apps,
reboot deferral, health check, experimental publishing) still holds.

## Goal

Make the experimental desktop look and feel like [zirconium](https://github.com/zirconium-dev/zirconium)
(niri + DankMaterialShell), the reference we already credit, on our AlmaLinux 10 aarch64 Pi
base, without giving up Juniper's guarantees:

- no session before authentication (fail closed at login);
- updates only through Juniper's tryboot + health-checked path;
- every third-party package pinned, fenced and build-time only;
- nothing phones home by default.

Success: a Pi 5 boots to a graphical DMS login, logs into a themed niri + DMS session (bar,
launcher, notifications, lock, OSDs, polkit agent) in blues and purples from a Juniper
wallpaper, and the reboot window, health check and Flatpak setup behave as they do today.
Still experimental until the owner's hardware run (#58).

## Decisions (owner, 2026-10-14)

| Topic | Decision |
|---|---|
| Scope | Full swap: DMS replaces waybar, fuzzel, swaync, swaylock, swaybg; `dms-greeter` replaces agreety |
| User config | chezmoi, like zirconium: a source tree in the image, applied at first login and daily (skipping files the user changed) |
| Look | A Juniper wallpaper (a juniper berry cluster in a flat, Raspberry-Pi-like style, blues and purples), DMS dynamic theme via matugen, dark |
| Idle hint | `swayidle -w idlehint 1800` stays (DMS never sets logind's idle hint itself); DMS does the locking |
| DMS system updates | Off: its `rpm-ostree` backend would bypass Juniper's update path |
| Network features | Weather off by default (open-meteo); auto-location stays off (ip-api.com); plugin browser untouched but nothing preinstalled |

## Packages and trust

Same pattern as today (`build_files/desktop.sh`): build-time-only COPR repos, our pinned copy
of each project's key in `build_files/copr-keys/`, `includepkgs` fences in
`build_files/desktop-copr.txt`, exact NEVRAs in `build_files/desktop.lock`, repo files removed
after install, `just bump-desktop` and the weekly `bump-desktop.yml` to move them.

| Source | Packages |
|---|---|
| COPR `avengemedia/dms` (new) | dms (with its dms-cli subpackage, if split) |
| COPR `avengemedia/danklinux` (new) | dms-greeter, quickshell, matugen, dgop, cliphist, material-symbols-fonts, plus quickshell's runtime deps from that COPR (breakpad, cpptrace, cli11 if needed at runtime) |
| COPR `yalter/niri` | niri (unchanged) |
| COPR `yselkowitz/wlroots-epel` | xwayland-satellite, foot, foot-terminfo, swayidle, brightnessctl, playerctl (+ their deps); waybar, fuzzel, swaylock, swaybg, SwayNotificationCenter dropped |
| COPR `yselkowitz/cosmic-epel` | greetd, greetd-selinux (unchanged) |
| AppStream / EPEL | accountsservice, qt6-qtmultimedia, qt6-qtwayland, chezmoi (EPEL), xdg-terminal-exec (EPEL), policycoreutils-python-utils (dms-greeter requires it) |

Not shipped: `cava` and `udiskie` (not in EL10; `cava` is only a Recommends), `ghostty` and
`qt6ct-kde` (no epel-10 build), and `danksearch` (fenced out of the COPR; it
would index the home dir on a Pi, and DMS works without it). Weak dependencies stay on (dnf's
default); the includepkgs fences limit what each COPR can supply to the packages above.

The two avengemedia projects are a new trust root: anyone with access can push builds, and the
lock file is what keeps a malicious or broken build out of an image until a reviewed bump.
Their epel-10-aarch64 chroots exist (dms 1.6.3, dms-greeter 1.6.2, quickshell 0.3.2, matugen
4.2.0 on 2026-10-14). If a pinned build disappears from COPR, the build fails loudly; the
fallback is the earlier spec's option 3 (rebuild in our own COPR).

## Login (greetd + dms-greeter)

- `/etc/greetd/config.toml`: `vt = 1`, `default_session.command = "dms-greeter --command
  niri --cache-dir /var/cache/dms-greeter"`, `user = "greeter"`,
  `service = "greetd-spawn"` (`--command` is the greeter's own compositor, so `niri`, not `niri-session`). No `initial_session`: no session before PAM accepts a password.
- The `greeter` user from a sysusers.d file (system user; uid assigned by sysusers, not a
  fixed 767).
- `/etc/pam.d/greetd-spawn` (AlmaLinux reads `/etc/pam.d`): includes `greetd` and adds `pam_env`
  (env file `/usr/share/juniper/greetd-spawn.pam_env.conf`) with `XDG_SESSION_TYPE=wayland`, so logind types the greeter session correctly (zirconium's
  wrapper). gnome-keyring PAM lines stay as greetd's package ships them; confirm unlock on
  hardware.
- tmpfiles: `/var/cache/dms-greeter` owned by `greeter`; the greeter's appearance
  (wallpaper, theme) symlinked from `/usr/share/juniper/dms-greeter/`. The greeter uses DMS's built-in static
  `purple` theme with the Juniper wallpaper (no matugen output exists before anyone logs in);
  the session uses `dynamic`. `/var/lib/greetd` as today.
- Health hook `10-greetd` unchanged (greetd active under tryboot).
- `dms greeter install|enable|uninstall` and `dms setup` are blocked with a
  `/usr/share/dms/cli-policy.json` like zirconium's: they write to `/usr` or `/etc/greetd` and
  would fight the image.
- Fail-closed check: if the greeter (quickshell) crashes, greetd restarts it; no user session
  exists. This replaces agreety's property one for one.

## Session

- `niri-session` starts niri as a systemd user service. DMS starts from its packaged
  `dms.service` (user unit, `PartOf=graphical-session.target`), enabled by a user preset,
  not `spawn-at-startup`. No `DMS_PRIVESC` drop-in, no qt6ct config, and no danksearch.
- `/usr/share/juniper/niri/juniper.kdl` (read-only, image-owned) keeps: xwayland-satellite,
  `prefer-no-csd`, the idle-hint helper, and Juniper's binds; it adds zirconium's DMS
  integration (`layer-rule` for the `quickshell` namespace, lid close →
  `dms ipc call lock lock`, `config-notification { disable-failed }`) and DMS binds:
  Mod+Space / Mod+D launcher, Mod+N notifications, Super+Alt+L lock, Mod+V clipboard,
  Ctrl+Shift+Esc process list, screenshots via `dms ipc call niri screenshot*`, media and
  brightness keys (`allow-when-locked`). Mod+Return opens `xdg-terminal-exec` (foot).
- `desktop-idle-lock` becomes `desktop-idle-hint`: `swayidle -w idlehint 1800` only. Lock on
  idle moves to DMS (`acLockTimeout` 600 in the shipped settings); `ujust desktop-lock-idle
  on|off` edits that setting with `jq` instead of a flag file. Locking is a convenience:
  authentication already happened at the greeter.
- `desktop-idle`'s and `flatpak-setup`'s `notify-send` land in DMS's notification centre
  (unchanged code).
- Clipboard history: `cliphist` via DMS (in memory/`~/.cache`; documented).

## User configuration (chezmoi)

- Source tree: `/usr/share/juniper/dots/` (chezmoi source format), containing:
  - `dot_config/niri/config.kdl`: includes only:
    `/usr/share/juniper/niri/juniper.kdl`, then DMS's files under `dms/` (optional
    includes; DMS writes them), then `local.kdl` (optional, the user's).
  - `dot_config/DankMaterialShell/settings.json`: wallpaper, `currentThemeName: "dynamic"`,
    `matugenScheme: "scheme-tonal-spot"`, dark mode, `weatherEnabled: false`,
    `useAutoLocation: false`, `acLockTimeout: 600`, `lockBeforeSuspend: true`, system-update
    widget hidden.
  - `dot_config/foot/foot.ini`, GTK 3/4 settings that include the matugen-generated colour files.
  - DMS-owned files (`settings.json`, `session.json`, foot's `dank-colors.ini`) are chezmoi
    `create_` files: written only when missing, never overwritten by the daily update.
    Image-owned entry files (niri `config.kdl`, `dms.kdl`, `foot.ini`, GTK settings) are normal
    files that the daily update refreshes unless the user changed them.
- `juniper-dots-init.service` (user, `ConditionPathExists=!%h/.local/state/juniper/dots.done`):
  `chezmoi apply --source /usr/share/juniper/dots --config ~/.config/juniper/chezmoi/chezmoi.toml
  --persistent-state ~/.config/juniper/chezmoi/chezmoistate.boltdb`, then writes the marker. The
  Juniper-owned config and state paths leave a user's own chezmoi setup untouched.
- `juniper-dots-update.timer` (daily): re-applies, skipping files changed since last apply
  (`--keep-going`, chezmoi's `skip` on conflicts), so image updates reach unchanged files.
- `ujust dots-update`, `ujust dots-reset [niri|all]` (back up then re-apply; `niri` resets only `config.kdl` and
  `dms.kdl`, never `local.kdl` or DMS's own niri files), `ujust toggle-auto-dots`. Managed files
  that already existed when Juniper first saw them (on the first run of any `dots` command, or
  when a newer image adds a file; `~/.local/state/juniper/dots-known` lists the ones seen) are
  kept, never overwritten, and listed in `~/.local/state/juniper/dots-kept`; they get no updates until `ujust dots-reset`. `ujust desktop-config` goes away (chezmoi writes `config.kdl`).
- Only on `juniper-desktop`; the headless images don't ship chezmoi.

## Look

- `/usr/share/juniper/wallpapers/juniper-berry.svg`: Juniper's terminal logo (fastfetch's
  `logo.txt`: a berry under three spokes) abstracted to an open ring and three strokes, in one
  cyan-to-magenta neon line, leaning back from the viewer in perspective, right of centre with
  its base pointing at the bottom centre of the screen, on a plain navy-to-violet gradient
  (changed after the first hardware run; it was a flat blue-violet berry cluster, centred).
  Original artwork: recognisably a juniper, not a copy of the Raspberry Pi logo (a
  trademark). A PNG render at 3840x2160 for matugen and the greeter (matugen reads raster).
- matugen derives the Material You palette from it at first login (DMS does this; seconds on
  a Pi 5). foot and GTK follow. Greeter shows the same wallpaper.

## Things removed

`waybar`, `fuzzel`, `SwayNotificationCenter`, `swaylock`, `swaybg`, `agreety` config,
`desktop-idle-lock`'s lock path, `ujust desktop-config`, juniper.kdl's spawns of
swaync/waybar.

## Testing

- `tests/image.sh` (desktop):
  - `need_cmds dms qs dms-greeter niri chezmoi matugen foot swayidle`; waybar, fuzzel,
    swaync, swaylock absent;
  - the greetd command line exactly; the `greetd-spawn` PAM file; drop-in rule becomes an
    allow-list instead of "no drop-ins";
  - `chezmoi apply` of the shipped source into a scratch home, then `niri validate` on the
    resulting `config.kdl` (which pulls in juniper.kdl);
  - shipped `settings.json` is valid JSON with weather off and lock timeout set;
  - lock-file NEVRAs installed; no COPR repo files left.
- `tests/unit.sh`: `desktop-idle-hint`, `desktop-lock-idle` editing settings.json (missing
  file, invalid JSON, toggling), dots-init idempotence with a stub chezmoi.
- Hardware (owner, #58, needs the micro-HDMI cable): greeter shows, password accepted,
  keyring unlocked, DMS bar/launcher/lock work, matugen theme applied, idle hint after
  30 min, reboot deferral notice visible, `systemctl --failed` clean.

## Docs

Rewrite the desktop spec's decision rows that this replaces (pointer to this file), README's
desktop section and feature table, CHANGELOG (Changed), THIRD_PARTY (avengemedia COPRs,
quickshell, wallpaper licence), STATUS.

## Risks

- **New COPR trust root.** Mitigated by pins and fences; still a single-maintainer project.
- **DMS moves fast** (1.x releases weekly). Bumps can change settings keys; the image test
  on the shipped settings and `niri validate` catch the worst.
- **RAM on a 4 GB Pi.** quickshell + DMS + greeter: measure on hardware; fallback is
  disabling DMS's heavier widgets in the shipped settings.
- **Greeter on EL10.** dms-greeter's epel-10 build is new; first boot on hardware is the
  real test, and agreety remains a one-line revert in `config.toml`.
