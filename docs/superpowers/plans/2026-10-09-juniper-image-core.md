# Juniper Image Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A headless, batteries-included bootc image for Raspberry Pi 4/5 layered on the AlmaLinux RPi bootc image, with Tailscale-first networking, safe automatic updates, ujust/MOTD/fastfetch UX, CI and a flashable disk image.

**Architecture:** One `Containerfile` `FROM` the digest-pinned AlmaLinux RPi bootc image runs `build_files/build.sh`, which installs packages and copies `system_files/` into `/`. Behaviour lives in small bash scripts under `/usr/libexec/juniper/` driven by systemd units/timers; each script is unit-tested on the host with stubbed commands (`tests/unit.sh`), and the built image is smoke-tested (`tests/image.sh`). GitHub Actions lints, builds on an arm64 runner, pushes, signs, and on request produces a GPT `.raw.xz` plus an rpi-imager OS list.

**Tech Stack:** bootc, AlmaLinux 10, podman, systemd, firewalld, cloud-init, Tailscale, just, fastfetch, bash, GitHub Actions, cosign, bootc-image-builder, rpi-bootc-bootloader.

**Spec:** `docs/superpowers/specs/2026-10-09-juniper-image-design.md`

## Global Constraints

- Base image: `quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b361228495c05656b1367fb41507a79ea9b7eca293f21bbc5e4801e3355337` (index digest as of 2026-10-09; Dependabot bumps it).
- Hardware: Pi 4, Pi 5, Pi 400/500, CM4/CM5. aarch64 only. GPT disk only. Dev target Pi 5 4GB.
- Published image: `ghcr.io/gnathoi/juniper` (CI computes `${IMAGE_REGISTRY:-ghcr.io}/${owner}/juniper`, lowercased; pushes with `GITHUB_TOKEN`, no registry secrets). The base image ref in the Containerfile is fully qualified with its registry (`quay.io/almalinuxorg/...`).
- Repo `github.com/gnathoi/juniper` is **private**; the GHCR package is made **public** so Pis can pull updates. Release assets stay private until the repo goes public (the rpi-imager OS-list URL only works after that).
- License Apache-2.0. Never copy files from `../bootc-images-rpi` (GPL-3.0); re-implement.
- Everything shipped goes under `/usr` unless the tool only reads `/etc`. Nothing written to `/var` at build time. `bootc container lint` must pass.
- Shell: bash, `set -euo pipefail`, 2-space indent (`shfmt -i 2 -ci`), shellcheck-clean. Every script overridable paths via `JUNIPER_*` env vars so tests can redirect them.
- State markers live in `/var/lib/juniper/` (`firstboot.done`, `locked`).
- **Image builds are verified on GitHub's arm64 runner, not locally** (the dev host has no arm64 emulation). Work happens on branch `impl/image-core`; to build and smoke-test the image: `git push origin impl/image-core && gh run watch --exit-status $(gh run list --branch impl/image-core --limit 1 --json databaseId -q '.[0].databaseId')`. The `build` job's "Smoke test" step runs `tests/image.sh`. Unit tests (`tests/unit.sh`) run natively and are the main TDD loop.
- The arm64 runner has ~14 GB disk; the workflow frees space before building. Private-repo Actions minutes are billed, so batch pushes per task rather than per step.
- Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Deviations from the spec (decided while planning, spec updated in Task 1)

- **greenboot → firmware tryboot.** greenboot's rollback needs GRUB boot counting; the Pi has none. `rpi-bootc-bootloader` (already in the base) supports `TRYBOOT=1`: the update reboot boots the new deployment once via the Pi firmware's tryboot; a healthy boot makes it the default (`rpi-bootc-bootloader sync`), an unhealthy one or a hang (hardware watchdog) falls back. Strictly better than `bootc rollback`.
- **No cloud.cfg module override.** The imager's `packages: [avahi-daemon]` fails fast on bootc and the failure is harmless; avahi is in the image already.
- **Tailscale join on Juniper is a unit, not runcmd.** `juniper-tailscale-join.service` runs while `/etc/tailscale/authkey` exists; the dd-flash template only needs `write_files`.
- **Lockdown trigger is a 5-minute timer** that disables itself once locked (path units on tailscaled state race the login).
- **Recipes cut:** `install-cockpit` (needs host bridge + Origins/serve config) and `setup-backup` (interactive restic config). Kept: `devbox`, `install-podlet`, `enable-metrics`.
- **Tailscale IP lives in the MOTD status block**, not a fastfetch module (avoids showing it twice).
- **Firewall uses stock zones** (`drop`, `trusted`) via `firewall-cmd`; no vendor zone files.
- **Homebrew is cloned on first boot, not baked in** (ruling R4): a tarball of a fresh clone is never byte-identical, so it would defeat rechunking and bloat every update. `juniper-brew-setup.service` clones into `/var/home/linuxbrew/.linuxbrew`, retrying until it succeeds.
- **Every publish reports its update size** (ruling R5): layers and MiB changed versus the previous `:latest`, in the GitHub job summary.
- **Registry is GHCR** (`ghcr.io/gnathoi/juniper`, public package, private repo) instead of quay.io; CI moved into Task 1 so every task's image changes are verified on the arm64 runner.

## Review Focus

1. **No Tailscale key ever supplied** (or tailscaled broken): the Pi must stay a normal LAN box with SSH open forever — lockdown must never fire. Test in Task 4.
2. **Power loss during first boot** before `firstboot.done`: the re-run must finish cleanly, and an interrupted Homebrew clone must not be mistaken for a complete one. Test in Task 3.
3. **Wi-Fi typo / no network on the very first boot:** the health check fails but this is not a tryboot, so it must not reboot (no boot loop). Test in Task 5.
4. **Tailscale node key expiry after lockdown** locks the user out of a headless Pi. Expected behaviour: docs and the user-data template tell users to use a *tagged* auth key (key expiry disabled by default) and that `ujust lan-ssh on` is the escape hatch. Covered by the user-data template text (Task 3) and README (Task 9).
5. **Timezone never set** (flashed without imager customisation): the reboot window silently runs in UTC. `update-schedule` must print which timezone it is using. Test in Task 5.

---

## File Structure

```
Containerfile                                   build entry; FROM base@digest
build_files/build.sh                            repos, packages, os-release, policy, enable units
system_files/usr/bin/ujust                      just wrapper
system_files/usr/libexec/juniper/firstboot      scrub CIDATA, retire cloud-init, sig enforcement
system_files/usr/libexec/juniper/brew-setup     clone Homebrew into /var/home/linuxbrew (first boot, retried)
system_files/usr/libexec/juniper/lockdown       firewall → Tailscale only
system_files/usr/libexec/juniper/apply-update   reboot into staged update via tryboot
system_files/usr/libexec/juniper/update-schedule  set/show/disable reboot window
system_files/usr/libexec/juniper/healthcheck    confirm or fall back from tryboot
system_files/usr/libexec/juniper/motd           login status block
system_files/usr/lib/systemd/system/juniper-*.{service,timer}
system_files/usr/lib/systemd/zram-generator.conf
system_files/usr/lib/systemd/journald.conf.d/50-juniper.conf
system_files/usr/lib/systemd/system.conf.d/50-juniper-watchdog.conf
system_files/usr/lib/bootc/kargs.d/10-juniper.toml
system_files/usr/share/juniper/just/{main,update,network,apps,pi}.just
system_files/usr/share/juniper/{logo.txt,tips.txt}
system_files/usr/share/juniper/cidata/{user-data,meta-data,README.txt}   template shipped on CIDATA + restored by firstboot
system_files/usr/share/pki/containers/juniper.pub
system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg
system_files/etc/rpi-bootc-bootloader/tryboot.conf
system_files/etc/profile.d/{juniper-motd.sh,juniper-brew.sh}
system_files/etc/xdg/fastfetch/config.jsonc
tests/unit.sh                                   host unit tests with stubs
tests/image.sh                                  smoke test run inside the built image
disk/bib-config.toml, disk/build-raw.sh, disk/render-os-list.sh, disk/icon.png
Justfile, .pre-commit-config.yaml, .github/workflows/build.yml, .github/dependabot.yml
LICENSE, THIRD_PARTY.md, README.md, .gitignore
```

---

### Task 1: Skeleton, Containerfile, test harnesses

**Files:**
- Create: `Containerfile`, `build_files/build.sh`, `tests/unit.sh`, `tests/image.sh`, `Justfile`, `.gitignore`, `LICENSE`, `THIRD_PARTY.md`, `README.md`, `.pre-commit-config.yaml`, `.github/workflows/build.yml`
- Modify: `docs/superpowers/specs/2026-10-09-juniper-image-design.md` (record the deviations above)

**Interfaces:**
- Produces: `tests/unit.sh` helpers `setup`, `stub NAME BODY`, `called STR`, `not_called STR`, `check DESC CMD...`; the runner executes every `test_*` function. New tests are inserted above the `# --- runner ---` line.
- Produces: `tests/image.sh` — ordered list of assertions, new ones inserted above `echo "image smoke test: OK"`.
- Produces: Justfile recipes `check`, `build`, `rechunk`, `test-image`, `build-raw ref out`; variables `image_ref`, `version`.
- Produces: build args `IMAGE_REF` (no tag) and `IMAGE_VERSION` (YYYYMMDD) visible to `build.sh` as env.
- Produces: workflow `.github/workflows/build.yml` with jobs `lint`, `build` (outputs `version`, `image_ref`, `digest`; steps "Smoke test", "Push"); env `PUBLISH`. Task 8 appends signing steps to `build`; Task 9 adds a `disk` job.

- [ ] **Step 1: Record the planning deviations in the spec**

Append to `docs/superpowers/specs/2026-10-09-juniper-image-design.md`:

```markdown
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
```

- [ ] **Step 2: Write the unit-test harness**

`tests/unit.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Unit tests for system_files/usr/libexec/juniper/*. Real commands (bootc, tailscale,
# firewall-cmd, systemctl, ...) are replaced by stubs on PATH that append their argv to
# $CALLS. Run: tests/unit.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIBEXEC=$ROOT/system_files/usr/libexec/juniper
ORIG_PATH=$PATH
fails=0

setup() {
  T=$(mktemp -d)
  export CALLS=$T/calls JUNIPER_STATE_DIR=$T/state
  mkdir -p "$T/bin" "$JUNIPER_STATE_DIR"
  : >"$CALLS"
  for cmd in bootc tailscale firewall-cmd systemctl shred ip rpi-bootc-bootloader \
    mount umount blkid chown timedatectl; do
    stub "$cmd" ''
  done
  export PATH=$T/bin:$ORIG_PATH
}

# stub NAME BODY: fake command that logs "NAME args..." to $CALLS, then runs BODY.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
called() { grep -qF -- "$1" "$CALLS"; }
not_called() { ! called "$1"; }
check() {
  if "${@:2}"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     calls: /' "$CALLS"
    fails=$((fails + 1))
  fi
}

test_harness_works() {
  stub bootc 'echo hi'
  check "harness: stub output" test "$(bootc status)" = hi
  check "harness: call logged" called "bootc status"
}

# --- runner ---
for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  setup
  "$t"
  rm -rf "$T"
done
if ((fails)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
```

