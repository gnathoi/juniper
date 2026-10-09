# rpi-imager Tailscale Customisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user paste a Tailscale auth key into Raspberry Pi Imager so that a flashed OS which ships Tailscale joins their tailnet on first boot. The change goes in a fork of `raspberrypi/rpi-imager` and is written so it can be upstreamed.

**Architecture:** The OS list advertises a new `tailscale` capability. Only when that capability is present, and the image takes cloud-init (`cloudinit` or `cloudinit-rpi`), does a new wizard step (`TailscaleCustomizationStep.qml`) appear, after Raspberry Pi Connect. The step keeps the key in the wizard's in-memory `customizationSettings` and nowhere else. `ImageWriter` checks the capability once more before calling `CustomisationGenerator::generateCloudInitUserData`. The generator writes a root-only `write_files` entry plus two `runcmd` entries: `systemctl enable --now tailscaled`, then `tailscale up … && shred -u /etc/tailscale/authkey`. Debug logging passes every payload through a new `redactSecrets()`. The CLI builds the same user-data from `--tailscale-authkey-file`.

**Tech Stack:** C++20, Qt 6 (≥ 6.9, release builds use 6.11.2), QML/Qt Quick, Catch2 v3, QtQuickTest, libFuzzer (clang), CMake + Ninja, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-09-imager-tailscale-design.md` in the Juniper repo (`gnathoi/juniper`). Read it before starting any task.

---

## Status and handoff

**Status on 2026-10-09:**

- The spec was approved on 2026-10-09: `docs/superpowers/specs/2026-10-09-imager-tailscale-design.md`.
- The Juniper side of the contract is already on Juniper `main`:
  - `system_files/usr/lib/systemd/system/juniper-tailscale-join.service` runs `tailscale up --ssh --auth-key=file:/etc/tailscale/authkey --timeout=120s && shred -u /etc/tailscale/authkey`. It is gated on `ConditionPathExists=/etc/tailscale/authkey`, ordered `After=cloud-final.service`, and retries every 60 s.
  - `system_files/usr/share/juniper/cidata/user-data` holds the commented `write_files` block that this plan's output has to match.
  - `system_files/usr/libexec/juniper/firstboot` shreds CIDATA `user-data`/`network-config` and cloud-init's cached copies.
  - `disk/render-os-list.sh` emits `init_format: "cloudinit"`, `capabilities: ["tailscale","passwordless_sudo"]`, and devices `pi5-64bit` and `pi4-64bit`.
  - `disk/bib-config.toml` makes partition 1 the FAT firmware partition with the label `CIDATA`. Imager writes `user-data`/`meta-data`/`network-config` to FAT partition 1 (`src/downloadthread.cpp:2790`, `:2825-2856`), so the files land in CIDATA.
- **Fork created on 2026-10-09:** `github.com/gnathoi/rpi-imager`, cloned at `~/workspace/rpi-imager-fork` (remote `upstream` = raspberrypi/rpi-imager). Branch `feat/tailscale-customisation` is at `8e7e0b6f`, which is still `upstream/main`, so every line number below is valid. No code commits yet, and nothing is pushed.
- **The fork is for our own use. There will be no upstream PR** (owner decision, 2026-10-09). Task 11 is dropped and Task 9 is deferred: we build locally. The upstream-style constraints below stay because they're cheap and keep rebasing on upstream easy.
- Juniper release `build-20261009` exists, so Task 10 Step 5 (real hardware) can run.
- Execution uses superpowers:subagent-driven-development. Its ledger, pre-flight scan and task briefs/reports live in the git-ignored `.superpowers/sdd/2026-10-09-imager-tailscale/` in the Juniper checkout on the dev machine. If that folder is lost, the "Execution rulings" below and `git log` in the fork are the record.

**Resume here (2026-10-10 morning):**

1. Task 0 is done (2026-10-09): distrobox `imager-dev` (Fedora 44, Qt 6.11.2), `build/` complete, and the baseline suites are green with 0 failures. A full build takes ~10 min, an incremental one ~2m20s. Build with `distrobox enter imager-dev -- bash -lc 'cd ~/workspace/rpi-imager-fork && cmake --build build -j16 -- -k 0'`. Keep the `-k 0`: upstream's `device_io_limits_test` doesn't compile (`::getpid` without `<unistd.h>`), so skip it in ctest. Never `git add -A`: `fetch-vendor-deps.sh` leaves `src/dependencies/vendor/libarchive` showing as modified.
2. Then Tasks 1–8 in order, then Task 10 Steps 1–3 (rootless route, see below), then Steps 4–5 with a real card and a Pi.

**Execution rulings (2026-10-09, from the pre-flight scan):**

- Spec deviations 1 (`--timeout=120s`) and 2 (list-form runcmd) are kept as argued below. Amend the spec's example YAML afterwards.
- Task 1 also updates `doc/local_json/create_local_json.py` (it rejects unknown capabilities), its README and the schema notes.
- Task 4 extends the existing `LogCapture` in `src/test/image_writer_test.cpp` (~14078) instead of adding a near-copy `DebugCapture`.
- Task 7 adds a QML test for the OS-change scrub. It also extends `tst_skip_customisation`, `tst_step_reachability` and the chaos step lists for the new step. `skipAllCustomisation()` must clear the key and options from `customizationSettings`, not just `tailscaleEnabled`. An already-staged payload must not take the key to the card after Skip: restage or strip it. If that needs an upstream-wide redesign, clear the key and note the rest.
- Task 8 narrows the fuzzer's newline invariant so the generator's fixed Tailscale lines don't trip it (input `"x\nruncmd:"` does today), while it still catches lines injected through fuzzed fields.
- Task 10 Steps 1–3 run rootless, because the distrobox can't losetup or mount. Build the fake image as a plain file (`sfdisk` + `mkfs.vfat --offset` or mtools), write the "card" to a plain file if the CLI accepts one, and read CIDATA with `mtools -i card.img@@1M`. If the CLI insists on a block device, do that one write with `sudo` on the host.

**Flashing a real card while the Juniper repo is private** (Task 10 Step 5; the README's `releases/latest/download/os-list.json` URL needs the repo to be public):

```bash
D=$(mktemp -d) && cd "$D"
gh release download build-20261009 --repo gnathoi/juniper -p 'juniper-20261009.raw.xz*'
cosign verify-blob --key ~/workspace/juniper/system_files/usr/share/pki/containers/juniper.pub \
  --bundle juniper-20261009.raw.xz.bundle juniper-20261009.raw.xz
xz -dk juniper-20261009.raw.xz        # render-os-list.sh hashes the expanded image (8.6 GB)
~/workspace/juniper/disk/render-os-list.sh juniper juniper-20261009.raw juniper-20261009.raw.xz \
  http://127.0.0.1:8000/juniper-20261009.raw.xz 20261009 >os-list.json
