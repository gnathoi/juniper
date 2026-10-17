# juniper-desktop on DankMaterialShell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the experimental desktop's waybar/fuzzel/swaync/swaylock session and agreety login with niri + DankMaterialShell and the dms-greeter graphical login, themed from a Juniper wallpaper, keeping every Juniper guarantee (auth before session, health-gated updates, pinned packages, nothing phoning home).

**Architecture:** `build_files/desktop.sh` installs DMS from two new pinned, fenced, build-time-only COPRs. greetd runs `dms-greeter --command niri`; the logged-in session is `niri-session`, whose `graphical-session.target` starts the packaged `dms.service`. Image-owned niri defaults stay read-only in `/usr/share/juniper/niri/juniper.kdl`; per-user files (niri entry config, DMS settings, foot) come from a chezmoi source tree in `/usr/share/juniper/dots`, applied by `/usr/libexec/juniper/dots` at first login and daily. Small helpers (`desktop-idle-hint`, `desktop-lock-idle`, `dots`) carry the logic and are unit-tested with stubs; `tests/image.sh` checks the built image.

**Tech Stack:** bootc Containerfile on AlmaLinux 10 aarch64, bash 5.2, systemd (system + user units), greetd, niri 26.04, DankMaterialShell 1.6.x (quickshell), dms-greeter, matugen, chezmoi (EPEL), jq, `tests/unit.sh` (stubbed bash tests), `tests/image.sh` (runs inside the built image in CI).

**Spec:** `docs/superpowers/specs/2026-10-14-dms-desktop-design.md` (read it with this plan). Older context: `docs/superpowers/specs/2026-10-10-juniper-desktop-design.md`.

## Facts checked while planning (2026-10-14)

- epel-10-aarch64 builds: `avengemedia/dms`: dms-1.6.3-1.el10, dms-cli-1.6.3-1.el10. `avengemedia/danklinux`: dms-greeter-1:1.6.2-3.el10, quickshell-0.3.2-1.el10, matugen-4.2.0-1.el10, dgop-1:1.6.2-1.el10, cliphist-0.7.0-1.el10, material-symbols-fonts-1.0-1.el10, danksearch-1.6.0-1.el10. A dry-run install of all of them plus `accountsservice qt6-qtmultimedia qt6-qtwayland chezmoi xdg-terminal-exec greetd` resolves with only those COPR packages from the COPRs (greetd from `yselkowitz/cosmic-epel`); everything else comes from AlmaLinux/EPEL. `cava`, `udiskie`, `ghostty`, `qt6ct-kde` are not available and not used.
- `dms` ships `/usr/lib/systemd/user/dms.service` (`PartOf=`/`WantedBy=graphical-session.target`, `ExecStart=/usr/bin/dms run --session`, `Type=dbus`, owns `org.freedesktop.Notifications`).
- `dms-greeter` (separate package, MIT, github.com/AvengeMedia/dank-greeter): `%pre` creates system user/group `greeter` (home `/var/lib/greeter`); `%post` runs `semanage fcontext` for `/usr/bin/dms-greeter` (bin_t), `/var/lib/greeter` (user_home_dir_t), `/var/cache/dms-greeter` (cache_home_t), **rewrites `/etc/greetd/config.toml`** to `dms-greeter --command niri` when it lacks "dms-greeter", and leaves `/etc/pam.d/greetd` alone if it mentions system-auth. Usage: `dms-greeter --command niri [--cache-dir DIR] [-C niri.kdl]`; without `-C` it writes its own minimal niri config. `--command` names the **compositor the greeter runs in**; the user picks the session (`niri.desktop` → `niri-session`) in the greeter.
- DMS settings (`~/.config/DankMaterialShell/settings.json`) and session state (`~/.local/state/DankMaterialShell/session.json`) are parsed key by key; missing keys take the spec default, so partial files are valid. Relevant keys: `currentThemeName` (default `"purple"`; `"dynamic"` = matugen from the wallpaper), `matugenScheme`, `weatherEnabled` (default true, open-meteo), `showWeather`, `useAutoLocation` (default false), `acLockTimeout`/`batteryLockTimeout` (seconds, default 0), `lockBeforeSuspend`, `updaterHideWidget`, `updaterUseCustomCommand`, `updaterCustomCommand`; `wallpaperPath` and `isLightMode` live in session.json.
- DMS's Go server can set logind's idle hint only when asked over IPC; nothing calls it. DMS's system-update backend for rpm-ostree runs `rpm-ostree upgrade`.
- zirconium's zdots (Apache-2.0, github.com/zirconium-dev/zdots @ ba17a3a) is the model for the dotfiles and greeter wiring; zirconium runs `yes s | chezmoi apply --no-tty --keep-going -S <src> --config <cfg>` so files a user changed are skipped.
- niri 26.04 accepts `include optional=true "…"`, `spawn-sh`, `layer-rule`, `switch-events { lid-close … }`, `config-notification { disable-failed }` (validated locally with niri 26.04).

## Deviations from the spec (decided while planning; the docs task updates the spec)