- [ ] **Step 3: Run the harness**

Run: `tests/unit.sh`
Expected: `ok   harness: stub output`, `ok   harness: call logged`, `all passed`.

- [ ] **Step 4: Write the failing image smoke test**

`tests/image.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Smoke test executed inside the built image (no systemd running):
#   just test-image
set -euo pipefail

grep -qx 'IMAGE_ID=juniper' /usr/lib/os-release
grep -q '^PRETTY_NAME="Juniper' /usr/lib/os-release

echo "image smoke test: OK"
```

- [ ] **Step 5: Write Containerfile, build.sh, Justfile**

`Containerfile`:

```dockerfile
# Juniper: batteries-included headless bootc image for Raspberry Pi 4/5.
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b361228495c05656b1367fb41507a79ea9b7eca293f21bbc5e4801e3355337

# Published image ref without tag (e.g. ghcr.io/gnathoi/juniper) and date version.
ARG IMAGE_REF=localhost/juniper
ARG IMAGE_VERSION=dev

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var \
    /ctx/build_files/build.sh

RUN bootc container lint --fatal-warnings
```

`build_files/build.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Builds the Juniper layer. Runs once inside the Containerfile with /ctx mounted.
set -xeuo pipefail

: "${IMAGE_REF:?}" "${IMAGE_VERSION:?}"

# --- files ---
cp -a /ctx/system_files/. /

# --- identity ---
sed -i '/^\(PRETTY_NAME\|VARIANT\|VARIANT_ID\|IMAGE_ID\|IMAGE_VERSION\)=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<EOF
PRETTY_NAME="Juniper ${IMAGE_VERSION} (AlmaLinux 10 bootc)"
VARIANT="Juniper"
VARIANT_ID=juniper
IMAGE_ID=juniper
IMAGE_VERSION=${IMAGE_VERSION}
EOF
```

`system_files/usr/share/juniper/tips.txt` (gives `system_files/` its first file):

```
Run `ujust` to see every Juniper command.
Long-running services belong in Podman quadlets: /etc/containers/systemd/*.container
`distrobox create` gives you a mutable dev box; the host stays immutable.
`ujust update-schedule 03:30` moves the nightly update reboot window.
`bootc status` shows booted, staged and rollback images.
Tailscale SSH is on: `ssh <user>@<hostname>` from any device on your tailnet.
`ujust pi-status` shows temperature and throttling.
Homebrew installs CLI tools into your home: `brew install <tool>`.
`ujust lan-ssh on` re-opens SSH on the local network if Tailscale ever goes away.
`podman auto-update` keeps containers with AutoUpdate=registry current every night.
```

`Justfile`:

```just
image_ref := "localhost/juniper"
version := `date -u +%Y%m%d`

# Lint and unit-test (same checks as CI's lint job)
check:
    pre-commit run --all-files

# Build the arm64 image as {{ image_ref }}:build (needs arm64 or qemu-user-static)
build:
    podman build --platform linux/arm64 \
      --build-arg IMAGE_REF={{ image_ref }} --build-arg IMAGE_VERSION={{ version }} \
      -t {{ image_ref }}:build .

# Rechunk :build into :latest and :{{ version }} (rootful podman storage)
rechunk:
    podman run --rm --privileged --security-opt label=disable \
      -v /var/lib/containers:/var/lib/containers \
      quay.io/centos-bootc/centos-bootc:stream10 \
      /usr/libexec/bootc-base-imagectl rechunk {{ image_ref }}:build {{ image_ref }}:latest
    podman tag {{ image_ref }}:latest {{ image_ref }}:{{ version }}

# Run tests/image.sh inside an image
test-image image=(image_ref + ":build"):
    podman run --rm --platform linux/arm64 -v ./tests:/tests:ro,z {{ image }} /tests/image.sh

# Build a flashable GPT .raw from a pushed image ref (root: loop devices)
build-raw ref out="juniper.raw":
    disk/build-raw.sh {{ ref }} {{ out }}
```

`.gitignore`:

```
*.raw
*.raw.xz
/output/
```

`LICENSE`: full Apache-2.0 text (`curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt -o LICENSE`).

`THIRD_PARTY.md`:

```markdown
# Third-party components

Juniper's own files are Apache-2.0. The image redistributes these components under their
own licenses (full texts in the image under /usr/share/licenses):

| Component | License | Source |
|---|---|---|
| AlmaLinux RPi bootc base image | various (RPM licenses); build tooling GPL-3.0 | quay.io/almalinuxorg/almalinux-bootc-rpi |
| rpi-bootc-bootloader (in base) | see upstream | github.com/kfox1111/rpi-bootc-bootloader |
| Tailscale | BSD-3-Clause | pkgs.tailscale.com |
| Homebrew | BSD-2-Clause | github.com/Homebrew/brew |
| fastfetch | MIT | EPEL |
| distrobox | GPL-3.0 | EPEL |
| just | CC0-1.0 | EPEL |
| podman | Apache-2.0 | AlmaLinux AppStream |

Juniper only builds `FROM` the AlmaLinux image; no files from bootc-images-rpi are copied.
```

`README.md` (expanded in Task 9):

```markdown
# Juniper

Batteries-included, headless [bootc](https://bootc-dev.github.io/bootc/) image for
Raspberry Pi 4/5, layered on the AlmaLinux RPi bootc image. Tailscale-first networking,
Podman quadlets, Distrobox, Homebrew, `ujust`, automatic updates with firmware rollback.

Status: under construction.
```

- [ ] **Step 6: Lint config and CI workflow (lint, arm64 build, smoke test, publish)**

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-executables-have-shebangs
      - id: check-shebang-scripts-are-executable
  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.10.0-2
    hooks:
      - id: shfmt
        args: [-w, -i, "2", -ci]
  - repo: https://github.com/AleksaC/hadolint-py
    rev: v2.12.0.3
    hooks:
      - id: hadolint
        files: Containerfile
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.7
    hooks:
      - id: actionlint
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args: [-d, "{extends: default, rules: {line-length: {max: 120}, document-start: disable, truthy: {check-keys: false}}}"]
  - repo: local
    hooks:
      - id: just-fmt
        name: just --fmt --check
        language: system
        entry: bash -c 'for f in Justfile system_files/usr/share/juniper/just/*.just; do just --unstable --fmt --check --justfile "$f"; done'
        files: (Justfile|\.just)$
        pass_filenames: false
      - id: unit-tests
        name: tests/unit.sh
        language: system
        entry: tests/unit.sh
        pass_filenames: false
```

Run: `pre-commit autoupdate && pre-commit run --all-files`
Expected: all hooks pass (fix any shellcheck/shfmt/yamllint findings they raise in earlier tasks' files, then re-run).


`.github/workflows/build.yml`:

```yaml
name: build

on:
  push:
    branches: ["**"]
    tags: ["v*"]
  schedule:
    - cron: "0 2 * * 1"  # Mondays 02:00 UTC: pick up base image and package updates
  workflow_dispatch:
    inputs:
      build_raw:
        description: Also build the flashable .raw disk image and a release
        type: boolean
        default: false

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  packages: write