rm juniper-20261009.raw
python3 -m http.server 8000 --bind 127.0.0.1 &
~/workspace/rpi-imager-fork/build/rpi-imager --repo http://127.0.0.1:8000/os-list.json
```

Check before relying on it: whether the Imager running inside the distrobox can open the SD card (it goes through udisks2 on the host's system D-Bus). If it can't, run it with `sudo -E` from the distrobox, or use the CLI with `--tailscale-authkey-file`. Once flashed, the Pi updates from `ghcr.io/gnathoi/*`, which is public, so a private repo doesn't stop updates. Create a **tagged**, one-off, pre-approved Tailscale key first, and tick "Enable Tailscale SSH" (see Observations).

**How the fork and clone were made (done; for reference):**

```bash
gh repo fork raspberrypi/rpi-imager --clone=false          # creates gnathoi/rpi-imager
git clone git@github.com:gnathoi/rpi-imager.git ~/workspace/rpi-imager-fork   # full history: no --depth (version strings use git describe)
cd ~/workspace/rpi-imager-fork
git remote add upstream https://github.com/raspberrypi/rpi-imager.git
git fetch upstream --tags
git switch -c feat/tailscale-customisation 8e7e0b6f        # the commit this plan's line numbers refer to
```

If upstream has moved on, rebase `feat/tailscale-customisation` onto `upstream/main` once Task 2 is green. Re-check the line numbers in the "Modify:" lines as you go: the code is cited by function name as well as by line.

**Build and test locally (Fedora 44 / Bluefin).** Bluefin is image-based, so build inside a distrobox:

```bash
distrobox create --name imager-dev --image registry.fedoraproject.org/fedora-toolbox:44
distrobox enter imager-dev
sudo dnf install -y gcc-c++ clang compiler-rt cmake ninja-build git pkgconf-pkg-config \
    gnutls-devel liburing-devel systemd-devel \
    qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtsvg-devel qt6-qttools-devel \
    libxkbcommon-devel mesa-libGL-devel \
    python3-pyyaml mtools dosfstools xz zstd jq util-linux
rpm -q qt6-qtbase-devel     # must be >= 6.9: find_package(Qt6 6.9 ...) in src/CMakeLists.txt:416-427
```

Qt requirement: at least 6.9 (`src/CMakeLists.txt:416-427`). Upstream release builds use 6.11.2 (`QT_VERSION_DEFAULT` in `qt/qt-build-common.sh:20`). If Fedora's Qt is older than 6.9, run `sudo dnf install -y mmdebstrap && debian/ensure-qt.sh amd64` and add `-DQt6_ROOT=$PWD/.debian/qt/amd64/6.11.2/gcc_64` to the configure line below (CONTRIBUTING.md, "Build quickly while developing"). If CMake reports a missing private Qt module, install `qt6-qtbase-private-devel`.

```bash
cd ~/workspace/rpi-imager-fork
sh debian/fetch-vendor-deps.sh                     # vendored submodules (xz, zstd, zlib, curl, libarchive, libusb, ...)
cmake -B build -G Ninja src -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build --target generate_version      # test targets need imager_version.h first (CONTRIBUTING.md)
cmake --build build
```

How to run the tests this plan touches. Binaries land in `build/test/`. Catch2 tags select cases:

```bash
build/test/customization_generator_test                 # whole generator suite (fast)
build/test/customization_generator_test "[tailscale]"   # just this feature
build/test/image_writer_test "[tailscale]"
export QT_QUICK_BACKEND=software RPI_IMAGER_TELEMETRY_URL= RPI_IMAGER_CONNECT_URL=http://127.0.0.1:1
build/test/qml_ui_test -platform offscreen -input src/test/qml/tst_tailscale_step.qml
build/test/qml_ui_test -platform offscreen -input src/test/qml/tst_wizard_navigation.qml
ctest --test-dir build -j4                              # everything; qml_ui_test alone takes ~7-12 min
```

**How to execute this plan.** Work in `~/workspace/rpi-imager-fork` on `feat/tailscale-customisation`. Keep this plan and the spec open from the Juniper repo. Use **superpowers:subagent-driven-development**: one fresh implementer per task, a reviewer after each task, and a whole-branch review at the end. Tasks 1-8 go on `feat/tailscale-customisation`, the branch that gets upstreamed. Task 9 creates the fork-only `juniper` branch for CI. Task 11 writes the PR description into the Juniper repo.

**Decisions this plan makes that the spec leaves open:**

- The step sits between Raspberry Pi Connect and Interfaces & Features. That renumbers `stepIfAndFeatures`/`stepWriting`/`stepDone`, but every reference to them is symbolic.
- "Enable Tailscale SSH" defaults to **off**, which is the conservative default for upstream. Juniper's docs should tell users to tick it (see Observations).
- "Write another" keeps the key: reusable keys are a legitimate way to flash a batch. The help text says that a one-time key covers one card only.
- The collapsed "Advanced" section is a "Use a different control server" checkbox that reveals the URL field. The wizard has no collapsible component, and the checkbox also makes "unset" explicit.
- The Writing and Done summary lists are not changed (YAGNI). They are listed as a possible follow-up in the PR description.

## Spec deviations

1. **`--timeout=120s` is added to `tailscale up`.** Recommendation: keep it. Without a timeout, `tailscale up` waits forever when the control server can't be reached. That would hold `cloud-final.service`, and everything ordered after it (including Juniper's own join service), indefinitely. 120 s matches `juniper-tailscale-join.service`. A failed join keeps the key because of `&& shred`.
2. **The runcmd entries use the generator's existing list form**, `- [ systemctl, enable, --now, tailscaled ]` and `- [ sh, -c, "<escaped command>" ]`, rather than the plain strings shown in the spec. They behave the same. This keeps the shell-in-YAML quoting in the one `runcmd` lambda (`src/customization_generator.cpp:937-940`) that has already been audited.
3. **The generator has no existing `write_files` to merge with.** Pi Connect deliberately writes its token via `runcmd` because `write_files` with a non-root owner fails before the user exists (`src/customization_generator.cpp:958-960`). The plan therefore emits exactly one `write_files:` section and pins that with a test. The `runcmd` merge is real: there is one section, and Tailscale's entries come last.
4. **The CLI does not use the generator today.** `src/cli.cpp:324-363` passes user-supplied `user-data`/`firstrun.sh` files straight through. The Tailscale flags therefore *generate* user-data and are refused alongside `--cloudinit-userdata` or `--first-run-script`, because merging arbitrary user YAML is out of scope. `--cloudinit-networkconfig` still combines. The CLI has no OS list, so there is no capability gate: the operator asserts that the image ships Tailscale.
5. **`src/cmdline_params.h` holds kernel command-line parameters**, not CLI flags, so it is not touched. CLI flags live in `Cli::run()` (`src/cli.cpp:152-168`).
6. **The capability gate is enforced in C++ as well as QML**, through `ImageWriter::imageSupportsTailscale()`: capability present *and* `init_format` is `cloudinit`/`cloudinit-rpi`. An OS that advertises `tailscale` with `systemd` or `rpi-preseed` therefore gets no step and no output, which is what the "first PR" scope requires.
7. **Redaction covers more than the spec lists.** For cloud-init, the Wi-Fi passphrase lives in `network-config`, which is never logged. It *is* logged through the `"Custom firstrun.sh:"` line (`src/imagewriter.cpp:4214`) for both `systemd` and `rpi-preseed`, which put their payload in the firstrun slot, so redaction applies there. The Raspberry Pi Connect token goes through the same mechanism, at the cost of one more list entry. Any `tskey-…` is redacted by pattern, including in hand-written user-data passed to the CLI.
8. **Telemetry needs no code.** `DownloadStatsTelemetry` sends only the URL, OS category, image name and language (`src/downloadstatstelemetry.cpp:18-37`). Task 4 verifies this with a grep.

**Observations for Juniper (not part of this plan; track them in the Juniper repo):**

- If the hostname step is used, the generator also emits `packages: [avahi-daemon]` and an `apt:` block (`src/customization_generator.cpp:732-741`). On AlmaLinux bootc, cloud-init's package module will fail; this is non-fatal.
- With SSH enabled, the generator emits `systemctl enable --now ssh` (`:919`). The unit is `sshd` on AlmaLinux, so that line fails, also non-fatally, because runcmd carries on after a failure.
- If Imager's join succeeds without `--ssh`, the key is shredded and `juniper-tailscale-join.service` never runs. Juniper's README should tell users to tick "Enable Tailscale SSH".

## Global Constraints

- The contract is distro-neutral: the OS-list capability `"tailscale"` means **the OS ships Tailscale preinstalled**. Imager never installs it.
- Supported `init_format`s in the first PR: `cloudinit` and `cloudinit-rpi`. `systemd` (firstrun.sh) and `rpi-preseed` (which needs a `[tailscale]` section in rpi-preseed upstream) are follow-ups that are listed in the PR description and **not implemented**.
- Generated cloud-init: `write_files` path `/etc/tailscale/authkey`, `permissions: "0600"`, `owner: root:root`, and `content` = the key run through `yamlEscapeString`. Runcmd: `systemctl enable --now tailscaled`, then `tailscale up --auth-key=file:/etc/tailscale/authkey [--ssh] [--hostname=<hostname>] [--login-server=<url>] && shred -u /etc/tailscale/authkey`, with `--timeout=120s` per Spec deviation 1.
- `shred` runs only after a successful join, so the key survives a failed join for retry.
- The new sections merge into the existing `write_files`/`runcmd` sections rather than adding duplicates.
- Every interpolated value goes through the existing `shellQuote`/`yamlEscapeString` helpers.
- `--hostname` comes from the existing hostname step and is omitted when that is unset.
- The step is shown only when the selected OS has the `tailscale` capability, and is placed after the Pi Connect step.
- Key field: masked, must match `^tskey-auth-[A-Za-z0-9-]+$`. Otherwise an inline error shows and Next is disabled.
- "Enable Tailscale SSH" adds `--ssh`. The control server URL must be `https://`.
- The help text says to use a one-time, pre-approved, expiring key, and that the key is stored unencrypted on the card until first boot.
- The key is held in memory only: never written to QSettings, never restored on the next launch, and not included in telemetry. It is replaced with `<redacted>` in debug logging, and so is the existing Wi-Fi password.
- CLI flags: `--tailscale-authkey-file <path>` (so the key never appears in `ps`), `--tailscale-ssh`, `--tailscale-login-server`.
- Licence: the fork stays Apache-2.0 (`license.txt`). New files carry upstream's header style (`SPDX-License-Identifier: Apache-2.0` plus a copyright line, as every file in `src/` has).
- Code style: match the surrounding code, including comment density (comments explain *why*), `QStringLiteral`, 4-space C++ indent, and QML `objectName`s on anything a test reaches.
- Commits: CONTRIBUTING.md has no commit rules; upstream history uses `type(scope): imperative lower-case summary`, for example `feat(connect): …`, `fix(customisation): …`, `test(wizard): …`, `docs: …`. The body explains why, and upstream commits carry no trailers. Append whatever attribution trailer your harness requires.
- The upstreamable branch `feat/tailscale-customisation` contains nothing Juniper-specific. Fork-only CI lives on the `juniper` branch (Task 9).

## Review Focus

These are the inputs and conditions the spec implies but doesn't spell out. Each is the most likely to bite a real user, and each is pinned by a test in the task named.

1. **A key pasted with surrounding spaces or a trailing newline**, the usual result of copying from a browser. It should be accepted and written without the whitespace. Tests: Task 2, "A pasted key is written without the whitespace around it"; Task 6, `test_a_pasted_key_with_spaces_round_it_is_taken_without_them`.
2. **A key entered for one OS, followed by a switch to an OS without the capability, or to one with `systemd`/`rpi-preseed`.** Nothing about Tailscale should reach the card. Test: Task 4, "Nothing about Tailscale reaches an OS that does not ship it".
3. **No network, or an unreachable control server, at first boot.** The join should give up rather than hang cloud-init, and the key should stay for a retry. Test: Task 2, "A Tailscale key alone writes the key file and joins", which pins `--timeout=120s` and `&& shred` exactly.
4. **`--debug` output pasted into a bug report after writing with a key and a quote-laden Wi-Fi passphrase.** Neither secret should appear. Tests: Task 3, both redaction cases; Task 4, "The log shows the customisation without its secrets".
5. **Back then Next within a session should show what was entered. Relaunching Imager should not bring the key back.** Tests: Task 6, `test_coming_back_shows_what_was_entered`; Task 4, "The Tailscale key is never saved to the settings file".

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `doc/json-schema/os-list-schema.json` | Modify ~489-512 | Add `tailscale` to the OS `capabilities` enum and description |
| `doc/os_customisation_formats.md` | Modify (append) | Document what the capability means and which formats honour it |
| `src/customization_generator.h` | Modify ~137-147, ~205 | Declare `isTailscaleAuthKey`, `isTailscaleLoginServer`, `redactSecrets` |
| `src/customization_generator.cpp` | Modify ~704-1019 and new functions | Write the Tailscale block; validators; redaction |
| `src/imagewriter.h` | Modify ~450-454, ~771-777 | `imageSupportsTailscale()`, validator invokables, `_customisationSecrets` |
| `src/imagewriter.cpp` | Modify ~4197-4246, ~4403-4474, ~4494 | Capability gate, session-only key, redacted logging |
| `src/cli.h`, `src/cli.cpp` | Modify | `Cli::buildTailscaleUserData` and three flags |
| `doc/man/rpi-imager.1` | Modify ~132-145, examples | Document the flags |
| `src/wizard/TailscaleCustomizationStep.qml` | Create | The wizard step |
| `src/CMakeLists.txt` | Modify ~627 | Register the QML file |
| `src/wizard/WizardContainer.qml` | Modify (many small edits) | Step index, skip/back logic, sidebar, resets |
| `src/wizard/OSSelectionStep.qml` | Modify ~194, ~860, ~894, ~917 | Set `tailscaleAvailable`, scrub on OS change |
| `src/test/customization_generator_test.cpp` | Modify (append) | Generator, validator and redaction tests |
| `src/test/image_writer_test.cpp` | Modify (append) | Gate, persistence, logging and CLI tests |
| `src/test/qml/tst_tailscale_step.qml` | Create | Step validation and session-memory tests |
| `src/test/qml/tst_wizard_navigation.qml` | Modify | Skip/back/sidebar tests |
| `src/test/qml/tst_os_selection_step.qml`, `tst_os_change_scrub.qml`, `tst_os_delegate.qml` | Modify | Fake containers gain the two new properties |
| `src/test/fuzz/fuzz_customisation_gen.cpp` | Modify | Hostile Tailscale fields and an invariant |
| `.github/workflows/tailscale-fork.yml` | Create (on the `juniper` branch only) | Fork CI: tests + AppImage |

---

### Task 0: Workspace and baseline

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: a working `build/` tree in `~/workspace/rpi-imager-fork` on branch `feat/tailscale-customisation`, with a known-green baseline for the suites this plan touches.

- [ ] **Step 1: Create the fork and clone.** Run the commands in "Next human action" above. If `gh repo fork` reports that the fork already exists, just clone it.

- [ ] **Step 2: Configure and build.** Use the "Build and test locally" commands above, inside the `imager-dev` distrobox.

- [ ] **Step 3: Record the baseline.**

```bash
build/test/customization_generator_test 2>&1 | tail -3
build/test/image_writer_test "[cli]" 2>&1 | tail -3
export QT_QUICK_BACKEND=software RPI_IMAGER_TELEMETRY_URL= RPI_IMAGER_CONNECT_URL=http://127.0.0.1:1
for f in tst_wizard_navigation tst_os_selection_step tst_os_change_scrub tst_os_delegate tst_pi_connect; do
  build/test/qml_ui_test -platform offscreen -input src/test/qml/$f.qml 2>&1 | tail -2
done
```

Expected: every summary line reports 0 failures. If something fails on a clean checkout, note it in the task report as pre-existing and carry on; never "fix" upstream failures on this branch.

---

### Task 1: The `tailscale` capability in the schema and docs

**Files:**
- Modify: `doc/json-schema/os-list-schema.json:493` (description) and `:501-510` (enum)
- Modify: `doc/os_customisation_formats.md` (append a section)

**Interfaces:**
- Consumes: nothing.
- Produces: the capability string `"tailscale"`, which every later task uses verbatim.

- [ ] **Step 1: Write the failing check**

```bash
jq -e '.. | objects | select(."$id"? == "#/properties/os_list/items/anyOf/0/properties/capabilities") | .items.enum | index("tailscale")' doc/json-schema/os-list-schema.json
```

- [ ] **Step 2: Run it and confirm it fails.** Expected: it prints `null` and exits 1.

- [ ] **Step 3: Add the enum value and describe it.** In `doc/json-schema/os-list-schema.json`, change the enum:

```json
                                    "enum": [
                                        "rpi_connect",
                                        "secure_boot",
                                        "passwordless_sudo",
                                        "tailscale",
                                        "i2c",
```

In the same object's `"description"` (line 493), insert this text after `'passwordless_sudo' (enables passwordless sudo option in user setup), `:

```
'tailscale' (the OS ships Tailscale preinstalled; enables joining a tailnet on first boot with an auth key. Imager never installs Tailscale. Honoured for init_format cloudinit and cloudinit-rpi only),
```

Leave `os-list-schema.html` alone. It is generated, it is already stale (it doesn't list `passwordless_sudo`), and upstream doesn't maintain it.

- [ ] **Step 4: Document the capability.** Append to `doc/os_customisation_formats.md`:

```markdown

## Tailscale

An OS entry whose `capabilities` include `"tailscale"` declares that the image **ships Tailscale preinstalled** (`tailscale` and `tailscaled`). Raspberry Pi Imager never installs it.

For such an image, Imager shows a Tailscale step. The user pastes an auth key (`tskey-auth-…`) and can optionally enable Tailscale SSH or name a self-hosted control server (`https://` only, for example Headscale). Imager adds the following to cloud-init `user-data`:

```yaml
write_files:
  - path: /etc/tailscale/authkey
    permissions: "0600"
    owner: root:root
    content: "tskey-auth-…"
runcmd:
  - [ systemctl, enable, --now, tailscaled ]
  - [ sh, -c, "tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s [--ssh] [--hostname='…'] [--login-server='…'] && shred -u /etc/tailscale/authkey" ]
```

The key file is deleted only after a successful join. runcmd carries on past a failure, so if the first join fails, the root-only key file stays on the device, and an OS can retry with its own unit, for example one gated on `ConditionPathExists=/etc/tailscale/authkey`. The key is unencrypted on the card until first boot, so use a one-time, pre-approved key that expires soon.

The capability is honoured for `"init_format": "cloudinit"` and `"cloudinit-rpi"`. For `systemd` and `rpi-preseed`, the step is not shown and nothing is written.

The command line offers the same through `--tailscale-authkey-file`, `--tailscale-ssh` and `--tailscale-login-server` (see `rpi-imager(1)`).
```

- [ ] **Step 5: Run the check again and confirm it passes.**

```bash
jq -e '.. | objects | select(."$id"? == "#/properties/os_list/items/anyOf/0/properties/capabilities") | .items.enum | index("tailscale")' doc/json-schema/os-list-schema.json
jq empty doc/json-schema/os-list-schema.json && echo valid-json
```

Expected: `3`, then `valid-json`.

- [ ] **Step 6: Commit**

```bash
git add doc/json-schema/os-list-schema.json doc/os_customisation_formats.md
git commit -m "docs: add the tailscale OS capability" -m "An OS that ships Tailscale can say so, and Imager can then join it to a tailnet on first boot with an auth key. Imager never installs Tailscale; the capability is honoured for the cloud-init formats only."
```

---

### Task 2: The generator writes the Tailscale block

**Files:**
- Modify: `src/customization_generator.h`. Add public declarations after `shellQuote` (line 147).
- Modify: `src/customization_generator.cpp`. Add the validators after `sanitisedCountryCode` (ends line 188), and add the block to `generateCloudInitUserData` (lines 897-1009).
- Test: `src/test/customization_generator_test.cpp` (append at the end of the file).

**Interfaces:**
- Consumes: the `tailscale` capability name (Task 1, documentation only).
- Produces (all `static` in `rpi_imager::CustomisationGenerator`):
  - `bool isTailscaleAuthKey(const QString& key)`
  - `bool isTailscaleLoginServer(const QString& url)`
  - Settings keys read by `generateCloudInitUserData`: `"tailscaleAuthKey"` (QString; the block is emitted iff it is non-empty after `trimmed()`), `"tailscaleSsh"` (bool) and `"tailscaleLoginServer"` (QString, optional). `"hostname"` is reused.

- [ ] **Step 1: Write the failing tests.** Add `#include <QJsonArray>`, `#include <QJsonDocument>` and `#include <QJsonValue>` to the include block at the top of `src/test/customization_generator_test.cpp`, after `#include <QTemporaryDir>`. Then append:

```cpp
// ---------------------------------------------------------------------------
// Tailscale
// ---------------------------------------------------------------------------
//
// The OS ships Tailscale (the "tailscale" capability); Imager hands over an
// auth key in a root-only file and joins on first boot. The key has to reach
// that file exactly as pasted and go nowhere else, and nothing else typed
// into the wizard may turn the join into a different command.

namespace {

const QString kTailscaleKey = QStringLiteral("tskey-auth-kTEST1CNTRL-0123456789abcdef");

QVariantMap tailscaleSettings()
{
    QVariantMap s;
    s.insert(QStringLiteral("tailscaleAuthKey"), kTailscaleKey);
    return s;
}

// Loads `document` with PyYAML and returns `expression` -- Python, with the
// document bound to d -- as JSON. Undefined when it could not be loaded.
QJsonValue yamlValue(const QByteArray &document, const QString &expression)
{
    QTemporaryDir dir;
    if (!dir.isValid())
        return {};
    const QString path = QDir(dir.path()).filePath(QStringLiteral("document"));
    {
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly))
            return {};
        f.write(document);
    }
    QProcess proc;
    proc.start(pythonThatParses("yaml"),
               {QStringLiteral("-c"),
                QStringLiteral("import sys,json,yaml; d=yaml.safe_load(open(sys.argv[1],'rb').read()); "
                               "print(json.dumps(") + expression + QStringLiteral("))"),
                path});
    proc.waitForFinished(rpi_test::kFixtureProcessTimeoutMs);
    const QByteArray out = proc.readAllStandardOutput().trimmed();
    return QJsonDocument::fromJson("[" + out + "]").array().at(0);
}

} // namespace

TEST_CASE("Only a Tailscale auth key is taken for one", "[customization][tailscale]")
{
    CHECK(CustomisationGenerator::isTailscaleAuthKey(kTailscaleKey));
    CHECK(CustomisationGenerator::isTailscaleAuthKey(QStringLiteral("tskey-auth-k1-a")));

    // API and OAuth client keys share the prefix and are refused by
    // `tailscale up`; the rest could not have been pasted from the console.
    for (const char *bad : {"", "tskey-auth-", "tskey-api-kTEST1CNTRL-0123",
                            "tskey-client-kTEST1CNTRL-0123", "TSKEY-AUTH-ABC",
                            "tskey-auth-abc def", "tskey-auth-abc\n", " tskey-auth-abc",
                            "tskey-auth-abc;reboot", "tskey-auth-abc'"}) {
        INFO("refused: " << bad);
        CHECK_FALSE(CustomisationGenerator::isTailscaleAuthKey(QString::fromUtf8(bad)));
    }
}

TEST_CASE("A control server has to be https", "[customization][tailscale]")
{
    CHECK(CustomisationGenerator::isTailscaleLoginServer(QStringLiteral("https://hs.example.com")));
    CHECK(CustomisationGenerator::isTailscaleLoginServer(QStringLiteral("https://hs.example.com:8443/")));

    for (const char *bad : {"", "http://hs.example.com", "hs.example.com", "https://",
                            "https://hs example.com", " https://hs.example.com",
                            "https://hs.example.com\n", "ftp://hs.example.com"}) {
        INFO("refused: " << bad);
        CHECK_FALSE(CustomisationGenerator::isTailscaleLoginServer(QString::fromUtf8(bad)));
    }
}

TEST_CASE("A Tailscale key alone writes the key file and joins", "[cloudinit][tailscale]")
{
    // Spelled out in full: this is the contract an OS relies on. The key is
    // shredded only after a join that worked, so a failed one can be
    // retried; and --timeout stops an unreachable control server from
    // holding cloud-final, and everything ordered after it, for ever.
    const QByteArray expected =
        "manage_resolv_conf: false\n"
        "\n"
        "write_files:\n"
        "  - path: /etc/tailscale/authkey\n"
        "    permissions: \"0600\"\n"
        "    owner: root:root\n"
        "    content: \"tskey-auth-kTEST1CNTRL-0123456789abcdef\"\n"
        "runcmd:\n"
        "  - [ systemctl, enable, --now, tailscaled ]\n"
        "  - [ sh, -c, \"tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s"
        " && shred -u /etc/tailscale/authkey\" ]\n";

    const QByteArray plain = CustomisationGenerator::generateCloudInitUserData(tailscaleSettings());
    INFO("cloudinit:\n" << plain.toStdString());
    CHECK(plain == expected);

    // cloudinit-rpi goes through the same generator with hasCcRpi set; the
    // block must not depend on it.
    const QByteArray rpi = CustomisationGenerator::generateCloudInitUserData(
        tailscaleSettings(), QString(), true);
    INFO("cloudinit-rpi:\n" << rpi.toStdString());
    CHECK(rpi == expected);
}

TEST_CASE("Tailscale SSH, the hostname and a control server reach tailscale up",
          "[cloudinit][tailscale]")
{
    QVariantMap s = tailscaleSettings();
    s.insert(QStringLiteral("tailscaleSsh"), true);
    s.insert(QStringLiteral("hostname"), QStringLiteral("juniper"));
    s.insert(QStringLiteral("tailscaleLoginServer"), QStringLiteral("https://hs.example.com"));

    const std::string yaml = CustomisationGenerator::generateCloudInitUserData(s).toStdString();
    INFO(yaml);
    CHECK_THAT(yaml, ContainsSubstring(
        "  - [ sh, -c, \"tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s"
        " --ssh --hostname='juniper' --login-server='https://hs.example.com'"
        " && shred -u /etc/tailscale/authkey\" ]\n"));
}

TEST_CASE("Without a key nothing about Tailscale is written", "[cloudinit][tailscale]")
{
    QVariantMap s;
    s.insert(QStringLiteral("hostname"), QStringLiteral("pi"));
    s.insert(QStringLiteral("tailscaleSsh"), true);
    s.insert(QStringLiteral("tailscaleLoginServer"), QStringLiteral("https://hs.example.com"));

    QByteArray yaml = CustomisationGenerator::generateCloudInitUserData(s);
    INFO(yaml.toStdString());
    CHECK_FALSE(yaml.contains("tailscale"));
    CHECK_FALSE(yaml.contains("write_files"));

    // A key of nothing but whitespace is no key.
    s.insert(QStringLiteral("tailscaleAuthKey"), QStringLiteral("  \r\n"));
    yaml = CustomisationGenerator::generateCloudInitUserData(s);
    CHECK_FALSE(yaml.contains("tailscale"));
}

TEST_CASE("A pasted key is written without the whitespace around it", "[cloudinit][tailscale]")
{
    // Copied from a browser, a key arrives with a newline, and sometimes spaces.
    QVariantMap s;
    s.insert(QStringLiteral("tailscaleAuthKey"), QStringLiteral("  ") + kTailscaleKey + QStringLiteral("\r\n"));

    const std::string yaml = CustomisationGenerator::generateCloudInitUserData(s).toStdString();
    CHECK_THAT(yaml, ContainsSubstring("    content: \"" + kTailscaleKey.toStdString() + "\"\n"));
}

TEST_CASE("Tailscale joins the one runcmd and write_files the rest use", "[cloudinit][tailscale]")
{
    // SSH, passwordless sudo, Raspberry Pi Connect and the Wi-Fi unblock all
    // add runcmd entries. Two runcmd keys would be a YAML document in which
    // the second silently replaces the first.
    QVariantMap s = tailscaleSettings();
    s.insert(QStringLiteral("sshUserName"), QStringLiteral("pi"));
    s.insert(QStringLiteral("sshUserPassword"), QStringLiteral("$5$abc$def"));  // already crypted: no hashing
    s.insert(QStringLiteral("sshPublicKey"), QStringLiteral("ssh-ed25519 AAAA pi@host"));
    s.insert(QStringLiteral("passwordlessSudo"), true);
    s.insert(QStringLiteral("piConnectEnabled"), true);
    s.insert(QStringLiteral("recommendedWifiCountry"), QStringLiteral("GB"));  // country, no SSID

    const QByteArray yaml = CustomisationGenerator::generateCloudInitUserData(
        s, QStringLiteral("rpuak_abcdefghijkmnpqrstuvwxyz"), false, true, QStringLiteral("pi"));
    INFO(yaml.toStdString());
    CHECK(yaml.count("\nruncmd:") == 1);
    CHECK(yaml.count("\nwrite_files:") == 1);

    if (pythonThatParses("yaml").isEmpty())
        SKIP("no python3 with PyYAML here, so the output cannot be parsed");

    CHECK(yamlValue(yaml, QStringLiteral("d['runcmd'][0]")).toArray()
          == QJsonArray{QStringLiteral("systemctl"), QStringLiteral("enable"),
                        QStringLiteral("--now"), QStringLiteral("ssh")});
    // Tailscale last: the join needs the network the earlier entries unblock.
    CHECK(yamlValue(yaml, QStringLiteral("d['runcmd'][-2]")).toArray()
          == QJsonArray{QStringLiteral("systemctl"), QStringLiteral("enable"),
                        QStringLiteral("--now"), QStringLiteral("tailscaled")});
    CHECK(yamlValue(yaml, QStringLiteral("d['runcmd'][-1][2]")).toString()
              .startsWith(QStringLiteral("tailscale up ")));
    CHECK(yamlValue(yaml, QStringLiteral("len(d['write_files'])")).toInt() == 1);
}

TEST_CASE("Nothing typed into the wizard can change the Tailscale join",
          "[cloudinit][tailscale][injection]")
{
    if (pythonThatParses("yaml").isEmpty())
        SKIP("no python3 with PyYAML here, so the output cannot be parsed");
    const QString shell = rpi_test::shellPath();
    if (shell.isEmpty())
        SKIP("no POSIX shell available to interpret the quoting");

    // The validators refuse all three. The generator must not depend on it:
    // the command line and older settings are other ways in.
    const QString key = QStringLiteral("tskey-auth-x\"\nruncmd: [reboot]\n'$(reboot)`reboot`");
    const QString host = QStringLiteral("pi'; reboot; '");
    const QString server = QStringLiteral("https://hs.example.com/$(reboot)'\"\n- [reboot]");
    QVariantMap s;
    s.insert(QStringLiteral("tailscaleAuthKey"), key);
    s.insert(QStringLiteral("hostname"), host);
    s.insert(QStringLiteral("tailscaleLoginServer"), server);

    const QByteArray yaml = CustomisationGenerator::generateCloudInitUserData(s);
    INFO(yaml.toStdString());

    // The key reaches the file exactly as given, and the injected runcmd did
    // not become one.
    CHECK(yamlValue(yaml, QStringLiteral("d['write_files'][0]['content']")).toString() == key);
    CHECK(yamlValue(yaml, QStringLiteral("len(d['runcmd'])")).toInt() == 2);

    // The key is read from the file, never from the command line.
    const QString up = yamlValue(yaml, QStringLiteral("d['runcmd'][-1][2]")).toString();
    CHECK_FALSE(up.contains(QStringLiteral("tskey")));

    // Run the command with tailscale swapped for something that prints its
    // arguments: each value has to come back as one argument, unchanged.
    QString cmd = up;
    cmd.replace(QStringLiteral("tailscale up "), QStringLiteral("printf '%s\\0' "));
    cmd.replace(QStringLiteral(" && shred -u /etc/tailscale/authkey"), QString());
    QProcess sh;
    sh.start(shell, {QStringLiteral("-c"), cmd});
    REQUIRE(sh.waitForFinished(10000));
    const QList<QByteArray> args = sh.readAllStandardOutput().split('\0');
    CHECK(args.contains((QStringLiteral("--hostname=") + host).toUtf8()));
    CHECK(args.contains((QStringLiteral("--login-server=") + server).toUtf8()));
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**

```bash
cmake --build build --target customization_generator_test
```

Expected: a compile error, `'isTailscaleAuthKey' is not a member of 'rpi_imager::CustomisationGenerator'`.

- [ ] **Step 3: Declare the validators.** In `src/customization_generator.h`, after the `shellQuote` declaration (line 147), add:

```cpp

    /**
     * @brief Whether a string is a Tailscale auth key ("tskey-auth-..." and
     * nothing else), as pasted from the admin console.
     *
     * Only auth keys join a device; API and OAuth client keys share the
     * "tskey-" prefix but `tailscale up` refuses them.
     */
    static bool isTailscaleAuthKey(const QString& key);

    /**
     * @brief Whether a URL can be handed to `tailscale up --login-server`:
     * https only, with a host -- a self-hosted control server such as
     * Headscale.
     */
    static bool isTailscaleLoginServer(const QString& url);