- greetd `command = "dms-greeter --command niri --cache-dir /var/cache/dms-greeter"` (not `--command niri-session`: `--command` is the greeter's own compositor).
- The PAM wrapper lives in `/etc/pam.d/greetd-spawn` (AlmaLinux reads `/etc/pam.d`), its env file at `/usr/share/juniper/greetd-spawn.pam_env.conf`.
- The greeter uses DMS's built-in static `purple` theme with the Juniper wallpaper (no matugen output exists before anyone logs in); the session uses `dynamic`.
- DMS-owned files (settings.json, session.json, foot's dank-colors.ini) are chezmoi `create_` files: written only when missing, never overwritten by the daily update. Image-owned entry files (niri `config.kdl`, `dms.kdl`, `foot.ini`, GTK settings) are normal files that the daily update refreshes unless the user changed them.
- No `DMS_PRIVESC` drop-in, no qt6ct config, danksearch's `dsearch.service` not enabled (indexing the home dir on a Pi; DMS works without it).

## Global Constraints

- Only `juniper-desktop` changes. `juniper-minimal` and `juniper` must not gain packages, files or units (their `tests/image.sh` branches already assert desktop content is absent; keep them passing).
- COPRs stay build-time only: pinned key in `build_files/copr-keys/<owner>-<project>.gpg`, `includepkgs` fence in `build_files/desktop-copr.txt`, exact versions in `build_files/desktop.lock` (written by `just bump-desktop`, never by hand), repo files deleted after install.
- No session exists before PAM accepts a password: no `initial_session`, no auto-login, greeter runs as the unprivileged `greeter` user.
- Juniper's update path is the only one: DMS's update widget is hidden and its custom command is `ujust update`.
- Nothing phones home by default: `weatherEnabled: false`, `showWeather: false`, `useAutoLocation: false`; no DMS plugins shipped.
- Reboot deferral keeps working: logind idle hint set after 1800 s idle by `swayidle -w idlehint 1800`; the user session's logind type must be `wayland` (greetd-spawn PAM env).
- Lock on idle default 600 s (DMS `acLockTimeout`/`batteryLockTimeout`), toggled by `ujust desktop-lock-idle on|off`.
- bash 5.2: never `x=$(<file)` (use `cat`); `set -euo pipefail` in scripts; no `yes | cmd` pipelines under pipefail (use `< <(yes s)`).
- Commit subjects and the PR title use a conventional prefix (`feat:`, `fix:`, `docs:`, `test:`, `build:`); every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `shellcheck` clean, `tests/unit.sh` passes and `pre-commit run --files <changed>` passes before each commit.

## Review Focus

- **A user who already has `~/.config/niri/config.kdl`** (from the old `ujust desktop-config`): the first dots apply must keep it (skip), not fail the unit or clobber it; `ujust dots-reset niri` moves it to a backup and installs Juniper's. Tested in Task 5 (`test_dots_*` with a stub chezmoi + image-level real apply into a home with a pre-existing file).
- **The greeter user's labels after a bootc build**: `semanage` ran during the RPM scriptlet in the build container; the image must still label `/var/lib/greeter` and `/var/cache/dms-greeter` correctly, or the greeter can't start under enforcing SELinux. Tested in Task 3 (`matchpathcon` in image.sh).
- **Lock-file entries with an epoch** (`dms-greeter-1:1.6.2-3.el10`, `dgop-1:…`): `rpm -q NVR` may not accept them, so the image test must compare `%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}` itself. Tested in Task 1.
- **`desktop-lock-idle` on a missing or hand-broken settings.json**: must create/refuse cleanly, never truncate the file. Tested in Task 5.
- **The dms-greeter `%post` rewriting `/etc/greetd/config.toml`** at install: our copy must win (desktop.sh copies `system_files_desktop` after the install) and `[general] service = "greetd-spawn"` must survive. Tested in Task 3 (exact-line checks in unit + image tests).

---

### Task 1: Packages and trust (DMS COPRs, lock, install list)

**Files:**
- Create: `build_files/copr-keys/avengemedia-dms.gpg`, `build_files/copr-keys/avengemedia-danklinux.gpg`
- Modify: `build_files/desktop-copr.txt`, `build_files/desktop.lock` (regenerated), `build_files/desktop.sh:24-30`
- Test: `tests/image.sh` (desktop branch: `need_cmds` line ~391 and the lock loop ~437)

**Interfaces:**
- Produces: commands on PATH in the desktop image: `dms`, `qs`, `dms-greeter`, `matugen`, `dgop`, `cliphist`, `chezmoi`, `xdg-terminal-exec`, `foot`, `swayidle`, `niri`, `greetd`; packages `accountsservice`, `qt6-qtmultimedia`, `qt6-qtwayland`, `material-symbols-fonts`. Gone: `waybar`, `fuzzel`, `swaync`, `swaylock`, `swaybg`.

- [ ] **Step 1: Fetch and pin the two COPR keys**

```bash
for p in dms danklinux; do
  curl -fsSL "https://download.copr.fedorainfracloud.org/results/avengemedia/$p/pubkey.gpg" \
    -o "build_files/copr-keys/avengemedia-$p.gpg"
  gpg --show-keys --with-fingerprint "build_files/copr-keys/avengemedia-$p.gpg"
done
```
Expected: one `pub rsa4096 … avengemedia_<project> (None) <avengemedia#<project>@copr.fedorahosted.org>` key per file. Copy both fingerprints into the commit message.

- [ ] **Step 2: Rewrite the fences**

`build_files/desktop-copr.txt` (whole file):
```
# OWNER/PROJECT PACKAGE... (includepkgs fence: the packages we use plus the COPR's own deps)
yalter/niri niri
yselkowitz/wlroots-epel xwayland-satellite foot foot-terminfo swayidle brightnessctl playerctl playerctl-libs fcft libsfdo
yselkowitz/cosmic-epel greetd greetd-selinux
avengemedia/dms dms dms-cli
avengemedia/danklinux dms-greeter quickshell matugen dgop cliphist material-symbols-fonts
```
(waybar, fuzzel, swaylock, swaybg, SwayNotificationCenter and their private deps nanosvg, gtk-layer-shell, gtk4-layer-shell, libmpdclient, granite, jsoncpp are dropped; fcft and libsfdo stay for foot.)

- [ ] **Step 3: Regenerate the lock**

Run: `just bump-desktop`
Expected: exit 0; `build_files/desktop.lock` now lists (versions may be newer) `cliphist-0.7.0-1.el10`, `dgop-1:1.6.2-1.el10`, `dms-1.6.3-1.el10`, `dms-cli-1.6.3-1.el10`, `dms-greeter-1:1.6.2-3.el10`, `material-symbols-fonts-1.0-1.el10`, `matugen-4.2.0-1.el10`, `quickshell-0.3.2-1.el10` plus the kept niri/foot/greetd/swayidle entries, and no waybar/fuzzel/swaylock/swaybg/SwayNotificationCenter. If it reports `not found in the COPRs: X`, X is not built for epel-10-aarch64: drop it from the fence only if foot/dms don't need it (check with the dry run in Step 6), else stop and report.

- [ ] **Step 4: Update the install list**

In `build_files/desktop.sh`, replace the `dnf -y install` block with:
```bash
mapfile -t locked </ctx/build_files/desktop.lock
dnf -y install --exclude=fzf "${locked[@]}" \
  xorg-x11-server-Xwayland wl-clipboard libnotify flatpak \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring \
  pipewire wireplumber pipewire-pulseaudio \
  mesa-dri-drivers mesa-vulkan-drivers \
  accountsservice qt6-qtmultimedia qt6-qtwayland chezmoi xdg-terminal-exec \
  google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts
```
(Weak deps stay on, as before: DMS's Recommends either aren't installable here (cava) or fall outside the fences (danksearch), and the existing desktop packages rely on theirs. `jq`, used by `desktop-lock-idle`, is already in every image.)

- [ ] **Step 5: Image test: commands and epoch-safe lock check**

In `tests/image.sh` desktop branch replace the `need_cmds` line with:
```bash
  need_cmds niri niri-session xwayland-satellite Xwayland greetd dms-greeter dms qs matugen dgop \
    cliphist chezmoi xdg-terminal-exec foot swayidle pipewire wireplumber flatpak notify-send jq
  # (agreety ships inside the greetd package; it's just unused)
  for cmd in waybar fuzzel swaylock swaync swaybg; do
    if command -v "$cmd" >/dev/null; then
      echo "replaced by DMS but still installed: $cmd"
      exit 1
    fi
  done
  rpm -q accountsservice qt6-qtmultimedia qt6-qtwayland material-symbols-fonts >/dev/null
```
Replace the lock loop with:
```bash
  # Every COPR package is exactly the locked version (epoch-aware: dms-greeter-1:1.6.2-3.el10)
  while read -r nevr; do
    name=${nevr%-*-*}
    have=$(rpm -q --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}\n' "$name" | sed 's/-(none):/-/; s/-0:/-/')
    [[ $have == "$nevr" ]] || {
      echo "not the locked version: $nevr (have $have)"
      exit 1
    }
  done </usr/share/juniper/desktop.lock
```

- [ ] **Step 6: Dry-run the resolution for aarch64 (no local arm64 build is possible)**

```bash
podman run --rm --arch amd64 -v ./build_files:/b:ro,z quay.io/almalinuxorg/almalinux:10 bash -c '
dnf -q install -y epel-release >/dev/null; dnf config-manager --set-enabled crb
while read -r proj pkgs; do [[ -z $proj || $proj == "#"* ]] && continue; id=${proj/\//-}
  printf "[%s]\nname=%s\nbaseurl=https://download.copr.fedorainfracloud.org/results/%s/epel-10-aarch64/\ngpgcheck=1\ngpgkey=file:///b/copr-keys/%s.gpg\nincludepkgs=%s\n" "$id" "$proj" "$proj" "$id" "$pkgs" >/etc/yum.repos.d/$id.repo
done </b/desktop-copr.txt
sed -i "s/\$basearch/aarch64/g; s/\$releasever/10/g" /etc/yum.repos.d/*.repo
mapfile -t locked </b/desktop.lock
dnf -y --forcearch=aarch64 --releasever=10 --installroot=/ir \
  --setopt=reposdir=/etc/yum.repos.d install --assumeno "${locked[@]}" accountsservice qt6-qtmultimedia \
  qt6-qtwayland chezmoi xdg-terminal-exec 2>&1 | grep -E "^Error|nothing provides|Install +[0-9]+ Packages"'
```
Expected: `Install NNN Packages`, no `Error`/`nothing provides`.

- [ ] **Step 7: Commit**

```bash
git add build_files tests/image.sh
git commit -m "build: install DankMaterialShell from pinned, fenced COPRs on juniper-desktop" -m "<key fingerprints>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Juniper wallpaper

**Files:**
- Create: `build_files/wallpaper.py` (generator), `system_files_desktop/usr/share/juniper/wallpapers/juniper-berry.svg`, `system_files_desktop/usr/share/juniper/wallpapers/juniper-berry.png` (3840x2160)
- Modify: `Justfile` (add `wallpaper` recipe)
- Test: `tests/unit.sh` (`test_wallpaper_is_current`), `tests/image.sh`

**Interfaces:**
- Produces: `/usr/share/juniper/wallpapers/juniper-berry.png` (Task 4's session.json and Task 3's greeter session.json point at this exact path).

- [ ] **Step 1: Write the failing test** (append near the other desktop tests in `tests/unit.sh`)

```bash
test_wallpaper_is_current() {
  local w=$ROOT/system_files_desktop/usr/share/juniper/wallpapers
  check "wallpaper: svg matches its generator" cmp -s <(python3 "$ROOT/build_files/wallpaper.py") "$w/juniper-berry.svg"
  check "wallpaper: png is 3840x2160" test "$(python3 -c '
import struct, sys
d = open(sys.argv[1], "rb").read(24)
print("%dx%d" % struct.unpack(">II", d[16:24]))' "$w/juniper-berry.png" 2>/dev/null)" = 3840x2160
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `UNIT_FILTER=wallpaper tests/unit.sh`
Expected: two `FAIL` lines (files missing).

- [ ] **Step 3: Add the generator** — `build_files/wallpaper.py`, executable, exactly:

```python
#!/usr/bin/env python3
"""Draws Juniper's wallpaper (juniper-berry.svg): a juniper berry cluster with needle sprigs in
blues and purples. `just wallpaper` regenerates the SVG and its 3840x2160 PNG; DMS derives the
desktop's colours from the PNG (matugen). Original artwork for Juniper, CC0-1.0."""
import math

W, H = 1920, 1080
CX, CY = 960, 600
R = 64


def berry_positions():
    pos = []
    for n, dy in ((2, -1), (3, 0), (2, 1)):
        for i in range(n):
            pos.append((CX + (i - (n - 1) / 2) * 2 * R * 1.02, CY + dy * R * 1.76))
    pos.append((CX, CY + 2 * R * 1.76))
    return pos


def berry(x, y, i):
    s = f'<g transform="translate({x:.1f},{y:.1f})">'
    s += f'<circle r="{R}" fill="url(#b{i % 3})"/>'
    s += f'<circle r="{R * 0.92:.1f}" fill="url(#bloom)"/>'
    hx, hy = -R * 0.32, -R * 0.36
    s += (f'<ellipse cx="{hx:.1f}" cy="{hy:.1f}" rx="{R * 0.22:.1f}" ry="{R * 0.13:.1f}" '
          f'fill="#dfe4ff" opacity="0.45" transform="rotate(-30 {hx:.1f} {hy:.1f})"/>')
    # The three-pointed scar at a juniper berry's tip
    s += '<g stroke="#241f5c" stroke-width="3" stroke-linecap="round" opacity="0.7">'
    for k in range(3):
        a = math.radians(90 + 120 * k)
        s += (f'<line x1="0" y1="{R * 0.5:.1f}" x2="{R * 0.15 * math.cos(a):.1f}" '
              f'y2="{R * 0.5 + R * 0.15 * math.sin(a):.1f}"/>')
    return s + "</g></g>"


def sprig(x0, y0, ang, length, bend):
    """A stem curving by `bend` degrees, with needles in pairs along it."""
    pts = []
    for k in range(41):
        t = k / 40
        a = math.radians(ang + bend * t)
        pts.append((x0 + math.cos(a) * length * t, y0 - math.sin(a) * length * t))
    out = ['<path d="M' + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
           + '" fill="none" stroke="#4d6fa3" stroke-width="7" stroke-linecap="round"/>']
    for k in range(4, 41, 3):
        x, y = pts[k]
        t = k / 40
        a = ang + bend * t
        nl = 56 * (1 - 0.5 * t)
        for side in (-1, 1):
            b = math.radians(a + side * 48)
            out.append(f'<line x1="{x:.1f}" y1="{y:.1f}" x2="{x + math.cos(b) * nl:.1f}" '
                       f'y2="{y - math.sin(b) * nl:.1f}" stroke="url(#needle)" '
                       'stroke-width="4" stroke-linecap="round"/>')
    return "".join(out)


pos = berry_positions()
top = pos[0][1] - R * 0.85
print(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
<!-- Juniper's wallpaper: a juniper berry cluster. Original artwork for Juniper, CC0-1.0. -->
<defs>
<radialGradient id="bg" cx="50%" cy="52%" r="75%"><stop offset="0" stop-color="#2b2660"/><stop offset="0.55" stop-color="#1a1740"/><stop offset="1" stop-color="#0d0b22"/></radialGradient>
<radialGradient id="b0" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#8d9cf2"/><stop offset="0.6" stop-color="#5a62cf"/><stop offset="1" stop-color="#33318f"/></radialGradient>
<radialGradient id="b1" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#a08ff0"/><stop offset="0.6" stop-color="#6c55c9"/><stop offset="1" stop-color="#3a2a8a"/></radialGradient>
<radialGradient id="b2" cx="38%" cy="32%" r="75%"><stop offset="0" stop-color="#7fb0f0"/><stop offset="0.6" stop-color="#4f6fd0"/><stop offset="1" stop-color="#2a3a8f"/></radialGradient>
<radialGradient id="bloom" cx="45%" cy="40%" r="60%"><stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
<linearGradient id="needle" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6f9fd4"/><stop offset="1" stop-color="#4a5fb0"/></linearGradient>
<radialGradient id="glow" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#6c5ce0" stop-opacity="0.28"/><stop offset="1" stop-color="#6c5ce0" stop-opacity="0"/></radialGradient>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<circle cx="{CX}" cy="{CY + 60}" r="430" fill="url(#glow)"/>
{sprig(CX - 10, top, 108, 250, 26)}
{sprig(CX + 10, top, 72, 250, -26)}
{"".join(berry(x, y, i) for i, (x, y) in enumerate(pos))}
</svg>''')
```

- [ ] **Step 4: Add the recipe** to `Justfile` (after `bump-desktop`):

```just
# Regenerate the desktop wallpaper (SVG from build_files/wallpaper.py, then its 3840x2160 PNG)
wallpaper:
    #!/usr/bin/bash
    set -euo pipefail
    d=system_files_desktop/usr/share/juniper/wallpapers
    mkdir -p "$d"
    python3 build_files/wallpaper.py >"$d/juniper-berry.svg"
    rsvg-convert -w 3840 -h 2160 "$d/juniper-berry.svg" -o "$d/juniper-berry.png"
    ls -l "$d"
```
Run: `just wallpaper` (needs `rsvg-convert`: `brew install librsvg` or `dnf install librsvg2-tools`), then open the PNG and check it by eye: centred berry cluster, two needle sprigs above, dark indigo background.

- [ ] **Step 5: Image check** (`tests/image.sh` desktop branch, after `need_cmds`):

```bash
  test -s /usr/share/juniper/wallpapers/juniper-berry.png
```

- [ ] **Step 6: Run tests**

Run: `UNIT_FILTER=wallpaper tests/unit.sh && shellcheck tests/unit.sh tests/image.sh`
Expected: `all passed`, no shellcheck output.

- [ ] **Step 7: Commit**

```bash
git add build_files/wallpaper.py Justfile system_files_desktop/usr/share/juniper/wallpapers tests
git commit -m "feat: juniper-berry wallpaper for the desktop" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Graphical login (greetd + dms-greeter)

**Files:**
- Modify: `system_files_desktop/etc/greetd/config.toml`, `system_files_desktop/usr/lib/tmpfiles.d/juniper-greetd.conf`
- Create: `system_files_desktop/etc/pam.d/greetd-spawn`, `system_files_desktop/usr/share/juniper/greetd-spawn.pam_env.conf`, `system_files_desktop/usr/share/juniper/dms-greeter/settings.json`, `system_files_desktop/usr/share/juniper/dms-greeter/session.json`, `system_files_desktop/usr/share/dms/cli-policy.json`
- Test: `tests/unit.sh` (`test_greetd_login_prompt_first`, rename to `test_greetd_graphical_login`), `tests/image.sh` (greetd block ~395-404)

**Interfaces:**
- Consumes: `/usr/share/juniper/wallpapers/juniper-berry.png` (Task 2), packages from Task 1.
- Produces: logged-in sessions typed `wayland` in logind (used by `desktop-idle`).

- [ ] **Step 1: Write the failing unit test** (replace `test_greetd_login_prompt_first`):

```bash
# greetd shows dms-greeter (as the unprivileged greeter user); a session starts only after PAM
# accepts a password, and is typed wayland in logind (the reboot window's idle check needs it).
test_greetd_graphical_login() {
  local d=$ROOT/system_files_desktop c=$ROOT/system_files_desktop/etc/greetd/config.toml
  check "greetd: no auto-login (no initial_session)" fails grep -q initial_session "$c"
  check "greetd: dms-greeter in niri" grep -qx 'command = "dms-greeter --command niri --cache-dir /var/cache/dms-greeter"' "$c"
  check "greetd: greeter runs as greeter" grep -qx 'user = "greeter"' "$c"
  check "greetd: sessions through greetd-spawn" grep -qx 'service = "greetd-spawn"' "$c"
  check "pam: greetd-spawn includes greetd" grep -qE '^auth +include +greetd$' "$d/etc/pam.d/greetd-spawn"
  check "pam: greetd-spawn types the session wayland" grep -q 'conffile=/usr/share/juniper/greetd-spawn.pam_env.conf' "$d/etc/pam.d/greetd-spawn"
  check "pam: env file" grep -qx 'XDG_SESSION_TYPE DEFAULT=wayland OVERRIDE=wayland' "$d/usr/share/juniper/greetd-spawn.pam_env.conf"
  check "greeter: static purple theme" test "$(jq -r .currentThemeName "$d/usr/share/juniper/dms-greeter/settings.json")" = purple
  check "greeter: Juniper wallpaper" test "$(jq -r .wallpaperPath "$d/usr/share/juniper/dms-greeter/session.json")" = /usr/share/juniper/wallpapers/juniper-berry.png
  check "greeter: weather off" test "$(jq -r .weatherEnabled "$d/usr/share/juniper/dms-greeter/settings.json")" = false
  check "dms: image-changing CLI commands blocked" test "$(jq -r '.blocked_commands | sort | join(",")' "$d/usr/share/dms/cli-policy.json")" = "greeter enable,greeter install,greeter uninstall,setup"
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `UNIT_FILTER=greetd tests/unit.sh`
Expected: FAIL lines for the new checks.

- [ ] **Step 3: Write the files**

`system_files_desktop/etc/greetd/config.toml`:
```toml
# Juniper Desktop: greetd shows DankMaterialShell's greeter (in its own niri, as the unprivileged
# greeter user); your session starts only after PAM accepts your password. No auto-login.
# greetd-spawn (/etc/pam.d) is greetd's PAM stack plus XDG_SESSION_TYPE=wayland for logind.
# Replaces the greetd package's default config and the one dms-greeter's install writes.
[general]
service = "greetd-spawn"

[terminal]
vt = 1

[default_session]
command = "dms-greeter --command niri --cache-dir /var/cache/dms-greeter"
user = "greeter"
```

`system_files_desktop/etc/pam.d/greetd-spawn`:
```
#%PAM-1.0
# greetd's stack for logged-in sessions, plus XDG_SESSION_TYPE=wayland so logind types the
# session correctly (desktop-idle's reboot deferral looks for wayland sessions).
auth       include      greetd
auth       required     pam_env.so conffile=/usr/share/juniper/greetd-spawn.pam_env.conf
account    include      greetd
password   include      greetd
session    include      greetd
```

`system_files_desktop/usr/share/juniper/greetd-spawn.pam_env.conf`:
```
XDG_SESSION_TYPE DEFAULT=wayland OVERRIDE=wayland
```

`system_files_desktop/usr/share/juniper/dms-greeter/settings.json`:
```json
{
  "currentThemeName": "purple",
  "weatherEnabled": false,
  "showWeather": false,
  "useAutoLocation": false,
  "clockFormat": "24h"
}
```

`system_files_desktop/usr/share/juniper/dms-greeter/session.json`:
```json
{
  "isLightMode": false,
  "wallpaperPath": "/usr/share/juniper/wallpapers/juniper-berry.png"
}
```

`system_files_desktop/usr/share/dms/cli-policy.json` (from zirconium, Apache-2.0):
```json
{
  "policy_version": 1,
  "blocked_commands": [
    "greeter install",
    "greeter enable",
    "greeter uninstall",
    "setup"
  ],
  "message": "Juniper is image-based: the greeter and DMS's system setup come with the image. Use ujust for system changes."
}
```

`system_files_desktop/usr/lib/tmpfiles.d/juniper-greetd.conf` (whole file):
```
# greetd's own tmpfiles entry only fixes ownership (Z); on bootc /var starts empty.
d /var/lib/greetd 0750 greetd greetd -
# dms-greeter's look comes with the image: Juniper's wallpaper, DMS's purple theme.
L+ /var/cache/dms-greeter/settings.json - - - - /usr/share/juniper/dms-greeter/settings.json
L+ /var/cache/dms-greeter/session.json - - - - /usr/share/juniper/dms-greeter/session.json
```

- [ ] **Step 4: Run the unit test**

Run: `UNIT_FILTER=greetd tests/unit.sh`
Expected: `all passed`.

- [ ] **Step 5: Image checks** — replace the agreety block in `tests/image.sh` desktop branch with:

```bash
  # Login: dms-greeter as the unprivileged greeter user; a session only after PAM, typed wayland.
  grep -qx 'command = "dms-greeter --command niri --cache-dir /var/cache/dms-greeter"' /etc/greetd/config.toml
  grep -qx 'service = "greetd-spawn"' /etc/greetd/config.toml
  getent passwd greeter >/dev/null
  [[ $(id -u greeter) -lt 1000 ]]
  test -s /etc/pam.d/greetd-spawn
  if grep -q initial_session /etc/greetd/config.toml ||
    compgen -G '/usr/lib/systemd/system/greetd.service.d/*' >/dev/null ||
    compgen -G '/etc/systemd/system/greetd.service.d/*' >/dev/null; then
    echo "greetd auto-login, or a drop-in overriding /etc/greetd/config.toml"
    exit 1
  fi
  # dms-greeter's install labelled its paths with semanage in the build; the image must keep them
  [[ $(matchpathcon -n /var/lib/greeter) == *:user_home_dir_t:* ]]
  [[ $(matchpathcon -n /var/cache/dms-greeter) == *:cache_home_t:* ]]
  [[ $(matchpathcon -n /usr/bin/dms-greeter) == *:bin_t:* ]]
```
If the `matchpathcon` lines fail in CI, the labels didn't survive: add the same three rules to the image at build time in `desktop.sh` (`semanage fcontext -a -t <type> '<regex>'` after the install, then rerun) and note it in the PR.

- [ ] **Step 6: Commit**

```bash
git add system_files_desktop tests
git commit -m "feat: graphical login with dms-greeter; sessions typed wayland via greetd-spawn" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Session (niri defaults, DMS service, idle hint, terminal)

**Files:**
- Modify: `system_files_desktop/usr/share/juniper/niri/juniper.kdl` (rewrite), `system_files_desktop/etc/niri/config.kdl` (comment only), `build_files/desktop.sh` (units)
- Create: `system_files_desktop/usr/libexec/juniper/desktop-idle-hint`, `system_files_desktop/usr/share/xdg-terminal-exec/xdg-terminals.list`
- Delete: `system_files_desktop/usr/libexec/juniper/desktop-idle-lock`
- Test: `tests/unit.sh` (replace `test_desktop_idle_lock`), `tests/image.sh`

**Interfaces:**
- Produces: `/usr/share/juniper/niri/juniper.kdl` (Task 5's `config.kdl` includes it first); `dms.service` globally enabled; `/usr/libexec/juniper/desktop-idle-hint` (no args, execs `swayidle -w idlehint 1800`).

- [ ] **Step 1: Write the failing tests** (replace `test_desktop_idle_lock`):

```bash
test_desktop_idle_hint() {
  stub swayidle ''
  "$LIBEXEC_DESKTOP/desktop-idle-hint"
  check "idle-hint: logind idle hint after 30 min" called "swayidle -w idlehint 1800"
  check "idle-hint: never locks (DMS does)" not_called "timeout"
  local k=$ROOT/system_files_desktop/usr/share/juniper/niri/juniper.kdl
  check "niri: starts the idle hint" grep -qx 'spawn-at-startup "/usr/libexec/juniper/desktop-idle-hint"' "$k"
  check "niri: no old bar/notifier/locker" fails grep -qE 'waybar|swaync|swaylock|fuzzel|desktop-idle-lock' "$k"
  check "niri: lid close locks via DMS" grep -q 'lid-close { spawn "dms" "ipc" "call" "lock" "lock"; }' "$k"
  check "niri: DMS layer rule" grep -q 'match namespace="quickshell"' "$k"
}
```

- [ ] **Step 2: Run to see it fail**

Run: `UNIT_FILTER=idle_hint tests/unit.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Write `desktop-idle-hint`** (mode 0755):

```bash
#!/usr/bin/env bash
# Started by niri (juniper.kdl): set logind's idle hint after 30 min idle; the reboot window
# (desktop-idle) waits for it. DankMaterialShell does the locking (ujust desktop-lock-idle).
set -euo pipefail
exec swayidle -w idlehint 1800
```
`git rm system_files_desktop/usr/libexec/juniper/desktop-idle-lock`

- [ ] **Step 4: Rewrite `juniper.kdl`** (whole file):

```kdl
// Juniper Desktop defaults: niri + DankMaterialShell. Included first by ~/.config/niri/config.kdl
// (Juniper's dotfiles, `ujust dots-reset niri`) and by /etc/niri/config.kdl. Settings you put in
// ~/.config/niri/local.kdl, and DMS's own ~/.config/niri/dms/*.kdl, override these.
// Key bindings and DMS integration adapted from zirconium (Apache-2.0).

// DMS itself starts from dms.service with the session; this sets logind's idle hint for the
// reboot window.
spawn-at-startup "/usr/libexec/juniper/desktop-idle-hint"

xwayland-satellite {
    path "xwayland-satellite"
}

prefer-no-csd

hotkey-overlay {
    skip-at-startup
}

config-notification {
    disable-failed
}

layer-rule {
    match namespace="quickshell"
    place-within-backdrop true
}

switch-events {
    lid-close { spawn "dms" "ipc" "call" "lock" "lock"; }
}

input {
    keyboard {
        numlock
    }
    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 12
    center-focused-column "never"
    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }
    default-column-width { proportion 0.5; }
}

window-rule {
    geometry-corner-radius 8
    clip-to-geometry true
}

binds {
    Mod+Slash { show-hotkey-overlay; }
    Mod+Return hotkey-overlay-title="Terminal" { spawn "xdg-terminal-exec"; }
    Mod+T hotkey-overlay-title="Terminal" { spawn "xdg-terminal-exec"; }
    Mod+Space hotkey-overlay-title="Launcher" { spawn "dms" "ipc" "call" "spotlight" "toggle"; }
    Mod+D hotkey-overlay-title="Launcher" { spawn "dms" "ipc" "call" "spotlight" "toggle"; }
    Mod+N hotkey-overlay-title="Notifications" { spawn "dms" "ipc" "call" "notifications" "toggle"; }
    Mod+V hotkey-overlay-title="Clipboard history" { spawn "dms" "ipc" "call" "clipboard" "toggle"; }
    Mod+M hotkey-overlay-title="Task manager" { spawn "dms" "ipc" "call" "processlist" "toggle"; }
    Ctrl+Shift+Escape hotkey-overlay-title="Task manager" { spawn "dms" "ipc" "call" "processlist" "toggle"; }
    Super+Alt+L hotkey-overlay-title="Lock" { spawn "dms" "ipc" "call" "lock" "lock"; }
    Mod+Alt+L hotkey-overlay-title="Lock" { spawn "dms" "ipc" "call" "lock" "lock"; }
    Print hotkey-overlay-title="Screenshot" { spawn "dms" "ipc" "call" "niri" "screenshot"; }

    XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-"; }
    XF86AudioMute allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
    XF86AudioPlay allow-when-locked=true { spawn "playerctl" "play-pause"; }
    XF86AudioNext allow-when-locked=true { spawn "playerctl" "next"; }
    XF86AudioPrev allow-when-locked=true { spawn "playerctl" "previous"; }
    XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }

    Mod+O repeat=false { toggle-overview; }
    Mod+Q repeat=false { close-window; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-up; }
    Mod+Down { focus-window-down; }
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+K { focus-window-up; }
    Mod+J { focus-window-down; }
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Shift+Up { move-window-up; }
    Mod+Shift+Down { move-window-down; }
    Mod+Page_Down { focus-workspace-down; }
    Mod+Page_Up { focus-workspace-up; }
    Mod+Shift+Page_Down { move-column-to-workspace-down; }
    Mod+Shift+Page_Up { move-column-to-workspace-up; }
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+R { switch-preset-column-width; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+C { center-column; }
    Mod+Shift+E { quit; }
}
```

- [ ] **Step 5: `/etc/niri/config.kdl` comment** (whole file):

```kdl
// niri reads this only when you have no ~/.config/niri/config.kdl (Juniper's dotfiles create
// one at first login; `ujust dots-reset niri` restores it). It pulls in Juniper's defaults.
include "/usr/share/juniper/niri/juniper.kdl"
```

- [ ] **Step 6: Terminal default** — `system_files_desktop/usr/share/xdg-terminal-exec/xdg-terminals.list`:
```
foot.desktop
```

- [ ] **Step 7: Units in `build_files/desktop.sh`** — after `systemctl enable greetd.service` add:
```bash
# DankMaterialShell starts with every graphical session (dms.service, WantedBy=graphical-session.target)
systemctl --global enable dms.service
```

- [ ] **Step 8: Image checks** (`tests/image.sh` desktop branch; replace the old `niri validate` / desktop-config lines):

```bash
  niri validate -c /usr/share/juniper/niri/juniper.kdl
  niri validate -c /etc/niri/config.kdl
  [[ $(systemctl --global is-enabled dms.service) == enabled ]]
  test -x /usr/libexec/juniper/desktop-idle-hint
  test ! -e /usr/libexec/juniper/desktop-idle-lock
  grep -qx foot.desktop /usr/share/xdg-terminal-exec/xdg-terminals.list
```

- [ ] **Step 9: Validate locally and run tests**

Run: `niri validate -c system_files_desktop/usr/share/juniper/niri/juniper.kdl` (niri 26.04 on the workstation, or skip if unavailable; CI validates) and `UNIT_FILTER='idle_hint|desktop_idle' tests/unit.sh && shellcheck system_files_desktop/usr/libexec/juniper/desktop-idle-hint tests/unit.sh tests/image.sh`
Expected: `config is valid`; `all passed`.

- [ ] **Step 10: Commit**

```bash
git add -A system_files_desktop build_files/desktop.sh tests
git commit -m "feat: niri + DankMaterialShell session; swayidle only sets the idle hint" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Dotfiles (chezmoi) and the desktop ujust recipes

**Files:**
- Create: `system_files_desktop/usr/share/juniper/dots/` tree (below), `system_files_desktop/usr/libexec/juniper/dots`, `system_files_desktop/usr/libexec/juniper/desktop-lock-idle`, `system_files_desktop/usr/lib/systemd/user/juniper-dots-init.service`, `system_files_desktop/usr/lib/systemd/user/juniper-dots-update.service`, `system_files_desktop/usr/lib/systemd/user/juniper-dots-update.timer`
- Modify: `system_files_desktop/usr/share/juniper/just/desktop.just`, `build_files/desktop.sh` (enable user units)
- Test: `tests/unit.sh` (`test_dots_*`, `test_desktop_lock_idle_*`), `tests/image.sh`

**Interfaces:**
- Consumes: `/usr/share/juniper/niri/juniper.kdl` (Task 4), `/usr/share/juniper/wallpapers/juniper-berry.png` (Task 2).
- Produces: `/usr/libexec/juniper/dots init|update [--auto]|reset niri|all`; `/usr/libexec/juniper/desktop-lock-idle [on|off]`; env overrides for tests: `JUNIPER_DOTS_SRC` (default `/usr/share/juniper/dots`), `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `JUNIPER_NOW` (timestamp for backup names).

Source tree (`system_files_desktop/usr/share/juniper/dots/`), chezmoi naming:

```
private_dot_config/niri/config.kdl                           (image-owned, refreshed daily)
private_dot_config/niri/dms.kdl                              (image-owned)
private_dot_config/DankMaterialShell/create_settings.json    (created once; DMS owns it after)
private_dot_local/state/DankMaterialShell/create_session.json
private_dot_config/foot/foot.ini                             (image-owned)
private_dot_config/foot/create_dank-colors.ini               (created once; DMS rewrites it)
private_dot_config/gtk-3.0/settings.ini
private_dot_config/gtk-4.0/settings.ini
```
`private_` on `.config` and `.local`: chezmoi sets the mode of directories it manages, and these
must stay 0700 (never loosen a user's home). Subdirectories are normal.

- [ ] **Step 1: Write the failing tests** (add to `tests/unit.sh`):

```bash
DOTS=$ROOT/system_files_desktop/usr/libexec/juniper/dots
dots_env() {
  export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config XDG_STATE_HOME=$T/home/.local/state
  export JUNIPER_DOTS_SRC=$T/src JUNIPER_NOW=20261014-120000
  mkdir -p "$HOME" "$JUNIPER_DOTS_SRC"
  # chezmoi stub: log argv and what it read on stdin (the skip answers)
  # shellcheck disable=SC2016 # expands inside the stub
  stub chezmoi 'if [[ $1 == managed ]]; then printf "%s\n" "$HOME/.config/niri/config.kdl" "$HOME/.config/niri/dms.kdl" "$HOME/.config/foot/foot.ini"; exit 0; fi
head -c 2 >"$T/chezmoi-stdin" || true'
}

test_dots_init_once() {
  dots_env
  "$DOTS" init
  check "dots: init applies Juniper's source" called "chezmoi apply --source $T/src --config $XDG_CONFIG_HOME/juniper/chezmoi/chezmoi.toml --persistent-state $XDG_CONFIG_HOME/juniper/chezmoi/chezmoistate.boltdb --no-tty --keep-going"
  check "dots: files you changed are skipped (s answers)" test "$(cat "$T/chezmoi-stdin")" = "s
"
  check "dots: own chezmoi config, not yours" test -e "$XDG_CONFIG_HOME/juniper/chezmoi/chezmoi.toml"
  check "dots: marked done" test -e "$XDG_STATE_HOME/juniper/dots.done"
  : >"$CALLS"
  "$DOTS" init
  check "dots: init only once" not_called "chezmoi apply"
}

test_dots_init_failure_retried() {
  dots_env
  stub chezmoi 'exit 1'
  check "dots: failed apply fails" fails "$DOTS" init
  check "dots: failed apply not marked done" test ! -e "$XDG_STATE_HOME/juniper/dots.done"
}

test_dots_update_respects_opt_out() {
  dots_env
  "$DOTS" update --auto
  check "dots: daily update applies" called "chezmoi apply"
  mkdir -p "$XDG_CONFIG_HOME/juniper" && : >"$XDG_CONFIG_HOME/juniper/no-auto-dots"
  : >"$CALLS"
  "$DOTS" update --auto
  check "dots: automatic update off -> skipped" not_called "chezmoi apply"
  "$DOTS" update
  check "dots: ujust dots-update still applies" called "chezmoi apply"
}

test_dots_reset_backs_up_then_forces() {
  dots_env
  mkdir -p "$HOME/.config/niri" "$HOME/.config/foot"
  echo mine >"$HOME/.config/niri/config.kdl"
  echo myfoot >"$HOME/.config/foot/foot.ini"
  "$DOTS" reset niri >/dev/null
  local b=$XDG_STATE_HOME/juniper/dots-backup-20261014-120000
  check "dots reset niri: old file kept in the backup" test "$(cat "$b/.config/niri/config.kdl")" = mine
  check "dots reset niri: moved out of the way" test ! -e "$HOME/.config/niri/config.kdl"
  check "dots reset niri: foot untouched" test -e "$HOME/.config/foot/foot.ini"
  check "dots reset niri: forced apply of niri only" called "chezmoi apply --source $T/src"
  check "dots reset niri: --force" called "--force $HOME/.config/niri"
  "$DOTS" reset all >/dev/null
  check "dots reset all: foot backed up too" test -e "$b/.config/foot/foot.ini"
  check "dots: bad scope refused" fails "$DOTS" reset everything
  check "dots: bad command refused" fails "$DOTS" frobnicate
}

LOCKIDLE=$ROOT/system_files_desktop/usr/libexec/juniper/desktop-lock-idle
test_desktop_lock_idle_edits_dms_settings() {
  export XDG_CONFIG_HOME=$T/cfg
  local s=$T/cfg/DankMaterialShell/settings.json
  "$LOCKIDLE" off >/dev/null
  check "lock-idle off: creates settings with 0" test "$(jq -c '[.acLockTimeout,.batteryLockTimeout]' "$s")" = '[0,0]'
  echo '{"currentThemeName":"dynamic","acLockTimeout":0}' >"$s"
  "$LOCKIDLE" on >/dev/null
  check "lock-idle on: 600 s" test "$(jq -c '[.acLockTimeout,.batteryLockTimeout]' "$s")" = '[600,600]'
  check "lock-idle: other settings kept" test "$(jq -r .currentThemeName "$s")" = dynamic
  check "lock-idle: status" stdout_has "on" "$LOCKIDLE"
  echo 'not json' >"$s"
  check "lock-idle: broken settings refused" fails "$LOCKIDLE" off
  check "lock-idle: broken settings left as they were" test "$(cat "$s")" = "not json"
  check "lock-idle: bad arg refused" fails "$LOCKIDLE" maybe
}
```
(`stdout_has` and `fails` already exist in `tests/unit.sh`; `stub` logs `NAME args` to `$CALLS`.)

- [ ] **Step 2: Run to see them fail**

Run: `UNIT_FILTER='dots|lock_idle' tests/unit.sh`
Expected: FAIL lines (scripts missing).

- [ ] **Step 3: Write `/usr/libexec/juniper/dots`** (0755):

```bash
#!/usr/bin/env bash
# Juniper's desktop dotfiles: chezmoi applies /usr/share/juniper/dots into your home with its own
# config and state (~/.config/juniper/chezmoi), so a chezmoi setup of yours is untouched.
#   init           first login (juniper-dots-init.service), once
#   update [--auto] daily (juniper-dots-update.timer, --auto: skipped after `ujust toggle-auto-dots`)
#   reset niri|all  move Juniper's files out of the way (backup in ~/.local/state/juniper) and
#                   apply them fresh (ujust dots-reset)
# Files you changed are skipped (chezmoi asks; we answer "s"). Files DMS owns (settings, colours)
# are only created when missing.
set -euo pipefail

src=${JUNIPER_DOTS_SRC:-/usr/share/juniper/dots}
cfg=${XDG_CONFIG_HOME:-$HOME/.config}
cfgdir=$cfg/juniper/chezmoi
state=${XDG_STATE_HOME:-$HOME/.local/state}/juniper
args=(--source "$src" --config "$cfgdir/chezmoi.toml" --persistent-state "$cfgdir/chezmoistate.boltdb"
  --no-tty --keep-going)

usage() {
  echo "usage: dots init | update [--auto] | reset niri|all" >&2
  exit 2
}
apply() {
  mkdir -p "$cfgdir"
  [[ -e $cfgdir/chezmoi.toml ]] || : >"$cfgdir/chezmoi.toml"
  chezmoi apply "${args[@]}" "$@" < <(yes s)
}

case ${1:-} in
  init)
    [[ ! -e $state/dots.done ]] || exit 0
    apply
    mkdir -p "$state"
    : >"$state/dots.done"
    ;;
  update)
    if [[ ${2:-} == --auto && -e $cfg/juniper/no-auto-dots ]]; then
      exit 0
    fi
    apply
    ;;
  reset)
    case ${2:-} in
      niri) targets=("$cfg/niri") ;;
      all) mapfile -t targets < <(chezmoi managed "${args[@]:0:6}" --path-style absolute --include files) ;;
      *) usage ;;
    esac
    backup=$state/dots-backup-${JUNIPER_NOW:-$(date +%Y%m%d-%H%M%S)}
    for t in "${targets[@]}"; do
      [[ -e $t ]] || continue
      rel=${t#"$HOME"/}
      mkdir -p "$backup/$(dirname "$rel")"
      mv "$t" "$backup/$rel"
    done
    apply --force "${targets[@]}"
    echo "Reset ${2}; your previous files are in $backup"
    ;;
  *) usage ;;
esac
```
(`"${args[@]:0:6}"` is `--source … --config … --persistent-state …` without the apply-only flags.)

- [ ] **Step 4: Write `/usr/libexec/juniper/desktop-lock-idle`** (0755):

```bash
#!/usr/bin/env bash
# `ujust desktop-lock-idle [on|off]`: DankMaterialShell locks the screen after 10 minutes idle
# (on) or never (off); with no argument, say which. Edits DMS's settings.json in place (DMS
# picks the change up live); a settings file that isn't valid JSON is left alone.
set -euo pipefail
f=${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/settings.json

current() {
  local t
  t=$(jq -r '.acLockTimeout // 0' "$f" 2>/dev/null || echo 0)
  if ((t > 0)); then echo "Lock on idle: on"; else echo "Lock on idle: off"; fi
}
set_timeout() {
  local tmp
  mkdir -p "${f%/*}"
  [[ -s $f ]] || echo '{}' >"$f"
  jq -e . "$f" >/dev/null 2>&1 || {
    echo "desktop-lock-idle: $f isn't valid JSON; fix it or remove it first" >&2
    exit 1
  }
  tmp=$(mktemp "$f.XXXXXX")
  jq --argjson t "$1" '.acLockTimeout = $t | .batteryLockTimeout = $t' "$f" >"$tmp"
  mv "$tmp" "$f"
}

case ${1:-} in
  on) set_timeout 600 && echo "Lock on idle: on (after 10 minutes)." ;;
  off) set_timeout 0 && echo "Lock on idle: off." ;;
  "") current ;;
  *)
    echo "usage: ujust desktop-lock-idle [on|off]" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 5: Write the dotfiles source tree**

`private_dot_config/niri/config.kdl`:
```kdl
// Juniper Desktop: your niri config. Juniper's defaults first, then DankMaterialShell's own
// settings (dms.kdl), then yours: put your changes in ~/.config/niri/local.kdl.
// Juniper's daily dotfiles update refreshes this file unless you edit it; `ujust dots-reset niri`
// brings it back.
include "/usr/share/juniper/niri/juniper.kdl"
include "dms.kdl"
include optional=true "local.kdl"
```

`private_dot_config/niri/dms.kdl` (from zdots, Apache-2.0):
```kdl
// Settings DankMaterialShell writes from its settings window (binds, colours, layout, outputs…).
include optional=true "dms/alttab.kdl"
include optional=true "dms/binds.kdl"
include optional=true "dms/colors.kdl"
include optional=true "dms/layout.kdl"
include optional=true "dms/wpblur.kdl"
include optional=true "dms/outputs.kdl"
include optional=true "dms/cursor.kdl"
include optional=true "dms/windowrules.kdl"
include optional=true "dms/input.kdl"
```

`private_dot_config/DankMaterialShell/create_settings.json`:
```json
{
  "currentThemeName": "dynamic",
  "currentThemeCategory": "dynamic",
  "matugenScheme": "scheme-tonal-spot",
  "runUserMatugenTemplates": true,
  "clockFormat": "24h",
  "weatherEnabled": false,
  "showWeather": false,
  "useAutoLocation": false,
  "acLockTimeout": 600,
  "batteryLockTimeout": 600,
  "lockBeforeSuspend": true,
  "updaterHideWidget": true,
  "updaterCheckOnStart": false,
  "updaterUseCustomCommand": true,
  "updaterCustomCommand": "ujust update",
  "updaterIncludeFlatpak": false
}
```

`private_dot_local/state/DankMaterialShell/create_session.json`:
```json
{
  "isLightMode": false,
  "wallpaperPath": "/usr/share/juniper/wallpapers/juniper-berry.png",
  "nightModeUseIPLocation": false,
  "showThirdPartyPlugins": false
}
```

`private_dot_config/foot/foot.ini`:
```ini
# Juniper's foot config; DankMaterialShell keeps dank-colors.ini in step with your wallpaper.
# Refreshed by Juniper's daily dotfiles update unless you edit it.
[main]
font=Noto Sans Mono:size=12
pad=8x8
include=~/.config/foot/dank-colors.ini

[colors]
alpha=0.92
```

`private_dot_config/foot/create_dank-colors.ini` (a starting palette until DMS writes its own):
```ini
[colors]
foreground=e3e1f5
background=17153a
regular0=1f1c45
regular1=e46a8a
regular2=7fc8a9
regular3=e5c07b
regular4=7b8cf0
regular5=a68cf5
regular6=6fb8e0
regular7=c9c6e8
bright0=3b3770
bright1=f08aa4
bright2=9fdcbf
bright3=f0d39a
bright4=9aa8f7
bright5=bfa8fa
bright6=8fcdef
bright7=f1effd
```

`private_dot_config/gtk-3.0/settings.ini` and `private_dot_config/gtk-4.0/settings.ini` (same content):
```ini
[Settings]
gtk-application-prefer-dark-theme=1
```

- [ ] **Step 6: User units**

`system_files_desktop/usr/lib/systemd/user/juniper-dots-init.service`:
```ini
[Unit]
Description=Juniper desktop dotfiles (first login)
ConditionPathExists=!%h/.local/state/juniper/dots.done
Before=graphical-session-pre.target niri.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/dots init

[Install]
WantedBy=graphical-session-pre.target
```

`juniper-dots-update.service`:
```ini
[Unit]
Description=Juniper desktop dotfiles (daily refresh of files you haven't changed)

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/dots update --auto
```

`juniper-dots-update.timer`:
```ini
[Unit]
Description=Daily Juniper desktop dotfiles refresh
ConditionPathExists=%h/.local/state/juniper/dots.done

[Timer]
OnStartupSec=5min
OnUnitInactiveSec=1d

[Install]
WantedBy=timers.target
```

In `build_files/desktop.sh` after the dms line:
```bash
systemctl --global enable juniper-dots-init.service juniper-dots-update.timer
```

- [ ] **Step 7: ujust recipes** — `system_files_desktop/usr/share/juniper/just/desktop.just` (whole file):

```just
# Lock the screen after 10 minutes idle: on (default) or off; no argument shows which
desktop-lock-idle state="":
    /usr/libexec/juniper/desktop-lock-idle {{ quote(state) }}

# Re-apply Juniper's desktop dotfiles now (files you changed are kept)
dots-update:
    /usr/libexec/juniper/dots update

# Put Juniper's niri config (niri) or all its desktop dotfiles (all) back; yours go to a backup
dots-reset scope="niri":
    /usr/libexec/juniper/dots reset {{ quote(scope) }}

# Turn the daily dotfiles refresh off or on
toggle-auto-dots:
    #!/usr/bin/bash
    set -euo pipefail
    f="$HOME/.config/juniper/no-auto-dots"
    if [[ -e $f ]]; then rm "$f"; echo "Daily dotfiles refresh on."; else mkdir -p "${f%/*}"; touch "$f"; echo "Daily dotfiles refresh off."; fi

# Install (or finish installing) Firefox and the Bazaar app store from Flathub
flatpak-setup:
    sudo /usr/libexec/juniper/flatpak-setup
```
(`desktop-lock-idle ""`: `quote("")` passes `''`, which the script treats as no argument.)

- [ ] **Step 8: Run unit tests**

Run: `UNIT_FILTER='dots|lock_idle' tests/unit.sh && shellcheck system_files_desktop/usr/libexec/juniper/{dots,desktop-lock-idle} tests/unit.sh`
Expected: `all passed`; no shellcheck output.

- [ ] **Step 9: Real chezmoi check locally** (chezmoi and niri exist on the workstation; CI repeats it in the image):

```bash
h=$(mktemp -d)
HOME=$h chezmoi apply --source system_files_desktop/usr/share/juniper/dots --config "$h/c.toml" \
  --persistent-state "$h/s.db" --no-tty --keep-going --destination "$h"
find "$h" -type f | sort
sed 's|/usr/share/juniper/niri/juniper.kdl|'"$PWD"'/system_files_desktop/usr/share/juniper/niri/juniper.kdl|' \
  "$h/.config/niri/config.kdl" >"$h/.config/niri/check.kdl"
niri validate -c "$h/.config/niri/check.kdl"
rm -rf "$h"
```
Expected: the eight files listed (`.config/niri/{config,dms}.kdl`, `.config/DankMaterialShell/settings.json`, `.local/state/DankMaterialShell/session.json`, `.config/foot/{foot.ini,dank-colors.ini}`, `.config/gtk-{3,4}.0/settings.ini`); `config is valid`.

- [ ] **Step 10: Image checks** (`tests/image.sh` desktop branch):

```bash
  # Juniper's dotfiles: a fresh home gets a valid niri config and DMS settings that keep the
  # update path and the network quiet; a file the user already has is kept.
  [[ $(systemctl --global is-enabled juniper-dots-init.service) == enabled ]]
  [[ $(systemctl --global is-enabled juniper-dots-update.timer) == enabled ]]
  t=$(mktemp -d)
  mkdir -p "$t/home/.config/foot"
  echo '# mine' >"$t/home/.config/foot/foot.ini"
  HOME=$t/home /usr/libexec/juniper/dots init
  niri validate -c "$t/home/.config/niri/config.kdl"
  grep -qx '# mine' "$t/home/.config/foot/foot.ini"
  s=$t/home/.config/DankMaterialShell/settings.json
  [[ $(jq -c '[.weatherEnabled, .useAutoLocation, .updaterHideWidget, .updaterCustomCommand, .acLockTimeout]' "$s") == '[false,false,true,"ujust update",600]' ]]
  [[ $(jq -r .wallpaperPath "$t/home/.local/state/DankMaterialShell/session.json") == /usr/share/juniper/wallpapers/juniper-berry.png ]]
  HOME=$t/home /usr/libexec/juniper/desktop-lock-idle off >/dev/null
  [[ $(jq .acLockTimeout "$s") == 0 ]]
  rm -rf "$t"
  for r in desktop-lock-idle dots-update dots-reset toggle-auto-dots flatpak-setup; do
    grep -qx "$r" <<<"$recipes" || {
      echo "missing recipe: $r"
      exit 1
    }
  done
  if grep -qx desktop-config <<<"$recipes"; then
    echo "desktop-config is gone (chezmoi writes the niri config)"
    exit 1
  fi
```
Also delete the old `desktop-config` lines (`HOME=$t just … desktop-config` block and `grep -qx 'desktop-config'`) from that branch.

- [ ] **Step 11: Commit**

```bash
git add -A system_files_desktop build_files/desktop.sh tests
git commit -m "feat: desktop dotfiles via chezmoi; DMS settings keep updates on Juniper's path" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Docs

**Files:**
- Modify: `README.md` (desktop section ~306-323 and the feature table row for the desktop), `CHANGELOG.md` (Unreleased → Changed/Added), `THIRD_PARTY.md`, `docs/superpowers/specs/2026-10-14-dms-desktop-design.md` (apply the "Deviations" list above), `docs/superpowers/specs/2026-10-10-juniper-desktop-design.md` (one line under its decisions table pointing to the new spec for bar/launcher/notifications/lock/greeter), `docs/superpowers/STATUS.md` (desktop line)

- [ ] **Step 1: README desktop section** — replace the paragraph starting "It boots to a text login prompt" and the three bullets with:

```markdown
It boots to DankMaterialShell's graphical login (dms-greeter); your niri session starts after you
log in with your password. The desktop is niri with DankMaterialShell: bar, launcher (Mod+Space),
notifications (Mod+N), clipboard history (Mod+V), lock screen (Super+Alt+L) and a settings
window, coloured from Juniper's juniper-berry wallpaper. Mod+Return opens a terminal (foot);
Mod+/ shows every key. `just flash` and `ujust switch` both require a password for the first
user (uid 1000), and on a flashed desktop `sudo` asks for it too.

DankMaterialShell's weather and location lookups are off, and its update button runs
`ujust update`, so updates still go through Juniper's health-checked path.

- Your niri changes go in `~/.config/niri/local.kdl`; DMS's settings window writes its own.
  Juniper refreshes the rest of its dotfiles daily unless you changed them
  (`ujust toggle-auto-dots` turns that off); `ujust dots-reset niri|all` puts Juniper's back
  (yours go to a backup in `~/.local/state/juniper`).
- `ujust desktop-lock-idle on|off` turns the lock after 10 minutes idle on or off.
- `ujust flatpak-setup` retries the first-boot install of Firefox and Bazaar.
```

- [ ] **Step 2: CHANGELOG** — under `## Unreleased`, `### Changed` add:

```markdown
- `juniper-desktop` (experimental): the session is niri with DankMaterialShell (bar, launcher, notifications, lock, clipboard history, settings), themed from a new Juniper wallpaper, behind DankMaterialShell's graphical login instead of a text prompt. waybar, fuzzel, SwayNotificationCenter and swaylock are gone. DMS's weather and location lookups are off and its update button runs `ujust update`. Your niri changes go in `~/.config/niri/local.kdl`; Juniper's dotfiles are applied with chezmoi at first login and refreshed daily unless you changed them (`ujust dots-reset`, `ujust toggle-auto-dots`); `ujust desktop-config` is gone
```

- [ ] **Step 3: THIRD_PARTY.md** — add rows to the table:

```markdown
| DankMaterialShell (dms, dms-cli), dms-greeter, dgop, danksearch (`juniper-desktop`) | MIT | COPRs avengemedia/dms, avengemedia/danklinux |
| quickshell (`juniper-desktop`) | LGPL-3.0-only AND GPL-3.0-only | COPR avengemedia/danklinux |
| matugen (`juniper-desktop`) | GPL-2.0-or-later | COPR avengemedia/danklinux |
| cliphist (`juniper-desktop`) | GPL-3.0-or-later | COPR avengemedia/danklinux |
| Material Symbols fonts (`juniper-desktop`) | Apache-2.0 | COPR avengemedia/danklinux |
| zirconium/zdots: niri key bindings, DMS integration, `dms.kdl`, greeter wiring, cli-policy (adapted) | Apache-2.0 | github.com/zirconium-dev/zdots |
```
and drop the waybar/fuzzel/SwayNotificationCenter/swaylock/swaybg mentions if the file lists them. Note under the table that the juniper-berry wallpaper is original artwork, CC0-1.0.

- [ ] **Step 4: Spec and STATUS** — in `2026-10-14-dms-desktop-design.md` apply this plan's "Deviations from the spec" bullets to the Login, Session and User configuration sections; add a line under the 2026-10-10 spec's decisions table: `Superseded for the bar, launcher, notifications, lock and greeter by 2026-10-14-dms-desktop-design.md.`; in STATUS.md change the desktop line to say the session is niri + DMS with dms-greeter (experimental, hardware test still #58).

- [ ] **Step 5: Lint and commit**

Run: `pre-commit run --files README.md CHANGELOG.md THIRD_PARTY.md docs/superpowers/specs/*.md docs/superpowers/STATUS.md`
Expected: Passed/Skipped only.

```bash
git add README.md CHANGELOG.md THIRD_PARTY.md docs
git commit -m "docs: juniper-desktop on DankMaterialShell" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Whole-suite check and PR

- [ ] **Step 1:** `tests/unit.sh` (full) and `pre-commit run --all-files` pass locally.
- [ ] **Step 2:** `git grep -nE 'agreety|waybar|fuzzel|swaync|swaylock|desktop-idle-lock|desktop-config|no-idle-lock' -- ':!docs/superpowers/plans/2026-10-1[04]*' ':!docs/superpowers/specs/2026-10-10*' ':!CHANGELOG.md'` prints only intentional mentions (image.sh's "replaced by DMS" list).
- [ ] **Step 3:** Push `feat/dms-desktop`, open the PR titled `feat: juniper-desktop on niri + DankMaterialShell with a graphical login`, body ending `Part of #58` and the deferred hardware checklist (greeter shows; login works; keyring unlocks; DMS bar/launcher/lock; matugen theme from the wallpaper; idle hint after 30 min → reboot deferral notice; `systemctl --failed` clean; RAM use on a 4 GB Pi 5).
- [ ] **Step 4:** Wait for CI (`build-desktop` runs `tests/image.sh`); fix failures in follow-up commits on the branch.