env:
  # Branch pushes build and test only; main, tags, the weekly cron and manual runs publish.
  PUBLISH: ${{ github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v') || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: extractions/setup-just@v3
      - uses: pre-commit/action@v3.0.1

  build:
    needs: lint
    runs-on: ubuntu-24.04-arm
    outputs:
      version: ${{ steps.meta.outputs.version }}
      image_ref: ${{ steps.meta.outputs.image_ref }}
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      - uses: extractions/setup-just@v3

      - name: Free disk space
        run: |
          sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/hostedtoolcache /opt/ghc /usr/local/.ghcup
          df -h /

      - name: Image metadata
        id: meta
        env:
          REGISTRY: ${{ vars.IMAGE_REGISTRY || 'ghcr.io' }}
          NAMESPACE: ${{ github.repository_owner }}
        run: |
          ref="${REGISTRY}/${NAMESPACE}/juniper"
          echo "image_ref=${ref,,}" >>"$GITHUB_OUTPUT"
          echo "version=$(date -u +%Y%m%d)" >>"$GITHUB_OUTPUT"

      - name: Build and rechunk
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
          VERSION: ${{ steps.meta.outputs.version }}
        run: |
          sudo "$(command -v just)" image_ref="$IMAGE_REF" version="$VERSION" build rechunk

      - name: Smoke test
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
        run: sudo "$(command -v just)" image_ref="$IMAGE_REF" test-image "$IMAGE_REF:latest"

      - name: Log in to registry
        if: env.PUBLISH == 'true'
        env:
          REGISTRY: ${{ vars.IMAGE_REGISTRY || 'ghcr.io' }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: echo "$GITHUB_TOKEN" | sudo podman login -u "$GITHUB_ACTOR" --password-stdin "$REGISTRY"

      - name: Push
        id: push
        if: env.PUBLISH == 'true'
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
          VERSION: ${{ steps.meta.outputs.version }}
        run: |
          for tag in latest "$VERSION" "sha-${GITHUB_SHA::7}"; do
            for i in 1 2 3; do
              sudo podman push --digestfile /tmp/digest "$IMAGE_REF:latest" "docker://$IMAGE_REF:$tag" && break
              sleep $((10 * i))
            done
          done
          echo "digest=$(cat /tmp/digest)" >>"$GITHUB_OUTPUT"
```

Run: `pre-commit run --all-files` → all hooks pass (fix what they flag, re-run).

- [ ] **Step 7: Build and run the smoke test on CI**

Run: `git checkout -b impl/image-core && git add -A && git commit -m "feat: image skeleton, test harnesses, CI" && git push -u origin impl/image-core`, then `gh run watch --exit-status <run id>`.
Expected: `lint` green; `build` green with `image smoke test: OK` in the "Smoke test" step log (`gh run view <id> --log | grep "smoke test"`). If `bootc container lint --fatal-warnings` fails on a warning that comes from the unmodified base image, drop `--fatal-warnings`, keep `bootc container lint`, and note the warning in a comment above that `RUN`.

- [ ] **Step 8: Commit any fixes**

```bash
git add -A
git commit -m "fix: CI findings" && git push   # only if Step 7 needed changes
```

---

### Task 2: Packages and base system configuration

**Files:**
- Modify: `build_files/build.sh`, `tests/image.sh`
- Create: `system_files/usr/lib/systemd/zram-generator.conf`, `system_files/usr/lib/systemd/journald.conf.d/50-juniper.conf`, `system_files/usr/lib/systemd/system.conf.d/50-juniper-watchdog.conf`, `system_files/usr/lib/bootc/kargs.d/10-juniper.toml`, `system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg`, `system_files/etc/profile.d/juniper-brew.sh`

**Interfaces:**
- Produces: enabled units `tailscaled.service firewalld.service avahi-daemon.service cloud-init.service podman-auto-update.timer`; masked `bootc-fetch-apply-updates.timer`.

- [ ] **Step 1: Add failing smoke assertions**

Insert into `tests/image.sh` above the final echo:

```bash
for cmd in tailscale tailscaled podman distrobox fastfetch just btop rg fzf nvim tmux jq rsync git firewall-cmd cloud-init; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd"; exit 1; }
done
for unit in tailscaled.service firewalld.service avahi-daemon.service cloud-init.service \
  cloud-final.service podman-auto-update.timer; do
  [[ $(systemctl is-enabled "$unit") == enabled ]] || { echo "not enabled: $unit"; exit 1; }
done
[[ $(systemctl is-enabled bootc-fetch-apply-updates.timer) == masked ]]
grep -q 'resize_what = "/var"' /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py
grep -q 'rootflags=noatime' /usr/lib/bootc/kargs.d/10-juniper.toml
```

- [ ] **Step 2: Run to verify failure**

Run: push the branch and watch CI (see Global Constraints)
Expected: FAIL with `missing: tailscale`.

- [ ] **Step 3: Install packages**

Append to `build_files/build.sh`:

```bash
# --- repositories ---
dnf -y install dnf-plugins-core https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf config-manager --set-enabled crb
curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/rhel/10/tailscale.repo

# --- packages ---
dnf -y install \
  podman firewalld cloud-init cloud-utils-growpart zram-generator \
  git-core tmux jq rsync zstd NetworkManager-wifi avahi \
  distrobox fastfetch just btop ripgrep fzf neovim \
  tailscale
dnf clean all

# cloud-init: /usr is read-only on bootc, so grow the filesystem holding /var instead.
resizefs=$(echo /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py)
sed -i 's@resize_what = "/"@resize_what = "/var"@' "$resizefs"
grep -q 'resize_what = "/var"' "$resizefs"
rm -f "$(dirname "$resizefs")"/__pycache__/cc_resizefs.*.pyc

# --- units ---
systemctl enable tailscaled.service firewalld.service avahi-daemon.service \
  cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service \
  podman-auto-update.timer
systemctl --global enable podman-auto-update.timer
systemctl mask bootc-fetch-apply-updates.timer
```


- [ ] **Step 4: Add the config files**

`system_files/usr/lib/systemd/zram-generator.conf`:

```ini
# Compressed swap in RAM instead of wearing the SD card.
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
```

`system_files/usr/lib/systemd/journald.conf.d/50-juniper.conf`:

```ini
[Journal]
SystemMaxUse=200M
```

`system_files/usr/lib/systemd/system.conf.d/50-juniper-watchdog.conf`:

```ini
# Pet the Pi's hardware watchdog (bcm2835_wdt max is 15s); a hung system resets itself,
# which also makes an unhealthy tryboot update fall back (see juniper-healthcheck).
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
```

`system_files/usr/lib/bootc/kargs.d/10-juniper.toml`:

```toml
# Fewer writes to the SD card. rpi-bootc-bootloader copies BLS options to cmdline.txt.
kargs = ["rootflags=noatime"]
```

`system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg`:

```yaml
#cloud-config
growpart:
  mode: auto
  devices:
    - /sysroot
```

`system_files/etc/profile.d/juniper-brew.sh`:

```sh
# Homebrew on PATH once juniper-brew-setup has cloned it.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
```

- [ ] **Step 5: Build and test**

Run: push the branch and watch CI (see Global Constraints)
Expected: `image smoke test: OK`. If `cloud-final.service` is not enabled, add it explicitly (already in the list) and check the unit name with `podman run --rm localhost/juniper:build systemctl list-unit-files 'cloud-*'`. If any EPEL package is missing, move it to a `ujust` brew install and note it in `THIRD_PARTY.md`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: packages and SD-card-friendly system config"
```

---

### Task 3: First boot (CIDATA scrub, cloud-init retirement, Homebrew, Tailscale join)

**Files:**
- Create: `system_files/usr/libexec/juniper/firstboot`, `system_files/usr/libexec/juniper/brew-setup`, `system_files/usr/lib/systemd/system/juniper-firstboot.service`, `system_files/usr/lib/systemd/system/juniper-brew-setup.service`, `system_files/usr/lib/systemd/system/juniper-tailscale-join.service`, `system_files/usr/share/juniper/cidata/user-data`, `system_files/usr/share/juniper/cidata/meta-data`, `system_files/usr/share/juniper/cidata/README.txt`
- Modify: `tests/unit.sh`, `tests/image.sh`, `build_files/build.sh`

**Interfaces:**
- Consumes: `git-core` in the image and `/etc/profile.d/juniper-brew.sh` (Task 2).
- Produces: `/usr/libexec/juniper/firstboot` honouring env `JUNIPER_STATE_DIR`, `JUNIPER_SHARE`, `JUNIPER_CIDATA_DIR` (skip mount when set), `JUNIPER_CLOUD_DISABLED`. Function `enforce_signatures` is added in Task 8.
- Produces: `/usr/libexec/juniper/brew-setup` honouring `JUNIPER_BREW_HOME`, `JUNIPER_BREW_REPO`.
- Produces: `/usr/share/juniper/cidata/*` (consumed by Task 9 `build-raw.sh`).

- [ ] **Step 1: Write failing tests**

Insert into `tests/unit.sh` above `# --- runner ---`:

```bash
firstboot_env() {
  export JUNIPER_SHARE=$T/share JUNIPER_CIDATA_DIR=$T/cidata \
    JUNIPER_CLOUD_DISABLED=$T/cloud-init.disabled
  mkdir -p "$JUNIPER_SHARE/cidata" "$JUNIPER_CIDATA_DIR"
  echo "#cloud-config template" >"$JUNIPER_SHARE/cidata/user-data"
  echo "secret wifi" >"$JUNIPER_CIDATA_DIR/network-config"
  echo "secret tskey" >"$JUNIPER_CIDATA_DIR/user-data"
}

test_firstboot_scrubs_cidata() {
  firstboot_env
  "$LIBEXEC/firstboot"
  check "firstboot: network-config removed" test ! -e "$JUNIPER_CIDATA_DIR/network-config"
  check "firstboot: user-data replaced by template" grep -q template "$JUNIPER_CIDATA_DIR/user-data"
  check "firstboot: no secrets left on CIDATA" not_grep_dir secret "$JUNIPER_CIDATA_DIR"
  check "firstboot: cloud-init disabled" test -e "$JUNIPER_CLOUD_DISABLED"
  check "firstboot: marked done" test -e "$JUNIPER_STATE_DIR/firstboot.done"
}

test_firstboot_rerun_after_power_loss() {
  firstboot_env
  "$LIBEXEC/firstboot"
  "$LIBEXEC/firstboot"
  check "firstboot rerun: still scrubbed" not_grep_dir secret "$JUNIPER_CIDATA_DIR"
  check "firstboot rerun: marked done" test -e "$JUNIPER_STATE_DIR/firstboot.done"
}

brew_env() {
  export JUNIPER_BREW_HOME=$T/linuxbrew JUNIPER_BREW_REPO=https://example.invalid/brew
  # Fake clone: create the destination (last argument) with a brew entrypoint.
  stub git 'dest=${*: -1}; mkdir -p "$dest/bin"; echo brew >"$dest/bin/brew"'
}

test_brew_setup_installs() {
  brew_env
  "$LIBEXEC/brew-setup"
  check "brew: cloned from repo" called "git clone --quiet https://example.invalid/brew"
  check "brew: entrypoint linked" test -L "$JUNIPER_BREW_HOME/.linuxbrew/bin/brew"
  check "brew: Homebrew checkout in place" test -f "$JUNIPER_BREW_HOME/.linuxbrew/Homebrew/bin/brew"
  check "brew: chowned to uid 1000" called "chown -R 1000:1000 $JUNIPER_BREW_HOME"
}

test_brew_setup_recovers_from_interrupted_clone() {
  brew_env
  mkdir -p "$JUNIPER_BREW_HOME/.linuxbrew.partial/junk"
  "$LIBEXEC/brew-setup"
  check "brew: partial replaced" test ! -e "$JUNIPER_BREW_HOME/.linuxbrew.partial"
  check "brew: complete after recovery" test -L "$JUNIPER_BREW_HOME/.linuxbrew/bin/brew"
}

test_brew_setup_failed_clone_is_not_installed() {
  brew_env
  stub git 'exit 128'
  check "brew: clone failure exits non-zero (systemd retries)" bash -c '! "$0"' "$LIBEXEC/brew-setup"
  check "brew: nothing that looks installed" test ! -e "$JUNIPER_BREW_HOME/.linuxbrew"
}

test_brew_setup_idempotent() {
  brew_env
  mkdir -p "$JUNIPER_BREW_HOME/.linuxbrew"
  "$LIBEXEC/brew-setup"
  check "brew: existing install left alone" not_called git
}

test_firstboot_mounts_cidata_by_label() {
  firstboot_env
  unset JUNIPER_CIDATA_DIR
  stub blkid 'echo /dev/mmcblk0p1'
  "$LIBEXEC/firstboot" || true
  check "firstboot: looks up CIDATA label" called "blkid -L CIDATA"
  check "firstboot: mounts it" called "mount /dev/mmcblk0p1"
  check "firstboot: unmounts it" called "umount"
}
```

and add the helper next to `called`/`not_called`:

```bash
not_grep_dir() { ! grep -rq -- "$1" "$2"; }
```

- [ ] **Step 2: Run to verify failure**

Run: `tests/unit.sh`
Expected: FAIL lines for the firstboot tests (`No such file or directory: .../firstboot`).

- [ ] **Step 3: Implement firstboot**

`system_files/usr/libexec/juniper/firstboot` (chmod +x):

```bash
#!/usr/bin/env bash
# One-shot first-boot setup, after cloud-init (juniper-firstboot.service):
# scrub secrets off the unencrypted CIDATA partition and retire cloud-init.
# Safe to re-run: every step is idempotent.
set -euo pipefail

state_dir=${JUNIPER_STATE_DIR:-/var/lib/juniper}
share=${JUNIPER_SHARE:-/usr/share/juniper}
cloud_disabled=${JUNIPER_CLOUD_DISABLED:-/etc/cloud/cloud-init.disabled}
cidata_dir=${JUNIPER_CIDATA_DIR:-}

scrub_cidata() {
  # The Wi-Fi password and Tailscale key were handed over via CIDATA; cloud-init has
  # already applied them, so put the secret-free template back.
  if [[ -z $cidata_dir ]]; then
    local dev
    dev=$(blkid -L CIDATA)
    cidata_dir=$(mktemp -d)
    mount "$dev" "$cidata_dir"
    trap 'umount "$cidata_dir"; rmdir "$cidata_dir"' EXIT
  fi
  rm -f "$cidata_dir/network-config"
  cp "$share/cidata/user-data" "$cidata_dir/user-data"
  sync
}

scrub_cidata
touch "$cloud_disabled"
mkdir -p "$state_dir"
touch "$state_dir/firstboot.done"
```

`system_files/usr/libexec/juniper/brew-setup` (chmod +x):

```bash
#!/usr/bin/env bash
# Installs Homebrew into /var/home/linuxbrew on first boot (juniper-brew-setup.service).
# Cloned here rather than baked into the image so image updates stay small; brew keeps
# itself updated afterwards. Exits non-zero on failure so systemd retries.
set -euo pipefail

brew_home=${JUNIPER_BREW_HOME:-/var/home/linuxbrew}
repo=${JUNIPER_BREW_REPO:-https://github.com/Homebrew/brew}

[[ -d $brew_home/.linuxbrew ]] && exit 0
# Clone beside the target and rename, so an interrupted clone never looks installed.
rm -rf "$brew_home/.linuxbrew.partial"
mkdir -p "$brew_home/.linuxbrew.partial/bin"
git clone --quiet "$repo" "$brew_home/.linuxbrew.partial/Homebrew"
ln -s ../Homebrew/bin/brew "$brew_home/.linuxbrew.partial/bin/brew"
mv "$brew_home/.linuxbrew.partial" "$brew_home/.linuxbrew"
chown -R 1000:1000 "$brew_home"
```

(Full clone, not `--depth 1`: `brew update` needs history.)

Note: with the stubbed `mount`, the label test cannot write into the temp dir's real content but `cp`/`rm` still operate on the empty temp dir, so the script completes; the `|| true` in the test only guards against environment differences.

- [ ] **Step 4: Add the units**

`system_files/usr/lib/systemd/system/juniper-firstboot.service`:

```ini
[Unit]
Description=Juniper first-boot setup (scrub CIDATA, retire cloud-init)
After=cloud-final.service
ConditionPathExists=!/var/lib/juniper/firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`system_files/usr/lib/systemd/system/juniper-brew-setup.service`:

```ini
[Unit]
Description=Install Homebrew into /var/home/linuxbrew
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/home/linuxbrew/.linuxbrew

[Service]
Type=exec
ExecStart=/usr/libexec/juniper/brew-setup
Restart=on-failure
RestartSec=5min

[Install]
WantedBy=multi-user.target
```

`system_files/usr/lib/systemd/system/juniper-tailscale-join.service`:

```ini
[Unit]
Description=Join the tailnet with the auth key provided at flash time
After=network-online.target tailscaled.service cloud-final.service
Wants=network-online.target tailscaled.service
ConditionPathExists=/etc/tailscale/authkey

[Service]
Type=exec
# The key is deleted only after a successful join, so failures retry (every minute, and
# again on every boot) until it works.
ExecStart=/bin/sh -c 'tailscale up --ssh --auth-key=file:/etc/tailscale/authkey --timeout=120s && shred -u /etc/tailscale/authkey'
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
```

Append to the `systemctl enable` line in `build_files/build.sh`: `juniper-firstboot.service juniper-brew-setup.service juniper-tailscale-join.service`.

- [ ] **Step 5: Add the CIDATA template files**

`system_files/usr/share/juniper/cidata/user-data`:

```yaml
#cloud-config
# Juniper first-boot configuration, applied once by cloud-init and then wiped from this
# partition. Raspberry Pi Imager (Juniper build) writes this for you; edit it by hand only
# if you flash with dd or similar. Uncomment and fill in what you need.
#
# hostname: juniper
#
# users:
#   - name: me
#     groups: [wheel]
#     sudo: ["ALL=(ALL) NOPASSWD:ALL"]
#     ssh_authorized_keys:
#       - ssh-ed25519 AAAA... me@laptop
#
# timezone: Europe/London
#
# Tailscale: create a one-off, pre-approved, TAGGED auth key at
# https://login.tailscale.com/admin/settings/keys (tagged devices don't expire, so the
# firewall lockdown can never lock you out). Once joined, only Tailscale can reach the Pi.
# write_files:
#   - path: /etc/tailscale/authkey
#     permissions: "0600"
#     content: "tskey-auth-..."
```

`system_files/usr/share/juniper/cidata/meta-data`: empty file (cloud-init NoCloud requires it to exist).

`system_files/usr/share/juniper/cidata/README.txt`:

```
Juniper for Raspberry Pi 4/5
============================

Easiest: flash with Raspberry Pi Imager using the Juniper OS list, which fills in your
user, SSH key, Wi-Fi and Tailscale key.

By hand: edit user-data on this partition (see the comments inside). For Wi-Fi, create a
file named network-config here:

  network:
    version: 2
    wifis:
      wlan0:
        dhcp4: true
        access-points:
          "MyNetwork":
            password: "secret"

Both files are wiped from this partition after first boot.
```

- [ ] **Step 6: Add smoke assertions**

Insert into `tests/image.sh` above the final echo:

```bash
for unit in juniper-firstboot.service juniper-brew-setup.service juniper-tailscale-join.service; do
  [[ $(systemctl is-enabled "$unit") == enabled ]] || { echo "not enabled: $unit"; exit 1; }
done
systemd-analyze verify /usr/lib/systemd/system/juniper-*.service
test -f /usr/share/juniper/cidata/user-data
```

- [ ] **Step 7: Run tests**

Run: `tests/unit.sh` → expected `all passed`. Then CI (push + `gh run watch`) → `image smoke test: OK`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: first boot scrubs CIDATA secrets, retires cloud-init, joins tailnet, installs Homebrew"
```

---

### Task 4: Firewall lockdown

**Files:**
- Create: `system_files/usr/libexec/juniper/lockdown`, `system_files/usr/lib/systemd/system/juniper-lockdown.service`, `system_files/usr/lib/systemd/system/juniper-lockdown.timer`
- Modify: `tests/unit.sh`, `tests/image.sh`, `build_files/build.sh`

**Interfaces:**
- Produces: marker `/var/lib/juniper/locked` (consumed by Task 5 healthcheck, Task 6 motd).
- Produces: `juniper-lockdown.service` (started by `ujust tailscale-up` in Task 6).

- [ ] **Step 1: Write failing tests**

Insert into `tests/unit.sh`:

```bash
test_lockdown_waits_for_join() {
  stub tailscale "echo '{\"BackendState\":\"NeedsLogin\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: firewall untouched before join" not_called firewall-cmd
  check "lockdown: not marked" test ! -e "$JUNIPER_STATE_DIR/locked"
}

test_lockdown_never_fires_without_tailscale() {
  stub tailscale 'exit 1'
  "$LIBEXEC/lockdown"
  check "lockdown: tailscale broken -> LAN stays open" not_called firewall-cmd
}

test_lockdown_locks_once_running() {
  stub tailscale "echo '{\"BackendState\":\"Running\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: tailscale0 trusted" called "firewall-cmd --permanent --zone=trusted --add-interface=tailscale0"
  check "lockdown: direct peers allowed" called "firewall-cmd --permanent --zone=drop --add-port=41641/udp"
  check "lockdown: default zone drop" called "firewall-cmd --set-default-zone=drop"
  check "lockdown: reloaded" called "firewall-cmd --reload"
  check "lockdown: marked" test -e "$JUNIPER_STATE_DIR/locked"
  check "lockdown: timer retired" called "systemctl disable --now juniper-lockdown.timer"
}

test_lockdown_only_once() {
  touch "$JUNIPER_STATE_DIR/locked"
  stub tailscale "echo '{\"BackendState\":\"Running\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: idempotent" not_called firewall-cmd
}
```

- [ ] **Step 2: Run to verify failure**

Run: `tests/unit.sh` → FAIL for the lockdown tests.

- [ ] **Step 3: Implement**

`system_files/usr/libexec/juniper/lockdown` (chmod +x):

```bash
#!/usr/bin/env bash
# Firewall the Pi down to Tailscale once it has joined a tailnet. Fires automatically once
# (juniper-lockdown.timer); afterwards `ujust lan-ssh on|off` adjusts it.
# Without a tailnet the Pi stays a normal LAN box: locking it then would brick it.
set -euo pipefail

state_dir=${JUNIPER_STATE_DIR:-/var/lib/juniper}
[[ -e $state_dir/locked ]] && exit 0

backend=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
[[ $backend == Running ]] || exit 0

firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
firewall-cmd --permanent --zone=drop --add-port=41641/udp
firewall-cmd --set-default-zone=drop
firewall-cmd --reload
mkdir -p "$state_dir"
touch "$state_dir/locked"
# ponytail: polling timer; retire it now that its job is done.
systemctl disable --now juniper-lockdown.timer
echo "Locked down: only Tailscale traffic can reach this Pi. 'ujust lan-ssh on' re-opens LAN SSH."
```

`system_files/usr/lib/systemd/system/juniper-lockdown.service`:

```ini
[Unit]
Description=Lock the firewall down to Tailscale once joined
After=firewalld.service tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/lockdown
```

`system_files/usr/lib/systemd/system/juniper-lockdown.timer`:

```ini
[Unit]
Description=Check every 5 minutes whether to lock the firewall down to Tailscale
ConditionPathExists=!/var/lib/juniper/locked

[Timer]
OnBootSec=1min
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
```

Append `juniper-lockdown.timer` to the `systemctl enable` line in `build.sh`.

- [ ] **Step 4: Smoke assertion**

Insert into `tests/image.sh`:

```bash
[[ $(systemctl is-enabled juniper-lockdown.timer) == enabled ]]
firewall-offline-cmd --get-default-zone | grep -qx public
```

- [ ] **Step 5: Run tests** — `tests/unit.sh` → `all passed`; CI (push + `gh run watch`) → OK.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: lock firewall down to Tailscale once the Pi has joined"
```

---

### Task 5: Automatic updates with tryboot fallback

**Files:**
- Create: `system_files/usr/libexec/juniper/apply-update`, `system_files/usr/libexec/juniper/update-schedule`, `system_files/usr/libexec/juniper/healthcheck`, `system_files/usr/lib/systemd/system/juniper-update.{service,timer}`, `system_files/usr/lib/systemd/system/juniper-reboot.{service,timer}`, `system_files/usr/lib/systemd/system/juniper-healthcheck.service`, `system_files/etc/rpi-bootc-bootloader/tryboot.conf`
- Modify: `tests/unit.sh`, `tests/image.sh`, `build_files/build.sh`

**Interfaces:**
- Consumes: `/var/lib/juniper/locked` (Task 4).
- Produces: `/usr/libexec/juniper/apply-update` (no args), `/usr/libexec/juniper/update-schedule [HH:MM|off]` with env `JUNIPER_DROPIN_DIR`; healthcheck env `JUNIPER_HEALTH_TRIES`, `JUNIPER_HEALTH_INTERVAL`, `JUNIPER_TRYBOOT_FLAG`. Used by Task 6 recipes.

- [ ] **Step 1: Write failing tests**

Insert into `tests/unit.sh`:

```bash
test_apply_update_without_staged() {
  stub bootc 'echo "{\"status\":{\"staged\":null}}"'
  "$LIBEXEC/apply-update"
  check "apply-update: no staged -> no reboot" not_called rpi-bootc-bootloader
}

test_apply_update_with_staged() {
  stub bootc 'echo "{\"status\":{\"staged\":{\"image\":{}}}}"'
  "$LIBEXEC/apply-update"
  check "apply-update: staged -> tryreboot" called "rpi-bootc-bootloader tryreboot"
}

test_update_schedule_sets_time() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  stub timedatectl 'echo Europe/London'
  out=$("$LIBEXEC/update-schedule" 03:30)
  check "schedule: drop-in written" grep -qx 'OnCalendar=\*-\*-\* 03:30:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: resets OnCalendar first" grep -qx 'OnCalendar=' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: timer re-enabled" called "systemctl enable --now juniper-reboot.timer"
  check "schedule: names the timezone" grep -q 'Europe/London' <<<"$out"
}

test_update_schedule_rejects_bad_input() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  for bad in 24:00 3:30 03:3 '03:30;reboot' 'now'; do
    check "schedule: rejects '$bad'" bash -c '! "$0" "$1" 2>/dev/null' "$LIBEXEC/update-schedule" "$bad"
  done
  check "schedule: nothing written" test ! -e "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_off() {
  "$LIBEXEC/update-schedule" off
  check "schedule off: timer disabled" called "systemctl disable --now juniper-reboot.timer"
}

health_env() {
  export JUNIPER_HEALTH_TRIES=1 JUNIPER_HEALTH_INTERVAL=0 JUNIPER_TRYBOOT_FLAG=$T/tryboot
}

test_healthcheck_healthy_confirms() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: healthy -> make booted the firmware default" called "rpi-bootc-bootloader sync"
}