```

- [ ] **Step 4: Implement the validators.** In `src/customization_generator.cpp`, add `#include <QUrl>` after `#include <QStringConverter>` (line 14). After `CustomisationGenerator::sanitisedCountryCode` (which ends at line 188), add:

```cpp

bool CustomisationGenerator::isTailscaleAuthKey(const QString& key) {
    // anchoredPattern rather than ^...$: PCRE's $ also matches before a final
    // newline, and a key pasted with one would pass.
    static const QRegularExpression re(QRegularExpression::anchoredPattern(
        QStringLiteral("tskey-auth-[A-Za-z0-9-]+")));
    return re.match(key).hasMatch();
}

bool CustomisationGenerator::isTailscaleLoginServer(const QString& url) {
    // Checked here rather than left to QUrl: it lands on a command line, and
    // whitespace there is the start of another argument.
    static const QRegularExpression space(QStringLiteral("\\s"));
    if (url.contains(space))
        return false;
    const QUrl u(url, QUrl::StrictMode);
    return u.isValid() && u.scheme() == QLatin1String("https") && !u.host().isEmpty();
}
```

- [ ] **Step 5: Emit the block.** In `generateCloudInitUserData`, replace these lines (906-909):

```cpp
    bool needsRuncmdForWifi = !wifiCountry.isEmpty() && ssidOctets.isEmpty();
    bool needsRuncmdForPiConnect = piConnectEnabled && !cleanToken.isEmpty();
    bool needsRuncmdForSsh = sshEnabled;
    bool needsRuncmd = needsRuncmdForPiConnect || needsRuncmdForWifi || needsRuncmdForSudo || needsRuncmdForSsh;
```

with:

```cpp
    bool needsRuncmdForWifi = !wifiCountry.isEmpty() && ssidOctets.isEmpty();
    bool needsRuncmdForPiConnect = piConnectEnabled && !cleanToken.isEmpty();
    bool needsRuncmdForSsh = sshEnabled;

    // Tailscale: the OS ships it (the "tailscale" capability), so all there
    // is to do is hand over the key and join. The key goes in a root-only
    // file rather than on the command line, where anyone could read it from
    // ps; `tailscale up` reads it from there itself. root exists at parse
    // time, so write_files is safe here, unlike the Connect token below.
    const QString tailscaleKey = settings.value("tailscaleAuthKey").toString().trimmed();
    const bool needsRuncmdForTailscale = !tailscaleKey.isEmpty();
    if (needsRuncmdForTailscale) {
        push(QStringLiteral("write_files:"), cloud);
        push(QStringLiteral("  - path: /etc/tailscale/authkey"), cloud);
        push(QStringLiteral("    permissions: \"0600\""), cloud);
        push(QStringLiteral("    owner: root:root"), cloud);
        push(QStringLiteral("    content: \"") + yamlEscapeString(tailscaleKey)
             + QStringLiteral("\""), cloud);
    }

    bool needsRuncmd = needsRuncmdForPiConnect || needsRuncmdForWifi || needsRuncmdForSudo
                       || needsRuncmdForSsh || needsRuncmdForTailscale;
```

Then, inside `if (needsRuncmd) { … }`, after the `if (needsRuncmdForWifi) { … }` block (which ends at line 1008) and before the closing brace of `if (needsRuncmd)`, add:

```cpp

        if (needsRuncmdForTailscale) {
            // Last, after the Wi-Fi unblock above: joining needs the network.
            // The key is shredded only once the join has worked. runcmd does
            // not stop at a failure, and an OS that retries the join needs
            // the key still there. --timeout so that an unreachable control
            // server cannot hold cloud-final, and everything ordered after
            // it, for ever.
            push(QStringLiteral("  - [ systemctl, enable, --now, tailscaled ]"), cloud);
            QString up = QStringLiteral("tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s");
            if (settings.value("tailscaleSsh").toBool())
                up += QStringLiteral(" --ssh");
            if (!hostname.isEmpty())
                up += QStringLiteral(" --hostname=") + shellQuote(hostname);
            const QString loginServer = settings.value("tailscaleLoginServer").toString().trimmed();
            if (!loginServer.isEmpty())
                up += QStringLiteral(" --login-server=") + shellQuote(loginServer);
            runcmd(up + QStringLiteral(" && shred -u /etc/tailscale/authkey"));
        }
```

`hostname` is the trimmed value already read at line 719.

- [ ] **Step 6: Run the tests and confirm they pass.**

```bash
cmake --build build --target customization_generator_test && build/test/customization_generator_test "[tailscale]"
build/test/customization_generator_test
```

Expected: `All tests passed` for both runs. The second run proves that no existing output changed.

- [ ] **Step 7: Commit**

```bash
git add src/customization_generator.h src/customization_generator.cpp src/test/customization_generator_test.cpp
git commit -m "feat(customisation): join a tailnet on first boot from cloud-init" -m "For an OS that ships Tailscale, write the auth key to a root-only /etc/tailscale/authkey and run tailscale up from it, shredding the key only once the join succeeds so a failed one can be retried. The entries join the existing runcmd; every value is quoted for the shell and escaped for YAML. --timeout keeps an unreachable control server from holding cloud-final."
```

---

### Task 3: Redacting secrets for the log

**Files:**
- Modify: `src/customization_generator.h`. Add the declaration after `isTailscaleLoginServer` (Task 2).
- Modify: `src/customization_generator.cpp`. Add the function after `isTailscaleLoginServer` and `#include <algorithm>`.
- Test: `src/test/customization_generator_test.cpp` (append).

**Interfaces:**
- Consumes: `kTailscaleKey` and `tailscaleSettings()` from Task 2's test namespace (same file).
- Produces: `static QByteArray rpi_imager::CustomisationGenerator::redactSecrets(const QByteArray& payload, const QStringList& secrets)`. It replaces every `tskey-[A-Za-z0-9-]+` and every listed secret, in each form the generators write one, with `<redacted>`.

- [ ] **Step 1: Write the failing tests.** Append to `src/test/customization_generator_test.cpp`:

```cpp
TEST_CASE("Redaction takes a Tailscale key out of whatever holds it",
          "[customization][tailscale][secrets]")
{
    const QByteArray yaml = CustomisationGenerator::generateCloudInitUserData(tailscaleSettings());
    const QByteArray shown = CustomisationGenerator::redactSecrets(yaml, {});
    INFO(shown.toStdString());
    CHECK_FALSE(shown.contains("tskey-"));
    CHECK(shown.contains("    content: \"<redacted>\"\n"));

    // Found by its shape, so hand-written user-data passed through the
    // command line is covered without being told what to look for.
    CHECK(CustomisationGenerator::redactSecrets("x: tskey-auth-abc-DEF123\n", {})
          == QByteArray("x: <redacted>\n"));
}

TEST_CASE("Redaction takes the Wi-Fi passphrase out of every document that carries it",
          "[customization][secrets]")
{
    // "zebra" marks each passphrase: whatever the escaping did to the rest,
    // finding it after redaction is a leak.
    const QStringList passphrases{
        QStringLiteral("zebrazebra"),
        QStringLiteral("zebra's \"quoted\" \\ pass"),
        QStringLiteral(" zebra\twith a tab"),
        QStringLiteral("zebrapass\n"),
    };
    for (const QString &pass : passphrases) {
        QVariantMap s;
        s.insert(QStringLiteral("wifiSSID"), QStringLiteral("home"));
        s.insert(QStringLiteral("wifiPassword"), pass);
        s.insert(QStringLiteral("recommendedWifiCountry"), QStringLiteral("GB"));
        INFO("passphrase: " << pass.toStdString());

        const QByteArray documents[] = {
            CustomisationGenerator::generateSystemdScript(s),
            CustomisationGenerator::generateCloudInitNetworkConfig(s),
            CustomisationGenerator::generateRpiPreseedToml(s),
        };
        for (const QByteArray &doc : documents) {
            REQUIRE(doc.contains("zebra"));     // or the case proves nothing
            const QByteArray shown = CustomisationGenerator::redactSecrets(doc, {pass});
            INFO(shown.toStdString());
            CHECK_FALSE(shown.contains("zebra"));
            CHECK(shown.contains("<redacted>"));
        }
    }
}

TEST_CASE("Redaction takes out a Raspberry Pi Connect token too", "[customization][secrets]")
{
    const QString token = QStringLiteral("rpuak_zebrazebrazebrazebrazeb");
    QVariantMap s;
    s.insert(QStringLiteral("piConnectEnabled"), true);
    s.insert(QStringLiteral("sshUserName"), QStringLiteral("pi"));
    const QByteArray script = CustomisationGenerator::generateSystemdScript(s, token);
    REQUIRE(script.contains("zebra"));
    CHECK_FALSE(CustomisationGenerator::redactSecrets(script, {token}).contains("zebra"));
}
```

- [ ] **Step 2: Run them and confirm they fail.**

```bash
cmake --build build --target customization_generator_test
```

Expected: a compile error, `'redactSecrets' is not a member of 'rpi_imager::CustomisationGenerator'`.

- [ ] **Step 3: Declare it.** In `src/customization_generator.h`, after `isTailscaleLoginServer`, add:

