# Juniper Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an experimental third image, `juniper-desktop` (`juniper` + a niri Wayland desktop), built and tested in CI, that boots to a graphical lock screen, has Firefox and the Bazaar store from Flathub, and requires a user password; then, after it passes on the owner's Pi 5, publish it with a disk image.

**Architecture:** A `desktop` Containerfile stage `FROM juniper` runs `build_files/desktop.sh` and copies `system_files_desktop/`, the same pattern as `juniper`'s `dev.sh`/`system_files_dev/`. COPR packages come from pinned keys and an exact-version lock file. The session is greetd auto-starting niri for uid 1000, with niri locking the screen first. Small, unit-tested scripts in `/usr/libexec/juniper/` carry the logic (greetd config, lock-first, Flatpak setup, reboot deferral, the switch password check); the shared health check gains a hook directory. `just flash` gains a prompted, hashed password.

**Tech Stack:** bootc/Containerfile on AlmaLinux 10 aarch64, bash, Python 3 (`render-cidata`), systemd units, greetd, niri, swaylock/swayidle, Flatpak, GitHub Actions, the repo's `tests/unit.sh` (stubbed bash tests) and `tests/image.sh` (runs inside the built image in CI).

**Spec:** `docs/superpowers/specs/2026-10-10-juniper-desktop-design.md` (read it with this plan). The build spike is draft PR #40 (`spike/juniper-desktop`, do not merge); Task 1 ports its proven pieces.

## Global Constraints