test_healthcheck_unhealthy_tryboot_falls_back() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: unhealthy tryboot -> reboot" called "systemctl reboot"
  check "health: unhealthy -> no sync" not_called "rpi-bootc-bootloader sync"
}

test_healthcheck_first_boot_no_network_no_loop() {
  health_env
  "$LIBEXEC/healthcheck" || true
  check "health: unhealthy normal boot -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_requires_tailscale_once_locked() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  stub tailscale "echo '{\"BackendState\":\"NeedsLogin\"}'"
  "$LIBEXEC/healthcheck" || true
  check "health: locked + tailscale down -> fall back" called "systemctl reboot"
}
```

- [ ] **Step 2: Run to verify failure** — `tests/unit.sh` → FAIL for the new tests.

- [ ] **Step 3: Implement the scripts**

`system_files/usr/libexec/juniper/apply-update` (chmod +x):

```bash
#!/usr/bin/env bash
# Reboot into a staged update (juniper-reboot.timer, `ujust update`).
# Uses firmware tryboot: the new deployment boots once; juniper-healthcheck makes it the
# default, otherwise the next boot falls back to the current one. A plain reboot would
# keep the old deployment because tryboot.conf sets TRYBOOT=1.
set -euo pipefail

if [[ $(bootc status --json | jq '.status.staged != null') != true ]]; then
  echo "No staged update; not rebooting."
  exit 0