```cpp

    /**
     * @brief A customisation payload with its secrets taken out, for the log.
     *
     * Every Tailscale key ("tskey-...") goes, whatever wrote it, and so does
     * each of `secrets` in every form the generators write one: as typed,
     * escaped for YAML, quoted for the shell (also after NetworkManager
     * keyfile escaping) and quoted for TOML. Each becomes "<redacted>".
     */
    static QByteArray redactSecrets(const QByteArray& payload, const QStringList& secrets);
```

Add `#include <QStringList>` after `#include <QVariantMap>` (line 11) in the header.

- [ ] **Step 4: Implement it.** In `src/customization_generator.cpp`, add `#include <algorithm>` before `#include <random>` (line 20). After `isTailscaleLoginServer`, add:

```cpp

QByteArray CustomisationGenerator::redactSecrets(const QByteArray& payload, const QStringList& secrets)
{
    static const QRegularExpression tailscaleKey(QStringLiteral("tskey-[A-Za-z0-9-]+"));
    const QString redacted = QStringLiteral("<redacted>");
    // The inside of a quoted value: each quoting adds one character either side.
    auto inner = [](const QString& quoted) { return quoted.mid(1, quoted.size() - 2); };

    QString text = QString::fromUtf8(payload);
    text.replace(tailscaleKey, redacted);
    for (const QString& secret : secrets) {
        // As the generators see it: they strip line terminators first.
        const QString s = stripLineTerminators(secret);
        if (s.isEmpty())
            continue;
        QStringList forms{secret, s, yamlEscapeString(s), inner(shellQuote(s)),
                          inner(shellQuote(keyfileEscape(s))), inner(tomlQuote(s))};
        // Longest first, so a short form never breaks up a longer one before
        // that one is matched.
        std::sort(forms.begin(), forms.end(),
                  [](const QString& a, const QString& b) { return a.size() > b.size(); });
        for (const QString& form : std::as_const(forms))
            text.replace(form, redacted);
    }
    return text.toUtf8();
}
```

`keyfileEscape` and `tomlQuote` are the file-local helpers at lines 58-87. `stripLineTerminators` is the existing public static at line 190.

- [ ] **Step 5: Run the tests and confirm they pass.**

```bash
cmake --build build --target customization_generator_test && build/test/customization_generator_test "[secrets]"
```

Expected: `All tests passed`.

- [ ] **Step 6: Commit**

```bash
git add src/customization_generator.h src/customization_generator.cpp src/test/customization_generator_test.cpp
git commit -m "feat(customisation): add redactSecrets for logging payloads" -m "The generated scripts carry a Wi-Fi passphrase, a Connect token and now a Tailscale key, and the whole payload goes to the debug log -- which is what people paste into bug reports. Redact each secret in every form the generators write it, and any tskey- whatever wrote it."
```

---

### Task 4: ImageWriter keeps the key to the session, the capable OS and out of the log

**Files:**
- Modify: `src/imagewriter.h`. Add invokables after `imageSupportsInterfaceCustomisation` (line 454), and a member after `_piConnectTokenIsOrgMinted` (line 777).
- Modify: `src/imagewriter.cpp`:
  - `setImageCustomisation` (lines 4214-4215)
  - `applyCustomisationFromSettings` (lines 4235-4236)
  - `setSavedCustomisationSettings` / `setPersistedCustomisationSetting` (lines 4403-4466)
  - new functions after `imageSupportsInterfaceCustomisation` (line 4497)
- Test: `src/test/image_writer_test.cpp` (append at the end of the file).

**Interfaces:**
- Consumes: `CustomisationGenerator::isTailscaleAuthKey`, `isTailscaleLoginServer` and `redactSecrets` (Tasks 2-3); the settings keys `tailscaleAuthKey`, `tailscaleSsh` and `tailscaleLoginServer`.
- Produces:
  - `Q_INVOKABLE bool ImageWriter::imageSupportsTailscale()`: true iff `_initFormat` is `cloudinit`/`cloudinit-rpi` **and** the SW capability `tailscale` is present.
  - `Q_INVOKABLE bool ImageWriter::isValidTailscaleAuthKey(const QString &key) const`
  - `Q_INVOKABLE bool ImageWriter::isValidTailscaleLoginServer(const QString &url) const`
  - Test helpers in `image_writer_test.cpp`'s new anonymous namespace, reused by Task 5: `kKey` (QString), `StagedCustomisation`, `DebugCapture`, `chooseOs(ImageWriter&, const QByteArray&, const QVariantList&)`, `tailscaleWizardSettings()`.

- [ ] **Step 1: Write the failing tests.** Append to `src/test/image_writer_test.cpp`:

```cpp

// ══════════════════════════════════════════════════════════════
// Tailscale: where the auth key may go, and where it may not
//
// The key joins a machine to somebody's network. It is written to the card
// for an OS that ships Tailscale and takes cloud-init, and nowhere else: not
// to another image, not to the settings file, not to the log.
// ══════════════════════════════════════════════════════════════

namespace {

// The staged payloads are protected; this is the writer the wizard drives,
// with them in reach.
class StagedCustomisation : public ImageWriter
{
public:
    StagedCustomisation() : ImageWriter(nullptr) {}
    using ImageWriter::_cloudinit;
    using ImageWriter::_firstrun;
};

// Everything the process logs while it lives, at every level.
class DebugCapture
{
public:
    explicit DebugCapture(QStringList *sink)
    {
        _sink = sink;
        _previous = qInstallMessageHandler(&DebugCapture::handle);
    }
    ~DebugCapture()
    {
        qInstallMessageHandler(_previous);
        _sink = nullptr;
    }
    DebugCapture(const DebugCapture &) = delete;
    DebugCapture &operator=(const DebugCapture &) = delete;

private:
    static void handle(QtMsgType, const QMessageLogContext &, const QString &msg)
    {
        if (_sink)
            *_sink << msg;
    }
    static inline QStringList *_sink = nullptr;
    static inline QtMessageHandler _previous = nullptr;
};

const QString kKey = QStringLiteral("tskey-auth-kTEST1CNTRL-0123456789abcdef");

QVariantMap tailscaleWizardSettings()
{
    QVariantMap s;
    s.insert(QStringLiteral("tailscaleAuthKey"), kKey);
    s.insert(QStringLiteral("tailscaleSsh"), true);
    return s;
}

// What OSSelectionStep does when a row is chosen.
void chooseOs(ImageWriter &w, const QByteArray &initFormat, const QVariantList &caps)
{
    w.setSrc(QUrl(QStringLiteral("https://example.invalid/os.img.xz")), 0, 0, QByteArray(),
             false, QString(), QStringLiteral("Test OS"), initFormat);
    w.setSWCapabilitiesList(caps);
}

} // namespace

TEST_CASE("Tailscale is written for a cloud-init OS that ships it", "[imagewriter][tailscale]")
{
    for (const QByteArray &format : {QByteArray("cloudinit"), QByteArray("cloudinit-rpi")}) {
        INFO("init_format " << format.toStdString());
        StagedCustomisation w;
        chooseOs(w, format, {QStringLiteral("tailscale")});
        CHECK(w.imageSupportsTailscale());

        w.applyCustomisationFromSettings(tailscaleWizardSettings());

        CHECK(w._cloudinit.contains("path: /etc/tailscale/authkey"));
        CHECK(w._cloudinit.contains(kKey.toUtf8()));
        CHECK(w._cloudinit.contains(" --ssh"));
    }
}

TEST_CASE("Nothing about Tailscale reaches an OS that does not ship it", "[imagewriter][tailscale]")
{
    // The key was entered for one OS and another was then chosen. The wizard
    // scrubs it too; this is the gate every route to the generator passes.
    struct Case { const char *what; QByteArray format; QVariantList caps; };
    const Case cases[] = {
        {"cloud-init without the capability", "cloudinit", {}},
        {"the capability, but systemd", "systemd", {QStringLiteral("tailscale")}},
        {"the capability, but rpi-preseed", "rpi-preseed", {QStringLiteral("tailscale")}},
    };
    for (const Case &c : cases) {
        INFO(c.what);
        StagedCustomisation w;
        chooseOs(w, c.format, c.caps);
        CHECK_FALSE(w.imageSupportsTailscale());

        QVariantMap s = tailscaleWizardSettings();
        s.insert(QStringLiteral("hostname"), QStringLiteral("pi"));   // so something is written
        w.applyCustomisationFromSettings(s);

        CHECK_FALSE(w._cloudinit.contains("tailscale"));
        CHECK_FALSE(w._cloudinit.contains("tskey"));
        CHECK_FALSE(w._firstrun.contains("tailscale"));
        CHECK_FALSE(w._firstrun.contains("tskey"));
    }
}

TEST_CASE("The Tailscale key is never saved to the settings file",
          "[imagewriter][tailscale][secrets]")
{
    // Relaunching Imager must not bring the key back: it is for this session.
    ImageWriter w(nullptr);
    w.clearSavedCustomisationSettings();

    w.setPersistedCustomisationSetting(QStringLiteral("tailscaleAuthKey"), kKey);
    CHECK_FALSE(ImageWriter(nullptr).getSavedCustomisationSettings()
                    .contains(QStringLiteral("tailscaleAuthKey")));

    // The legacy whole-map save is refused it too, and keeps the rest.
    w.setSavedCustomisationSettings({{QStringLiteral("hostname"), QStringLiteral("pi")},
                                     {QStringLiteral("tailscaleAuthKey"), kKey}});
    const QVariantMap saved = ImageWriter(nullptr).getSavedCustomisationSettings();
    CHECK(saved.value(QStringLiteral("hostname")).toString() == QStringLiteral("pi"));
    CHECK_FALSE(saved.contains(QStringLiteral("tailscaleAuthKey")));

    w.clearSavedCustomisationSettings();
}

TEST_CASE("The log shows the customisation without its secrets",
          "[imagewriter][tailscale][secrets]")
{
    // --debug output is what gets pasted into a bug report.
    StagedCustomisation w;
    QStringList logged;
    {
        DebugCapture capture(&logged);

        chooseOs(w, "cloudinit", {QStringLiteral("tailscale")});
        w.applyCustomisationFromSettings(tailscaleWizardSettings());
        REQUIRE(w._cloudinit.contains(kKey.toUtf8()));   // the key really was written

        chooseOs(w, "systemd", {});
        QVariantMap wifi;
        wifi.insert(QStringLiteral("wifiSSID"), QStringLiteral("home"));
        wifi.insert(QStringLiteral("wifiPassword"), QStringLiteral("zebra's \"pass\""));
        wifi.insert(QStringLiteral("recommendedWifiCountry"), QStringLiteral("GB"));
        w.applyCustomisationFromSettings(wifi);
        REQUIRE(w._firstrun.contains("zebra"));          // and so was the passphrase

        // The command line passes hand-written user-data straight through.
        w.setImageCustomisation({}, {}, {},
                                "write_files:\n  - content: \"" + kKey.toUtf8() + "\"\n", {});
    }
    const QString all = logged.join(QLatin1Char('\n'));
    INFO(all.toStdString());
    REQUIRE(all.contains(QStringLiteral("Cloudinit:")));   // it did log the payloads
    CHECK_FALSE(all.contains(QStringLiteral("tskey")));
    CHECK_FALSE(all.contains(QStringLiteral("zebra")));
    CHECK(all.contains(QStringLiteral("<redacted>")));
}

TEST_CASE("The wizard's Tailscale checks are the generator's", "[imagewriter][tailscale]")
{
    ImageWriter w(nullptr);
    CHECK(w.isValidTailscaleAuthKey(kKey));
    CHECK_FALSE(w.isValidTailscaleAuthKey(QStringLiteral("tskey-api-kTEST1CNTRL-0123")));
    CHECK(w.isValidTailscaleLoginServer(QStringLiteral("https://hs.example.com")));
    CHECK_FALSE(w.isValidTailscaleLoginServer(QStringLiteral("http://hs.example.com")));
}
```

- [ ] **Step 2: Run them and confirm they fail.**

```bash
cmake --build build --target image_writer_test
```

Expected: a compile error, `'class StagedCustomisation' has no member named 'imageSupportsTailscale'`.

- [ ] **Step 3: Declare the additions.** In `src/imagewriter.h`, after `Q_INVOKABLE bool imageSupportsInterfaceCustomisation();` (line 454), add:

```cpp
    // Whether the selected OS ships Tailscale (the "tailscale" capability)
    // and takes cloud-init, the only format the join is written for.
    Q_INVOKABLE bool imageSupportsTailscale();
    // For the wizard's fields. CustomisationGenerator holds the rules, so the
    // command line and the wizard cannot disagree.
    Q_INVOKABLE bool isValidTailscaleAuthKey(const QString &key) const;
    Q_INVOKABLE bool isValidTailscaleLoginServer(const QString &url) const;
```

After `bool _piConnectTokenIsOrgMinted = false;` (line 777), add:

```cpp
    // What setImageCustomisation() keeps out of the log: the Wi-Fi
    // passphrase, the Tailscale key and the Connect token behind the last
    // applyCustomisationFromSettings().
    QStringList _customisationSecrets;
```

- [ ] **Step 4: Gate, record the secrets and redact.** In `src/imagewriter.cpp`, replace the two logging lines in `setImageCustomisation` (4214-4215):

```cpp
    qDebug() << "Custom firstrun.sh:" << firstrun;
    qDebug() << "Cloudinit:" << cloudinit;
```

with:

```cpp
    qDebug() << "Custom firstrun.sh:"
             << rpi_imager::CustomisationGenerator::redactSecrets(firstrun, _customisationSecrets);
    qDebug() << "Cloudinit:"
             << rpi_imager::CustomisationGenerator::redactSecrets(cloudinit, _customisationSecrets);
```

In `applyCustomisationFromSettings`, after `s.insert(QStringLiteral("osReleaseDate"), _osReleaseDate);` (line 4236), add:

```cpp

    // Tailscale is written only for an OS that ships it, and only by the
    // cloud-init generator. The wizard scrubs these on an OS change too;
    // this is the one place every route to the generators passes.
    if (!imageSupportsTailscale()) {
        s.remove(QStringLiteral("tailscaleAuthKey"));
        s.remove(QStringLiteral("tailscaleSsh"));
        s.remove(QStringLiteral("tailscaleLoginServer"));
    }
    _customisationSecrets = {s.value(QStringLiteral("wifiPassword")).toString(),
                             s.value(QStringLiteral("tailscaleAuthKey")).toString(),
                             _piConnectToken};
```

Immediately before `void ImageWriter::setSavedCustomisationSettings` (line 4403), add:

```cpp
// A Tailscale auth key joins a machine to somebody's network. It lives for
// the session and is never written to the settings file, whoever asks.
static bool isSessionOnlyCustomisation(const QString &key)
{
    return key == QLatin1String("tailscaleAuthKey");
}

```

In `setSavedCustomisationSettings`, change the loop body:

```cpp
    for (const QString &key : keys) {
        if (isSessionOnlyCustomisation(key))
            continue;
        _settings.setValue(key, map.value(key));
    }
```

At the top of `setPersistedCustomisationSetting` (line 4460), add:

```cpp
    if (isSessionOnlyCustomisation(key))
        return;
```

After `ImageWriter::imageSupportsInterfaceCustomisation()` (ends line 4497), add:

```cpp

bool ImageWriter::imageSupportsTailscale()
{
    return (_initFormat == "cloudinit" || _initFormat == "cloudinit-rpi")
           && checkSWCapability(QStringLiteral("tailscale"));
}

bool ImageWriter::isValidTailscaleAuthKey(const QString &key) const
{
    return rpi_imager::CustomisationGenerator::isTailscaleAuthKey(key);
}

bool ImageWriter::isValidTailscaleLoginServer(const QString &url) const
{
    return rpi_imager::CustomisationGenerator::isTailscaleLoginServer(url);
}
```

- [ ] **Step 5: Run the tests and confirm they pass.**

```bash
cmake --build build --target image_writer_test && build/test/image_writer_test "[tailscale]"
```

Expected: `All tests passed (… assertions in 5 test cases)`.

- [ ] **Step 6: Confirm telemetry carries no customisation.** This is a check, not code:

```bash
sed -n 18,40p src/downloadstatstelemetry.cpp
grep -n "DownloadStatsTelemetry(" src/imagewriter.cpp
```

Expected: the constructor takes `url, parentcategory, osname, embedded, imagerLang`, and the query string sent holds only those. Nothing from `customizationSettings` reaches it. Say so in the task report.