- Image name `juniper-desktop`; `IMAGE_ID`/`VARIANT_ID` `juniper-desktop`; `PRETTY_NAME` "Juniper Desktop <version>"; built `FROM juniper` in the same Containerfile.
- The headless images (`juniper-minimal`, `juniper`) must not change behaviour: no new packages, no display settings, no new units. Shared code changes must be no-ops for them (verified by their image tests).
- Hardware target: Pi 5 first (the owner's 4 GB board); Pi 4 best-effort.
- KMS overlay only via the per-kernel `/usr/lib/modules/*/rpi-config.txt` (tryboot covers it): `disable_splash=1`, `camera_auto_detect=0`, `display_auto_detect=1`, `dtoverlay=vc4-kms-v3d`, `max_framebuffers=2`, `disable_fw_kms_setup=1`.
- COPRs: pinned public keys in the repo, `includepkgs=` fences, exact versions from `build_files/desktop.lock`, repo files removed after the build; `just bump-desktop` refreshes the lock.
- Session: greetd starts `niri-session` for uid 1000; the screen locks before anything else; lock on idle after 10 minutes (`swayidle`), logind idle hint after 30 minutes.
- Password required for `juniper-desktop`: `just flash` prompts twice (never stored in `flash.yaml`), writes only a SHA-512 crypt hash (`$6$`) to `user-data` with `lock_passwd: false`; `ujust switch` to the desktop asks for one first. SSH stays key-only.
- Apps: Flathub as a system remote; `org.mozilla.firefox` and `io.github.kolunmi.Bazaar` installed system-wide on first boot by `juniper-flatpak-setup.service`; daily `flatpak update` plus unused-runtime cleanup.
- Reboot window: deferred while a desktop session is active and not idle, at most 7 days after the first deferral.
- Health check: under tryboot the desktop image also requires `greetd.service` active (desktop-only `health.d/` hook).
- Publishing (sign, disk image, release, `os-list.json`) is off until the hardware test plan passes on the owner's Pi 5 (Task 10).
- Every commit subject and PR title starts with a conventional prefix (`feat:`, `fix:`, `docs:`, `ci:`, `test:`, `chore:`, `build:`, `refactor:`); squash merges; `main` accepts PRs only. Commit messages end with the session's `Co-Authored-By`/`Claude-Session` lines.
- `pre-commit run --all-files` and `tests/unit.sh` pass before every push.

## Review Focus

1. **A desktop user with no password** (installed by some route other than `just flash`/`ujust switch`, e.g. a raw `bootc switch`) must not be locked out: the lock-first step skips locking and shows "set a password" when greetd-config recorded that the user has none. Test in Task 3.
2. **First boot offline or Flathub unreachable**: Flatpak setup fails without marking itself done, so it retries on the next boot; `ujust flatpak-setup` retries now; a half-done install (Firefox in, Bazaar not) completes on retry. Test in Task 4.
3. **A desktop never goes idle** (kiosk, video): the reboot deferral still ends 7 days after the first deferral, and only when an update is staged. Test in Task 6.
4. **A user's own niri config** drops Juniper's defaults: the lock-first spawn lives in the included Juniper file, and `ujust desktop-config` writes a stub that keeps the include first. Test in Task 3 (the stub starts with the include; `niri validate` passes).
5. **Passwords with spaces, quotes, `$`, non-ASCII, or a mismatched second entry**: `just flash` refuses mismatches and short passwords; the hash is generated from stdin so the shell never splits or expands it; `render-cidata` refuses a plain-text `password:` value. Tests in Task 5.

---

## File structure

| Path | Responsibility | Task |
|---|---|---|
| `Containerfile` | `desktop` stage | 1 |
| `build_files/desktop.sh` | COPR repos (pinned), packages, files, units, layers, cleanup | 1, 2 |
| `build_files/desktop.lock` | exact COPR package versions | 2 |
| `build_files/copr-keys/*.gpg` | pinned COPR public keys | 2 |
| `Justfile` | `image=juniper-desktop` target; `check-layers`; `bump-desktop` | 1, 2 |
| `build_files/build.sh` | `juniper-desktop` pretty name in os-release | 1 |
| `.github/workflows/build.yml` | build-matrix entry, publish guard, image-size step | 1 (publish: 10) |
| `system_files/usr/share/juniper/just/main.just` | `import? "desktop.just"` | 1 |
| `system_files_desktop/usr/share/juniper/rpi-config.txt` | KMS overlay settings | 1 |
| `system_files_desktop/usr/lib/sysusers.d/juniper-wsdd.conf` | wsdd user for bootc lint | 1 |
| `system_files_desktop/usr/lib/tmpfiles.d/juniper-greetd.conf` | `/var/lib/greetd` | 1 |
| `system_files_desktop/usr/libexec/juniper/greetd-config` | greetd config + password flag | 3 |
| `system_files_desktop/usr/lib/systemd/system/greetd.service.d/10-juniper.conf` | runs greetd-config, uses its output | 3 |
| `system_files_desktop/usr/libexec/juniper/desktop-lock-first` | lock now, or "set a password" | 3 |
| `system_files_desktop/usr/share/juniper/niri/juniper.kdl` | Juniper's niri defaults | 3 |
| `system_files_desktop/etc/niri/config.kdl` | includes the defaults | 3 |
| `system_files_desktop/usr/share/juniper/just/desktop.just` | desktop recipes | 3, 4 |
| `system_files_desktop/etc/flatpak/remotes.d/flathub.flatpakrepo` | Flathub remote + key | 4 |
| `system_files_desktop/usr/libexec/juniper/flatpak-setup` | first-boot app install | 4 |
| `system_files_desktop/usr/lib/systemd/system/juniper-flatpak-{setup,update}.service`, `juniper-flatpak-update.timer` | units | 4 |
| `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml` | password support, `juniper-desktop` image | 5 |
| `system_files_desktop/usr/libexec/juniper/desktop-idle` | reboot-window deferral | 6 |
| `system_files_desktop/usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf` | `ExecCondition` | 6 |
| `system_files/usr/libexec/juniper/switch-image`, `.../just/update.just` | switch with password check | 7 |
| `system_files/usr/libexec/juniper/healthcheck`, `system_files_desktop/usr/lib/juniper/health.d/10-greetd` | health hooks | 8 |
| `README.md`, `.github/ISSUE_TEMPLATE/hardware-report.yml`, `CHANGELOG.md`, `docs/superpowers/STATUS.md` | docs | 9 |
| `tests/unit.sh`, `tests/image.sh` | tests | every task |

Unit-test conventions (read `tests/unit.sh` first): each `test_*` function gets a fresh `$T`, stubs on `PATH` log calls to `$CALLS` (`stub NAME BODY`), `check "label" CMD...` asserts, `called`/`not_called`/`fails`/`stderr_has` helpers exist. Scripts take `JUNIPER_*` environment overrides for paths, so tests never touch the host. Desktop scripts live under `system_files_desktop/`; add `LIBEXEC_DESKTOP=$ROOT/system_files_desktop/usr/libexec/juniper` next to `LIBEXEC` at the top of `tests/unit.sh` in the first task that needs it (Task 3).

`tests/image.sh` runs inside each built image in CI (`just test-image`); arm64 images can't be built on the x86 dev laptop, so image-level checks are verified by pushing the branch and reading `gh pr checks`.

---

### Task 1: The `desktop` image builds in CI (port the spike, build-only)

**Files:**
- Modify: `Containerfile`, `Justfile`, `build_files/build.sh`, `.github/workflows/build.yml`, `system_files/usr/share/juniper/just/main.just`, `tests/image.sh`
- Create: `build_files/desktop.sh`, `system_files_desktop/usr/share/juniper/rpi-config.txt`, `system_files_desktop/usr/lib/sysusers.d/juniper-wsdd.conf`, `system_files_desktop/usr/lib/tmpfiles.d/juniper-greetd.conf`

**Interfaces:**
- Produces: Containerfile target `desktop`; `just image=juniper-desktop build|test-image|check-layers`; `/usr/share/juniper/rpi-config.txt` (desktop variant) installed into every `/usr/lib/modules/*/`; `IMAGE_ID=juniper-desktop`; `tests/image.sh` branch `[[ $IMAGE_ID == juniper-desktop ]]`. Later tasks add files under `system_files_desktop/` and packages to `desktop.sh`.

- [ ] **Step 1: Write the failing image tests.** In `tests/image.sh`, accept the new ID and add checks. Copy the spike's version from `git show origin/spike/juniper-desktop:tests/image.sh` as the reference, then make these edits on `main`'s file:

```bash
# near the top: accept the third image
[[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-minimal || $IMAGE_ID == juniper-desktop ]] || {
  echo "unexpected IMAGE_ID: $IMAGE_ID"
  exit 1
}
```

Replace the existing per-kernel `rpi-config.txt` loop with:

```bash
for kdir in /usr/lib/modules/*/; do
  grep -qx 'disable_splash=1' "$kdir/rpi-config.txt"
  # KMS graphics only on the desktop; the headless images keep displays off.
  if [[ $IMAGE_ID == juniper-desktop ]]; then
    grep -qx 'dtoverlay=vc4-kms-v3d' "$kdir/rpi-config.txt"
    grep -qx 'display_auto_detect=1' "$kdir/rpi-config.txt"
  else
    grep -qx 'display_auto_detect=0' "$kdir/rpi-config.txt"
    if grep -q 'vc4-kms' "$kdir/rpi-config.txt"; then
      echo "KMS overlay in a headless image"
      exit 1
    fi
  fi
done
```

Change the "full image only" condition from `[[ $IMAGE_ID == juniper ]]` to `[[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-desktop ]]`, and append at the end of the file:

```bash
if [[ $IMAGE_ID == juniper-desktop ]]; then
  # --- desktop only ---
  need_cmds niri niri-session xwayland-satellite Xwayland greetd agreety foot waybar fuzzel \
    swaylock swayidle swaync pipewire wireplumber flatpak notify-send
  need_enabled greetd.service
  ls /usr/lib64/dri/v3d_dri.so /usr/lib64/dri/vc4_dri.so >/dev/null
  ls /usr/lib/modules/*/kernel/drivers/gpu/drm/v3d/v3d.ko* >/dev/null
  # The COPRs are build-time only: devices never pull from them.
  if ls /etc/yum.repos.d/*copr* 2>/dev/null; then
    echo "COPR repo left in the image"
    exit 1
  fi
  cycles=$(systemd-analyze verify graphical.target cloud-init.target 2>&1 | grep 'ordering cycle' || true)
  [[ -z $cycles ]] || {
    echo "$cycles"
    exit 1
  }
else
  if command -v niri >/dev/null || [[ -e /usr/share/juniper/just/desktop.just ]]; then
    echo "desktop content in a headless image"
    exit 1
  fi
  # The base defaults to graphical.target; nothing graphical starts without a display manager.
  if [[ -e /etc/systemd/system/display-manager.service ]]; then
    echo "display manager enabled in a headless image"
    exit 1
  fi
fi
```

- [ ] **Step 2: Add the build plumbing.**

`Containerfile`: add after `COPY system_files_dev /system_files_dev` in the `ctx` stage:

```dockerfile
COPY system_files_desktop /system_files_desktop
```

and at the end of the file:

```dockerfile
FROM juniper AS desktop

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var \
    /ctx/build_files/desktop.sh

RUN bootc container lint --fatal-warnings
```

Add `#   --target desktop  -> juniper-desktop (juniper + niri desktop; experimental)` to the header comment.

`Justfile`:

```just
target := if image == "juniper-minimal" { "minimal" } else if image == "juniper-desktop" { "desktop" } else { "juniper" }
```

and in `check-layers`: `[[ {{ image }} == juniper || {{ image }} == juniper-desktop ]] && want+=(homebrew)`.

`build_files/build.sh`, in the `case` that sets `pretty`: add `juniper-desktop) pretty="Juniper Desktop" ;;`.

`system_files/usr/share/juniper/just/main.just`, after the existing `import?` of `dev.just`:

```just
# Desktop recipes exist only in juniper-desktop.
import? "desktop.just"
```

`.github/workflows/build.yml`, `build` job: matrix `image: [juniper-minimal, juniper, juniper-desktop]` with the comment `# juniper-desktop: built and tested; not published until Task 10`; the "Verify pinned Homebrew image signature" step condition becomes `if: matrix.image != 'juniper-minimal'`; the push step and the digest artifact upload get `&& matrix.image != 'juniper-desktop'` added to their `if:`; add after "Check layers":

```yaml
      - name: Image size
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
        run: |
          size=$(sudo podman image inspect --format '{{.Size}}' "$IMAGE_REF:latest")
          echo "### Image size: ${{ matrix.image }}: $((size / 1048576)) MiB (uncompressed)" >>"$GITHUB_STEP_SUMMARY"
```

Do not add `juniper-desktop` to the `sign`, `disk` or `release` matrices.

- [ ] **Step 3: Write `build_files/desktop.sh`** (no COPR pinning yet; Task 2 replaces the repo setup):

```bash
#!/usr/bin/env bash
# Desktop layer on top of juniper (Containerfile stage "desktop"): niri Wayland session.
set -xeuo pipefail

# --- repositories: COPRs for what EPEL 10 lacks, used for this build only. Each may only
# supply the packages it's here for (includepkgs), so it can't replace system packages.
copr() { # copr OWNER/PROJECT PACKAGE...
  local f=/etc/yum.repos.d/juniper-copr-${1/\//-}.repo
  curl -fsSLo "$f" "https://copr.fedorainfracloud.org/coprs/$1/repo/epel-10/x.repo"
  sed -i -e 's/^skip_if_unavailable=True/skip_if_unavailable=False/' "$f"
  shift
  echo "includepkgs=$*" >>"$f"
}
copr yalter/niri niri
copr yselkowitz/wlroots-epel xwayland-satellite foot foot-terminfo waybar fuzzel swaylock \
  swayidle swaybg SwayNotificationCenter brightnessctl \
  playerctl playerctl-libs nanosvg fcft gtk-layer-shell \
  gtk4-layer-shell libmpdclient granite jsoncpp libsfdo # their dependencies from the same COPR
copr yselkowitz/cosmic-epel greetd greetd-selinux

# --- packages ---
dnf -y install --exclude=fzf \
  niri xwayland-satellite xorg-x11-server-Xwayland \
  greetd greetd-selinux \
  foot waybar fuzzel swaylock swayidle swaybg SwayNotificationCenter brightnessctl wl-clipboard \
  libnotify flatpak \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring \
  pipewire wireplumber pipewire-pulseaudio \
  mesa-dri-drivers mesa-vulkan-drivers \
  google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts
dnf clean all
rm -f /etc/yum.repos.d/juniper-copr-*.repo

cp -a /ctx/system_files_desktop/. /

# KMS graphics, per kernel (replaces the headless rpi-config.txt build.sh installed).
for kdir in /usr/lib/modules/*/; do
  install -m 0644 /usr/share/juniper/rpi-config.txt "$kdir/rpi-config.txt"
done

# --- units ---
systemctl enable greetd.service
systemctl set-default graphical.target

# --- layers ---
tag() { python3 -c '
import os, sys
for p in sys.stdin.read().split("\0"):
    if p:
        os.setxattr(p, "user.component", sys.argv[1].encode(), follow_symlinks=False)
' "$1"; }
find /ctx/system_files_desktop -type f -printf '/%P\0' | tag juniper
printf '%s\0' /usr/lib/modules/*/rpi-config.txt | tag juniper

# --- cleanup: package scriptlets leave runtime-only content that bootc lint rejects ---
/ctx/build_files/clean-runtime-dirs.sh
```

`chmod +x build_files/desktop.sh`.

- [ ] **Step 4: Add the desktop system files.**

`system_files_desktop/usr/share/juniper/rpi-config.txt`:

```
# Juniper Desktop: KMS graphics (included from this deployment's boot entry, so a bad
# setting falls back with the rest of the update)
disable_splash=1
camera_auto_detect=0
display_auto_detect=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
```

`system_files_desktop/usr/lib/sysusers.d/juniper-wsdd.conf`:

```
# wsdd (pulled in by gvfs for the GNOME portal) creates its user in a scriptlet but ships no
# sysusers.d entry; bootc lint requires one. The service itself stays disabled.
u wsdd - "Web Services Dynamic Discovery host daemon" / /usr/sbin/nologin
```

`system_files_desktop/usr/lib/tmpfiles.d/juniper-greetd.conf`:

```
# greetd's own tmpfiles entry only fixes ownership (Z); on bootc /var starts empty.
d /var/lib/greetd 0750 greetd greetd -
```

- [ ] **Step 5: Commit**

```bash
git add Containerfile Justfile build_files/build.sh build_files/desktop.sh .github/workflows/build.yml \
  system_files/usr/share/juniper/just/main.just system_files_desktop tests/image.sh \
  docs/superpowers/specs/2026-10-10-juniper-desktop-design.md docs/superpowers/plans/2026-10-10-juniper-desktop.md
git commit -m "feat: juniper-desktop image stage (niri), built and tested in CI only"
```

- [ ] **Step 6: Lint and unit tests locally, then push and check CI.**

Run: `pre-commit run --all-files && tests/unit.sh`
Expected: all hooks pass; `all passed`.

Run: `git push -u origin feat/juniper-desktop` then open a draft PR (`feat: juniper-desktop (experimental niri image)`) and `gh pr checks <n> --watch`.
Expected: `build (juniper-minimal)`, `build (juniper)`, `build (juniper-desktop)` pass (lint, smoke test incl. the new negative checks for the headless images); `sign`/`disk`/`release` skipped.

---

### Task 2: Pin the COPRs (keys, fences, lock file, `just bump-desktop`)

**Files:**
- Create: `build_files/copr-keys/yalter-niri.gpg`, `build_files/copr-keys/yselkowitz-wlroots-epel.gpg`, `build_files/copr-keys/yselkowitz-cosmic-epel.gpg`, `build_files/desktop-copr.txt`, `build_files/desktop.lock`
- Modify: `build_files/desktop.sh` (repository section), `Justfile` (`bump-desktop`), `tests/image.sh`

**Interfaces:**
- Consumes: Task 1's `desktop.sh`.
- Produces: `build_files/desktop-copr.txt`: one COPR per line, `OWNER/PROJECT PACKAGE...` (the fenced package list, including the COPR's own dependencies), read by `desktop.sh` and `bump-desktop`. `build_files/desktop.lock`: one `name-version-release` per line (no arch, no epoch unless non-zero as `name-epoch:version-release`), sorted, for every COPR package (the fenced list from Task 1); copied into the image as `/usr/share/juniper/desktop.lock`. `just bump-desktop` rewrites it.

- [ ] **Step 1: Fetch and commit the COPR public keys** (each COPR project publishes one):

```bash
mkdir -p build_files/copr-keys
for p in yalter/niri yselkowitz/wlroots-epel yselkowitz/cosmic-epel; do
  curl -fsSLo "build_files/copr-keys/${p/\//-}.gpg" \
    "https://download.copr.fedorainfracloud.org/results/$p/pubkey.gpg"
done
head -1 build_files/copr-keys/*.gpg   # each: -----BEGIN PGP PUBLIC KEY BLOCK-----
```

- [ ] **Step 2: Write the failing image test** (append inside the `juniper-desktop` branch of `tests/image.sh`):

```bash
  # Every COPR package is exactly the version in the lock file.
  test -s /usr/share/juniper/desktop.lock
  while read -r nvr; do
    rpm -q "$nvr" >/dev/null || {
      echo "not the locked version: $nvr"
      exit 1
    }
  done </usr/share/juniper/desktop.lock
```

- [ ] **Step 3: Move the COPR lists into `build_files/desktop-copr.txt`** (from Task 1's three `copr` calls):

```
# OWNER/PROJECT PACKAGE... (includepkgs fence: the packages we use plus the COPR's own deps)
yalter/niri niri
yselkowitz/wlroots-epel xwayland-satellite foot foot-terminfo waybar fuzzel swaylock swayidle swaybg SwayNotificationCenter brightnessctl playerctl playerctl-libs nanosvg fcft gtk-layer-shell gtk4-layer-shell libmpdclient granite jsoncpp libsfdo
yselkowitz/cosmic-epel greetd greetd-selinux
```

- [ ] **Step 4: Add `just bump-desktop`** to the `Justfile` (after `bump-tools`). It queries the aarch64 COPR repos from an x86 container with `--forcearch`, so it runs on the dev laptop:

```just
# Pin the desktop's COPR packages to their newest builds (build_files/desktop.lock)
bump-desktop:
    #!/usr/bin/bash
    set -euo pipefail
    podman run --rm -v ./build_files:/b:ro,z quay.io/almalinuxorg/almalinux:10 bash -c '
      set -euo pipefail
      pkgs=()
      while read -r proj list; do
        [[ -z $proj || $proj == "#"* ]] && continue
        id=${proj/\//-}
        printf "[%s]\nname=%s\nbaseurl=https://download.copr.fedorainfracloud.org/results/%s/epel-10-\$basearch/\ngpgcheck=1\ngpgkey=file:///b/copr-keys/%s.gpg\nenabled=1\n" \
          "$id" "$proj" "$proj" "$id" >"/etc/yum.repos.d/$id.repo"
        read -ra more <<<"$list"
        pkgs+=("${more[@]}")
      done </b/desktop-copr.txt
      dnf -q --forcearch=aarch64 --disablerepo="*" --enablerepo="yalter-niri,yselkowitz-*" \
        repoquery --latest-limit 1 --qf "%{name}-%{evr}\n" "${pkgs[@]}"
    ' | sed 's/-0:/-/' | sort -u >build_files/desktop.lock
    git diff --stat build_files/desktop.lock
```

Run: `just bump-desktop && cat build_files/desktop.lock`
Expected: one line per package in `desktop-copr.txt`, e.g. `niri-26.04-1.el10`.

- [ ] **Step 5: Replace the repository section of `desktop.sh`** with pinned keys, fixed base URLs, the data file and the lock file:

```bash
# --- repositories: COPRs for what EPEL 10 lacks, used for this build only and removed after.
# Pinned: our copy of each project's key (build_files/copr-keys), includepkgs fences so a COPR
# can't replace system packages (build_files/desktop-copr.txt), and exact versions from
# build_files/desktop.lock (just bump-desktop).
while read -r proj pkgs; do
  [[ -z $proj || $proj == "#"* ]] && continue
  id=${proj/\//-}
  cat >"/etc/yum.repos.d/juniper-copr-$id.repo" <<EOF
[juniper-copr-$id]
name=COPR $proj (build-time only)
baseurl=https://download.copr.fedorainfracloud.org/results/$proj/epel-10-\$basearch/
gpgcheck=1
gpgkey=file:///ctx/build_files/copr-keys/$id.gpg
skip_if_unavailable=False
includepkgs=$pkgs
EOF
done </ctx/build_files/desktop-copr.txt
```

and change the install so COPR packages come from the lock:

```bash
mapfile -t locked </ctx/build_files/desktop.lock
dnf -y install --exclude=fzf "${locked[@]}" \
  xorg-x11-server-Xwayland wl-clipboard libnotify flatpak \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring \
  pipewire wireplumber pipewire-pulseaudio \
  mesa-dri-drivers mesa-vulkan-drivers \
  google-noto-sans-fonts google-noto-sans-mono-fonts google-noto-emoji-fonts
dnf clean all
rm -f /etc/yum.repos.d/juniper-copr-*.repo
install -D -m 0644 /ctx/build_files/desktop.lock /usr/share/juniper/desktop.lock
```

- [ ] **Step 6: Commit, then push and check CI** (`gh pr checks <n> --watch`; expected: `build (juniper-desktop)` passes including the lock test).

```bash
git add build_files/copr-keys build_files/desktop-copr.txt build_files/desktop.lock build_files/desktop.sh Justfile tests/image.sh
git commit -m "build: pin the desktop's COPRs (keys, fences, lock file, just bump-desktop)"
```

---

### Task 3: Session — greetd auto-start, lock first, niri defaults

**Files:**
- Create: `system_files_desktop/usr/libexec/juniper/greetd-config`, `system_files_desktop/usr/lib/systemd/system/greetd.service.d/10-juniper.conf`, `system_files_desktop/usr/libexec/juniper/desktop-lock-first`, `system_files_desktop/usr/share/juniper/niri/juniper.kdl`, `system_files_desktop/etc/niri/config.kdl`, `system_files_desktop/usr/share/juniper/just/desktop.just`
- Modify: `tests/unit.sh` (add `LIBEXEC_DESKTOP`), `tests/image.sh`

**Interfaces:**
- Produces: `greetd-config` writes `$JUNIPER_GREETD_CONFIG` (default `/run/juniper/greetd.toml`) and `$JUNIPER_LOCK_FLAG` (default `/run/juniper/desktop-lock`, contents `1` = the user has a usable password, `0` = not); `desktop-lock-first` reads that flag; env overrides `JUNIPER_AUTOLOGIN_UID` (default 1000). Recipes `desktop-config`, `desktop-lock-idle`.

- [ ] **Step 1: Write the failing unit tests** (add `LIBEXEC_DESKTOP=$ROOT/system_files_desktop/usr/libexec/juniper` near `LIBEXEC=` at the top of `tests/unit.sh`, then before `# --- runner ---`):

```bash
greetd_env() {
  export JUNIPER_GREETD_CONFIG=$T/greetd.toml JUNIPER_LOCK_FLAG=$T/desktop-lock
  # shellcheck disable=SC2016 # expands inside the stub
  stub getent 'case "$1 $2" in
    "passwd 1000") echo "nat:x:1000:1000::/var/home/nat:/bin/bash" ;;
    "shadow nat") echo "nat:${SHADOW_HASH-\$6\$salt\$hash}:20000:0:99999:7:::" ;;
    *) exit 2 ;;
  esac'
}

test_greetd_config_autostarts_niri_for_uid_1000() {
  greetd_env
  "$LIBEXEC_DESKTOP/greetd-config"
  check "greetd: initial_session is niri for nat" grep -q '^user = "nat"' "$JUNIPER_GREETD_CONFIG"
  check "greetd: initial_session command" grep -q '^command = "niri-session"' "$JUNIPER_GREETD_CONFIG"
  check "greetd: agreety after logout" grep -q 'agreety --cmd niri-session' "$JUNIPER_GREETD_CONFIG"
  check "greetd: password flag 1" test "$(cat "$JUNIPER_LOCK_FLAG")" = 1
}

test_greetd_config_flags_missing_password() {
  greetd_env
  for h in '!!' '!' '*' ''; do
    SHADOW_HASH=$h "$LIBEXEC_DESKTOP/greetd-config"
    check "greetd: no usable password ('$h') -> flag 0" test "$(cat "$JUNIPER_LOCK_FLAG")" = 0
  done
}

test_greetd_config_without_uid_1000() {
  greetd_env
  JUNIPER_AUTOLOGIN_UID=4242 "$LIBEXEC_DESKTOP/greetd-config"
  check "greetd: no user -> no initial_session" fails grep -q initial_session "$JUNIPER_GREETD_CONFIG"
  check "greetd: no user -> agreety only" grep -q 'agreety' "$JUNIPER_GREETD_CONFIG"
}

test_desktop_lock_first() {
  export JUNIPER_LOCK_FLAG=$T/desktop-lock
  stub swaylock ''
  stub notify-send ''
  echo 1 >"$JUNIPER_LOCK_FLAG"
  "$LIBEXEC_DESKTOP/desktop-lock-first"
  check "lock-first: password -> swaylock" called "swaylock -f"
  : >"$CALLS"
  echo 0 >"$JUNIPER_LOCK_FLAG"
  "$LIBEXEC_DESKTOP/desktop-lock-first"
  check "lock-first: no password -> no lock" not_called "swaylock"
  check "lock-first: no password -> tells you" called "notify-send"
  : >"$CALLS"
  rm -f "$JUNIPER_LOCK_FLAG"
  "$LIBEXEC_DESKTOP/desktop-lock-first"
  check "lock-first: no flag -> locks (fail closed)" called "swaylock -f"
}
```

- [ ] **Step 2: Run and verify they fail.** Run: `tests/unit.sh 2>&1 | grep -E "FAIL|No such|greetd|lock-first"`. Expected: "No such file or directory" for `greetd-config`.

- [ ] **Step 3: Write `greetd-config`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# greetd.service ExecStartPre: write greetd's config. Start niri for the first human user
# (uid 1000) at boot; niri locks the screen first (desktop-lock-first). After logout, or with
# no such user, agreety asks for a password. Also records whether that user has a usable
# password, so desktop-lock-first never locks someone out.
set -euo pipefail

out=${JUNIPER_GREETD_CONFIG:-/run/juniper/greetd.toml}
flag=${JUNIPER_LOCK_FLAG:-/run/juniper/desktop-lock}
uid=${JUNIPER_AUTOLOGIN_UID:-1000}

mkdir -p "$(dirname "$out")" "$(dirname "$flag")"
user=$(getent passwd "$uid" | cut -d: -f1) || user=
{
  printf '[terminal]\nvt = 1\n\n'
  printf '[default_session]\ncommand = "agreety --cmd niri-session"\nuser = "greetd"\n'
  if [[ -n $user ]]; then
    printf '\n[initial_session]\ncommand = "niri-session"\nuser = "%s"\n' "$user"
  fi
} >"$out.tmp"
mv "$out.tmp" "$out"

# Usable password: a shadow hash that isn't empty, locked (!...) or disabled (*).
hash=$(getent shadow "$user" 2>/dev/null | cut -d: -f2) || hash=
if [[ -n $user && -n $hash && $hash != '!'* && $hash != '*'* ]]; then
  echo 1 >"$flag"
else
  echo 0 >"$flag"
fi
chmod 0644 "$flag"
```

`greetd.service.d/10-juniper.conf`:

```ini
# The auto-start user only exists on the device (cloud-init creates it), so greetd's config
# is generated at each start; /etc/greetd/config.toml stays the package default.
[Service]
ExecStartPre=/usr/libexec/juniper/greetd-config
ExecStart=
ExecStart=/usr/bin/greetd --config /run/juniper/greetd.toml
```

- [ ] **Step 4: Write `desktop-lock-first`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# First thing niri starts (juniper.kdl): lock the screen, so every boot ends at the lock
# screen. Without a usable password (greetd-config's flag says 0), locking would lock the
# user out: say how to set one instead. No flag at all: lock (fail closed).
set -euo pipefail
flag=${JUNIPER_LOCK_FLAG:-/run/juniper/desktop-lock}

if [[ $(cat "$flag" 2>/dev/null || echo 1) == 0 ]]; then
  notify-send -u critical "Set a password" \
    "This desktop has no password, so it can't lock. Open a terminal (Super+Return) and run: sudo passwd $USER"
  exit 0
fi
exec swaylock -f
```

- [ ] **Step 5: Write the niri defaults.** `system_files_desktop/usr/share/juniper/niri/juniper.kdl`:

```kdl
// Juniper Desktop defaults, included by /etc/niri/config.kdl (and by the stub that
// `ujust desktop-config` writes). Later settings in your own config override these.

// Lock first, so every boot ends at the lock screen; then the bar, notifications and idle.
spawn-at-startup "/usr/libexec/juniper/desktop-lock-first"
spawn-at-startup "waybar"
spawn-at-startup "swaync"
spawn-at-startup "/usr/libexec/juniper/desktop-idle-lock"

xwayland-satellite {
    path "xwayland-satellite"
}

prefer-no-csd

binds {
    Mod+Return { spawn "foot"; }
    Mod+D { spawn "fuzzel"; }
    Super+Alt+L { spawn "swaylock" "-f"; }
    Mod+Q { close-window; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-up; }
    Mod+Down { focus-window-down; }
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+Shift+E { quit; }
    Mod+Shift+Slash { show-hotkey-overlay; }
}
```

`system_files_desktop/etc/niri/config.kdl`:

```kdl
// niri reads this when you have no ~/.config/niri/config.kdl. It only pulls in Juniper's
// defaults, so image updates can improve them. For your own settings run
// `ujust desktop-config`, which creates ~/.config/niri/config.kdl with the same include.
include "/usr/share/juniper/niri/juniper.kdl"
```

`system_files_desktop/usr/share/juniper/just/desktop.just`:

```just
# Create your own niri config (~/.config/niri/config.kdl) that includes Juniper's defaults
desktop-config:
    #!/usr/bin/bash
    set -euo pipefail
    f=$HOME/.config/niri/config.kdl
    if [[ -e $f ]]; then echo "$f exists; leaving it alone."; exit 0; fi
    mkdir -p "${f%/*}"
    printf '%s\n' '// Juniper defaults first: they lock the screen at login. Keep this line.' \
      'include "/usr/share/juniper/niri/juniper.kdl"' '' '// Your settings below override the defaults.' >"$f"
    niri validate -c "$f" && echo "Created $f"

# Lock the screen after 10 minutes idle: on (default) or off
desktop-lock-idle state="":
    #!/usr/bin/bash
    set -euo pipefail
    f=$HOME/.config/juniper/no-idle-lock
    case {{ quote(state) }} in
      on) rm -f "$f"; echo "Lock on idle: on (from your next login)." ;;
      off) mkdir -p "${f%/*}"; touch "$f"; echo "Lock on idle: off (from your next login)." ;;
      "") [[ -e $f ]] && echo "Lock on idle: off" || echo "Lock on idle: on" ;;
      *) echo "usage: ujust desktop-lock-idle [on|off]" >&2; exit 2 ;;
    esac
```

`juniper.kdl` starts idle handling through a wrapper so `desktop-lock-idle` can switch it; create `system_files_desktop/usr/libexec/juniper/desktop-idle-lock` (`chmod +x`):

```bash
#!/usr/bin/env bash
# Started by niri (juniper.kdl): lock after 10 min idle unless `ujust desktop-lock-idle off`;
# always set logind's idle hint after 30 min (the reboot window waits for it).
set -euo pipefail
if [[ -e ${XDG_CONFIG_HOME:-$HOME/.config}/juniper/no-idle-lock ]]; then
  exec swayidle -w idlehint 1800
fi
exec swayidle -w timeout 600 'swaylock -f' before-sleep 'swaylock -f' idlehint 1800
```

Add to the unit tests:

```bash
test_desktop_idle_lock() {
  export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config
  stub swayidle ''
  "$LIBEXEC_DESKTOP/desktop-idle-lock"
  check "idle-lock: locks after 10 min" called "swayidle -w timeout 600 swaylock -f"
  mkdir -p "$XDG_CONFIG_HOME/juniper" && touch "$XDG_CONFIG_HOME/juniper/no-idle-lock"
  : >"$CALLS"
  "$LIBEXEC_DESKTOP/desktop-idle-lock"
  check "idle-lock: off -> idle hint only" called "swayidle -w idlehint 1800"
  check "idle-lock: off -> no lock" not_called "swaylock"
}
```

- [ ] **Step 6: Add image tests** (inside the `juniper-desktop` branch of `tests/image.sh`):

```bash
  systemd-analyze verify greetd.service
  # niri accepts Juniper's defaults, the /etc config, and the stub desktop-config writes.
  niri validate -c /usr/share/juniper/niri/juniper.kdl
  niri validate -c /etc/niri/config.kdl
  t=$(mktemp -d)
  HOME=$t just --justfile /usr/share/juniper/just/desktop.just desktop-config
  head -2 "$t/.config/niri/config.kdl" | grep -q '^include "/usr/share/juniper/niri/juniper.kdl"'
  rm -rf "$t"
  grep -qx 'desktop-config' <<<"$recipes"
```

- [ ] **Step 7: Run unit tests, lint, push, check CI.** `tests/unit.sh` → `all passed`; `pre-commit run --all-files`; push; `gh pr checks` → `build (juniper-desktop)` passes (incl. `niri validate`).

- [ ] **Step 8: Commit**

```bash
git add system_files_desktop tests/unit.sh tests/image.sh
git commit -m "feat(desktop): greetd starts niri, lock screen first, niri defaults"
```

---

### Task 4: Apps — Flathub, Firefox, Bazaar

**Files:**
- Create: `system_files_desktop/etc/flatpak/remotes.d/flathub.flatpakrepo`, `system_files_desktop/usr/libexec/juniper/flatpak-setup`, `system_files_desktop/usr/lib/systemd/system/juniper-flatpak-setup.service`, `system_files_desktop/usr/lib/systemd/system/juniper-flatpak-update.service`, `system_files_desktop/usr/lib/systemd/system/juniper-flatpak-update.timer`
- Modify: `build_files/desktop.sh` (enable units), `system_files_desktop/usr/share/juniper/just/desktop.just`, `tests/unit.sh`, `tests/image.sh`

**Interfaces:**
- Produces: `flatpak-setup` (env `JUNIPER_STATE_DIR`, default `/var/lib/juniper`; marker `flatpak-setup.done`; apps `org.mozilla.firefox io.github.kolunmi.Bazaar`); recipe `flatpak-setup`.

- [ ] **Step 1: Write the failing unit tests:**

```bash
test_flatpak_setup_installs_apps_once() {
  stub flatpak ''
  stub runuser ''
  "$LIBEXEC_DESKTOP/flatpak-setup" >/dev/null
  check "flatpak: installs Firefox and Bazaar from flathub" \
    called "flatpak install --system --noninteractive --or-update flathub org.mozilla.firefox io.github.kolunmi.Bazaar"
  check "flatpak: marked done" test -e "$JUNIPER_STATE_DIR/flatpak-setup.done"
}

test_flatpak_setup_offline_retries() {
  stub flatpak 'exit 1'
  check "flatpak: failure is reported" fails "$LIBEXEC_DESKTOP/flatpak-setup"
  check "flatpak: failure not marked done (retried next boot)" test ! -e "$JUNIPER_STATE_DIR/flatpak-setup.done"
}
```

(`setup()` already exports `JUNIPER_STATE_DIR=$T/state`.)

- [ ] **Step 2: Run, verify they fail** (no such file).

- [ ] **Step 3: Write `flatpak-setup`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# First boot (juniper-flatpak-setup.service) and `ujust flatpak-setup`: install Firefox and the
# Bazaar app store from Flathub, system-wide. Marked done only on success, so a first boot
# without internet retries on the next boot. --or-update makes reruns finish a partial install.
set -euo pipefail
state=${JUNIPER_STATE_DIR:-/var/lib/juniper}
apps=(org.mozilla.firefox io.github.kolunmi.Bazaar)

flatpak install --system --noninteractive --or-update flathub "${apps[@]}"
mkdir -p "$state"
touch "$state/flatpak-setup.done"

# Tell the desktop user, if they're logged in (best-effort).
user=$(getent passwd 1000 | cut -d: -f1) || exit 0
if [[ -S /run/user/1000/bus ]]; then
  runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    notify-send "Apps ready" "Firefox and the Bazaar app store are installed." || true
fi
```

- [ ] **Step 4: Write the units.**

`juniper-flatpak-setup.service`:

```ini
[Unit]
Description=Install Firefox and the Bazaar app store from Flathub (first boot)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/juniper/flatpak-setup.done

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/flatpak-setup
TimeoutStartSec=60min

[Install]
WantedBy=multi-user.target
```

`juniper-flatpak-update.service`:

```ini
[Unit]
Description=Update Flatpak apps and remove unused runtimes
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --system --noninteractive -y
ExecStart=/usr/bin/flatpak uninstall --system --unused --noninteractive -y
```

`juniper-flatpak-update.timer`:

```ini
[Unit]
Description=Daily Flatpak updates

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

In `desktop.sh`, after `systemctl enable greetd.service`:
`systemctl enable juniper-flatpak-setup.service juniper-flatpak-update.timer`.

Fetch the remote file (it carries Flathub's GPG key):

```bash
mkdir -p system_files_desktop/etc/flatpak/remotes.d
curl -fsSLo system_files_desktop/etc/flatpak/remotes.d/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo
grep -q '^GPGKey=' system_files_desktop/etc/flatpak/remotes.d/flathub.flatpakrepo
```

Append to `desktop.just`:

```just
# Install (or finish installing) Firefox and the Bazaar app store from Flathub
flatpak-setup:
    sudo /usr/libexec/juniper/flatpak-setup
```

- [ ] **Step 5: Image tests** (desktop branch of `tests/image.sh`):

```bash
  grep -q '^GPGKey=' /etc/flatpak/remotes.d/flathub.flatpakrepo
  need_enabled juniper-flatpak-setup.service juniper-flatpak-update.timer
  systemd-analyze verify juniper-flatpak-setup.service juniper-flatpak-update.service
  grep -qx 'flatpak-setup' <<<"$recipes"
```

- [ ] **Step 6: Run unit tests and lint; push; CI green.** Expected as before.

- [ ] **Step 7: Commit**

```bash
git add system_files_desktop build_files/desktop.sh tests/unit.sh tests/image.sh
git commit -m "feat(desktop): Flathub, with Firefox and Bazaar installed on first boot; daily Flatpak updates"
```

---

### Task 5: `just flash` sets a password (required for the desktop)

**Files:**
- Modify: `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml`, `tests/unit.sh`

**Interfaces:**
- Consumes: none.
- Produces: `render-cidata` accepts `image: juniper-desktop`; config key `password` whose only allowed value is `prompt`; reads the hash from env `JUNIPER_PASSWORD_HASH` (must match `^\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$`); writes `passwd` and `lock_passwd: false` for the user; fails if `image` is `juniper-desktop` and no hash is given. `flash.sh` prompts when the image is `juniper-desktop` or `password: prompt`.

- [ ] **Step 1: Write the failing unit tests:**

```bash
test_render_cidata_password_hash() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/flash.yaml"
  hash=$(printf '%s' 'a pass "word" with $ and ü' | openssl passwd -6 -stdin)
  JUNIPER_PASSWORD_HASH=$hash "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out" 2>/dev/null
  check "cidata: hashed password set" test "$(yget "$T/out/user-data" 'd["users"][0]["passwd"]')" = "$hash"
  check "cidata: password not locked" test "$(yget "$T/out/user-data" 'd["users"][0]["lock_passwd"]')" = False
}

test_render_cidata_desktop_needs_password() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/flash.yaml"
  check "cidata: desktop without a password refused" stderr_has "needs a password" \
    "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out"
}

test_render_cidata_refuses_plaintext_and_bad_hash() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\npassword: hunter2\n' >"$T/plain.yaml"
  check "cidata: plain-text password refused" stderr_has "password: prompt" \
    "$ROOT/disk/render-cidata" "$T/plain.yaml" "$T/out1"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/ok.yaml"
  check "cidata: non-SHA-512 hash refused" fails env JUNIPER_PASSWORD_HASH='$1$abc$def' \
    "$ROOT/disk/render-cidata" "$T/ok.yaml" "$T/out2"
  check "cidata: headless without password still fine" "$ROOT/disk/render-cidata" "$T/ok.yaml" "$T/out3"
}
```

- [ ] **Step 2: Run, verify they fail** (`image must be juniper or juniper-minimal`, unknown key `password`).

- [ ] **Step 3: Implement in `render-cidata`.** Add `"password"` to `KEYS`; allow `juniper-desktop` in the image check; in `load()` after the image check:

```python
    if "password" in cfg and cfg["password"] != "prompt":
        fail("password: plain-text passwords aren't allowed here; use `password: prompt` "
             "(just flash asks for it and stores only a hash)")
    pw_hash = os.environ.get("JUNIPER_PASSWORD_HASH")
    if pw_hash is not None and not re.fullmatch(r"\$6\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}", pw_hash):
        fail("JUNIPER_PASSWORD_HASH must be a SHA-512 crypt hash ($6$...)")
    if cfg.get("image") == "juniper-desktop" and not pw_hash:
        fail("juniper-desktop needs a password: it starts at a lock screen (just flash asks for one)")
```

Return `pw_hash` from `load()` (extend the tuple) and in `main()` set it on the user:

```python
    if pw_hash:
        ud["users"][0]["passwd"] = pw_hash
        ud["users"][0]["lock_passwd"] = False
```

- [ ] **Step 4: Implement the prompt in `flash.sh`.** Move the `render-cidata` call after the `image=` detection, and before it insert:

```bash
want_pw=$(python3 -c 'import sys, yaml; c = yaml.safe_load(open(sys.argv[1])) or {}; print("yes" if c.get("image") == "juniper-desktop" or c.get("password") == "prompt" else "no")' "$config")
if [[ $want_pw == yes ]]; then
  read -rsp "Password for the Pi's user (for the lock screen and sudo): " pw1 && echo
  read -rsp "Again: " pw2 && echo
  [[ $pw1 == "$pw2" ]] || die "passwords don't match; nothing written"
  ((${#pw1} >= 8)) || die "use at least 8 characters"
  # From stdin, so the shell never splits or expands it; only the hash goes any further.
  JUNIPER_PASSWORD_HASH=$(printf '%s' "$pw1" | openssl passwd -6 -stdin)
  export JUNIPER_PASSWORD_HASH
  unset pw1 pw2
fi
"$here/render-cidata" "$config" "$work/cidata"
```

Add `Password: set` / `Password: none (SSH keys only)` to the summary printed before the y/N prompt (in the Python summary block: `print(f"Password:  {'set' if 'passwd' in u else 'none (SSH keys only)'}")`).

`examples/flash.yaml`: document

```yaml
# juniper-desktop requires a password (just flash asks for it; only a hash is written). For
# the headless images it's optional: uncomment to be asked too.
# password: prompt
```

and list `juniper-desktop` in the `image:` comment.

- [ ] **Step 5: Run unit tests and lint.** Expected: `all passed`. Manual check: `disk/flash.sh --fetch-only` still works for `juniper`.

- [ ] **Step 6: Commit**

```bash
git add disk/render-cidata disk/flash.sh examples/flash.yaml tests/unit.sh
git commit -m "feat(flash): prompted, hashed password; required for juniper-desktop"
```

---

### Task 6: The reboot window waits for an idle desktop (7-day cap)

**Files:**
- Create: `system_files_desktop/usr/libexec/juniper/desktop-idle`, `system_files_desktop/usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf`
- Modify: `tests/unit.sh`, `tests/image.sh`

**Interfaces:**
- Produces: `desktop-idle` exit 0 = reboot may proceed, 1 = skip this window. Env: `JUNIPER_STATE_DIR` (marker `reboot-deferred-since`, epoch seconds), `JUNIPER_NOW` (epoch, tests), `JUNIPER_DEFER_CAP_DAYS` (default 7).

- [ ] **Step 1: Write the failing unit tests:**

```bash
idle_env() {
  export JUNIPER_NOW=2000000000
  stub bootc 'echo "{\"status\":{\"staged\":{}}}"'
  stub runuser ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub loginctl 'case "$1" in
    list-sessions) echo "3 1000 nat seat0 tty1" ;;
    show-session) case "$4" in Type) echo wayland ;; Active) echo yes ;; IdleHint) echo "${IDLE:-no}" ;; esac ;;
  esac'
}

test_desktop_idle_defers_active_session() {
  idle_env
  check "idle: active desktop -> skip" fails "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: first deferral recorded" test "$(cat "$JUNIPER_STATE_DIR/reboot-deferred-since")" = 2000000000
}

test_desktop_idle_proceeds_when_idle_or_nothing_staged() {
  idle_env
  IDLE=yes "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: idle session -> reboot" test $? = 0
  stub bootc 'echo "{\"status\":{\"staged\":null}}"'
  check "idle: nothing staged -> no deferral" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: nothing staged -> marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_cap() {
  idle_env
  mkdir -p "$JUNIPER_STATE_DIR"
  echo $((2000000000 - 7 * 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: deferred 7 days -> reboot anyway" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: cap clears the marker" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}
```

- [ ] **Step 2: Run, verify they fail.**

- [ ] **Step 3: Write `desktop-idle`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# ExecCondition of juniper-reboot.service on the desktop: exit 0 lets the weekly reboot
# window reboot into a staged update; exit 1 skips this window while someone is using the
# desktop (a wayland session that's active and not idle; swayidle sets the idle hint after
# 30 min). Never longer than JUNIPER_DEFER_CAP_DAYS after the first deferral.
set -euo pipefail
state=${JUNIPER_STATE_DIR:-/var/lib/juniper}
now=${JUNIPER_NOW:-$(date +%s)}
cap=$((${JUNIPER_DEFER_CAP_DAYS:-7} * 86400))
since_f=$state/reboot-deferred-since

if [[ $(bootc status --json | jq '.status.staged != null') != true ]]; then
  rm -f "$since_f"
  exit 0
fi

in_use=false
for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
  [[ $(loginctl show-session "$s" -p Type --value) == wayland ]] || continue
  [[ $(loginctl show-session "$s" -p Active --value) == yes ]] || continue
  [[ $(loginctl show-session "$s" -p IdleHint --value) == no ]] && in_use=true
done
if ! $in_use; then
  rm -f "$since_f"
  exit 0
fi

mkdir -p "$state"
[[ -e $since_f ]] || echo "$now" >"$since_f"
if ((now - $(cat "$since_f") >= cap)); then
  rm -f "$since_f"
  echo "Desktop in use, but the update has waited ${JUNIPER_DEFER_CAP_DAYS:-7} days: rebooting."
  exit 0
fi
echo "Desktop in use: not rebooting for the staged update this window."
user=$(getent passwd 1000 | cut -d: -f1) || exit 1
if [[ -S /run/user/1000/bus ]]; then
  runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    notify-send "Update ready" "Reboot when convenient (ujust update), or it happens within a week." || true
fi
exit 1
```

`juniper-reboot.service.d/10-desktop-idle.conf`:

```ini
# Desktop only: don't reboot under someone using the desktop (at most a week's delay).
[Service]
ExecCondition=/usr/libexec/juniper/desktop-idle
```

Image test (desktop branch): `systemctl cat juniper-reboot.service | grep -q 'ExecCondition=/usr/libexec/juniper/desktop-idle'`; headless branch: `! systemctl cat juniper-reboot.service | grep -q desktop-idle` written as an `if … then echo; exit 1; fi`.

Note the loginctl stub's `show-session` arguments: the script calls `loginctl show-session "$s" -p Type --value`, so `$4` is `Type`/`Active`/`IdleHint` — `$1`=show-session, `$2`=id, `$3`=-p, `$4`=property.

- [ ] **Step 4: Run unit tests, lint, push, CI green.**

- [ ] **Step 5: Commit**

```bash
git add system_files_desktop tests/unit.sh tests/image.sh
git commit -m "feat(desktop): the reboot window waits for an idle desktop, at most 7 days"
```

---

### Task 7: `ujust switch` to the desktop requires a password

**Files:**
- Create: `system_files/usr/libexec/juniper/switch-image`
- Modify: `system_files/usr/share/juniper/just/update.just` (`switch` recipe), `tests/unit.sh`

**Interfaces:**
- Produces: `switch-image IMAGE` (runs as the user; uses `sudo`): if `IMAGE` contains `juniper-desktop` and `sudo passwd -S "$USER"` reports status other than `PS`/`P`, runs `sudo passwd "$USER"` and re-checks before `sudo bootc switch IMAGE` and `sudo /usr/libexec/juniper/apply-update`.

- [ ] **Step 1: Write the failing unit tests:**

```bash
switch_env() {
  export USER=nat T JUNIPER_APPLY_UPDATE=apply-update
  # shellcheck disable=SC2016 # expands inside the stub
  stub sudo '"$@"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then echo "nat ${PW_STATUS:-LK} 2026-10-10 0 99999 7 -1"; else echo set >"$T/pw-set"; fi'
  stub apply-update ''
}

test_switch_desktop_without_password_asks_first() {
  switch_env
  # Status flips to PS once passwd has run.
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then [[ -e $T/pw-set ]] && s=PS || s=LK; echo "nat $s 2026-10-10 0 99999 7 -1"; else touch "$T/pw-set"; fi'
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest >/dev/null
  check "switch: asked for a password" called "passwd nat"
  check "switch: then switched" called "bootc switch ghcr.io/gnathoi/juniper-desktop:latest"
}

test_switch_desktop_refuses_if_still_no_password() {
  switch_env
  stub passwd 'if [[ $1 == -S ]]; then echo "nat LK 2026-10-10 0 99999 7 -1"; fi'
  check "switch: still no password -> no switch" fails "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest
  check "switch: nothing staged" not_called "bootc switch"
}

test_switch_headless_needs_no_password() {
  switch_env
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-minimal:latest >/dev/null
  check "switch: headless -> no password check" not_called "passwd -S"
  check "switch: headless switched" called "bootc switch ghcr.io/gnathoi/juniper-minimal:latest"
}
```

(The script calls `"${JUNIPER_APPLY_UPDATE:-/usr/libexec/juniper/apply-update}"`; `switch_env` points it at the stub. `T` is exported so the `passwd` stub can use it.)

- [ ] **Step 2: Run, verify they fail.**

- [ ] **Step 3: Write `switch-image`** (`chmod +x`):

```bash
#!/usr/bin/env bash
# ujust switch IMAGE: switch to another image and reboot into it now. juniper-desktop starts at
# a lock screen, so make sure the user has a password before switching to it.
set -euo pipefail
image=${1:?usage: ujust switch IMAGE}
apply=${JUNIPER_APPLY_UPDATE:-/usr/libexec/juniper/apply-update}

has_password() { [[ $(sudo passwd -S "$USER" | awk '{print $2}') == P* ]]; }

if [[ $image == *juniper-desktop* ]] && ! has_password; then
  echo "juniper-desktop starts at a lock screen, so $USER needs a password first."
  sudo passwd "$USER" || true
  has_password || {
    echo "No password set; not switching." >&2
    exit 1
  }
fi
sudo bootc switch "$image"
sudo "$apply"
```

`passwd -S` statuses: `PS`/`P` = usable password; `LK`/`L` = locked; `NP` = none. The glob `P*` matches `PS` and `P` only.

`update.just` `switch` recipe body becomes:

```just
switch image:
    /usr/libexec/juniper/switch-image {{ quote(image) }}
```

- [ ] **Step 4: Run unit tests, lint.** Expected `all passed`. The existing image test that lists `switch` among recipes still passes.

- [ ] **Step 5: Commit**

```bash
git add system_files/usr/libexec/juniper/switch-image system_files/usr/share/juniper/just/update.just tests/unit.sh
git commit -m "feat: ujust switch to juniper-desktop asks for a password first"
```

---

### Task 8: Health-check hooks; the desktop requires greetd

**Files:**
- Modify: `system_files/usr/libexec/juniper/healthcheck`, `tests/unit.sh`, `tests/image.sh`
- Create: `system_files_desktop/usr/lib/juniper/health.d/10-greetd`

**Interfaces:**
- Produces: `healthy()` also runs every executable in `${JUNIPER_HEALTH_D:-/usr/lib/juniper/health.d}` (sorted); any non-zero exit = unhealthy. No directory = no hooks (the headless images).

- [ ] **Step 1: Write the failing unit tests** (reuse `health_env`):

```bash
test_healthcheck_hook_failure_falls_back_under_tryboot() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 1\n' >"$JUNIPER_HEALTH_D/10-greetd" && chmod +x "$JUNIPER_HEALTH_D/10-greetd"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck" || true
  check "health: failing hook under tryboot -> reboot" called "systemctl reboot"
}

test_healthcheck_passing_hook_and_no_hooks() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: no hook dir -> healthy" called "rpi-bootc-bootloader sync"
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 0\n' >"$JUNIPER_HEALTH_D/10-ok" && chmod +x "$JUNIPER_HEALTH_D/10-ok"
  : >"$CALLS"
  "$LIBEXEC/healthcheck"
  check "health: passing hook -> healthy" called "rpi-bootc-bootloader sync"
}
```

- [ ] **Step 2: Run, verify the first fails** (hook ignored → sync, no reboot).

- [ ] **Step 3: Implement.** In `healthcheck`, add `health_d=${JUNIPER_HEALTH_D:-/usr/lib/juniper/health.d}` with the other settings, and at the end of `healthy()`:

```bash
  # Image-specific checks (juniper-desktop: greetd must be running). None on headless images.
  local hook
  for hook in "$health_d"/*; do
    [[ -x $hook ]] || continue
    "$hook" || return 1
  done
```

`system_files_desktop/usr/lib/juniper/health.d/10-greetd` (`chmod +x`):

```bash
#!/usr/bin/env bash
# juniper-desktop: an update whose login/lock screen doesn't start is broken.
exec systemctl is-active --quiet greetd.service
```

Image tests: desktop branch `test -x /usr/lib/juniper/health.d/10-greetd`; headless branch `if [[ -e /usr/lib/juniper/health.d ]]; then echo "health hooks in a headless image"; exit 1; fi`.

- [ ] **Step 4: Run unit tests (all, including the existing healthcheck tests), lint, push, CI green.**

- [ ] **Step 5: Commit**

```bash
git add system_files/usr/libexec/juniper/healthcheck system_files_desktop/usr/lib/juniper tests/unit.sh tests/image.sh
git commit -m "feat: health-check hooks; juniper-desktop requires greetd under tryboot"
```

---

### Task 9: Docs — README tables, issue form, changelog, status

**Files:**
- Modify: `README.md`, `.github/ISSUE_TEMPLATE/hardware-report.yml`, `CHANGELOG.md`, `docs/superpowers/STATUS.md`

- [ ] **Step 1: README comparison table:** replace it with (rows as on `main`, plus a third column, the Interface row and a Flathub row):

```markdown
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
```

Check the rows against `main`'s README first and keep any row added since.

- [ ] **Step 2: Tested hardware table:** add the `juniper-desktop` column, every cell `untested` (Task 10 flips Pi 5 / microSD).

- [ ] **Step 3: Images section:** add `ghcr.io/gnathoi/juniper-desktop:latest` under a "Desktop (experimental, not published yet)" note; Install section: `just flash` asks for a password for the desktop.

- [ ] **Step 4: Issue form:** add `juniper-desktop` to the `image` dropdown options.

- [ ] **Step 5: CHANGELOG** under Unreleased, `### Added`: "Experimental `juniper-desktop` image (niri, lock screen first, Firefox and Bazaar from Flathub); built and tested in CI, not published yet. `just flash` can set a password (required for the desktop); `ujust switch` to the desktop asks for one."

- [ ] **Step 6: STATUS.md:** sub-project D row → "Implemented on `feat/juniper-desktop` (PR #n), build-only; next: hardware test plan on the owner's Pi 5 (spec), then Task 10 to publish." Close draft PR #40 with a comment linking the new PR.

- [ ] **Step 7: Lint, commit, push; mark the PR ready; merge when green.**

```bash
git add README.md .github/ISSUE_TEMPLATE/hardware-report.yml CHANGELOG.md docs/superpowers/STATUS.md
git commit -m "docs: juniper-desktop in the README tables, issue form, changelog and status"
```

---

### Task 10: Hardware run on the owner's Pi 5, then publish (separate PR)

Not code until the hardware run passes. Needs the micro-HDMI cable. Before publishing there is no signed `juniper-desktop` image for the Pi to pull (signing only runs in the `release` environment for publishing runs), so build it on the Pi itself, as done for the tryboot tests on 2026-10-10. Images in local container storage aren't covered by the `ghcr.io/gnathoi` signature policy, so the Pi can switch to it:

- [ ] **Step 1:** On the Pi (running `juniper`), build the image from the merged `main`: `git clone https://github.com/gnathoi/juniper && cd juniper && sudo just image=juniper-desktop build`, then `sudo bootc switch --transport containers-storage localhost/juniper-desktop:build` and `sudo /usr/libexec/juniper/apply-update`. (Uses the Pi's own arm64 podman; takes ~15–20 min.)
- [ ] **Step 2:** Work through the spec's "Hardware test plan" (items 2–10) and record results in `docs/acceptance.md`. Item 1 (flashing) waits for a published disk image.
- [ ] **Step 3:** If it passes: PR `ci: publish juniper-desktop`: add `juniper-desktop` to the `sign`, `disk` and `release` matrices; drop the `&& matrix.image != 'juniper-desktop'` guards from the push and digest steps; `disk/render-os-list.sh` gains `juniper-desktop) name="Juniper Desktop"; desc=…`; the release job's `jq -s` merges `os-list-juniper-desktop.json` too; README Tested-hardware Pi 5 / microSD cell → `✅ tested <date>`; CHANGELOG. Then a release (`gh workflow run build --ref main -f build_raw=true`, with the owner's go-ahead) and hardware test item 1 by flashing the published disk image with `just flash`.

---

## Self-review notes

- Spec coverage: layering (T1), COPR option 1 (T2), GPU/boot settings (T1), session + lock first + niri config + idle lock (T3), apps (T4), passwords via flash (T5) and switch (T7), reboot window (T6), health hook (T8), README/issue form/changelog deliverables (T9), publishing + disk image after hardware (T10), hardware test plan (T10).
- Spec items deliberately left for hardware: nothing visible before swaylock; greetd SELinux; niri include merging (validated syntactically in T3, behaviour on hardware); keyring unlock; waybar Juniper module (spec "Session" bullet) is **not** in this plan: add it after the first hardware run if wanted (YAGNI until the base desktop works).
- Names used across tasks: `greetd-config`, `desktop-lock-first`, `desktop-idle-lock`, `flatpak-setup`, `desktop-idle`, `switch-image`; env `JUNIPER_GREETD_CONFIG`, `JUNIPER_LOCK_FLAG`, `JUNIPER_AUTOLOGIN_UID`, `JUNIPER_STATE_DIR`, `JUNIPER_NOW`, `JUNIPER_DEFER_CAP_DAYS`, `JUNIPER_HEALTH_D`, `JUNIPER_APPLY_UPDATE`, `JUNIPER_PASSWORD_HASH`.