fi
exec rpi-bootc-bootloader tryreboot
```

`system_files/usr/libexec/juniper/update-schedule` (chmod +x):

```bash
#!/usr/bin/env bash
# Show, set or disable the automatic update reboot window.
#   update-schedule          show the update and reboot timers
#   update-schedule HH:MM    window starts at HH:MM local time (+ up to 90 min random delay)
#   update-schedule off      never reboot automatically (updates still download)
set -euo pipefail

dropin_dir=${JUNIPER_DROPIN_DIR:-/etc/systemd/system/juniper-reboot.timer.d}
arg=${1:-}

case $arg in
  "")
    systemctl list-timers juniper-update.timer juniper-reboot.timer
    ;;
  off)
    systemctl disable --now juniper-reboot.timer
    echo "Automatic update reboots are off. Apply updates with: ujust update"
    ;;
  *)
    if [[ ! $arg =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "usage: ujust update-schedule [HH:MM|off]   (24-hour local time, e.g. 03:30)" >&2
      exit 2
    fi
    mkdir -p "$dropin_dir"
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\n' "$arg" >"$dropin_dir/schedule.conf"
    systemctl daemon-reload
    systemctl enable --now juniper-reboot.timer
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
    echo "Update reboots start at $arg ${tz:-UTC} time, plus up to 90 minutes of random delay."
    ;;
esac
```

`system_files/usr/libexec/juniper/healthcheck` (chmod +x):

```bash
#!/usr/bin/env bash
# Every boot (juniper-healthcheck.service): if the system is healthy, make the booted
# deployment the firmware default; if an update booted via tryboot is unhealthy, reboot
# so the firmware falls back to the previous deployment.
# ponytail: a bad update is retried at each reboot window until a fixed image ships; add a
# known-bad digest list if that ever matters.
set -euo pipefail

state_dir=${JUNIPER_STATE_DIR:-/var/lib/juniper}
tries=${JUNIPER_HEALTH_TRIES:-20}
interval=${JUNIPER_HEALTH_INTERVAL:-15}
tryboot_flag=${JUNIPER_TRYBOOT_FLAG:-/proc/device-tree/chosen/bootloader/tryboot}

healthy() {
  [[ -n $(ip route show default) ]] || return 1
  # Tailscale is only required once the Pi has joined (and is firewalled to it).
  if [[ -e $state_dir/locked ]]; then
    [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') == Running ]] || return 1
  fi
}

in_tryboot() {
  # Big-endian u32 set by the Pi bootloader when it booted tryboot.txt.
  [[ -r $tryboot_flag ]] && [[ $(od -An -tu4 --endian=big "$tryboot_flag" | tr -d ' ') != 0 ]]
}

for ((i = 0; i < tries; i++)); do
  if healthy; then
    rpi-bootc-bootloader sync
    exit 0
  fi
  sleep "$interval"
done

echo "Health check failed: no default route or Tailscale not running." >&2
if in_tryboot; then
  echo "Unhealthy update under tryboot; rebooting into the previous deployment." >&2
  systemctl reboot
fi
exit 1
```

- [ ] **Step 4: Units and tryboot config**

`system_files/etc/rpi-bootc-bootloader/tryboot.conf`:

```
# Staged updates boot once via firmware tryboot; juniper-healthcheck confirms them.
TRYBOOT=1
```

`system_files/usr/lib/systemd/system/juniper-update.service`:

```ini
[Unit]
Description=Download and stage the latest Juniper image
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bootc upgrade --quiet
```

`system_files/usr/lib/systemd/system/juniper-update.timer`:

```ini
[Unit]
Description=Daily Juniper image download

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

`system_files/usr/lib/systemd/system/juniper-reboot.service`:

```ini
[Unit]
Description=Reboot into a staged Juniper update

[Service]
Type=oneshot
ExecStart=/usr/libexec/juniper/apply-update
```

`system_files/usr/lib/systemd/system/juniper-reboot.timer`:

```ini
[Unit]
Description=Nightly reboot window for staged Juniper updates (ujust update-schedule)

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=90min

[Install]
WantedBy=timers.target
```

`system_files/usr/lib/systemd/system/juniper-healthcheck.service`:

```ini
[Unit]
Description=Juniper boot health check (confirms or falls back from a tryboot update)
After=network-online.target tailscaled.service juniper-firstboot.service
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/libexec/juniper/healthcheck

[Install]
WantedBy=multi-user.target
```

Append `juniper-update.timer juniper-reboot.timer juniper-healthcheck.service` to the `systemctl enable` line in `build.sh`.

- [ ] **Step 5: Smoke assertions**

Insert into `tests/image.sh`:

```bash
for unit in juniper-update.timer juniper-reboot.timer juniper-healthcheck.service; do
  [[ $(systemctl is-enabled "$unit") == enabled ]] || { echo "not enabled: $unit"; exit 1; }
done
command -v rpi-bootc-bootloader >/dev/null
grep -qx 'TRYBOOT=1' /etc/rpi-bootc-bootloader/tryboot.conf
systemd-analyze verify /usr/lib/systemd/system/juniper-*.service /usr/lib/systemd/system/juniper-*.timer
```

- [ ] **Step 6: Run tests** — `tests/unit.sh` → `all passed`; CI (push + `gh run watch`) → OK.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: nightly staged updates with randomized reboot window and tryboot fallback"
```

---

### Task 6: ujust, MOTD and fastfetch

**Files:**
- Create: `system_files/usr/bin/ujust`, `system_files/usr/share/juniper/just/{main,update,network,apps,pi}.just`, `system_files/usr/libexec/juniper/motd`, `system_files/etc/profile.d/juniper-motd.sh`, `system_files/etc/xdg/fastfetch/config.jsonc`, `system_files/usr/share/juniper/logo.txt`
- Modify: `tests/image.sh`

**Interfaces:**
- Consumes: `/usr/libexec/juniper/{apply-update,update-schedule}` (Task 5), `juniper-lockdown.service` (Task 4), `/var/lib/juniper/locked`, `/usr/share/juniper/tips.txt` (Task 1).
- Produces: `ujust` recipes `update`, `update-schedule [time]`, `lan-ssh on|off`, `tailscale-up`, `tailscale-ssh on|off`, `toggle-motd`, `devbox`, `install-podlet`, `enable-metrics`, `pi-status`.

- [ ] **Step 1: Failing smoke assertions**

Insert into `tests/image.sh`:

```bash
for r in update update-schedule lan-ssh tailscale-up tailscale-ssh toggle-motd devbox install-podlet enable-metrics pi-status; do
  ujust --summary | tr ' ' '\n' | grep -qx "$r" || { echo "missing recipe: $r"; exit 1; }
done
fastfetch --config /etc/xdg/fastfetch/config.jsonc --pipe >/dev/null
HOME=/tmp /usr/libexec/juniper/motd | grep -q 'Tailscale'
```

- [ ] **Step 2: Run to verify failure** — CI (push + `gh run watch`) → FAIL (`ujust: command not found`).

- [ ] **Step 3: ujust wrapper and recipes**

`system_files/usr/bin/ujust` (chmod +x):

```bash
#!/usr/bin/bash
# Juniper's command runner (Bluefin-style): ujust <recipe>, or ujust to list.
exec just --justfile /usr/share/juniper/just/main.just --working-directory "$PWD" "$@"
```

`system_files/usr/share/juniper/just/main.just`:

```just
set shell := ["bash", "-c"]

import "update.just"
import "network.just"
import "apps.just"
import "pi.just"

[private]
default:
    @echo "Juniper commands (ujust <command>):"
    @just --justfile {{ justfile() }} --list --list-heading ''
```

`system_files/usr/share/juniper/just/update.just`:

```just
# Download the latest Juniper image and reboot into it now
update:
    sudo bootc upgrade
    sudo /usr/libexec/juniper/apply-update

# Show the update schedule, set the reboot window (HH:MM local time) or turn it off
update-schedule time="":
    sudo /usr/libexec/juniper/update-schedule {{ quote(time) }}
```

`system_files/usr/share/juniper/just/network.just`:

```just
# Allow (on) or block (off) SSH from the local network after Tailscale lockdown
lan-ssh state:
    #!/usr/bin/bash
    set -euo pipefail
    case {{ quote(state) }} in
      on) sudo firewall-cmd --permanent --zone=drop --add-service=ssh ;;
      off) sudo firewall-cmd --permanent --zone=drop --remove-service=ssh ;;
      *) echo "usage: ujust lan-ssh on|off" >&2; exit 2 ;;
    esac
    sudo firewall-cmd --reload