- [ ] **Step 7: Run the wider suite for regressions.**

```bash
build/test/image_writer_test "[imagewriter]" 2>&1 | tail -3
```

Expected: no new failures compared with the Task 0 baseline.

- [ ] **Step 8: Commit**

```bash
git add src/imagewriter.h src/imagewriter.cpp src/test/image_writer_test.cpp
git commit -m "feat(imagewriter): keep the Tailscale key to the session and the log clean" -m "Write the Tailscale join only for an OS that advertises the tailscale capability and takes cloud-init, whatever the wizard holds. Never persist the key to QSettings, and pass every logged payload through redactSecrets so the key, the Wi-Fi passphrase and the Connect token stay out of --debug output."
```

---

### Task 5: Command-line flags

**Files:**
- Modify: `src/cli.h`. Add the declaration after `readCustomisationFile` (line 64).
- Modify: `src/cli.cpp`:
  - include
  - new function after `Cli::readCustomisationFile` (ends line 145)
  - options (lines 152-168)
  - `initFormat` (lines 227-228)
  - after the cache check (line 258)
  - the cloud-init branch (lines 324-326)
- Modify: `doc/man/rpi-imager.1`. Add the options after `--sha256` (lines 132-139) and an example.
- Test: `src/test/image_writer_test.cpp` (append after Task 4's cases).

**Interfaces:**
- Consumes: `CustomisationGenerator::isTailscaleAuthKey`, `isTailscaleLoginServer` and `generateCloudInitUserData` (Task 2). From Task 4's test namespace: `kKey`.
- Produces: `static QString Cli::buildTailscaleUserData(const QString &authKeyFile, bool ssh, const QString &loginServer, bool otherCustomisation, QByteArray &userData)`. It returns an empty string on success, otherwise a complete `Error: …` message that never contains the key. The CLI flags are `--tailscale-authkey-file <path>`, `--tailscale-ssh` and `--tailscale-login-server <url>`.

- [ ] **Step 1: Write the failing tests.** Append to `src/test/image_writer_test.cpp`:

```cpp

TEST_CASE("The command line joins a tailnet from a key in a file", "[imagewriter][cli][tailscale]")
{
    QTemporaryDir dir;
    REQUIRE(dir.isValid());
    const QString keyFile = dir.filePath(QStringLiteral("key"));
    {
        QFile f(keyFile);
        REQUIRE(f.open(QIODevice::WriteOnly));
        f.write(kKey.toUtf8() + "\n");   // as echo leaves it
    }

    QByteArray userData;
    const QString problem = Cli::buildTailscaleUserData(
        keyFile, true, QStringLiteral("https://hs.example.com"), false, userData);
    INFO("reported: " << problem.toStdString());
    CHECK(problem.isEmpty());
    CHECK(userData.contains("    content: \"" + kKey.toUtf8() + "\"\n"));
    CHECK(userData.contains("--ssh --login-server='https://hs.example.com'"));
}

TEST_CASE("No Tailscale option means no Tailscale user-data", "[imagewriter][cli][tailscale]")
{
    QByteArray userData = "stale";
    CHECK(Cli::buildTailscaleUserData(QString(), false, QString(), true, userData).isEmpty());
    CHECK(userData.isEmpty());
}

TEST_CASE("The command line refuses Tailscale options it cannot honour",
          "[imagewriter][cli][tailscale]")
{
    QTemporaryDir dir;
    REQUIRE(dir.isValid());
    const QString good = dir.filePath(QStringLiteral("good"));
    const QString bad = dir.filePath(QStringLiteral("bad"));
    {
        QFile g(good);
        REQUIRE(g.open(QIODevice::WriteOnly));
        g.write(kKey.toUtf8());
        QFile b(bad);
        REQUIRE(b.open(QIODevice::WriteOnly));
        b.write("tskey-api-kSECRETVALUE-123\n");   // an API key, not an auth key
    }

    struct Case { const char *what; QString file; bool ssh; QString server; bool other; const char *says; };
    const Case cases[] = {
        {"--tailscale-ssh on its own", QString(), true, QString(), false, "--tailscale-authkey-file"},
        {"a control server on its own", QString(), false, QStringLiteral("https://hs.example.com"), false,
         "--tailscale-authkey-file"},
        {"with user-data of its own", good, false, QString(), true, "--cloudinit-userdata"},
        {"a key file that is not there", dir.filePath(QStringLiteral("missing")), false, QString(), false,
         "does not exist"},
        {"a key that is not an auth key", bad, false, QString(), false, "tskey-auth-"},
        {"a control server over http", good, false, QStringLiteral("http://hs.example.com"), false, "https://"},
    };
    for (const Case &c : cases) {
        INFO(c.what);
        QByteArray userData;
        const QString problem = Cli::buildTailscaleUserData(c.file, c.ssh, c.server, c.other, userData);
        INFO("reported: " << problem.toStdString());
        CHECK_THAT(problem.toStdString(), ContainsSubstring(c.says));
        CHECK_THAT(problem.toStdString(), ContainsSubstring("Error:"));
        // The key is never echoed, not even the one that was refused.
        CHECK_THAT(problem.toStdString(), !ContainsSubstring("SECRETVALUE"));
        CHECK(userData.isEmpty());
    }
}
```

- [ ] **Step 2: Run them and confirm they fail.**

```bash
cmake --build build --target image_writer_test
```

Expected: a compile error, `'buildTailscaleUserData' is not a member of 'Cli'`.

- [ ] **Step 3: Declare it.** In `src/cli.h`, after the `readCustomisationFile` declaration (line 64), add:

```cpp

    // The cloud-init user-data that joins a tailnet on first boot, from
    // --tailscale-authkey-file and its two companions. Empty, with an empty
    // `userData`, when none of them was given; otherwise the reason they
    // cannot be used. `otherCustomisation` is whether --cloudinit-userdata
    // or --first-run-script was given: the two cannot be merged, so that is
    // refused rather than one of them quietly lost. The key comes from a
    // file so that it never shows in ps, and it is never echoed back.
    static QString buildTailscaleUserData(const QString &authKeyFile, bool ssh,
                                          const QString &loginServer,
                                          bool otherCustomisation, QByteArray &userData);
```

- [ ] **Step 4: Implement it.** In `src/cli.cpp`, add `#include "customization_generator.h"` after `#include "imageadvancedoptions.h"` (line 16). After `Cli::readCustomisationFile` (ends line 145), add:

```cpp

QString Cli::buildTailscaleUserData(const QString &authKeyFile, bool ssh,
                                    const QString &loginServer,
                                    bool otherCustomisation, QByteArray &userData)
{
    userData.clear();
    if (authKeyFile.isEmpty())
    {
        if (ssh || !loginServer.isEmpty())
            return QStringLiteral("Error: --tailscale-ssh and --tailscale-login-server need --tailscale-authkey-file");
        return QString();
    }
    if (otherCustomisation)
        return QStringLiteral("Error: --tailscale-authkey-file cannot be combined with --cloudinit-userdata "
                              "or --first-run-script; add the Tailscale write_files and runcmd entries "
                              "to your own user-data instead");

    QByteArray contents;
    QString error;
    if (!readCustomisationFile(authKeyFile, QStringLiteral("Tailscale auth key file"), contents, error))
        return error;

    const QString key = QString::fromUtf8(contents).trimmed();
    if (!rpi_imager::CustomisationGenerator::isTailscaleAuthKey(key))
        return QStringLiteral("Error: Tailscale auth key file does not hold a tskey-auth- key: ") + authKeyFile;
    if (!loginServer.isEmpty() && !rpi_imager::CustomisationGenerator::isTailscaleLoginServer(loginServer))
        return QStringLiteral("Error: --tailscale-login-server must be an https:// URL");

    QVariantMap settings;
    settings.insert(QStringLiteral("tailscaleAuthKey"), key);
    settings.insert(QStringLiteral("tailscaleSsh"), ssh);
    if (!loginServer.isEmpty())
        settings.insert(QStringLiteral("tailscaleLoginServer"), loginServer);
    userData = rpi_imager::CustomisationGenerator::generateCloudInitUserData(settings);
    return QString();
}
```

- [ ] **Step 5: Wire the flags into `run()`.** In `parser.addOptions({…})`, after the `cloudinit-networkconfig` line (162), add:

```cpp
        {"tailscale-authkey-file", "Join a tailnet on first boot with the auth key in this file (cloud-init images that ship Tailscale)", "path", ""},
        {"tailscale-ssh", "With --tailscale-authkey-file: enable Tailscale SSH"},
        {"tailscale-login-server", "With --tailscale-authkey-file: use this https:// control server, e.g. Headscale", "url", ""},
```

Replace the `initFormat` computation (lines 227-228):

```cpp
    QByteArray initFormat = (parser.value("cloudinit-userdata").isEmpty()
                             && parser.value("cloudinit-networkconfig").isEmpty()
                             && parser.value("tailscale-authkey-file").isEmpty()) ? "systemd" : "cloudinit";
```

After the `cacheProblem` block (ends line 258), add:

```cpp

    QByteArray tailscaleUserData;
    const QString tailscaleProblem = buildTailscaleUserData(
        parser.value("tailscale-authkey-file"), parser.isSet("tailscale-ssh"),
        parser.value("tailscale-login-server"),
        !parser.value("cloudinit-userdata").isEmpty() || !parser.value("first-run-script").isEmpty(),
        tailscaleUserData);
    if (!tailscaleProblem.isEmpty())
    {
        std::cerr << tailscaleProblem.toStdString() << std::endl;
        return 1;
    }
```

Replace the head of the cloud-init branch (lines 324-326):

```cpp
    if (!parser.value("cloudinit-userdata").isEmpty() || !parser.value("cloudinit-networkconfig").isEmpty())
    {
        QByteArray userData, networkConfig;
```

with:

```cpp
    if (!tailscaleUserData.isEmpty() || !parser.value("cloudinit-userdata").isEmpty()
        || !parser.value("cloudinit-networkconfig").isEmpty())
    {
        // At most one of the two sources: buildTailscaleUserData() refused both.
        QByteArray userData = tailscaleUserData, networkConfig;
```

- [ ] **Step 6: Document the flags.** In `doc/man/rpi-imager.1`, after the `--sha256` entry (whose last line is `.IR \-\-cli .` followed by `.`, at line 139), insert:

```
.TP
.BI \-\-tailscale\-authkey\-file \ path
Join a Tailscale network on first boot with the auth key held in
.IR path .
Reading it from a file keeps it out of the process list. Writes cloud-init
user-data, so the image must take cloud-init and ship Tailscale. The key is
deleted from the device once the join succeeds. Cannot be combined with
.I \-\-cloudinit\-userdata
or
.IR \-\-first\-run\-script .
Only valid when run with
.IR \-\-cli .
.
.TP
.B \-\-tailscale\-ssh
With
.IR \-\-tailscale\-authkey\-file ,
enable Tailscale SSH on the device.
.
.TP
.BI \-\-tailscale\-login\-server \ url
With
.IR \-\-tailscale\-authkey\-file ,
use this https:// control server, for example Headscale, instead of Tailscale's.
.
```

Under `.SH EXAMPLES`, after the `--secure-boot-key` example entry, add:

```
.TP
.B rpi\-imager \-\-cli \-\-tailscale\-authkey\-file ~/tskey \-\-tailscale\-ssh os.img.xz /dev/mmcblk0
Write an image that ships Tailscale, and join it to the tailnet with Tailscale
SSH enabled on its first boot.
.
```

Check the rendering: `man -l doc/man/rpi-imager.1 | grep -A4 tailscale-authkey`. Expected: the option and its text, with no stray `.TP`.

- [ ] **Step 7: Run the tests and confirm they pass.**

```bash
cmake --build build --target image_writer_test && build/test/image_writer_test "[cli]"
cmake --build build && build/rpi-imager --cli --help | grep tailscale
```

Expected: `All tests passed`, then the three options listed in the help output.

- [ ] **Step 8: Commit**

```bash
git add src/cli.h src/cli.cpp doc/man/rpi-imager.1 src/test/image_writer_test.cpp
git commit -m "feat(cli): add --tailscale-authkey-file, --tailscale-ssh and --tailscale-login-server" -m "Scripted imaging can join a tailnet the same way the wizard does. The key is read from a file so it never appears in ps, validated, and never echoed back. The flags generate the user-data, so they are refused alongside --cloudinit-userdata or --first-run-script rather than silently dropping one."
```

---

### Task 6: The wizard step

**Files:**
- Create: `src/wizard/TailscaleCustomizationStep.qml`
- Modify: `src/CMakeLists.txt:627`. Add the file to the QML module list.
- Test: `src/test/qml/tst_tailscale_step.qml` (create)

**Interfaces:**
- Consumes: `ImageWriterSingleton.isValidTailscaleAuthKey(key)`, `isValidTailscaleLoginServer(url)` and `getSavedCustomisationSettings()` (Task 4). From the container: `wizardContainer.tailscaleAvailable` (bool), `wizardContainer.tailscaleEnabled` (bool, written by the step), `wizardContainer.customizationSettings` (object), and `wizardContainer.skipAllCustomisation()`.
- Produces:
  - QML type `TailscaleCustomizationStep`, with `property bool isValid` (set on Next) and signals `nextClicked`/`backClicked`/`skipClicked` (from `WizardStepBase`).
  - It writes `customizationSettings.tailscaleAuthKey` (string), `.tailscaleSsh` (bool) and `.tailscaleLoginServer` (string, or deleted).
  - objectNames: `tailscaleEnableToggle`, `tailscaleAuthKeyField`, `tailscaleKeyError`, `tailscaleSshCheck`, `tailscaleCustomServerCheck`, `tailscaleLoginServerField`, `tailscaleLoginServerError`.

- [ ] **Step 1: Write the failing test.** Create `src/test/qml/tst_tailscale_step.qml`:

```qml
/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (C) 2026 Raspberry Pi Ltd
 *
 * TailscaleCustomizationStep: the auth key that joins the board to a tailnet.
 *
 * The key is written to the card and used once, on a first boot nobody is
 * watching. A key that cannot work produces a board that never appears in
 * the tailnet, so the step will not continue with one. And the key is a
 * credential, so it lives for the session and nowhere else.
 */

import QtQuick
import QtQuick.Controls
import QtTest
import RpiImager

TestCase {
    id: testCase
    name: "TailscaleStep"
    when: windowShown
    width: 900
    height: 700
    visible: true

    QtObject {
        id: fakeContainer
        property Item overlayRootRef: null
        property var customizationSettings: ({})
        property bool tailscaleAvailable: true
        property bool tailscaleEnabled: false
        property bool hostnameConfigured: false
        property bool localeConfigured: false
        property bool userConfigured: false
        property bool wifiConfigured: false
        property bool sshEnabled: false
        property string networkInfoText: ""
        function jumpToStep(n) {}
        function skipAllCustomisation() {}
    }

    Component {
        id: stepComponent
        TailscaleCustomizationStep {
            wizardContainer: fakeContainer
            width: 900
            height: 700
        }
    }

    property var step: null
    readonly property string goodKey: "tskey-auth-kTEST1CNTRL-0123456789abcdef"

    function makeStep() {
        if (step)
            step.destroy()
        step = stepComponent.createObject(testCase)
        verify(step, "the step was created")
    }

    function init() {
        fakeContainer.overlayRootRef = testCase
        fakeContainer.customizationSettings = ({})
        fakeContainer.tailscaleEnabled = false
        makeStep()
    }

    function cleanup() {
        if (step) {
            step.destroy()
            step = null
        }
    }

    function child(name) {
        var c = findChild(step, name)
        verify(c, "found " + name)
        return c
    }

    function useKey(text) {
        child("tailscaleEnableToggle").checked = true
        child("tailscaleAuthKeyField").text = text
    }

    // ── Off ───────────────────────────────────────────────────────────

    function test_nothing_is_asked_while_tailscale_is_off() {
        verify(step.nextButtonEnabled)
        step.nextClicked()
        verify(step.isValid)
        compare(fakeContainer.tailscaleEnabled, false)
        verify(fakeContainer.customizationSettings.tailscaleAuthKey === undefined)
    }

    // ── Which keys get through ────────────────────────────────────────

    function test_a_well_formed_key_lets_the_user_continue() {
        useKey(goodKey)
        verify(step.nextButtonEnabled)
        verify(!child("tailscaleKeyError").visible)
    }

    function test_a_key_that_cannot_join_is_refused_data() {
        return [
            { tag: "empty",           key: "" },
            { tag: "no body",         key: "tskey-auth-" },
            { tag: "an API key",      key: "tskey-api-kTEST1CNTRL-0123" },
            { tag: "an OAuth client", key: "tskey-client-kTEST1CNTRL-0123" },
            { tag: "a space inside",  key: "tskey-auth-kTEST1 CNTRL" },
            { tag: "shell syntax",    key: "tskey-auth-k1;reboot" },
            { tag: "a quote",         key: "tskey-auth-k1\"" }
        ]
    }

    function test_a_key_that_cannot_join_is_refused(data) {
        useKey(data.key)
        verify(!step.nextButtonEnabled, "Next stays off: " + data.tag)
        // Said out loud once there is something to say it about.
        compare(child("tailscaleKeyError").visible, data.key.length > 0)

        step.nextClicked()

        verify(!step.isValid)
        verify(fakeContainer.customizationSettings.tailscaleAuthKey === undefined)
    }

    function test_a_pasted_key_with_spaces_round_it_is_taken_without_them() {
        useKey("  " + goodKey + "  ")
        verify(step.nextButtonEnabled)

        step.nextClicked()

        compare(fakeContainer.customizationSettings.tailscaleAuthKey, goodKey)
    }

    // ── The control server ────────────────────────────────────────────

    function test_the_control_server_has_to_be_https_data() {
        return [
            { tag: "https",           url: "https://hs.example.com",       ok: true },
            { tag: "port and path",   url: "https://hs.example.com:8443/", ok: true },
            { tag: "http",            url: "http://hs.example.com",        ok: false },
            { tag: "no scheme",       url: "hs.example.com",               ok: false },
            { tag: "ticked but empty", url: "",                            ok: false }
        ]
    }

    function test_the_control_server_has_to_be_https(data) {
        useKey(goodKey)
        child("tailscaleCustomServerCheck").checked = true
        child("tailscaleLoginServerField").text = data.url

        compare(step.nextButtonEnabled, data.ok, data.tag)
        compare(child("tailscaleLoginServerError").visible, !data.ok)
    }

    function test_an_unticked_control_server_is_not_used() {
        useKey(goodKey)
        child("tailscaleCustomServerCheck").checked = true
        child("tailscaleLoginServerField").text = "http://was-typed-then-unticked"
        child("tailscaleCustomServerCheck").checked = false
        verify(step.nextButtonEnabled)

        step.nextClicked()

        verify(fakeContainer.customizationSettings.tailscaleLoginServer === undefined)
    }

    // ── Where the answers go ──────────────────────────────────────────

    function test_next_records_the_choices_for_this_session_only() {
        useKey(goodKey)
        child("tailscaleSshCheck").checked = true
        child("tailscaleCustomServerCheck").checked = true
        child("tailscaleLoginServerField").text = "https://hs.example.com"

        step.nextClicked()

        verify(step.isValid)
        compare(fakeContainer.tailscaleEnabled, true)
        var cs = fakeContainer.customizationSettings
        compare(cs.tailscaleAuthKey, goodKey)
        compare(cs.tailscaleSsh, true)
        compare(cs.tailscaleLoginServer, "https://hs.example.com")
        verify(ImageWriterSingleton.getSavedCustomisationSettings().tailscaleAuthKey === undefined,
               "never written to the settings file")
    }

    function test_turning_tailscale_off_forgets_the_key() {
        fakeContainer.customizationSettings = ({ tailscaleAuthKey: goodKey, tailscaleSsh: true,
                                                 tailscaleLoginServer: "https://hs.example.com" })
        fakeContainer.tailscaleEnabled = true
        makeStep()
        child("tailscaleEnableToggle").checked = false

        step.nextClicked()

        verify(step.isValid)
        compare(fakeContainer.tailscaleEnabled, false)
        var cs = fakeContainer.customizationSettings
        verify(cs.tailscaleAuthKey === undefined)
        verify(cs.tailscaleSsh === undefined)
        verify(cs.tailscaleLoginServer === undefined)
    }

    function test_coming_back_shows_what_was_entered() {
        // Back, then Next, in the same session.
        fakeContainer.customizationSettings = ({ tailscaleAuthKey: goodKey, tailscaleSsh: true,
                                                 tailscaleLoginServer: "https://hs.example.com" })
        makeStep()

        verify(child("tailscaleEnableToggle").checked)
        compare(child("tailscaleAuthKeyField").text, goodKey)
        verify(child("tailscaleSshCheck").checked)
        verify(child("tailscaleCustomServerCheck").checked)
        compare(child("tailscaleLoginServerField").text, "https://hs.example.com")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails.**

```bash
cmake --build build --target qml_ui_test
QT_QUICK_BACKEND=software build/test/qml_ui_test -platform offscreen -input src/test/qml/tst_tailscale_step.qml
```

Expected: FAIL, `TailscaleCustomizationStep is not a type`.

- [ ] **Step 3: Write the step.** Create `src/wizard/TailscaleCustomizationStep.qml`:

```qml
/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (C) 2026 Raspberry Pi Ltd
 */

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../qmlcomponents"
import "components"

import RpiImager

WizardStepBase {
    id: root

    title: qsTr("Customisation: Tailscale")
    subtitle: qsTr("Join your Tailscale network on first boot")
    showSkipButton: true
    // One switch and what follows from it, as on the Raspberry Pi Connect step.
    fieldsFollowNextButton: true
    nextButtonAccessibleDescription: qsTr("Save Tailscale settings and continue to next customisation step")
    backButtonAccessibleDescription: qsTr("Return to previous step")
    skipButtonAccessibleDescription: qsTr("Skip all customisation and proceed directly to writing the image")

    // Only visible/active when the selected OS ships Tailscale
    visible: wizardContainer.tailscaleAvailable
    enabled: wizardContainer.tailscaleAvailable

    // Set on Next; the container advances only when it is true.
    property bool isValid: false

    // The rules live in CustomisationGenerator, shared with the command line.
    readonly property bool keyValid: ImageWriterSingleton.isValidTailscaleAuthKey(fieldAuthKey.value)
    readonly property bool loginServerValid: !chkCustomServer.checked
        || ImageWriterSingleton.isValidTailscaleLoginServer(fieldLoginServer.value)

    nextButtonEnabled: !enablePill.checked || (root.keyValid && root.loginServerValid)

    Component.onCompleted: {
        root.registerFocusGroup("tailscale", function() {
            var items = [enablePill.focusItem]
            if (enablePill.helpLinkItem && enablePill.helpLinkItem.visible)
                items.push(enablePill.helpLinkItem)
            // Hidden items are dropped by rebuildFocusOrder(); the label only
            // takes focus while a screen reader is active.
            items.push(labelAuthKey)
            items.push(fieldAuthKey.textField)
            items.push(chkSsh)
            items.push(chkCustomServer)
            items.push(fieldLoginServer)
            if (ImageWriterSingleton && ImageWriterSingleton.screenReaderActive)
                items.push(helpText)
            return items
        }, 0)

        // Back on this step in the same session: show what was entered.
        // Nothing comes from the settings file -- the key is never in it.
        var saved = wizardContainer.customizationSettings
        if (saved.tailscaleAuthKey) {
            enablePill.checked = true
            fieldAuthKey.text = saved.tailscaleAuthKey
            chkSsh.checked = saved.tailscaleSsh === true
            if (saved.tailscaleLoginServer) {
                chkCustomServer.checked = true
                fieldLoginServer.text = saved.tailscaleLoginServer
            }
        }
    }

    content: [
    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.sectionPadding
        spacing: Style.stepContentSpacing

        WizardSectionContainer {
            ImOptionPill {
                id: enablePill
                objectName: "tailscaleEnableToggle"
                Layout.fillWidth: true
                text: qsTr("Enable Tailscale")
                accessibleDescription: qsTr("Join this device to your Tailscale network the first time it boots")
                helpLabel: ImageWriterSingleton.isEmbeddedMode() ? "" : qsTr("Generate an auth key")
                helpUrl: ImageWriterSingleton.isEmbeddedMode() ? "" : "https://login.tailscale.com/admin/settings/keys"
                checked: false
                onToggled: root.rebuildFocusOrder()
            }

            WizardFormLabel {
                id: labelAuthKey
                text: qsTr("Auth key:")
                visible: enablePill.checked
                accessibleDescription: qsTr("Paste an auth key from the Keys page of the Tailscale admin console. It starts with tskey-auth-.")
            }

            ImPasswordField {
                id: fieldAuthKey
                objectName: "tailscaleAuthKeyField"
                Layout.fillWidth: true
                visible: enablePill.checked
                font.pointSize: Style.fontSizeInput
                placeholderText: qsTr("tskey-auth-…")
                accessibleDescription: qsTr("Tailscale auth key. It is written to the card and used once, on first boot.")
                // A key holds no spaces, and one pasted from a browser often
                // brings some with it.
                trimWhitespace: true
            }

            WizardDescriptionText {
                id: keyError
                objectName: "tailscaleKeyError"
                visible: enablePill.checked && fieldAuthKey.value.length > 0 && !root.keyValid
                color: Style.formLabelErrorColor
                text: qsTr("This is not a Tailscale auth key. Auth keys start with tskey-auth-.")
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
                Accessible.ignored: !visible
            }

            ImCheckBox {
                id: chkSsh
                objectName: "tailscaleSshCheck"
                visible: enablePill.checked
                text: qsTr("Enable Tailscale SSH")
                Accessible.description: qsTr("Let devices your Tailscale access rules allow sign in to this one over SSH, authenticated by Tailscale.")
            }

            ImCheckBox {
                id: chkCustomServer
                objectName: "tailscaleCustomServerCheck"
                visible: enablePill.checked
                text: qsTr("Use a different control server")
                Accessible.description: qsTr("For a self-hosted control server such as Headscale. Leave unticked to use Tailscale's own.")
                onCheckedChanged: root.rebuildFocusOrder()
            }

            ImTextField {
                id: fieldLoginServer
                objectName: "tailscaleLoginServerField"
                Layout.fillWidth: true
                visible: enablePill.checked && chkCustomServer.checked
                font.pointSize: Style.fontSizeInput
                placeholderText: qsTr("https://headscale.example.com")
                Accessible.description: qsTr("Address of the control server. It must start with https://.")
                trimWhitespace: true
            }

            WizardDescriptionText {
                id: loginServerError
                objectName: "tailscaleLoginServerError"
                visible: enablePill.checked && chkCustomServer.checked && !root.loginServerValid
                color: Style.formLabelErrorColor
                text: qsTr("The control server must be an https:// address.")
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
                Accessible.ignored: !visible
            }

            WizardDescriptionText {
                id: helpText
                visible: enablePill.checked
                text: qsTr("Use a one-time, pre-approved auth key that expires soon, and tag it so this device stays signed in. "
                           + "The key is stored unencrypted on the card until first boot. If joining fails, it stays on the "
                           + "device, readable only by root, so the system can try again. A one-time key works for one card; "
                           + "to write several, use a reusable key.")
            }
        }
    }
    ]

    onNextClicked: {
        root.isValid = false
        var cs = wizardContainer.customizationSettings
        if (enablePill.checked) {
            if (!root.keyValid || !root.loginServerValid)
                return
            // Runtime state only. Never passed to setPersistedCustomisationSetting(),
            // and ImageWriter refuses to persist the key if anything tries.
            cs.tailscaleAuthKey = fieldAuthKey.value
            cs.tailscaleSsh = chkSsh.checked
            if (chkCustomServer.checked)
                cs.tailscaleLoginServer = fieldLoginServer.value
            else
                delete cs.tailscaleLoginServer
            wizardContainer.tailscaleEnabled = true
        } else {
            delete cs.tailscaleAuthKey
            delete cs.tailscaleSsh
            delete cs.tailscaleLoginServer
            wizardContainer.tailscaleEnabled = false
        }
        root.isValid = true
    }

    // Skipping means skipping all of it, wherever the button is pressed.
    onSkipClicked: wizardContainer.skipAllCustomisation()
}
```

- [ ] **Step 4: Register the file.** In `src/CMakeLists.txt`, after `        wizard/PiConnectCustomizationStep.qml` (line 627), add:

```cmake
        wizard/TailscaleCustomizationStep.qml