# Log in to Tailscale (prints a login URL), then lock the firewall down to it
tailscale-up:
    sudo tailscale up --ssh
    sudo systemctl start juniper-lockdown.service

# Turn Tailscale SSH on or off
tailscale-ssh state:
    #!/usr/bin/bash
    set -euo pipefail
    case {{ quote(state) }} in
      on) sudo tailscale set --ssh=true ;;
      off) sudo tailscale set --ssh=false ;;
      *) echo "usage: ujust tailscale-ssh on|off" >&2; exit 2 ;;
    esac

# Show or hide the login status banner for your user
toggle-motd:
    #!/usr/bin/bash
    set -euo pipefail
    f="$HOME/.config/juniper/no-motd"
    if [[ -e $f ]]; then rm "$f"; echo "Login banner on."; else mkdir -p "${f%/*}"; touch "$f"; echo "Login banner off."; fi
```

`system_files/usr/share/juniper/just/apps.just`:

```just
# Create and enter a mutable Fedora dev container (distrobox) named devbox
devbox:
    distrobox create --yes --name devbox --image registry.fedoraproject.org/fedora-toolbox:latest
    distrobox enter devbox

# Install podlet (converts compose files / podman commands to quadlets) into ~/.local/bin
install-podlet:
    #!/usr/bin/bash
    set -euo pipefail
    asset=podlet-aarch64-unknown-linux-gnu
    url=https://github.com/containers/podlet/releases/latest/download/$asset.tar.xz
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSLo "$tmp/p.tar.xz" "$url"
    curl -fsSLo "$tmp/p.sha256" "$url.sha256"
    [[ $(sha256sum "$tmp/p.tar.xz" | cut -d' ' -f1) == $(cut -d' ' -f1 "$tmp/p.sha256") ]] || { echo "checksum mismatch" >&2; exit 1; }
    mkdir -p ~/.local/bin
    tar -xJf "$tmp/p.tar.xz" -C ~/.local/bin --strip-components=1 "$asset/podlet"
    ~/.local/bin/podlet --version

# Run Prometheus node_exporter as a quadlet (reachable over Tailscale on :9100)
enable-metrics:
    #!/usr/bin/bash
    set -euo pipefail
    sudo tee /etc/containers/systemd/node-exporter.container >/dev/null <<'EOF'
    [Unit]
    Description=Prometheus node exporter
    [Container]
    Image=quay.io/prometheus/node-exporter:latest
    Network=host
    PodmanArgs=--pid=host
    Volume=/:/host:ro,rslave
    Exec=--path.rootfs=/host
    AutoUpdate=registry
    [Install]
    WantedBy=multi-user.target
    EOF
    sudo systemctl daemon-reload
    sudo systemctl start node-exporter.service
    echo "Metrics: http://$(tailscale ip -4 | head -1):9100/metrics"
```

`system_files/usr/share/juniper/just/pi.just`:

```just
# Show Pi temperature, throttling and clock speed
pi-status:
    sudo vcgencmd measure_temp
    sudo vcgencmd get_throttled
    sudo vcgencmd measure_clock arm
```

Verify the podlet archive layout once: `curl -fsSL https://github.com/containers/podlet/releases/latest/download/podlet-aarch64-unknown-linux-gnu.tar.xz | tar -tJ` must list `podlet-aarch64-unknown-linux-gnu/podlet`; adjust `--strip-components`/member if not.

- [ ] **Step 4: MOTD and fastfetch**

`system_files/usr/libexec/juniper/motd` (chmod +x):

```bash
#!/usr/bin/env bash
# Login banner: fastfetch, then Juniper status. Shown by /etc/profile.d/juniper-motd.sh.
set -uo pipefail

state_dir=${JUNIPER_STATE_DIR:-/var/lib/juniper}
# shellcheck source=/dev/null
. /usr/lib/os-release

row() { printf '  \e[1;32m%-10s\e[0m %s\n' "$1" "$2"; }

if ip=$(tailscale ip -4 2>/dev/null) && [[ -n $ip ]]; then
  if [[ -e $state_dir/locked ]]; then fw="firewall: Tailscale only"; else fw="firewall: LAN open"; fi
  ts="${ip%%$'\n'*} ($fw)"
else
  ts="not connected - run: ujust tailscale-up"
fi

if [[ -e /run/ostree/staged-deployment ]]; then
  when=$(systemctl show juniper-reboot.timer -P NextElapseUSecRealtime 2>/dev/null)
  upd="staged, reboots ${when:-manually (ujust update)}"
else
  upd="up to date"
fi

fastfetch 2>/dev/null
row Image "${PRETTY_NAME}"
row Tailscale "$ts"
row Update "$upd"
row Tip "$(shuf -n1 /usr/share/juniper/tips.txt 2>/dev/null)"
printf '\n  ujust for commands · ujust toggle-motd to hide this\n\n'
```

`system_files/etc/profile.d/juniper-motd.sh`:

```sh
# Juniper login banner for interactive shells; `ujust toggle-motd` turns it off per user.
case $- in
  *i*)
    if [ -z "${JUNIPER_MOTD_SHOWN:-}" ] && [ ! -e "$HOME/.config/juniper/no-motd" ]; then
      export JUNIPER_MOTD_SHOWN=1
      /usr/libexec/juniper/motd
    fi
    ;;
esac
```

`system_files/etc/xdg/fastfetch/config.jsonc`:

```jsonc
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/usr/share/juniper/logo.txt",
    "color": { "1": "green", "2": "blue" },
    "padding": { "right": 2 }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    { "type": "cpu", "temp": true },
    "memory",
    "swap",
    { "type": "disk", "folders": "/var" },
    "localip"
  ]
}
```

`system_files/usr/share/juniper/logo.txt` (`$1` = foliage green, `$2` = berry blue; original art):

```
$1               .
$1              /|\
$1             //|\\
$1        .   ///|\\\   .
$1       /|\   \\|//   /|\
$1      //|\\ $2o$1  |  $2o$1 //|\\
$1     ///|\\\  \|/  ///|\\\
$1        \\\\ $2o$1 | $2o$1 ////
$1     .   \\\\\|/////   .
$1    /|\  $2o$1 \\\|/// $2o$1  /|\
$1   //|\\\\  $2o$1 \|/ $2o$1  ////|\\
$1        \\\\\\|//////
$1          $2o$1   |   $2o$1
$1              |
$1             _|_
```

- [ ] **Step 5: Run tests** — CI (push + `gh run watch`) → OK. Also eyeball: `podman run --rm -it localhost/juniper:build fastfetch` and iterate on `logo.txt` until it looks like a juniper sprig.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: ujust recipes, login MOTD and juniper fastfetch"
```

---

### Task 7: Dependabot, first publish, public package

**Files:**
- Create: `.github/dependabot.yml`

**Interfaces:**
- Consumes: workflow from Task 1 (publishes on `main`, tags, weekly cron, manual runs).
- Produces: public package `ghcr.io/gnathoi/juniper` with tags `latest`, `YYYYMMDD`, `sha-xxxxxxx`.

- [ ] **Step 1: Dependabot**

`.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
```

Run: `pre-commit run --all-files` → pass. Commit and push:

```bash
git add .github/dependabot.yml
git commit -m "ci: weekly Dependabot for actions and the base image digest"
git push
```

- [ ] **Step 2: First publish from main**

Merge the branch so far: `gh pr create --base main --head impl/image-core --fill && gh pr merge --merge`. The push to `main` runs `build` with `PUBLISH=true`.
Expected: `skopeo inspect docker://ghcr.io/gnathoi/juniper:latest` works **after** Step 3 (before it, the package is private and needs `skopeo login ghcr.io`).

- [ ] **Step 3: Make the package public (user action)**

GitHub → your profile → Packages → `juniper` → Package settings → Danger zone → Change visibility → Public. Then `skopeo inspect docker://ghcr.io/gnathoi/juniper:latest` succeeds without login.

- [ ] **Step 4: Report update size on every publish (ruling R5)**

In `.github/workflows/build.yml`, replace the `Push` step's `run:` so it records the previous `:latest` layer digests before pushing and writes a summary afterwards (keep the existing per-tag retry/`exit 1` logic exactly as it is, between the two new blocks):

```bash
          creds="$GITHUB_ACTOR:$GITHUB_TOKEN"
          command -v skopeo >/dev/null || sudo apt-get install -y skopeo
          prev=$(skopeo inspect --creds "$creds" "docker://$IMAGE_REF:latest" 2>/dev/null \
            | jq -c '[.LayersData[].Digest]' || echo '[]')

          # ... existing per-tag push loop and digest output, unchanged ...

          skopeo inspect --creds "$creds" "docker://$IMAGE_REF@$(cat /tmp/digest)" | jq -r --argjson prev "$prev" '
            [.LayersData[] | select(.Digest as $d | $prev | index($d) | not)] as $new
            | "### Update size\n\(($new | length)) of \(.LayersData | length) layers changed, \((([$new[].Size] | add) // 0) / 1048576 | floor) MiB to download"' \
            >>"$GITHUB_STEP_SUMMARY"
```

and add `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` to that step's `env:`. Run `pre-commit run --all-files` → clean. Verify on the next main publish: the run summary shows "Update size". After a no-op rebuild (re-run the workflow on main without changes) it should report only a few small layers changed (os-release/version metadata); if it reports most layers changed, rechunking isn't producing stable layers — record the numbers in the Task 7 report.

- [ ] **Step 5: Check Dependabot sees the Containerfile**

Repo → Insights → Dependency graph → Dependabot: `Containerfile` listed under docker. If it is not, `git mv Containerfile Dockerfile`, change the Justfile `podman build` to add `-f Dockerfile`, and change hadolint's `files:` to `Dockerfile`.

---

### Task 8: Image signing and on-device enforcement

**Files:**
- Create: `system_files/usr/share/pki/containers/juniper.pub`
- Modify: `build_files/build.sh`, `system_files/usr/libexec/juniper/firstboot`, `tests/unit.sh`, `tests/image.sh`, `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `build` job outputs `image_ref`, `digest` (Task 1); firstboot script (Task 3).
- Produces: `/etc/containers/policy.json` entry for `$IMAGE_REF` requiring `sigstoreSigned` with `/usr/share/pki/containers/juniper.pub`; secret `SIGNING_SECRET`.

- [ ] **Step 1: Check the key pair exists (the user generated it before execution)**

Run: `test -s system_files/usr/share/pki/containers/juniper.pub && gh secret list | grep -q SIGNING_SECRET && echo ok`
Expected: `ok`. If not, stop and ask the user to run the key-generation commands from the execution handoff. Never create, read or commit a private key.

- [ ] **Step 2: Failing tests**

Insert into `tests/unit.sh`:

```bash
test_firstboot_enforces_signatures() {
  firstboot_env
  stub bootc 'if [[ $1 == status ]]; then echo "{\"spec\":{\"image\":{\"image\":\"ghcr.io/gnathoi/juniper:latest\"}}}"; fi'
  "$LIBEXEC/firstboot"
  check "firstboot: switches origin to signature-enforced" \
    called "bootc switch --mutate-in-place --enforce-container-sigpolicy ghcr.io/gnathoi/juniper:latest"
}
```

Insert into `tests/image.sh`:

```bash
jq -e '[.transports.docker[][] | select(.type == "sigstoreSigned" and .keyPath == "/usr/share/pki/containers/juniper.pub")] | length == 1' /etc/containers/policy.json >/dev/null
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/juniper.yaml
bootc switch --mutate-in-place --enforce-container-sigpolicy quay.io/x/y --help >/dev/null
```

- [ ] **Step 3: Run to verify failure** — `tests/unit.sh` → FAIL on the new test.

- [ ] **Step 4: Implement**

Add to `firstboot` (function, called right after `scrub_cidata`):

```bash
enforce_signatures() {
  # Images written by bootc-image-builder don't enforce signatures; switch the origin in
  # place (no new deployment) so every future `bootc upgrade` verifies the cosign signature.
  local ref
  ref=$(bootc status --json | jq -r '.spec.image.image // empty')
  [[ -n $ref ]] || return 0
  bootc switch --mutate-in-place --enforce-container-sigpolicy "$ref"
}
```

and call it: `enforce_signatures` on the line after `scrub_cidata`. The other firstboot tests keep passing because the default `bootc` stub prints nothing (empty ref → skip).

Append to `build_files/build.sh` after the `cp -a` of system_files:

```bash
# --- signature policy: updates of this image must carry our cosign signature ---
jq --arg ref "$IMAGE_REF" \
  '.transports.docker[$ref] = [{"type": "sigstoreSigned",
     "keyPath": "/usr/share/pki/containers/juniper.pub",
     "signedIdentity": {"type": "matchRepository"}}]' \
  /etc/containers/policy.json >/tmp/policy.json
mv /tmp/policy.json /etc/containers/policy.json
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$IMAGE_REF" \
  >/etc/containers/registries.d/juniper.yaml
```

If the `bootc switch --mutate-in-place … --help` smoke line fails with "unexpected argument", the flag does not exist in this bootc: replace the firstboot body with `bootc switch --enforce-container-sigpolicy "$ref"` (stages the same image; enforcement starts after the first update reboot), update the unit test's expected string, and drop that smoke line.

- [ ] **Step 5: Sign in CI**

Append to the `build` job in `.github/workflows/build.yml`:

```yaml
      - uses: sigstore/cosign-installer@v3
        if: env.PUBLISH == 'true'

      - name: Sign
        if: env.PUBLISH == 'true'
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
          DIGEST: ${{ steps.push.outputs.digest }}
          REGISTRY: ${{ vars.IMAGE_REGISTRY || 'ghcr.io' }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}
          COSIGN_PASSWORD: ""
        run: |
          echo "$GITHUB_TOKEN" | cosign login "$REGISTRY" -u "$GITHUB_ACTOR" --password-stdin
          cosign sign --yes --key env://COSIGN_PRIVATE_KEY "$IMAGE_REF@$DIGEST"

      - name: SBOM
        if: env.PUBLISH == 'true'
        uses: anchore/sbom-action@v0
        with:
          image: ${{ steps.meta.outputs.image_ref }}@${{ steps.push.outputs.digest }}
          format: spdx-json
          output-file: sbom.spdx.json
          registry-username: ${{ github.actor }}
          registry-password: ${{ secrets.GITHUB_TOKEN }}

      - name: Attest SBOM
        if: env.PUBLISH == 'true'
        env:
          IMAGE_REF: ${{ steps.meta.outputs.image_ref }}
          DIGEST: ${{ steps.push.outputs.digest }}
          COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}
          COSIGN_PASSWORD: ""
        run: cosign attest --yes --key env://COSIGN_PRIVATE_KEY --type spdxjson --predicate sbom.spdx.json "$IMAGE_REF@$DIGEST"
```

- [ ] **Step 6: Verify** — `tests/unit.sh` passes; CI smoke test passes; after merging to main, `cosign verify --key system_files/usr/share/pki/containers/juniper.pub ghcr.io/gnathoi/juniper:latest` succeeds.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: cosign-signed images, enforced on device via containers policy"
```

---

### Task 9: Flashable disk image, OS list, release, docs

**Files:**
- Create: `disk/bib-config.toml`, `disk/build-raw.sh`, `disk/render-os-list.sh`, `disk/icon.png`
- Modify: `.github/workflows/build.yml`, `README.md`, `tests/unit.sh`

**Interfaces:**
- Consumes: `/usr/share/juniper/cidata/*` from `system_files` (Task 3); `build` job outputs `image_ref`, `version` (Task 1).
- Produces: release assets `juniper-<version>.raw.xz`, `SHA256SUMS`, `os-list.json`. While the repo is private these need `gh release download`; the stable OS-list URL `https://github.com/gnathoi/juniper/releases/latest/download/os-list.json` works for rpi-imager only once the repo is public.

- [ ] **Step 1: Failing test for the OS list renderer**

Insert into `tests/unit.sh`:

```bash
test_render_os_list() {
  printf 'rawbytes' >"$T/j.raw"
  printf 'xz' >"$T/j.raw.xz"
  "$ROOT/disk/render-os-list.sh" "$T/j.raw" "$T/j.raw.xz" https://example/j.raw.xz 20261009 >"$T/os.json"
  check "os-list: url" jq -e '.os_list[0].url == "https://example/j.raw.xz"' "$T/os.json"
  check "os-list: extract_size" jq -e '.os_list[0].extract_size == 8' "$T/os.json"
  check "os-list: sha256 of raw" jq -e --arg h "$(sha256sum "$T/j.raw" | cut -d' ' -f1)" '.os_list[0].extract_sha256 == $h' "$T/os.json"
  check "os-list: cloudinit + tailscale capability" jq -e '.os_list[0].init_format == "cloudinit" and (.os_list[0].capabilities | index("tailscale"))' "$T/os.json"
  check "os-list: pi4+pi5 only" jq -e '.os_list[0].devices == ["pi5-64bit","pi4-64bit"]' "$T/os.json"
}
```

Run `tests/unit.sh` → FAIL (script missing).

- [ ] **Step 2: Implement disk files**

`disk/render-os-list.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Prints an rpi-imager OS list for one release.
#   render-os-list.sh RAW RAW_XZ DOWNLOAD_URL VERSION
set -euo pipefail

raw=$1 xz=$2 url=$3 version=$4
jq -n \
  --arg url "$url" --arg version "$version" \
  --arg sha "$(sha256sum "$raw" | cut -d' ' -f1)" \
  --argjson size "$(stat -c %s "$raw")" \
  --argjson dl "$(stat -c %s "$xz")" \
  --arg date "$(date -u +%F)" \
  --arg icon "${JUNIPER_ICON_URL:-https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-owner/juniper}/main/disk/icon.png}" \
  '{os_list: [{
     name: "Juniper \($version)",
     description: "Headless AlmaLinux bootc image: Tailscale, Podman, Distrobox, Homebrew",
     icon: $icon, url: $url,
     extract_size: $size, extract_sha256: $sha, image_download_size: $dl,
     release_date: $date,
     devices: ["pi5-64bit", "pi4-64bit"],
     init_format: "cloudinit",
     capabilities: ["tailscale", "passwordless_sudo"]
   }]}'
```

`disk/bib-config.toml`:

```toml
# GPT layout for Pi 4/5. Partition 1 is the Pi firmware partition and doubles as the
# cloud-init NoCloud source (label CIDATA). rpi-bootc-bootloader expects it to be p1.
[[customizations.disk.partitions]]
type = "plain"
label = "CIDATA"
mountpoint = "/boot/efi"
fs_type = "vfat"
minsize = "1 GiB"

[[customizations.disk.partitions]]
type = "plain"
label = "boot"
mountpoint = "/boot"
fs_type = "xfs"
minsize = "1 GiB"

[[customizations.disk.partitions]]
type = "plain"
label = "root"
mountpoint = "/"
fs_type = "xfs"
minsize = "6 GiB"
```