```

- [ ] **Step 5: Run the tests and confirm they pass.**

```bash
cmake --build build --target qml_ui_test qml_load_test
QT_QUICK_BACKEND=software RPI_IMAGER_TELEMETRY_URL= RPI_IMAGER_CONNECT_URL=http://127.0.0.1:1 \
    build/test/qml_ui_test -platform offscreen -input src/test/qml/tst_tailscale_step.qml
build/test/qml_load_test
```

Expected: `Totals: N passed, 0 failed` for the step, and `All tests passed` for the load test.

- [ ] **Step 6: Commit**

```bash
git add src/wizard/TailscaleCustomizationStep.qml src/CMakeLists.txt src/test/qml/tst_tailscale_step.qml
git commit -m "feat(wizard): add a Tailscale customisation step" -m "A switch, a masked auth key field that refuses anything but a tskey-auth- key, Tailscale SSH, and an optional https-only control server for Headscale. The key lives in the session's customisation settings only. Not yet reachable: the container wires it in next."
```

---

### Task 7: Wire the step into the wizard

**Files:**
- Modify: `src/wizard/WizardContainer.qml` (the edits A-N below)
- Modify: `src/wizard/OSSelectionStep.qml:193-195, 860, 894, 917`
- Modify: `src/test/qml/tst_os_selection_step.qml:35`, `src/test/qml/tst_os_change_scrub.qml:40` and `src/test/qml/tst_os_delegate.qml:39`. These are fake containers that need the new properties.
- Test: `src/test/qml/tst_wizard_navigation.qml` (the `init()` function at lines 47-68, and new cases after `test_interfaces_are_skipped_when_the_board_offers_none`, line 373)

**Interfaces:**
- Consumes: the `TailscaleCustomizationStep` type with `isValid` (Task 6), and `ImageWriterSingleton.imageSupportsTailscale()` (Task 4).
- Produces, on `WizardContainer`:
  - `property bool tailscaleEnabled`
  - `property bool tailscaleAvailable`
  - `readonly property int stepTailscaleCustomization: 10`
  - `stepIfAndFeatures` → 11, `stepWriting` → 12, `stepDone` → 13, `totalSteps` → 14
  - the sidebar label `qsTr("Tailscale")`

- [ ] **Step 1: Write the failing tests.** In `src/test/qml/tst_wizard_navigation.qml`, add these two lines to `init()`, after `wiz.piConnectEnabled = false`:

```js
        wiz.tailscaleAvailable = false
        wiz.tailscaleEnabled = false
```

Then, after the function `test_interfaces_are_skipped_when_the_board_offers_none(data)` (ends line 373), add:

```js

    // -- Tailscale ---------------------------------------------------------
    //
    // Shown only for an OS that ships it, after Raspberry Pi Connect.

    function test_tailscale_follows_pi_connect_when_the_os_ships_it() {
        startAt(wiz.stepPiConnectCustomization)
        wiz.tailscaleAvailable = true

        wiz.nextStep()
        compare(wiz.currentStep, wiz.stepTailscaleCustomization)

        wiz.nextStep()
        compare(wiz.currentStep, wiz.stepIfAndFeatures)
    }

    function test_tailscale_is_skipped_when_the_os_cannot_use_it() {
        startAt(wiz.stepPiConnectCustomization)
        wiz.tailscaleAvailable = false

        wiz.nextStep()

        compare(wiz.currentStep, wiz.stepIfAndFeatures)
    }

    function test_going_back_skips_tailscale_the_same_way() {
        startAt(wiz.stepIfAndFeatures)
        wiz.tailscaleAvailable = false
        wiz.previousStep()
        compare(wiz.currentStep, wiz.stepPiConnectCustomization)

        startAt(wiz.stepIfAndFeatures)
        wiz.tailscaleAvailable = true
        wiz.previousStep()
        compare(wiz.currentStep, wiz.stepTailscaleCustomization)
    }

    function test_the_sidebar_lists_tailscale_only_for_an_os_that_ships_it() {
        verify(wiz.getCustomizationSubstepLabels().indexOf("Tailscale") === -1)

        wiz.tailscaleAvailable = true
        var i = wiz.getCustomizationSubstepLabels().indexOf("Tailscale")
        verify(i >= 0, "listed")
        verify(!wiz.isCustomizationSubstepConfigured(i))
        wiz.tailscaleEnabled = true
        verify(wiz.isCustomizationSubstepConfigured(i), "and bold once configured")
        compare(wiz.getLastCustomizationStep(), wiz.stepTailscaleCustomization)
    }

    function test_skipping_customisation_forgets_tailscale() {
        startAt(wiz.stepTailscaleCustomization)
        wiz.tailscaleAvailable = true
        wiz.tailscaleEnabled = true

        wiz.skipAllCustomisation()

        verify(!wiz.tailscaleEnabled)
        compare(wiz.currentStep, wiz.stepWriting)
    }