`disk/build-raw.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Builds a flashable GPT .raw for Pi 4/5 from a pushed Juniper image (run as root):
#   build-raw.sh ghcr.io/gnathoi/juniper:latest juniper.raw
# bootc-image-builder makes the disk; then the image's rpi-bootc-bootloader copies Pi
# firmware, kernel and config into the CIDATA (FAT) partition, which bib can't do.
set -euo pipefail

ref=${1:?usage: build-raw.sh IMAGE_REF:TAG OUTPUT.raw}
out=${2:?usage: build-raw.sh IMAGE_REF:TAG OUTPUT.raw}
here=$(cd "$(dirname "$0")" && pwd)
cidata_src=$here/../system_files/usr/share/juniper/cidata
work=$(mktemp -d)
loop=

cleanup() {
  umount "$work/mnt" 2>/dev/null || true
  [[ -n $loop ]] && losetup -d "$loop"
  rm -rf "$work"
}
trap cleanup EXIT

podman pull "$ref"
cp "$here/bib-config.toml" "$work/config.toml"
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$work":/output -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw --rootfs xfs --no-default-kernel-args --config /output/config.toml --local "$ref"
mv "$work/image/disk.raw" "$out"

loop=$(losetup -f --show -P "$out")
fatlabel "${loop}p1" CIDATA
mkdir -p "$work/mnt"
mount "${loop}p1" "$work/mnt"
cp "$cidata_src/user-data" "$cidata_src/meta-data" "$cidata_src/README.txt" "$work/mnt/"
# Inside the image: /tmp is the FAT partition; rpi-bootc-bootloader finds p1 itself from
# the /sysroot mount and writes config.txt + per-deployment kernel/dtbs.
podman run --rm --privileged -v /dev:/dev -v "$work/mnt":/tmp --entrypoint /bin/bash "$ref" -c \
  "mount ${loop}p3 /sysroot && mount ${loop}p2 /boot \
   && cp -a --no-preserve=links /usr/lib/ostree-boot/* /tmp/ \
   && rpi-bootc-bootloader sync"
echo "Wrote $out"
```

`disk/icon.png`: a 64×64 PNG (green circle with a blue berry). Generate once with
`podman run --rm -v "$PWD/disk:/out:z" docker.io/dpokidov/imagemagick:latest -size 64x64 xc:none -fill '#2f6b3a' -draw 'circle 32,32 32,4' -fill '#4a5ea8' -draw 'circle 42,22 42,14' /out/icon.png`.

Run `tests/unit.sh` → `all passed`.

- [ ] **Step 3: CI disk job**

Append to `.github/workflows/build.yml` under `jobs:`:

```yaml
  disk:
    needs: build
    if: startsWith(github.ref, 'refs/tags/v') || (github.event_name == 'workflow_dispatch' && inputs.build_raw)
    runs-on: ubuntu-24.04-arm
    permissions:
      contents: write
    env:
      IMAGE_REF: ${{ needs.build.outputs.image_ref }}
      VERSION: ${{ needs.build.outputs.version }}
      TAG: ${{ github.ref_type == 'tag' && github.ref_name || format('build-{0}', needs.build.outputs.version) }}
    steps:
      - uses: actions/checkout@v4
      - uses: extractions/setup-just@v3
      - name: Free disk space
        run: |
          sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/hostedtoolcache /opt/ghc /usr/local/.ghcup
          df -h /
      - run: sudo apt-get update && sudo apt-get install -y dosfstools xz-utils jq
      - name: Build raw disk
        run: sudo "$(command -v just)" build-raw "$IMAGE_REF:latest" "juniper-$VERSION.raw"
      - name: Compress and render OS list
        run: |
          sudo chown "$USER" "juniper-$VERSION.raw"
          xz -T0 -k "juniper-$VERSION.raw"
          disk/render-os-list.sh "juniper-$VERSION.raw" "juniper-$VERSION.raw.xz" \
            "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/juniper-$VERSION.raw.xz" \
            "$VERSION" >os-list.json
          sha256sum "juniper-$VERSION.raw.xz" os-list.json >SHA256SUMS
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ env.TAG }}
          name: Juniper ${{ env.VERSION }}
          files: |
            juniper-${{ env.VERSION }}.raw.xz
            os-list.json
            SHA256SUMS
```

Run `pre-commit run --all-files` → pass.

- [ ] **Step 4: README**

Replace `README.md` with:

```markdown
# Juniper

Batteries-included, headless [bootc](https://bootc-dev.github.io/bootc/) image for
Raspberry Pi 4/5 (incl. 400/500, CM4/CM5), layered on the AlmaLinux RPi bootc image in the
spirit of Bluefin and Bazzite.

- **Tailscale-first**: give it an auth key at flash time; once joined, the firewall drops
  everything except Tailscale.
- **Containers for services**: Podman quadlets with nightly `podman auto-update`.
- **Dev tools**: Distrobox, Homebrew, git, tmux, neovim, ripgrep, fzf, btop, `ujust`.
- **Hands-off updates**: images download daily and reboot in a randomised window from
  04:00 local time; the Pi firmware's tryboot falls back automatically if an update is
  unhealthy. Images are cosign-signed and verified on the device.

## Install

1. Create a **tagged**, one-off, pre-approved auth key at
   <https://login.tailscale.com/admin/settings/keys>. Tagged devices never expire, so the
   lockdown can't lock you out later.
2. Flash with Raspberry Pi Imager (Juniper build) using our OS list:
   `rpi-imager --repo https://github.com/gnathoi/juniper/releases/latest/download/os-list.json`
   and fill in user, SSH key, Wi-Fi, timezone and the Tailscale key.
   Or download `juniper-*.raw.xz` from Releases, flash it with any tool, and edit
   `user-data` on the small FAT partition (instructions in `README.txt` there).
3. Boot. The Pi joins your tailnet; `ssh <user>@<hostname>` over Tailscale.

## Everyday commands

| Command | What it does |
|---|---|
| `ujust` | list everything |
| `ujust update` | update and reboot now |
| `ujust update-schedule 03:30` / `off` | move or disable the reboot window |
| `ujust lan-ssh on` / `off` | re-open SSH on the local network (escape hatch) |
| `ujust tailscale-up` | log in to Tailscale interactively |
| `ujust devbox` | mutable Fedora dev container |
| `ujust enable-metrics` | node_exporter on :9100 over Tailscale |
| `ujust pi-status` | temperature and throttling |

## Switch an existing AlmaLinux RPi bootc system

    sudo bootc switch --enforce-container-sigpolicy ghcr.io/gnathoi/juniper:latest

## Build

    just check          # lint + unit tests
    just build          # arm64 image (arm64 host or qemu-user-static)
    just test-image
    sudo just build-raw ghcr.io/gnathoi/juniper:latest

CI rebuilds weekly (Monday 02:00 UTC), on every merge, and on demand (Actions → build →
Run workflow, tick "build_raw" for a disk image and release).

## License

Apache-2.0. See THIRD_PARTY.md for bundled components.
```

- [ ] **Step 5: Verify** — push and merge to main, then `gh workflow run build -f build_raw=true` (or Actions → build → Run workflow with `build_raw` ticked). Expected: release `build-YYYYMMDD` with `.raw.xz`, `os-list.json`, `SHA256SUMS`; `jq . os-list.json` shows correct sizes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: flashable GPT disk image, rpi-imager OS list and release job"
```

---

### Task 10: Hardware acceptance on the Pi 5

**Files:**
- Create: `docs/acceptance.md` (filled-in checklist with results and dates)

Nothing here can run in CI; this task proves the risky assumptions on real hardware. Record pass/fail and any fix commits in `docs/acceptance.md`.

- [ ] **Step 1: Flash and first boot** — `gh release download --repo gnathoi/juniper --pattern 'juniper-*.raw.xz'`, flash it with `dd` (or Imager with the custom repo), edit `user-data` (user, SSH key, tagged Tailscale key, timezone) and add `network-config` for Wi-Fi. Boot. Expected within 5 minutes: node appears in the Tailscale admin console; `ssh` over Tailscale works.
- [ ] **Step 2: First-boot effects** — on the Pi:
  - `sudo ls /etc/tailscale/authkey` → no such file
  - `sudo mount LABEL=CIDATA /mnt && grep -c tskey /mnt/user-data; ls /mnt/network-config; sudo umount /mnt` → `0` and no such file
  - `test -e /etc/cloud/cloud-init.disabled && echo ok`
  - `brew --version` (new login shell)
  - `cat /proc/cmdline | grep -o rootflags=noatime`
  - `swapon --show` lists `/dev/zram0`
  - `sudo wdctl` shows timeout 15s
  - `bootc status` shows signature enforcement (`signature: …` / `ostree-image-signed`)
- [ ] **Step 3: Lockdown** — within 5 minutes of joining: `sudo firewall-cmd --get-default-zone` → `drop`; from a LAN machine, `ssh <lan-ip>` times out; over Tailscale it works; `tailscale ping` direct path works. `ujust lan-ssh on` → LAN SSH works; `off` → blocked again. Confirm Tailscale's own nftables rules coexist (`sudo nft list ruleset | grep -c ts-`).
- [ ] **Step 4: Update + tryboot** — push a trivial change (e.g. a new tip) to get a new image; on the Pi: `sudo systemctl start juniper-update.service`, then `ujust update`. Expected: Pi reboots, `bootc status` shows the new image booted, `cat /proc/device-tree/chosen/bootloader/tryboot | od -An -tu4 --endian=big` was `1` on that boot (check `journalctl -u juniper-healthcheck -b`), and after healthcheck `config-bootc-default.txt` on CIDATA points to the new entry. Reboot again: still on the new image.
- [ ] **Step 5: Fallback** — build a deliberately broken image on a branch (e.g. mask `tailscaled.service` in build.sh), push it to a test tag, `sudo bootc switch` to it (staged), `sudo /usr/libexec/juniper/apply-update`. Expected: tryboot boots it, healthcheck fails after ~5 min, Pi reboots into the previous deployment, Tailscale back. Then `sudo bootc switch` back to `:latest`.
- [ ] **Step 6: Reboot window** — `ujust update-schedule 03:30` prints the Pi's timezone; `systemctl list-timers juniper-reboot.timer` shows next run 03:30–05:00. `ujust update-schedule off` → timer inactive.
- [ ] **Step 7: UX** — new SSH login shows fastfetch with the juniper logo and the status block; `ujust toggle-motd` hides it; `ujust devbox`, `ujust install-podlet`, `ujust enable-metrics` (curl `:9100/metrics` over Tailscale), `ujust pi-status` all work.
- [ ] **Step 8: Commit**

```bash
git add docs/acceptance.md
git commit -m "docs: Pi 5 hardware acceptance results"
```