```

- [ ] **Step 2: Run them and confirm they fail.**

```bash
QT_QUICK_BACKEND=software build/test/qml_ui_test -platform offscreen -input src/test/qml/tst_wizard_navigation.qml
```

Expected: FAIL, with errors such as `Cannot assign to non-existent property "tailscaleAvailable"`.

- [ ] **Step 3: Edit `WizardContainer.qml`.** Each edit gives the unique text to find and its replacement.

**A** (lines 69-71): add the properties.

```qml
    property bool piConnectEnabled: false
    // Whether selected OS supports Raspberry Raspberry Pi Connect customization
    property bool piConnectAvailable: false
```
→
```qml
    property bool piConnectEnabled: false
    // Whether selected OS supports Raspberry Raspberry Pi Connect customization
    property bool piConnectAvailable: false
    property bool tailscaleEnabled: false
    // Whether the selected OS ships Tailscale and takes cloud-init
    property bool tailscaleAvailable: false
```

**B** (lines 33 and 140-143): the step indices.

```qml
    readonly property int totalSteps: 13
```
→
```qml
    readonly property int totalSteps: 14
```

and

```qml
    readonly property int stepPiConnectCustomization: 9
    readonly property int stepIfAndFeatures: 10
    readonly property int stepWriting: 11
    readonly property int stepDone: 12
```
→
```qml
    readonly property int stepPiConnectCustomization: 9
    readonly property int stepTailscaleCustomization: 10
    readonly property int stepIfAndFeatures: 11
    readonly property int stepWriting: 12
    readonly property int stepDone: 13
```

**C** (lines 299-305): `getLastCustomizationStep`.

```qml
        return (ccRpiAvailable && ifAndFeaturesAvailable)
            ? stepIfAndFeatures
            : piConnectAvailable
```
→
```qml
        return (ccRpiAvailable && ifAndFeaturesAvailable)
            ? stepIfAndFeatures
            : tailscaleAvailable
            ? stepTailscaleCustomization
            : piConnectAvailable
```

**D** (lines 318-320): the sidebar labels.

```qml
        if (piConnectAvailable) {
            labels.push(qsTr("Raspberry Pi Connect"))
        }
```
→
```qml
        if (piConnectAvailable) {
            labels.push(qsTr("Raspberry Pi Connect"))
        }
        if (tailscaleAvailable) {
            labels.push(qsTr("Tailscale"))
        }
```

**E** (line 340): configured state.

```qml
        if (stepLabel === qsTr("Raspberry Pi Connect")) return piConnectEnabled
```
→
```qml
        if (stepLabel === qsTr("Raspberry Pi Connect")) return piConnectEnabled
        if (stepLabel === qsTr("Tailscale")) return tailscaleEnabled
```

**F** (line 624): the current-step label.

```qml
                                        else if (root.currentStep === root.stepPiConnectCustomization) currentStepLabel = qsTr("Raspberry Pi Connect")
```
→
```qml
                                        else if (root.currentStep === root.stepPiConnectCustomization) currentStepLabel = qsTr("Raspberry Pi Connect")
                                        else if (root.currentStep === root.stepTailscaleCustomization) currentStepLabel = qsTr("Tailscale")
```

**G** (lines 635 and 642): clickability.

```qml
                                        root.wifiConfigured || root.sshEnabled || root.piConnectEnabled ||
```
→
```qml
                                        root.wifiConfigured || root.sshEnabled || root.piConnectEnabled || root.tailscaleEnabled ||
```

and

```qml
                                        root.isStepPermissible(root.stepPiConnectCustomization) ||
```
→
```qml
                                        root.isStepPermissible(root.stepPiConnectCustomization) ||
                                        root.isStepPermissible(root.stepTailscaleCustomization) ||
```

**H** (line 664): the sidebar click target.

```qml
                                            else if (stepLabel === qsTr("Raspberry Pi Connect")) target = root.stepPiConnectCustomization
```
→
```qml
                                            else if (stepLabel === qsTr("Raspberry Pi Connect")) target = root.stepPiConnectCustomization
                                            else if (stepLabel === qsTr("Tailscale")) target = root.stepTailscaleCustomization
```

**I** (`invalidateDeviceDependentSteps`, lines 379-381):

```qml
        piConnectEnabled = false
        piConnectAvailable = false
        secureBootAvailable = false
        ccRpiAvailable = false
```
→
```qml
        piConnectEnabled = false
        piConnectAvailable = false
        tailscaleEnabled = false
        tailscaleAvailable = false
        secureBootAvailable = false
        ccRpiAvailable = false
```

**J** (`invalidateOSDependentSteps`, lines 408-410):

```qml
        piConnectAvailable = false
        secureBootAvailable = false
        passwordlessSudoAvailable = false
```
→
```qml
        piConnectAvailable = false
        tailscaleEnabled = false
        tailscaleAvailable = false
        secureBootAvailable = false
        passwordlessSudoAvailable = false
```

**K** (`nextStep`, lines 880-883): skip when unavailable. The order matters: Pi Connect, then Tailscale, then Interfaces.

```qml
            if (!piConnectAvailable && nextIndex === stepPiConnectCustomization) {
                nextIndex++
            }
```
→
```qml
            if (!piConnectAvailable && nextIndex === stepPiConnectCustomization) {
                nextIndex++
            }
            // Skip Tailscale when the OS does not ship it
            if (!tailscaleAvailable && nextIndex === stepTailscaleCustomization) {
                nextIndex++
            }
```

**L** (`previousStep`, lines 940-944): the same skip, going back.

```qml
                if (prevIndex == stepIfAndFeatures && (!ccRpiAvailable || !ifAndFeaturesAvailable)) {
                    prevIndex--
                }
```
→
```qml
                if (prevIndex == stepIfAndFeatures && (!ccRpiAvailable || !ifAndFeaturesAvailable)) {
                    prevIndex--
                }
                if (prevIndex === stepTailscaleCustomization && !tailscaleAvailable) {
                    prevIndex--
                }
```

**M** (`getStepComponent`, line 994, plus a new `Component` after `piConnectCustomizationStep`, which ends at line 1147):

```qml
            case stepPiConnectCustomization: return piConnectCustomizationStep
```
→
```qml
            case stepPiConnectCustomization: return piConnectCustomizationStep
            case stepTailscaleCustomization: return tailscaleCustomizationStep
```

Insert before `    Component {\n        id: ifAndFeaturesStep`:

```qml
    Component {
        id: tailscaleCustomizationStep
        TailscaleCustomizationStep {
            wizardContainer: root
            appOptionsButton: optionsButton
            onNextClicked: {
                // Only advance once the step has accepted what was entered
                if (isValid) {
                    root.nextStep()
                }
            }
            onBackClicked: root.previousStep()
            onSkipClicked: {
                // Skip functionality is handled in the step itself
            }
        }
    }

```

**N** (`resetWizard`, lines 1558-1560, and `skipAllCustomisation`, line 1623):

```qml
        piConnectEnabled = false
        piConnectAvailable = false
        targetIsFastboot = false
```
→
```qml
        piConnectEnabled = false
        piConnectAvailable = false
        tailscaleEnabled = false
        tailscaleAvailable = false
        targetIsFastboot = false
```

and, inside `skipAllCustomisation()`:

```qml
        secureBootEnabled = false
        piConnectEnabled = false
        ifI2cEnabled = false
```
→
```qml
        secureBootEnabled = false
        piConnectEnabled = false
        tailscaleEnabled = false
        ifI2cEnabled = false
```

`resetToWriteStep()` is deliberately left alone. "Write another" keeps the key, because a reusable key flashing a batch is a legitimate use, and the step's help text says a one-time key covers one card.

- [ ] **Step 4: Edit `OSSelectionStep.qml`.** Custom image without customisation (lines 193-194):

```qml
                root.wizardContainer.piConnectEnabled = false
                root.wizardContainer.piConnectAvailable = false
```
→
```qml
                root.wizardContainer.piConnectEnabled = false
                root.wizardContainer.piConnectAvailable = false
                root.wizardContainer.tailscaleEnabled = false
                root.wizardContainer.tailscaleAvailable = false
```

Erase/format (line 860), the first `= false` after `setSWCapabilitiesList("[]")`:

```qml
                root.wizardContainer.piConnectAvailable = false
                root.wizardContainer.secureBootAvailable = ImageWriterSingleton.isSecureBootForcedByCliFlag() || ImageWriterSingleton.getDebugForceSecureBoot()
                root.wizardContainer.passwordlessSudoAvailable = false
```
→
```qml
                root.wizardContainer.piConnectAvailable = false
                root.wizardContainer.tailscaleAvailable = false
                root.wizardContainer.secureBootAvailable = ImageWriterSingleton.isSecureBootForcedByCliFlag() || ImageWriterSingleton.getDebugForceSecureBoot()
                root.wizardContainer.passwordlessSudoAvailable = false
```

Normal OS (line 894):

```qml
                root.wizardContainer.piConnectAvailable = ImageWriterSingleton.checkSWCapability("rpi_connect")
```
→
```qml
                root.wizardContainer.piConnectAvailable = ImageWriterSingleton.checkSWCapability("rpi_connect")
                root.wizardContainer.tailscaleAvailable = ImageWriterSingleton.imageSupportsTailscale()
```

Scrub (after the Pi Connect block at lines 914-917):

```qml
                if (!root.wizardContainer.piConnectAvailable) {
                    delete root.wizardContainer.customizationSettings.piConnectEnabled
                    root.wizardContainer.piConnectEnabled = false
                }
```
→
```qml
                if (!root.wizardContainer.piConnectAvailable) {
                    delete root.wizardContainer.customizationSettings.piConnectEnabled
                    root.wizardContainer.piConnectEnabled = false
                }
                // A key entered for an OS that ships Tailscale does not
                // follow the user to one that does not.
                if (!root.wizardContainer.tailscaleAvailable) {
                    delete root.wizardContainer.customizationSettings.tailscaleAuthKey
                    delete root.wizardContainer.customizationSettings.tailscaleSsh
                    delete root.wizardContainer.customizationSettings.tailscaleLoginServer
                    root.wizardContainer.tailscaleEnabled = false
                }
```

- [ ] **Step 5: Teach the three fake containers the new properties.** In each of `src/test/qml/tst_os_selection_step.qml`, `tst_os_change_scrub.qml` and `tst_os_delegate.qml`, after the line `        property bool piConnectEnabled: false` inside the `fakeContainer` QtObject, add:

```qml
        property bool tailscaleAvailable: false
        property bool tailscaleEnabled: false
```

(`OSSelectionStep` writes both, and a stub missing a property throws part-way through `selectOSitem()`, as the comment at `tst_os_selection_step.qml:21-24` warns.)

- [ ] **Step 6: Run the tests and confirm they pass, with no regressions.**

```bash
cmake --build build --target qml_ui_test
export QT_QUICK_BACKEND=software RPI_IMAGER_TELEMETRY_URL= RPI_IMAGER_CONNECT_URL=http://127.0.0.1:1
for f in tst_wizard_navigation tst_tailscale_step tst_os_selection_step tst_os_change_scrub tst_os_delegate \
         tst_step_reachability tst_skip_customisation tst_pi_connect tst_sidebar_width; do
  build/test/qml_ui_test -platform offscreen -input src/test/qml/$f.qml 2>&1 | tail -1
done
ctest --test-dir build -R qml_ui_test --output-on-failure      # the whole QML suite, including the storms
```

Expected: each `Totals:` line shows `0 failed`, and ctest reports `100% tests passed`.

- [ ] **Step 7: Look at it.** Build, then run the GUI against a list that advertises the capability. The synthetic list from Task 10, Steps 1-3, works, or use any local `os-list.json` with `"init_format": "cloudinit"` and `"capabilities": ["tailscale"]`:

```bash
build/rpi-imager --repo /path/to/os-list.json
```

Check that "Tailscale" appears in the sidebar after Raspberry Pi Connect, that the key field is masked, and that Next stays disabled until the key is valid. Check that Tab reaches the switch, the help link, the field, both checkboxes and the URL field. Check that the step is absent after choosing an OS without the capability.

- [ ] **Step 8: Commit**

```bash
git add src/wizard/WizardContainer.qml src/wizard/OSSelectionStep.qml src/test/qml/tst_wizard_navigation.qml \
        src/test/qml/tst_os_selection_step.qml src/test/qml/tst_os_change_scrub.qml src/test/qml/tst_os_delegate.qml
git commit -m "feat(wizard): offer the Tailscale step for an OS that ships it" -m "Placed after Raspberry Pi Connect and skipped, both ways, unless the OS advertises the tailscale capability and takes cloud-init. Choosing an OS without it drops any key already entered; skipping customisation forgets it; write another keeps it, for reusable keys."
```

---

### Task 8: Fuzz the new fields

**Files:**
- Modify: `src/test/fuzz/fuzz_customisation_gen.cpp:38-56`

**Interfaces:**
- Consumes: the `tailscaleAuthKey`/`tailscaleSsh`/`tailscaleLoginServer` settings keys (Task 2) and `redactSecrets` (Task 3).
- Produces: nothing new for other tasks.

- [ ] **Step 1: Add the fields, the redaction call and a sound invariant.** In `LLVMFuzzerTestOneInput`, after `s["wifiSSIDHidden"] = false;` (line 50), add:

```cpp
    s["tailscaleAuthKey"] = value;
    s["tailscaleLoginServer"] = value;
    s["tailscaleSsh"] = true;
```

After the three generator calls (lines 52-54), add:

```cpp

    // Tailscale is joined exactly when there is a key: a value that is
    // nothing but whitespace is no key, and any other value is one (the
    // generator escapes it rather than judging it). Anything else means a
    // field leaked into, or out of, the join.
    {
        const QByteArray yaml =
            rpi_imager::CustomisationGenerator::generateCloudInitUserData(s, value);
        if (yaml.contains("tailscale up") != !value.trimmed().isEmpty())
            __builtin_trap();
        // The log redaction runs over every payload before it is printed.
        (void)rpi_imager::CustomisationGenerator::redactSecrets(yaml, {value});
    }
```

The existing newline invariant (lines 96-127) now covers the key and the login server too: each takes the same hostile value.

- [ ] **Step 2: Build the fuzzer.** This needs clang and libFuzzer (`compiler-rt`), which are installed in the distrobox:

```bash
cmake -S src -B build-fuzz -G Ninja -DCMAKE_BUILD_TYPE=Release -DRPI_IMAGER_FUZZERS=ON \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DXZ_SANDBOX=no
cmake --build build-fuzz --target fuzz_customisation_gen
```

Add `-DQt6_DIR=…/lib/cmake/Qt6` if CMake does not find Qt by itself (`src/test/fuzz/README.md`).

Expected: `build-fuzz/test/fuzz/fuzz_customisation_gen` exists.

- [ ] **Step 3: Run it for five minutes.**

```bash
mkdir -p /tmp/fuzz-cg && build-fuzz/test/fuzz/fuzz_customisation_gen -max_total_time=300 /tmp/fuzz-cg
```

Expected: it ends with `Done N runs in 300 second(s)`, with no `deadly signal` and no crash file. If it traps, minimise the crash file and fix the generator, not the invariant, unless the invariant is provably wrong, and say which in the report.

- [ ] **Step 4: Commit**

```bash
git add src/test/fuzz/fuzz_customisation_gen.cpp
git commit -m "test(fuzz): put a hostile value in the Tailscale fields" -m "The key and the control server go through the same newline invariant as every other field, the join must appear exactly when there is a key, and the log redaction runs over every generated payload."
```

---

### Task 9: Fork CI that builds the AppImage

**Files:**
- Create: `.github/workflows/tailscale-fork.yml`. This file exists **only on the fork's `juniper` branch**, never on `feat/tailscale-customisation`.

**Interfaces:**
- Consumes: Tasks 1-8 on `feat/tailscale-customisation`.
- Produces: branch `juniper` (= `feat/tailscale-customisation` + this one commit). An `appimage` workflow artifact on every push, and a GitHub release with the AppImage attached for each `v*-tailscale.*` tag. Task 10 downloads from here.

- [ ] **Step 1: Create the branch.**

```bash
git switch -c juniper feat/tailscale-customisation
```

- [ ] **Step 2: Write the workflow.** Create `.github/workflows/tailscale-fork.yml`:

```yaml
# Fork-only: builds and tests rpi-imager with Tailscale customisation, and
# publishes an AppImage until the feature lands upstream. Lives on the
# `juniper` branch only; never part of the upstream PR.
name: Tailscale fork build

on:
  push:
    branches: [juniper]
    tags: ['v*-tailscale.*']
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # version strings come from git describe --tags

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends ninja-build libgnutls28-dev liburing-dev \
            libudev-dev libgl1-mesa-dev libxkbcommon-dev libfontconfig1-dev python3-yaml \
            mtools dosfstools file

      - uses: jurplel/install-qt-action@v4
        with:
          version: '6.11.2'   # QT_VERSION_DEFAULT in qt/qt-build-common.sh
          cache: true

      - name: Fetch vendored dependencies
        run: sh debian/fetch-vendor-deps.sh

      - name: Build with tests
        run: |
          cmake -B build -G Ninja src -DBUILD_TESTING=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
          cmake --build build --target generate_version
          cmake --build build --target customization_generator_test image_writer_test qml_ui_test

      - name: Test
        env:
          QT_QUICK_BACKEND: software
          RPI_IMAGER_TELEMETRY_URL: ''
          RPI_IMAGER_CONNECT_URL: 'http://127.0.0.1:1'
        run: |
          build/test/customization_generator_test
          build/test/image_writer_test "[tailscale]"
          for f in tst_tailscale_step tst_wizard_navigation tst_os_selection_step tst_os_change_scrub; do
            build/test/qml_ui_test -platform offscreen -input "src/test/qml/$f.qml"
          done

      - name: Build AppImage
        env:
          APPIMAGE_EXTRACT_AND_RUN: '1'   # runners have no FUSE for linuxdeploy's own AppImages
        run: ./create-appimage.sh --qt-root="$QT_ROOT_DIR"

      - uses: actions/upload-artifact@v4
        with:
          name: appimage
          path: '*.AppImage'

      - name: Attach to release
        if: startsWith(github.ref, 'refs/tags/')
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" ./*.AppImage --repo "$GITHUB_REPOSITORY" \
            --title "$GITHUB_REF_NAME" \
            --notes "Unofficial build of rpi-imager with Tailscale customisation (branch juniper of $GITHUB_REPOSITORY). Upstream: raspberrypi/rpi-imager."
```

Known ceiling: an AppImage built on ubuntu-24.04 needs glibc ≥ 2.39, which covers Fedora 40+ and Ubuntu 24.04+. That is enough for the desktops that run Imager for Juniper. Upstream builds portable AppImages in a bookworm chroot with `debian/release.sh appimages amd64` (`doc/linux-build.md`). Switch to that if older hosts matter. On GitHub-hosted runners it needs `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` and a cache of `.debian/`.

- [ ] **Step 3: Validate locally and push.**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/tailscale-fork.yml'))" && echo ok
git add .github/workflows/tailscale-fork.yml
git commit -m "ci: build and test the Tailscale fork, publish its AppImage"
git push -u origin feat/tailscale-customisation juniper
gh run watch --repo gnathoi/rpi-imager --exit-status "$(gh run list --repo gnathoi/rpi-imager --branch juniper --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: `ok`, then the run succeeds with an `appimage` artifact. If `install-qt-action` can't find 6.11.2, use the newest 6.11.x it lists (`aqt list-qt linux desktop`). If `create-appimage.sh` fails against the aqt Qt, fall back to the `debian/release.sh` route above and record which was used.

- [ ] **Step 4: Tag the first release.**

```bash
git tag v2.0.12-tailscale.1 juniper && git push origin v2.0.12-tailscale.1
gh release view v2.0.12-tailscale.1 --repo gnathoi/rpi-imager
```

Expected: a release with `Raspberry_Pi_Imager-v2.0.12-tailscale.1-desktop-x86_64.AppImage` attached.

To keep `juniper` current afterwards: `git switch juniper && git rebase feat/tailscale-customisation && git push --force-with-lease`.

---

### Task 10: End-to-end check with Juniper's OS list

**Files:** none in the fork. This is a verification task, so record the results in the task report.

**Interfaces:**
- Consumes: a built `build/rpi-imager` (or the AppImage from Task 9), and a Juniper checkout at `$JUNIPER` (for `disk/render-os-list.sh`).
- Produces: evidence that a card written from Juniper's OS list carries the expected `user-data` in CIDATA, and that the log stays clean.

- [ ] **Step 1: Build a synthetic Juniper-shaped image.** Its partition 1 is FAT32 with the label CIDATA, as in `disk/bib-config.toml`.

```bash
export JUNIPER=~/workspace/juniper            # your Juniper checkout
E2E=$(mktemp -d) && cd "$E2E"
truncate -s 64M fake.img
printf 'label: dos\nstart=2048, type=c\n' | sfdisk fake.img
L=$(sudo losetup -fP --show fake.img)
sudo mkfs.vfat -F 32 -n CIDATA "${L}p1"
sudo mount "${L}p1" /mnt && printf 'console=serial0,115200 console=tty1\n' | sudo tee /mnt/cmdline.txt >/dev/null
sudo umount /mnt && sudo losetup -d "$L"
xz -k -T0 fake.img
```

- [ ] **Step 2: Render the OS list with Juniper's own script, and serve it.**

```bash
"$JUNIPER/disk/render-os-list.sh" juniper fake.img fake.img.xz http://127.0.0.1:8000/fake.img.xz e2e > os-list.json
jq '.os_list[0] | {init_format, capabilities, devices}' os-list.json
python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1 &
```

Expected: `"init_format": "cloudinit"`, capabilities `["tailscale","passwordless_sudo"]` and devices `["pi5-64bit","pi4-64bit"]`.

- [ ] **Step 3: Write a loop-backed "card" with the CLI, and read CIDATA back.**

```bash
printf '%s\n' tskey-auth-kE2E1CNTRL-0123456789abcdef > key && chmod 600 key
truncate -s 128M card.img
CARD=$(sudo losetup -fP --show card.img)
sudo ~/workspace/rpi-imager-fork/build/rpi-imager --cli --debug --enable-writing-system-drives --disable-eject \
    --tailscale-authkey-file key --tailscale-ssh --tailscale-login-server https://hs.example.com \
    fake.img.xz "$CARD" 2>&1 | tee cli.log
sudo losetup -d "$CARD" && CARD=$(sudo losetup -fP --show card.img)
sudo mount -o ro "${CARD}p1" /mnt && sudo cat /mnt/user-data | tee user-data && grep ds=nocloud /mnt/cmdline.txt
sudo umount /mnt && sudo losetup -d "$CARD"
python3 -c "import yaml; d=yaml.safe_load(open('user-data')); print(d['write_files'][0]['content']); print(d['runcmd'][-1][2])"
grep -c 'tskey-auth-kE2E' cli.log; grep -c '<redacted>' cli.log
```

Expected `user-data`:

```yaml
#cloud-config
manage_resolv_conf: false

write_files:
  - path: /etc/tailscale/authkey
    permissions: "0600"
    owner: root:root
    content: "tskey-auth-kE2E1CNTRL-0123456789abcdef"
runcmd:
  - [ systemctl, enable, --now, tailscaled ]
  - [ sh, -c, "tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s --ssh --login-server='https://hs.example.com' && shred -u /etc/tailscale/authkey" ]
```

The other expected results:

- `cmdline.txt` contains `ds=nocloud;i=rpi-imager-…`.
- Python prints the key, then the `tailscale up … && shred -u /etc/tailscale/authkey` command.
- `grep -c 'tskey-auth-kE2E' cli.log` prints `0`, and the `<redacted>` count is at least `1`.

Compare the `write_files` block with the commented one in `$JUNIPER/system_files/usr/share/juniper/cidata/user-data`: it must have the same path, the same permissions and the same key shape.

- [ ] **Step 4: The same through the GUI, on a real removable card.**

```bash
~/workspace/rpi-imager-fork/build/rpi-imager --repo http://127.0.0.1:8000/os-list.json
```

1. Choose Raspberry Pi 5 if the device step offers it. A custom list has no `imager.devices` section, so if the step is empty or skipped, carry on.
2. Choose "Juniper e2e" and a USB card.
3. Set hostname `juniper-e2e`, then go through to the Tailscale step. It should come after Raspberry Pi Connect, which is absent here, so after Remote access.
4. Paste the key with a trailing space, tick SSH, and write.

Then:

```bash
sudo mount -o ro /dev/disk/by-label/CIDATA /mnt && sudo cat /mnt/user-data && sudo umount /mnt
```

Expected: the block from Step 3, with `--hostname='juniper-e2e'` and no `--login-server`. Then choose the official list's Raspberry Pi OS and confirm that **no** Tailscale step appears.

- [ ] **Step 5: Real hardware.** Do this only when a Juniper release exists: `gh release list --repo gnathoi/juniper`.

1. In the Tailscale admin console, create a one-off, pre-approved, **tagged** auth key.
2. Run `rpi-imager --repo https://github.com/gnathoi/juniper/releases/latest/download/os-list.json`.
3. Flash Juniper to an SD card with the key and SSH ticked, then boot a Pi 4 or Pi 5.

Expected:
- The device appears in `tailscale status` on your laptop within a few minutes.
- `tailscale ssh <user>@juniper-e2e 'sudo test ! -e /etc/tailscale/authkey && echo key-gone'` prints `key-gone`.
- On the device, `/var/lib/juniper/firstboot.done` exists.
- CIDATA's `user-data` is back to the commented template, scrubbed by `juniper-firstboot`.

- [ ] **Step 6: Clean up.** Run `kill %1` (the http server) and `rm -rf "$E2E"`. Revoke the test key in the admin console.

---

### Task 11: Draft the upstream PR description

**Files:**
- Create in the **Juniper** repo: `docs/superpowers/upstream/2026-10-09-rpi-imager-tailscale-pr.md`

**Interfaces:**
- Consumes: everything above, plus the results of Task 10.
- Produces: the PR body, ready for `gh pr create --repo raspberrypi/rpi-imager --head gnathoi:feat/tailscale-customisation --base main --body-file …`. **Don't open the PR**; a human does that after reading it.

- [ ] **Step 1: Write the description.** Fill the bracketed counts from the actual test runs:

```markdown
# Customisation: join a tailnet on first boot (Tailscale)

## What

A new OS-list capability, `"tailscale"`, lets an OS that **ships Tailscale preinstalled** offer a Tailscale step in the customisation wizard. The user pastes an auth key and can optionally enable Tailscale SSH or name a self-hosted (Headscale) control server. Imager writes the key to `/etc/tailscale/authkey` (root, `0600`) through cloud-init `write_files`. It joins with `tailscale up --auth-key=file:/etc/tailscale/authkey --timeout=120s [--ssh] [--hostname=…] [--login-server=…] && shred -u /etc/tailscale/authkey`.

Imager never installs Tailscale. The contract is distro-neutral: any OS that ships `tailscale`/`tailscaled` can add the capability.

## Scope

- `init_format` `cloudinit` and `cloudinit-rpi`. For any other format, the step is not shown and nothing is written; this is enforced in `ImageWriter::imageSupportsTailscale()` as well as in the wizard.
- The CLI gets `--tailscale-authkey-file`, `--tailscale-ssh` and `--tailscale-login-server`. The key comes from a file so it never appears in `ps`. These flags generate user-data, so they are refused alongside `--cloudinit-userdata`/`--first-run-script`.

## Secret handling

- The key is held in memory for the session only. `setPersistedCustomisationSetting`/`setSavedCustomisationSettings` refuse it.
- Debug logging now passes payloads through `CustomisationGenerator::redactSecrets()`. That removes the Tailscale key (any `tskey-…`), the Wi-Fi passphrase in every form the generators write it, and the Raspberry Pi Connect token. Before this change, `--debug` printed all three.
- Telemetry is unchanged: it never carried customisation.
- The key is shredded only after a successful join, so an OS can retry a failed one. The help text says that the key is unencrypted on the card until first boot, and recommends one-time, pre-approved, expiring, tagged keys.

## Tests

- `customization_generator_test`: [N] new cases. They cover the exact document; flags; no-key-no-output; runcmd/write_files merging with SSH, sudo, Connect and Wi-Fi; hostile key/hostname/server values parsed with PyYAML and executed through `sh`; validators; and redaction across firstrun.sh, network-config and rpi-preseed.toml.
- `image_writer_test`: [N] new cases. They cover the capability/format gate, the key never reaching QSettings, the debug log carrying no secrets, and the CLI flag validation.
- QtQuickTest: `tst_tailscale_step.qml` ([N] cases), and new navigation cases in `tst_wizard_navigation.qml`.
- `fuzz_customisation_gen`: the new fields take the hostile value, plus an invariant that the join appears exactly when there is a key. [M] minutes, clean.
- Manual: a loop-backed card written with the CLI, and a USB card written with the GUI, from an OS list advertising the capability. The `user-data` on the FAT partition matched, and the log showed only `<redacted>`.

## Follow-ups (not in this PR)

- `systemd` (firstrun.sh): write the key file and run the same `tailscale up` from `firstrun.sh`.
- `rpi-preseed`: this needs a `[tailscale]` section in rpi-preseed upstream first.
- List Tailscale in the Writing/Done summaries (`CommonStrings`, `WritingStep.qml`, `DoneStep.qml`, `completionSnapshot`) if you'd like it there.

## Questions for maintainers

- New files carry the repository's usual `SPDX-License-Identifier: Apache-2.0` / `Copyright (C) 2026 Raspberry Pi Ltd` header. Tell me if you prefer contributor attribution.
- Is "after Raspberry Pi Connect" the right place for the step, and is defaulting "Enable Tailscale SSH" to off the default you want?
```

- [ ] **Step 2: Commit it to the Juniper repo.**

```bash
cd "$JUNIPER"
git add docs/superpowers/upstream/2026-10-09-rpi-imager-tailscale-pr.md
git commit -m "docs: draft the upstream rpi-imager Tailscale PR description"
```

- [ ] **Step 3: Hand off.** Report the branch (`gnathoi/rpi-imager:feat/tailscale-customisation`), the release (`v2.0.12-tailscale.1`) and the command above for opening the PR. Wait for a human to approve before running it.

---

## Self-review

**Spec coverage:**

| Spec item | Task |
|---|---|
| Capability `tailscale` in the schema and docs | 1 |
| Generated `write_files`/`runcmd`, shred on success, merging, escaping, `--hostname` from the hostname step | 2 |
| Only `cloudinit`/`cloudinit-rpi`; no output without the capability | 4 (C++ gate), 7 (wizard) |
| Wizard step: toggle, masked key with the regex, inline error and Next disabled, SSH checkbox, collapsed https-only control server, help text | 6 |
| Placed after Pi Connect, shown only with the capability | 7 |
| Key in memory only, never QSettings, never restored | 4, 6 |
| Not in telemetry | 4, Step 6 (verified) |
| Redaction of the key and the Wi-Fi password in logging | 3, 4 |
| CLI flags | 5 |
| Generator tests, redaction test, fuzz extension, QML test | 2, 3, 4, 8, 6/7 |
| Fork CI building the AppImage | 9 |
| Juniper's OS list and `--repo` | 10 |
| PR description with follow-ups | 11 |

**Placeholder scan:** no TBD/TODO. The bracketed counts in Task 11 are filled from the actual test output.

**Type and name consistency:**
- Settings keys `tailscaleAuthKey`/`tailscaleSsh`/`tailscaleLoginServer` are the same in Tasks 2, 4, 5, 6, 7 and 8.
- `imageSupportsTailscale`, `isValidTailscaleAuthKey` and `isValidTailscaleLoginServer` are the same in Tasks 4, 6 and 7.
- `tailscaleAvailable`/`tailscaleEnabled`/`stepTailscaleCustomization` are the same in Tasks 6 and 7.
- `buildTailscaleUserData` is the same in the Task 5 header, implementation and tests.
- `kKey` (image_writer_test) and `kTailscaleKey` (customization_generator_test) are deliberately separate names in separate files.

**Review Focus:** each of the five items has a named test in its owning task.
