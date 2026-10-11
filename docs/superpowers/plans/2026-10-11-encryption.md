# Encryption at Rest Implementation Plan (issue #50 Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On first boot, a card flashed with `encrypt: true` encrypts its root partition in place with LUKS2.
- **Key:** derived from the Pi's OTP device key (through `rpi-fw-crypto`) plus the card's serial.
- **Recovery:** an age-sealed keyslot for the owner's SSH keys.
- **Every boot:** the device unlocks unattended and falls back through tryboot as today.
- **Failure:** it fails open (boots plain, with loud warnings) when anything in the path can't run, and the decision is final.
- **Rollout:** encryption ships **gated off** (`encrypt: true` to opt in) until the owner's Pi 5 run passes; then a small PR flips the default.

**Architecture:** A Juniper dracut module, `90juniper-cryptroot`, adds two initramfs units:
- `juniper-cryptroot-prepare.service` runs **before udev**. It does the first-boot conversion, resume, recovery sealing and growing, encrypting path only.
- `juniper-cryptroot-unlock.service` runs **after udev**. It opens `/dev/mapper/juniper-root`, then calls the best-effort key lock.

The logic is in two unit-tested bash scripts in `/usr/libexec/juniper/`: `fwkey` (the firmware key) and `cryptroot` (decisions, cryptsetup, sfdisk, age, state). The kernel command line doesn't change.

**Tech Stack:** bootc/Containerfile on AlmaLinux 10 aarch64, dracut 107 (systemd initramfs), cryptsetup 2.8.1, raspberrypi/utils `rpifwcrypto`, age 1.3 (EPEL 10), bash, Python 3 (`render-cidata`), `tests/unit.sh` (stubbed bash tests), `tests/image.sh` (inside the built image in CI), and a privileged loop-device test in CI.

**Spec:** `docs/superpowers/specs/2026-10-11-encryption-design.md`. It has the owner decisions, rulings 1–7, and spike findings B1–B4 and F1–F11. The pre-flight review's Critical and Important items (C1–C3, I1–I15) are fixed in the tasks below; each fix is tagged where it lands.

## Critical path: an opt-in build the owner can flash today

1. **Task 1**: already up as **PR #75** (separate `fix:` PR). It isn't needed for the first boot, but it must be merged before an encrypted card takes any update.
2. **Task 2**: `rpi-fw-crypto`, `age`, `lock_device_private_key=1`, initramfs trims.
3. **Task 3**: `fwkey`.
4. **Task 4**: `cryptroot`.
5. **Task 5**: the dracut module and units, **including Step 4, the Pi 5 serial smoke test** (needs the owner's Pi 5).
6. **Task 8, `render-cidata` part only** (Steps 1–2). Writing the two CIDATA files by hand also works, so this one is soft.

Strongly recommended before the hardware session, but not blocking a flash: **Task 6** (loop test with the real cryptsetup, including the C1/C3/I5 kill points).

These can follow: Tasks 7, 8 (`flash.sh` part), 9, 11, 12, 12b, 13, 14. **Task 10 (re-bind) is deferred to #76** (ruling 5).

## Global Constraints

These are repeated in each task brief where they apply.

- **Owner decisions and rulings (spec):**
  - stolen card only;
  - board OTP key plus card serial; **a USB disk with no serial binds to the board only** (ruling 1);
  - age recovery to the `flash.yaml` SSH keys or `recovery_key:`;
  - **no usable recipient means no encryption** (ruling 3);
  - fail open with NOT ENCRYPTED in the MOTD, `pi-status` and `juniper_encrypted 0`;
  - Pi 5 first;
  - reflash only;
  - **re-bind deferred to #76** (ruling 5);
  - **cloud-init growpart unchanged for plain cards; the initramfs grows only on the encrypting path** (ruling 6);
  - default off until Task 13, then Task 14.
- **Key rules:**
  - key id 1;
  - probe with `hmac` on `juniper.probe.v1`; **Superseded 2026-10-11:** `hmac` wedged the mailbox on EEPROM 2025-11-05. Probe with `pubkey` (250 = not set), gate on build-timestamp >= 1769002727 (Pi 5; fail open on Pi 4), and bound every call with a deadline and a wedged marker (spec, "Hardware findings");
  - `genkey --key-id 1 --alg ec` **only** on `KEY_NOT_SET` (error 6), and **only as the last first-boot precondition** (I7);
  - never `privkey`, `rpi-otp-private-key`, `vcmailbox 0x00030081` or `set-key-usage`;
  - after unlock, `set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED` **is best-effort** (ruling 4, I3): `unavailable` is expected, and it never fails the boot;
  - `lock_device_private_key=1` in **both** per-deployment `rpi-config.txt` sources, `system_files` and `system_files_desktop` (I12); never `lock_device_key_write=1`.
- **Derivation:**
  - `msg = "juniper.luks.root.v1" 0x00 "<type>:<id>"`.
  - The passphrase is **exactly 64 lowercase hex bytes, with no newline** (`printf '%s'`).
  - Ids:
    - `mmc:` + `/sys/block/<disk>/device/cid`;
    - `nvme:` + `device/serial`, whitespace removed;
    - `usb:` + `idVendor:idProduct:serial`;
    - `board:` (empty id) for a USB disk with no serial (I2).
- **LUKS2:**
  - `--type luks2 --sector-size 512 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --label juniper-root`;
  - `aes-xts-plain64 --key-size 512` if `/proc/cpuinfo` lists `aes`, else `xchacha12,aes-adiantum-plain64 --key-size 256`;
  - `--reduce-device-size 32M`;
  - **keyslot 0 is the board slot, keyslot 1 the recovery slot** (I5);
  - open with `--allow-discards` as `juniper-root`.
- **Tokens** (all values strings; LUKS2 requires `"keyslots":[]`):
  - token 0: `{"type":"juniper","keyslots":[],"root_uuid":"<X>","binding":"juniper.luks.root.v1","id_type":"<mmc|nvme|usb|board>","recovery":"<pending|sealed>","recipients":"<n>"}`;
  - token 1: `{"type":"juniper-recovery","keyslots":[],"age":"<armored age ciphertext, JSON-escaped>"}` (I10).
- **CIDATA marker `juniper-encrypt`:** `on`/`off` (written by `render-cidata`); `converting`, `encrypted`, `not-encrypted:<reason>` (written by `cryptroot`).
- **Secrets never touch a disk.** The board passphrase and `R` move only through pipes and `/dev/fd/N` from process substitution. No here-strings, heredocs or temporary files for them, and never `set -x`.
- **Fail open is final** (C2, I8): any first-boot exit before the LUKS header exists records `not-encrypted:<reason>`.
- **No LUKS header writes under tryboot** (I9).
- **Conventions:**
  - conventional prefixes on every commit and PR title; squash merges;
  - commit messages end with the session's `Co-Authored-By`/`Claude-Session` lines;
  - `pre-commit run --all-files` and `tests/unit.sh` pass before every push; arm64 image checks come from `gh pr checks`.

## Review Focus

1. **Plaintext of either secret on any disk,** the FAT partition included. Tasks 3, 4 and 6 use `not_grep_dir`/`grep -a` after each scenario.
2. **An irreversible OTP write in the wrong case:** after a later fail-open, on `KEY_LOCKED`, an unknown error, missing `/dev/vcio`, or when `encrypt` isn't `on`. Covered by Tasks 3 and 4.
3. **Power loss at each first-boot step converges:**
   - before the header;
   - after the header but before the token (C1);
   - mid-reencrypt;
   - after age, before the slot;
   - after the slot, before token `sealed`;
   - after the grow, before the record.

   Task 4 unit-tests each and Task 6 runs them for real.
4. **An encrypted card with no recovery** must be impossible or loudly reported (C3). Covered by Tasks 4, 6 and 7.
5. **Unlock failure** must fall back under tryboot and never reboot in a tight loop (Task 4).

---

## File structure

| Path | Responsibility | Task |
|---|---|---|
| `system_files/usr/libexec/juniper/bootloader`, `…/ostree-finalize-staged.service.d/zz-juniper.conf`, `healthcheck`, `apply-update` | `MNTDEV` wrapper | 1 (PR #75) |
| `Containerfile`, `build_files/fwcrypto.lock`, `build_files/fwcrypto.sh`, `Justfile` (`bump-fwcrypto`), `build_files/build.sh` | build and install `rpi-fw-crypto`; install `age` | 2 |
| `system_files/usr/share/juniper/rpi-config.txt`, `system_files_desktop/usr/share/juniper/rpi-config.txt` | `lock_device_private_key=1` | 2 |
| `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf` | `early_microcode="no"` (2); `add_dracutmodules`, header comment (5) | 2, 5 |
| `THIRD_PARTY.md` | raspberrypi/utils licence row | 2 |
| `system_files/usr/libexec/juniper/fwkey` | firmware key | 3 |
| `system_files/usr/libexec/juniper/cryptroot` | prepare and unlock | 4 |
| `system_files/usr/lib/dracut/modules.d/90juniper-cryptroot/*` | initramfs integration | 5 |
| `tests/cryptroot-loop.sh`, `Justfile` (`test-cryptroot`), `.github/workflows/build.yml` | privileged loop test | 6 |
| `system_files/usr/libexec/juniper/encryption-status`, `…/juniper-encryption-status.service`, `metrics`, `motd`, `…/just/pi.just`, `firstboot`, `build_files/build.sh` | reporting | 7 |
| `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml` | flash options | 8 |
| `disk/unlock-card`, `Justfile` (`unlock-card`) | laptop recovery | 9 |
| `system_files/usr/libexec/juniper/switch-image`, `Containerfile` (`LABEL`) | switch guard | 11 |
| `…/just/pi.just` (`recovery-reseal`), `cryptroot` | re-seal (optional) | 12 |
| `README.md`, `CHANGELOG.md`, `docs/upstream.md`, `docs/superpowers/STATUS.md`, `docs/acceptance.md` | docs | 12b, 13 |
| `tests/unit.sh`, `tests/image.sh` | tests | every task |

**Not touched:** `system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg` (ruling 6) and `system_files/usr/share/juniper/just/services.just`, which already passes `--collector.textfile.directory=/host/var/lib/juniper/metrics`.

Unit-test conventions (`tests/unit.sh`):
- each `test_*` gets a fresh `$T`;
- `stub NAME BODY` writes a fake that logs `NAME args` to `$CALLS`, then runs BODY;
- helpers: `called`, `not_called`, `not_grep_dir`, `check "label" CMD…`, `fails`, `stderr_has`;
- Task 4 adds `order A B` (the first line matching A comes before the first line matching B) and `order_last A B` (the **last** line matching A comes before the last line matching B; I13).

Scripts take `JUNIPER_*` overrides for every path. `tests/image.sh` runs with `set -euo pipefail`, so avoid `cmd | grep -q` where `cmd` may fail or take SIGPIPE: capture to a variable or a temp file first.

Suggested PRs:
- PR #75 = Task 1;
- the implementation PR = Tasks 2–9, 11 and 12b (`feat:`, default off);
- an optional follow-up = Task 12;
- the flip PR = Task 14 after Task 13.

---

### Task 1: rpi-bootc-bootloader gets `MNTDEV` from `cidata-device` — **PR #75 (critical path; separate)**

**Status:** implemented in PR #75 (`fix: rpi-bootc-bootloader finds the firmware partition via cidata-device (MNTDEV)`). Review and merge it before any encrypted card takes an update.

**Brief (for reference or rework):**
- **Problem (B3):** with root on `/dev/mapper/juniper-root`, `rpi-bootc-bootloader` v0.0.8 computes `MNTDEV` as the root device itself (`sed -E 's/[0-9]+$/1/'`, lines 224 and 357). `finalize-staged` then silently skips the sync. Upstream honours an exported `MNTDEV` (`if [ -z "$MNTDEV" ]`, lines 214 and 347).
- **Files:**
  - create `system_files/usr/libexec/juniper/bootloader`: `MNTDEV=$("${JUNIPER_CIDATA_DEVICE:-/usr/libexec/juniper/cidata-device}") || exit 1; export MNTDEV; exec rpi-bootc-bootloader "$@"`;
  - create `system_files/usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf` containing `[Service]`, `ExecStop=`, `ExecStop=/usr/libexec/juniper/bootloader finalize-staged`;
  - in `healthcheck` (line **166**), use `"${JUNIPER_BOOTLOADER:-/usr/libexec/juniper/bootloader}" sync`;
  - in `apply-update` (line 55), use `exec "${JUNIPER_BOOTLOADER:-…}" tryreboot`.
- **Tests:**
  - unit: the wrapper exports `MNTDEV` from a stubbed `cidata-device` and passes its arguments through; when `cidata-device` fails, it exits 1 without running the script; the existing healthcheck and apply-update tests expect the wrapper;
  - image: `test -x /usr/libexec/juniper/bootloader`, and `grep -qx 'ExecStop=/usr/libexec/juniper/bootloader finalize-staged' /usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf`. Grep the file, not `systemctl cat`, because systemd isn't running in the image test.
- **Hardware (owner's Pi, any image):** after merge, one `ujust update`. `rpi-bootc-log.txt` on CIDATA must be fresh, and `tryboot.txt` must name the new entry.

---

### Task 2: Build `rpi-fw-crypto`; ship `age`; lock raw key reads; trim the initramfs — **critical path**

**Files:**
- Create: `build_files/fwcrypto.lock`, `build_files/fwcrypto.sh`
- Modify: `Containerfile`, `build_files/build.sh`, `Justfile`, `system_files/usr/share/juniper/rpi-config.txt`, `system_files_desktop/usr/share/juniper/rpi-config.txt`, `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf`, `THIRD_PARTY.md`, `tests/image.sh`

**Facts (spike B2, F2, F7, F11):**
- `rpi-fw-crypto` isn't packaged for EL10.
- `raspberrypi/utils` `rpifwcrypto/` was last changed at `61371fa` (2026-06-17). It is two C files and CMake with `find_package(GnuTLS REQUIRED)`. The README's "3.10" is the CMake minimum; EL10 gnutls 3.8.10 is fine.
- `librpifwcrypto` opens `/dev/vcio_crypto`, then `/dev/vcio`. The kernel has `BCM_VCIO=y`, so the device is `/dev/vcio`, root-only.
- The CLI subcommands Juniper uses: `hmac --in <file> --key-id 1 --outform hex`, `genkey --key-id 1 --alg ec`, `get-key-status 1`, `set-key-status 1 <FLAGS…>`. Errors print `Last crypto error: N (…)`.
- `age-1.3.1` is in EPEL 10, which the build already enables with a pinned key.
- `desktop.sh` replaces every `rpi-config.txt` with `system_files_desktop/usr/share/juniper/rpi-config.txt`, so both files need the line (I12).
- `01-dist.conf` sets `early_microcode="yes"`, which puts x86 `AuthenticAMD.bin` (0.3 MB) in the arm64 early cpio.

**Interfaces produced:**
- `/usr/bin/rpi-fw-crypto` and `/usr/lib64/librpifwcrypto.so.0*` in every image;
- `/usr/bin/age`;
- `lock_device_private_key=1` in every `/usr/lib/modules/*/rpi-config.txt` of all three images;
- `just bump-fwcrypto`.

- [ ] **Step 1: Failing image tests** (shared section of `tests/image.sh`; pipefail-safe, per the review's minor items):

```bash
need_cmds rpi-fw-crypto age cryptsetup sfdisk partx
ldd /usr/bin/rpi-fw-crypto >"$tmp/ldd"; grep -q 'librpifwcrypto.so.0 => /usr/lib64/' "$tmp/ldd"
usage=$({ rpi-fw-crypto 2>&1 || true; })
for sub in 'hmac --in' 'genkey' 'get-key-status' 'set-key-status'; do
  grep -q -- "$sub" <<<"$usage" || { echo "rpi-fw-crypto lacks $sub"; exit 1; }
done
test -s /usr/share/licenses/rpi-fw-crypto/LICENCE
for kdir in /usr/lib/modules/*/; do
  grep -qx 'lock_device_private_key=1' "$kdir/rpi-config.txt"
  if grep -q 'lock_device_key_write' "$kdir/rpi-config.txt"; then echo "lock_device_key_write breaks genkey"; exit 1; fi
done
for img in /usr/lib/modules/*/initramfs.img; do
  lsinitrd "$img" >"$tmp/inv"
  if grep -q 'kernel/x86/microcode' "$tmp/inv"; then echo "x86 microcode in the arm64 initramfs"; exit 1; fi
done
# /dev/vcio stays root-only: it is the only barrier without the HMAC lock (ruling 4).
if grep -rlE 'vcio.*MODE|vcio.*GROUP' /usr/lib/udev/rules.d /etc/udev/rules.d 2>/dev/null; then
  echo "a udev rule widens /dev/vcio"; exit 1
fi
```

(`tmp=$(mktemp -d)` near the top of `image.sh` if it doesn't exist already.)

- [ ] **Step 2: Pinned source.** Create `build_files/fwcrypto.lock`:

```
# raspberrypi/utils (rpifwcrypto/ only). Bump with `just bump-fwcrypto`.
commit=<full 40-character SHA of 61371fa>
sha256=<sha256 of https://codeload.github.com/raspberrypi/utils/tar.gz/<commit>>
```

`just bump-fwcrypto`:
- resolves the latest `master` commit touching `rpifwcrypto/` through `https://api.github.com/repos/raspberrypi/utils/commits?path=rpifwcrypto&per_page=1`;
- downloads both tarballs and prints `diff -ru` of `rpifwcrypto/`;
- rewrites the lock.

- [ ] **Step 3: Builder stage.** In the `Containerfile`, before `minimal`, add a stage on the **same base digest** as `minimal`:

```dockerfile
FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b361228495c05656b1367fb41507a79ea9b7eca293f21bbc5e4801e3355337 AS fwcrypto
COPY build_files/fwcrypto.lock build_files/fwcrypto.sh /
RUN /fwcrypto.sh
```

`build_files/fwcrypto.sh` (`set -euo pipefail`):
1. `dnf -y install gcc cmake gnutls-devel`.
2. `curl -fsSLo /src.tgz https://codeload.github.com/raspberrypi/utils/tar.gz/$commit`, then `echo "$sha256  /src.tgz" | sha256sum -c`.
3. Extract it and run `cmake -S utils-$commit/rpifwcrypto -B /b -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib64 -DCMAKE_BUILD_TYPE=Release`, `cmake --build /b`, `DESTDIR=/out cmake --install /b`.
4. `install -Dm0644 utils-$commit/LICENCE /out/usr/share/licenses/rpi-fw-crypto/LICENCE`.

In the `minimal` stage's `RUN`, add `--mount=type=bind,from=fwcrypto,source=/out,target=/fwcrypto`. In `build.sh`, after the package install and **before** the dracut loop:

```bash
# rpi-fw-crypto (issue #50): built from a pinned raspberrypi/utils commit (Containerfile stage).
cp -a /fwcrypto/usr/. /usr/
dnf -y install age   # EPEL; only /usr/bin/age is used (initramfs recovery sealing)
```

and add `/usr/bin/rpi-fw-crypto /usr/lib64/librpifwcrypto.so*` to the `tag juniper` list.

- [ ] **Step 4:** Append to **both** `rpi-config.txt` files:

```
# The firmware refuses raw reads of the OTP device key (rpi-fw-crypto privkey); hmac and sign still work.
lock_device_private_key=1
```

In `90-juniper.conf`, add `early_microcode="no"` with the comment `# else dracut puts x86 AMD microcode in the early cpio (0.3 MB)`. Add a `THIRD_PARTY.md` row: raspberrypi/utils rpifwcrypto, BSD-3-Clause, `https://github.com/raspberrypi/utils`, the pinned commit.

- [ ] **Step 5:** Push and read `gh pr checks`; note the initramfs size in the PR body. Commit `build: rpi-fw-crypto from a pinned upstream commit, age, raw OTP key reads locked`.

---

### Task 3: `fwkey` — probe, ensure, card id, derive, lock — **critical path**

> **Superseded 2026-10-11 (read first):** this task's `hmac` probe and its token-before-resume ordering failed on hardware. See the spec's "Hardware findings": gate on build-timestamp, probe with `pubkey`, deadline every call, token 0 only after the conversion.

**Files:**
- Create: `system_files/usr/libexec/juniper/fwkey`
- Modify: `tests/unit.sh`

**Facts:**
- `rpi-fw-crypto` exits with `-last_error` (error 6 → exit 250) and prints `Last crypto error: N (text)` on stderr.
- Error codes: 3 `KEY_NOT_FOUND`, 4 `KEY_LOCKED`, 5 `KEY_OTP_ERROR`, 6 `KEY_NOT_SET`, 7 `KEY_INVALID`, 8 `NOT_SUPPORTED`, 10 `KEY_NOT_BLANK`.
- `hmac --in /dev/stdin` reads up to 2048 bytes; `--outform hex` prints 64 hex characters.
- `get-key-status 1` prints `Key 1 status: 0x%08x (…)`; `HMAC_LOCKED` is bit 11 (`0x800`).

**Interfaces:**

| Command | stdout | Exit |
|---|---|---|
| `fwkey probe` | `ok`, `not-set`, `locked` or `unavailable:<detail>` | 0 |
| `fwkey ensure` | `ok`, `generated` or `unavailable:<detail>`. It calls `genkey --key-id 1 --alg ec` **only** after `probe` returns `not-set`, then probes again | 0 if usable, else 1 |
| `fwkey card-id DISK` (kernel name, for example `mmcblk0`) | `mmc:<cid>`, `nvme:<serial>`, `usb:<vid>:<pid>:<serial>` or `board:` (a USB disk with no serial, ruling 1) | 0; 1 only if DISK doesn't exist in sysfs |
| `fwkey derive DISK` | **exactly** 64 lowercase hex bytes, **no newline** (`printf '%s'`) | 1 on any failure, with empty stdout |
| `fwkey lock` | `locked` or `unavailable` | **always 0** (best-effort, ruling 4) |

**Superseded 2026-10-11:** the `hmac` probe below is dead; use `pubkey` (spec, "Hardware findings").

Environment: `JUNIPER_SYSFS` (default `/sys`; used for the id attributes and the USB walk), `JUNIPER_VCIO` (default `/dev/vcio`), `RPI_FW_CRYPTO` (default `rpi-fw-crypto`). No temporary files at all. The probe's stdout and stderr are captured together: `both=$(printf 'juniper.probe.v1' | hmac 2>&1)`.

- [ ] **Step 1: Failing unit tests.** Use a stub `rpi-fw-crypto` driven by `$T/fw.mode` (`ok`|`not-set`|`locked`|`gen-fails`|`nolock`). For `hmac` it copies stdin to `$T/hmac.in` and prints `openssl dgst -sha256 -mac HMAC -macopt key:juniper-test` of it, cut to 64 characters.

```bash
fwkey_env() {
  export JUNIPER_SYSFS=$T/sys JUNIPER_VCIO=$T/vcio TMPDIR=$T/tmp
  mkdir -p "$TMPDIR" "$T/sys/block/mmcblk0/device"; : >"$JUNIPER_VCIO"
  echo 0353445344333247803a1b2c3d014e00 >"$T/sys/block/mmcblk0/device/cid"
  # shellcheck disable=SC2016
  stub rpi-fw-crypto 'mode=$(cat "$T/fw.mode" 2>/dev/null || echo ok)
case $1 in
  hmac) cat >"$T/hmac.in"
        case $mode in
          ok|nolock) openssl dgst -sha256 -mac HMAC -macopt key:juniper-test -r "$T/hmac.in" | cut -c1-64 | tr -d "\n" ;;
          not-set|gen-fails) echo "Last crypto error: 6 (Key is all zeros)" >&2; exit 250 ;;
          locked) echo "Last crypto error: 4 (locked)" >&2; exit 252 ;;
        esac ;;
  genkey) [[ $mode == gen-fails ]] && { echo "Last crypto error: 10 (not blank)" >&2; exit 246; }
          echo ok >"$T/fw.mode"; echo "Successfully generated ECDSA key in slot 1" ;;
  set-key-status) [[ $mode == nolock ]] && { echo "Last crypto error: 2 (EINVAL)" >&2; exit 254; }; echo "Set key 1 status" ;;
  get-key-status) [[ $mode == nolock ]] && echo "Key 1 status: 0x00000101 (x)" || echo "Key 1 status: 0x00001b01 (x)" ;;
esac'
}

test_fwkey_derive_exact_bytes() {
  fwkey_env
  "$LIBEXEC/fwkey" derive mmcblk0 >"$T/out"
  check "fwkey: exactly 64 hex bytes, no newline" test "$(wc -c <"$T/out")" = 64
  check "fwkey: hex only" grep -Eqx '[0-9a-f]{64}' "$T/out"
  check "fwkey: exact HMAC input" cmp -s "$T/hmac.in" <(printf 'juniper.luks.root.v1\0mmc:0353445344333247803a1b2c3d014e00')
}
test_fwkey_usb_without_serial_is_board_only() {   # ruling 1 (I2)
  fwkey_env
  mkdir -p "$T/sys/devices/usb1/1-1/1-1:1.0/host0/target0/0:0:0:0" "$T/sys/block/sda"
  echo 0781 >"$T/sys/devices/usb1/1-1/idVendor"; echo 5583 >"$T/sys/devices/usb1/1-1/idProduct"
  ln -s "$T/sys/devices/usb1/1-1/1-1:1.0/host0/target0/0:0:0:0" "$T/sys/block/sda/device"
  check "fwkey: board-only id" test "$("$LIBEXEC/fwkey" card-id sda)" = "board:"
  echo 4C530001 >"$T/sys/devices/usb1/1-1/serial"
  check "fwkey: usb id with serial" test "$("$LIBEXEC/fwkey" card-id sda)" = "usb:0781:5583:4C530001"
}
test_fwkey_nvme_serial_trimmed() { … "  S6X1NJ0R123456  " → nvme:S6X1NJ0R123456 … }
test_fwkey_genkey_only_when_not_set() {
  fwkey_env; echo not-set >"$T/fw.mode"
  check "fwkey: generated" test "$("$LIBEXEC/fwkey" ensure)" = generated
  check "fwkey: genkey once" test "$(grep -c '^rpi-fw-crypto genkey --key-id 1 --alg ec$' "$CALLS")" = 1
}
test_fwkey_never_writes_when_locked_or_no_vcio() {
  for mode in locked novcio; do
    fwkey_env; echo "$mode" >"$T/fw.mode"; [[ $mode == novcio ]] && rm -f "$JUNIPER_VCIO"
    check "fwkey ($mode): ensure fails" fails "$LIBEXEC/fwkey" ensure
    check "fwkey ($mode): no genkey" not_called "rpi-fw-crypto genkey"
  done
}
test_fwkey_never_reads_raw_key() {
  fwkey_env; echo not-set >"$T/fw.mode"
  "$LIBEXEC/fwkey" ensure >/dev/null; "$LIBEXEC/fwkey" derive mmcblk0 >/dev/null; "$LIBEXEC/fwkey" lock >/dev/null
  check "fwkey: no privkey" not_called "privkey"
  check "fwkey: no key-usage write" not_called "set-key-usage"
  check "fwkey: no vcmailbox" not_called "vcmailbox"
  check "fwkey: no temp files" test -z "$(ls -A "$TMPDIR")"
}
test_fwkey_lock_is_best_effort() {   # ruling 4 (I3)
  fwkey_env
  check "fwkey: locked" test "$("$LIBEXEC/fwkey" lock)" = locked
  check "fwkey: one call, four flags" called "rpi-fw-crypto set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED"
  check "fwkey: SIGN stays unlocked" not_called "SIGN_LOCKED"
  echo nolock >"$T/fw.mode"
  check "fwkey: unavailable, exit 0" test "$("$LIBEXEC/fwkey" lock)" = unavailable
}
test_fwkey_derive_fails_closed() { … mode locked → exit 1, empty stdout … }
```

- [ ] **Step 2: Implement `fwkey`.** Skeleton (complete the dispatcher as in the table):

```bash
#!/usr/bin/env bash
# The Pi's OTP device key through the firmware (rpi-fw-crypto, key id 1), for the LUKS root
# (issue #50). Never reads the raw key; generates one only when the slot is blank; never
# writes key usage. Secrets go to stdout only; no temporary files.
set -euo pipefail
sysfs=${JUNIPER_SYSFS:-/sys}
vcio=${JUNIPER_VCIO:-/dev/vcio}
fw=${RPI_FW_CRYPTO:-rpi-fw-crypto}
label='juniper.luks.root.v1'

hmac() { "$fw" hmac --in /dev/stdin --key-id 1 --outform hex; }
fw_error() { printf '%s\n' "$1" | sed -n 's/^Last crypto error: \([0-9]*\).*/\1/p' | head -1; }

probe() {
  [[ -e $vcio ]] || { echo "unavailable:no $vcio"; return; }
  local both err
  # Superseded 2026-10-11: probe with pubkey, not hmac (wedged the mailbox)
  both=$(printf 'juniper.probe.v1' | hmac 2>&1) || true
  if printf '%s\n' "$both" | grep -Eqx '[0-9a-f]{64}'; then echo ok; return; fi
  err=$(fw_error "$both")
  case $err in 6) echo not-set ;; 4) echo locked ;; *) echo "unavailable:firmware error ${err:-none}" ;; esac
}

card_id() {
  local d=$sysfs/block/$1 v p
  [[ -e $d ]] || return 1
  if [[ -r $d/device/cid ]] && v=$(tr -d '[:space:]' <"$d/device/cid") && [[ -n $v ]]; then printf 'mmc:%s\n' "$v"; return; fi
  if [[ $1 == nvme* && -r $d/device/serial ]] && v=$(tr -d '[:space:]' <"$d/device/serial") && [[ -n $v ]]; then printf 'nvme:%s\n' "$v"; return; fi
  p=$(readlink -f "$d/device" 2>/dev/null || true)
  while [[ -n $p && $p == "$sysfs"/* && ! -r $p/idVendor ]]; do p=${p%/*}; done
  if [[ -n $p && -r $p/idVendor ]]; then
    if [[ -r $p/serial ]] && v=$(tr -d '[:space:]' <"$p/serial") && [[ -n $v ]]; then
      printf 'usb:%s:%s:%s\n' "$(cat "$p/idVendor")" "$(cat "$p/idProduct")" "$v"; return
    fi
    printf 'board:\n'; return   # ruling 1: USB without a serial binds to the board only
  fi
  printf 'board:\n'
}

derive() {
  local id out
  id=$(card_id "$1") || return 1
  out=$(printf '%s\0%s' "$label" "$id" | hmac 2>/dev/null) || return 1
  [[ $out =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$out"
}
```

- [ ] **Step 3:** Run `tests/unit.sh`, `shellcheck` and `shfmt`. Commit `feat: fwkey, the OTP device key helper for the encrypted root`.

---

### Task 4: `cryptroot` — prepare (before udev) and unlock (after udev) — **critical path**

> **Superseded 2026-10-11 (read first):** this task's `hmac` probe and its token-before-resume ordering failed on hardware. See the spec's "Hardware findings": gate on build-timestamp, probe with `pubkey`, deadline every call, token 0 only after the conversion.

**Files:**
- Create: `system_files/usr/libexec/juniper/cryptroot`
- Modify: `tests/unit.sh` (add `order`, `order_last`, and `cryptroot_env`)

**Facts:**
- Boot cmdline: `root=UUID=<X> rw boot=UUID=… rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot ostree=…`. **Every card of a release has the same UUIDs.**
- GPT layout: p1 ESP-type `CIDATA` 1 GiB; p2 XFS `/boot` 1 GiB; p3 type `b921b045-1df0-41c3-af44-4c6f280d3fae` (root-arm64), 6 GiB, ending at the 8 GiB image's last LBA. The backup GPT sits at 8 GiB.
- The XFS has 512-byte sectors, so the LUKS sector size must be 512.
- Offline encryption puts the data offset at 16 MiB and gives a dynamic segment. **A killed run needs `cryptsetup repair` before `--resume-only`.**
- `/run/cryptsetup` must be created by the script.
- `blkid` takes **one** `-t`. Always pass `-c /dev/null`, because the cache goes stale after repartitioning.
- The tryboot flag is a big-endian u32: `od -An -tu4 --endian=big -N4 /proc/device-tree/chosen/bootloader/tryboot` equals `1`. Copy the check from `emergency-fallback`.
- The age stub must honour `-o FILE`.

**Topology (I14).** Map a partition to its disk and number from the **real** sysfs:
- `part=$(basename "$dev")`;
- `n=$(cat "$JUNIPER_BLOCK_SYSFS/class/block/$part/partition")`;
- `disk=$(basename "$(readlink -f "$JUNIPER_BLOCK_SYSFS/class/block/$part/..")")`.

`JUNIPER_BLOCK_SYSFS` defaults to `/sys` and stays `/sys` in the Task 6 loop test. `JUNIPER_SYSFS` is only for `fwkey`'s id attributes. In unit tests, both point into `$T`.

**Interfaces:**

`cryptroot prepare` runs in the initramfs before udev. It exits 0 unless the system must not continue. It runs these steps **in order**; each is idempotent and skips itself when it has nothing to do (I6):

1. **Find.**
   - `X` comes from `root=UUID=` in `$JUNIPER_CMDLINE` (a file; default `/proc/cmdline`).
   - Poll `blkid -c /dev/null -t UUID=$X -o device` for up to `$JUNIPER_ROOT_WAIT` seconds (30), at 1 s intervals.
   - Plain candidates are the devices printed. LUKS candidates are `blkid -c /dev/null -t LABEL=juniper-root -o device`, keeping those where `blkid -c /dev/null -s TYPE -o value DEV` is `crypto_LUKS` **and** either:
     - token 0 has `root_uuid == X`; or (C1)
     - there is no `juniper` token, the partition's GPT type is root-arm64 (`blkid -p -s PART_ENTRY_TYPE -o value`), it is on the same disk as CIDATA, and that CIDATA's marker is `converting`.
   - CIDATA is the partition labelled `CIDATA` on the root's disk (`blkid -c /dev/null -t LABEL=CIDATA -o device`, filtered by disk). It is mounted **read-only** at `$JUNIPER_CIDATA_MNT` (`/run/juniper/cidata`), remounted read-write only around each write (`cidata_write NAME CONTENT`: `mount -o remount,rw`, write `NAME.new`, `mv`, `sync`, `mount -o remount,ro`), and unmounted on exit.
2. **Tryboot guard (I9).** If the tryboot flag is set, log `juniper-cryptroot: under tryboot; header changes deferred until a confirmed boot`, write `/run/juniper/cryptroot`, and exit 0. Steps 3–6 never run under tryboot.
3. **First boot** (exactly one plain candidate and marker `on` or `converting`):
   1. If the kernel command line has `juniper.encrypt=0`, record `not-encrypted:juniper.encrypt=0` (I8) and skip to step 7.
   2. Arm the **fail-open guard (C2):** `trap 'record "not-encrypted:${step:-prepare} failed"' ERR EXIT`, with `step=<name>` set before each sub-step.
   3. Check the preconditions **in this order** (spec). The first failure calls `record "not-encrypted:<reason>"`, disarms the trap, and skips to step 7:
      1. more than one plain candidate: `two disks carry this root filesystem`;
      2. the root isn't GPT type root-arm64, or isn't on the CIDATA disk: `root partition not on the boot disk`;
      3. disk sectors minus (root start + root size + 34) is less than 131072: `no free space after the root partition`;
      4. `age -R "$cidata/juniper-recovery.txt" -o /dev/null </dev/null` fails: `no usable recovery recipient` (C3);
      5. `fwkey card-id` fails: `disk not found in sysfs`;
      6. **last** (I7): `fwkey ensure` fails: `firmware key interface unavailable: <detail>`.
   4. `cidata_write juniper-encrypt converting` (C1).
   5. `mkdir -p /run/cryptsetup`, then `sfdisk --relocate gpt-bak-std /dev/$disk`.
   6. Grow by 64 MiB with an absolute size (I15). `cur` is the partition's size in sectors (`cat $JUNIPER_BLOCK_SYSFS/class/block/$part/size`). Run `printf 'size=%s\n' "$((cur + 131072))" | sfdisk -N "$n" --no-reread --no-tell-kernel /dev/$disk`, then `partx -u -n "$n" /dev/$disk`.
   7. `fwkey derive "$disk" | cryptsetup reencrypt --batch-mode --encrypt --init-only --type luks2 --key-slot 0 --reduce-device-size 32M --cipher "$cipher" --key-size "$keysize" --sector-size 512 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --label juniper-root --key-file - "/dev/$part"`.
   8. **Disarm the trap.** From here, failures leave the marker at `converting` so the next boot resumes.
   9. **Superseded 2026-10-11:** cryptsetup refuses `token import` while the header is marked for reencryption (reboot loop). Import token 0 only after the conversion completes; before then the candidate is found by the `converting` marker, GPT root type and CIDATA disk. Original text: import token 0 with `recovery: pending`, `recipients: <n>` and `id_type` (from `fwkey card-id`, the part before `:`).
4. **Resume.**
   - A LUKS candidate with no token (the C1 case) gets token 0 imported first. (**Superseded 2026-10-11:** it is imported only once the conversion has finished.)
   - If `cryptsetup luksDump` shows `online-reencrypt` in its requirements:
     - after an interruption (a second boot): `fwkey derive | cryptsetup repair --batch-mode --key-file - DEV`;
     - then `fwkey derive | cryptsetup reencrypt --batch-mode --resume-only --progress-frequency 10 --key-file - DEV`.
   - Within one boot, `--resume-only` follows `--init-only` directly, with no repair.
5. **Seal** (token 0 `recovery` is `pending`; C3, I5):
   1. Make `R`: `r=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')`, which gives 64 hex characters.
   2. `printf '%s' "$r" | age -R "$cidata/juniper-recovery.txt" -a -o "$cidata/juniper-recovery.age.new"`, inside a `cidata_rw` window. If this fails, leave `pending`, log it, and continue.
   3. If `cryptsetup luksDump` shows keyslot 1, run `fwkey derive "$disk" | cryptsetup luksKillSlot --batch-mode --key-file - DEV 1`.
   4. `fwkey derive "$disk" | cryptsetup luksAddKey --batch-mode --key-slot 1 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - DEV /dev/fd/3 3< <(printf '%s' "$r")`, then `unset r`.
   5. Import token 1: type `juniper-recovery`, with `age` set to the `.new` file's content (JSON-escaped: `\` becomes `\\`, `"` becomes `\"`, and newlines become `\n`; use `sed`, since there is no `jq` in the initramfs).
   6. `mv` `.age.new` to `juniper-recovery.age`, then `sync`.
   7. Set token 0 to `recovery: sealed` (`cryptsetup token import --token-id 0 --token-replace`).
6. **Grow** (an encrypted card whose partition doesn't reach the end; encrypting path only, I1): `printf 'size=+\n' | sfdisk -N "$n" --no-reread --no-tell-kernel /dev/$disk`, then `partx -u -n "$n" /dev/$disk`.
7. **Record.**
   - If the marker is `converting` and the card is LUKS with no `online-reencrypt` requirement, write `encrypted`.
   - Write `/run/juniper/cryptroot`: `state=` and `reason=`.
   - Plain cards with marker `off` or missing make **no** sfdisk, fwkey or cryptsetup calls, and no CIDATA writes (I1, ruling 2).

`cryptroot unlock` runs in the initramfs after udev:
1. If `root=UUID=X` resolves to a plain filesystem, append `state=not-encrypted` to `/run/juniper/cryptroot` (keeping prepare's `reason`) and exit 0.
2. For each LUKS candidate (as in Find), run `fwkey derive "$disk" | cryptsetup open --allow-discards --key-file - DEV juniper-root`, and stop at the first success.
3. Then `fwkey lock` (best-effort). Write `/run/juniper/cryptroot`:
   - `state=encrypted`;
   - `cipher=` (from `cryptsetup status juniper-root`);
   - `binding=board+<id_type>`, or `board` when `id_type=board`;
   - `key_lock=`;
   - `recovery=sealed:<recipients>` or `pending`.

   Ignore unknown token fields.
4. On failure, retry three times, 10 s apart. Then:
   - under tryboot, exit 1;
   - otherwise write to `/dev/console`: `juniper-cryptroot: this card is bound to another Raspberry Pi or another card; unlock it on a laptop with the recovery key (just unlock-card)`. Then `sleep "${JUNIPER_UNLOCK_FAIL_DELAY:-120}"` and exit 1. dracut-initqueue ends the boot at about 180 s anyway.

All messages go to stderr (journal+console), prefixed `juniper-cryptroot:`. Nothing ever echoes `fwkey derive` output, and there is no `set -x`.

Environment overrides: `JUNIPER_CMDLINE`, `JUNIPER_SYSFS`, `JUNIPER_BLOCK_SYSFS`, `JUNIPER_CIDATA_MNT`, `JUNIPER_RUN_DIR`, `JUNIPER_CPUINFO`, `JUNIPER_TRYBOOT_FLAG`, `JUNIPER_ROOT_WAIT`, `JUNIPER_UNLOCK_FAIL_DELAY`, `JUNIPER_FWKEY` (default `/usr/libexec/juniper/fwkey`).

- [ ] **Step 1: Failing unit tests.** `cryptroot_env STATE MARKER` builds the fake world under `$T`:
- `$T/cmdline` with `root=UUID=U1`;
- a block sysfs where `class/block/mmcblk0p3/partition` contains `3`, `size` contains `12584927`, and `..` points to `mmcblk0` (whose `size` is `62521344`);
- a `blkid` stub answering from `$T/blkid.db`;
- stubs for `cryptsetup` (it keeps fake header state in `$T/luks/*` so `luksDump` and token export reflect earlier calls), `sfdisk` (it records stdin to `$T/sfdisk.N`), `partx`, `mount`/`umount` (CIDATA is `$T/cidata`) and `age` (it honours `-o` and fails when `$T/age.fail` exists);
- a stub `fwkey` (`derive` prints `$(fake_pass)`, 64 hex; `ensure` follows `$T/fw.mode`; `card-id` prints `mmc:abc`; `lock` prints `unavailable`).

```bash
test_cryptroot_first_boot_sequence() {
  cryptroot_env plain on
  "$LIBEXEC/cryptroot" prepare
  check "prep: marker converting before relocate" order "mount -o remount,rw" "sfdisk --relocate gpt-bak-std /dev/mmcblk0"
  check "prep: +64 MiB absolute" grep -qx "size=$((12584927 + 131072))" "$T/sfdisk.1"
  check "prep: init-only slot 0" called "--init-only --type luks2 --key-slot 0 --reduce-device-size 32M"
  # Superseded 2026-10-11: the token now follows the finished conversion
  check "prep: token before resume" order "cryptsetup token import --token-id 0" "--resume-only"
  check "prep: sector 512, aes" called "--cipher aes-xts-plain64 --key-size 512 --sector-size 512"
  check "prep: age before slot 1" order "age -R" "cryptsetup luksAddKey --batch-mode --key-slot 1"
  check "prep: max grow is last sfdisk" grep -qx 'size=+' "$T/sfdisk.2"
  check "prep: max grow after sealing" order_last "cryptsetup luksAddKey" "sfdisk -N 3"   # I13
  check "prep: recovery file" test -s "$T/cidata/juniper-recovery.age"
  check "prep: recorded" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: no passphrase anywhere" not_grep_dir "$(fake_pass)" "$T"
}
test_cryptroot_off_or_missing_does_nothing() {   # I1, ruling 2
  for m in off missing; do
    cryptroot_env plain "$m"; "$LIBEXEC/cryptroot" prepare
    check "prep ($m): no sfdisk" not_called sfdisk
    check "prep ($m): no fwkey" not_called fwkey
    check "prep ($m): no cryptsetup" not_called cryptsetup
  done
}
test_cryptroot_failure_before_header_is_final() {   # C2
  cryptroot_env plain on; stub sfdisk 'exit 1'
  "$LIBEXEC/cryptroot" prepare || true
  check "prep: recorded fail-open" grep -q '^not-encrypted:' "$T/cidata/juniper-encrypt"
  : >"$CALLS"; stub sfdisk ''
  "$LIBEXEC/cryptroot" prepare
  check "prep: second boot doesn't encrypt" not_called "cryptsetup reencrypt"
}
test_cryptroot_karg_is_final() { … juniper.encrypt=0 → "not-encrypted:juniper.encrypt=0"; second run without karg → no cryptsetup … }   # I8
test_cryptroot_genkey_only_last() {   # I7
  for case in norecipient twocands; do
    cryptroot_env plain on; setup_case "$case"; "$LIBEXEC/cryptroot" prepare
    check "prep ($case): fwkey ensure not called" not_called "fwkey ensure"
  done
}
test_cryptroot_recipients_validated_by_age() { … touch $T/age.fail → reason "no usable recovery recipient", no cryptsetup … }   # C3
# Superseded 2026-10-11: token imported only after the conversion; candidate found by marker + GPT type + CIDATA disk
test_cryptroot_resume_after_header_without_token() {   # C1
  cryptroot_env luks-notoken converting; "$LIBEXEC/cryptroot" prepare
  check "prep: token imported" called "cryptsetup token import --token-id 0"
  check "prep: repair then resume" order "cryptsetup repair" "--resume-only"
}
test_cryptroot_resume_mid_reencrypt() { … requirement online-reencrypt → repair, resume, seal, grow, record … }
test_cryptroot_seal_retry_kills_slot1_first() { … token pending + slot 1 active → luksKillSlot … 1 before luksAddKey --key-slot 1; exactly one slot 1 … }   # I5
test_cryptroot_seal_age_failure_leaves_pending() { … age fails → no luksAddKey; token stays pending; state recovery=pending … }   # C3
test_cryptroot_recovery_via_pipe() { … cryptsetup stub records readlink /proc/self/fd/3 → matches ^pipe: … }
test_cryptroot_token_json_shape() { … imported JSON contains "keyslots":[] and string values; token 1 has "type":"juniper-recovery" … }
test_cryptroot_no_header_writes_under_tryboot() {   # I9
  cryptroot_env luks-pending encrypted; printf '\0\0\0\1' >"$T/tryboot"; export JUNIPER_TRYBOOT_FLAG=$T/tryboot
  "$LIBEXEC/cryptroot" prepare
  for c in "luksAddKey" "luksKillSlot" "token import" "reencrypt" "repair" "sfdisk"; do check "tryboot: no $c" not_called "$c"; done
}
test_cryptroot_usb_board_only_encrypts() { … fwkey card-id prints board: → encrypts; token id_type "board" … }   # I2
test_cryptroot_cidata_ro_except_writes() { … every write to $T/cidata is bracketed by remount,rw / remount,ro … }
test_cryptroot_adiantum_without_aes() { … }
test_cryptroot_unlock_plain_is_noop() { … }
test_cryptroot_unlock_tries_each_candidate() { … the first open fails, the second opens; fwkey lock once; /run file has binding=board+mmc, key_lock=unavailable, recovery=sealed:2 … }
test_cryptroot_unlock_failure_under_tryboot_exits_fast() { … no sleep … }
test_cryptroot_unlock_failure_normal_boot_hint() { … JUNIPER_UNLOCK_FAIL_DELAY=0; console text contains "just unlock-card", not "rebind" … }
```

`order A B`: `[[ $(grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1) -lt $(grep -nF -- "$2" "$CALLS" | head -1 | cut -d: -f1) ]]`. `order_last A B` is the same with `tail -1`.

- [ ] **Step 2: Implement `cryptroot`** to the interfaces above. Keep helpers small:
- `find_root`;
- `part_info DEV` (sets `part disk n`);
- `marker_read`/`cidata_write`;
- `token_read KEY`/`token_write` (flat JSON parsed with `sed`);
- `is_tryboot`;
- `record STATE [REASON]`;
- `grow_abs SECTORS`/`grow_max`;
- `seal_recovery`.
- [ ] **Step 3:** Run the unit tests, shellcheck and shfmt. Commit `feat: cryptroot, first-boot LUKS2 encryption and unlock logic`.

---

### Task 5: Dracut module and initramfs units — **critical path, Step 4 needs the owner's Pi 5**

**Files:**
- Create: `system_files/usr/lib/dracut/modules.d/90juniper-cryptroot/module-setup.sh`, `…/juniper-cryptroot-prepare.service`, `…/juniper-cryptroot-unlock.service`
- Modify: `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf` (edit, don't replace; it already has Task 2's `early_microcode`), `build_files/build.sh` (tag the module files `juniper`), `tests/image.sh`

**Facts:**
- B1: there is no `systemd-cryptsetup` module and no `cryptsetup` binary in today's initramfs.
- The initramfs already carries `dm-crypt.ko.xz`, `adiantum`, `chacha_generic`, `chacha-neon`, `nhpoly1305-neon`, `aes-ce-blk`, `aes-neon-bs`, and `af_alg`/`algif_skcipher`. The last two come only through `crypt`, so list them explicitly.
- `xts` is built in (`=y`). `xchacha12` isn't a module name; xchacha comes from `chacha_generic`.
- `tests/image.sh` already caps the initramfs at **35 MiB** (`(( $(stat -c %s "$img") < 35 * 1024 * 1024 ))`, around line 117). It is 28.7 MB today, and this task adds about 5–6 MB. **Replace that line with a 40 MiB cap** (I11).
- dracut sets no device job timeout on the root device. `dracut-initqueue` (rd.retry about 180 s) starts after udev-trigger.
- `50-juniper-watchdog.conf` is in the initramfs.

- [ ] **Step 1: Failing image tests.** In the existing initramfs loop, change `35` to `40`, and add:

```bash
  lsinitrd "$img" >"$tmp/inv"
  for f in usr/sbin/cryptsetup usr/bin/rpi-fw-crypto usr/bin/age usr/sbin/sfdisk usr/sbin/partx usr/sbin/blkid \
    usr/libexec/juniper/cryptroot usr/libexec/juniper/fwkey \
    usr/lib/systemd/system/juniper-cryptroot-prepare.service usr/lib/systemd/system/juniper-cryptroot-unlock.service \
    sysinit.target.wants/juniper-cryptroot-prepare.service initrd.target.wants/juniper-cryptroot-unlock.service \
    kernel/drivers/md/dm-crypt.ko kernel/drivers/md/dm-mod.ko kernel/crypto/adiantum.ko kernel/crypto/algif_skcipher.ko \
    arch/arm64/crypto/aes-ce-blk.ko; do
    grep -q "$f" "$tmp/inv" || { echo "initramfs lacks $f"; exit 1; }
  done
  # Every command cryptroot/fwkey call resolves inside the unpacked initramfs.
  rm -rf "$tmp/ir"; mkdir "$tmp/ir"; (cd "$tmp/ir" && lsinitrd --unpack "$img" >/dev/null)
  bash -n "$tmp/ir/usr/libexec/juniper/cryptroot"; bash -n "$tmp/ir/usr/libexec/juniper/fwkey"
  for c in cryptsetup rpi-fw-crypto age sfdisk partx blkid mount umount mkdir cat grep sed head tr od cut readlink sync mv sleep basename modprobe; do
    ls "$tmp/ir"/usr/{bin,sbin}/"$c" >/dev/null 2>&1 || { echo "initramfs lacks command $c"; exit 1; }
  done
```

`dm-mod` is `=m`; check the exact path in `modules.dep` and adjust it if the build puts it elsewhere.

- [ ] **Step 2: The module:**

```bash
#!/usr/bin/bash
# Juniper: LUKS2 root bound to the Pi's OTP key (issue #50). Logic: /usr/libexec/juniper/cryptroot.
check() { require_binaries cryptsetup rpi-fw-crypto age sfdisk partx blkid || return 1; return 0; }
depends() { echo dm systemd; }
installkernel() {
  hostonly='' instmods dm_mod dm_crypt af_alg algif_skcipher adiantum chacha_generic chacha-neon \
    nhpoly1305 nhpoly1305-neon poly1305-neon aes-ce-blk aes-ce-cipher aes-neon-bs
}
install() {
  inst_multiple cryptsetup rpi-fw-crypto age sfdisk partx blkid mount umount mkdir cat grep sed \
    head tr od cut readlink sync mv sleep basename modprobe
  inst_simple /usr/libexec/juniper/cryptroot
  inst_simple /usr/libexec/juniper/fwkey
  inst_simple "$moddir/juniper-cryptroot-prepare.service" "$systemdsystemunitdir/juniper-cryptroot-prepare.service"
  inst_simple "$moddir/juniper-cryptroot-unlock.service" "$systemdsystemunitdir/juniper-cryptroot-unlock.service"
  $SYSTEMCTL -q --root "$initdir" add-wants sysinit.target juniper-cryptroot-prepare.service
  $SYSTEMCTL -q --root "$initdir" add-wants initrd.target juniper-cryptroot-unlock.service
}
```

`juniper-cryptroot-prepare.service`:

```ini
[Unit]
Description=Juniper encrypted root: first-boot encryption, resume, recovery sealing
DefaultDependencies=no
# Before udev: on first boot the root filesystem disappears and reappears as LUKS; doing it
# before any device unit exists keeps systemd's root-device handling out of it.
After=systemd-modules-load.service
Before=systemd-udevd.service systemd-udev-trigger.service dracut-pre-udev.service sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/modprobe -a dm_mod dm_crypt
ExecStart=/usr/libexec/juniper/cryptroot prepare
TimeoutStartSec=infinity
StandardOutput=journal+console
StandardError=journal+console
```

`juniper-cryptroot-unlock.service`:

```ini
[Unit]
Description=Juniper encrypted root: unlock with this Pi's key
DefaultDependencies=no
After=systemd-udev-trigger.service systemd-udevd.service juniper-cryptroot-prepare.service
Before=initrd-root-device.target cryptsetup.target sysroot.mount
OnFailure=emergency.target
OnFailureJobMode=replace-irreversibly

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/juniper/cryptroot unlock
TimeoutStartSec=5min
StandardOutput=journal+console
StandardError=journal+console
```

`juniper.encrypt=0` is handled inside `cryptroot`, not by a unit `Condition`. In `90-juniper.conf`:
- add `add_dracutmodules+=" juniper-cryptroot "`;
- rewrite the header's "Kept: … crypt/dm for LUKS" to "crypt/dm are kept for the dm-crypt modules; LUKS unlock is Juniper's own juniper-cryptroot module (the base pulled systemd-cryptsetup in through clevis/tpm2-tss, which we omit)".

- [ ] **Step 3:** Push and read `gh pr checks`; record the new initramfs size. Commit `feat: initramfs module for the encrypted root`.
- [ ] **Step 4 (needs the owner's Pi 5): serial smoke test.**
  1. Build the branch.
  2. Run `just flash` with `encrypt: true` (after Task 8 Step 2), or write `juniper-encrypt` (`on`) and `juniper-recovery.txt` (your `ssh-ed25519` line) onto CIDATA by hand.
  3. Add `console=ttyAMA10,115200` to the entry's `cmdline.txt`, and capture with `stty -F /dev/ttyUSB0 115200 raw -echo; cat /dev/ttyUSB0`.

  Confirm:
  - prepare ran before `systemd-udevd` (`journalctl -b -o short-monotonic -u juniper-cryptroot-prepare -u systemd-udevd`);
  - progress lines appeared, and the conversion finished;
  - unlock opened `juniper-root`;
  - `sysroot.mount` mounted;
  - `CIDATA/juniper-encrypt` says `encrypted`;
  - `/run/juniper/cryptroot` exists.

  **If ordering fails, use the spec's fallback:** end the conversion with `systemctl reboot`, and re-test.

---

### Task 6: Privileged loop-device test of the real scripts (CI) — recommended before the hardware session

**Files:**
- Create: `tests/cryptroot-loop.sh`
- Modify: `Justfile` (`test-cryptroot`), `.github/workflows/build.yml` (a step after `test-image`, `juniper-minimal` only)

**Why:** the unit tests stub cryptsetup. This test runs the image's cryptsetup 2.8.1, sfdisk, age and the real `cryptroot`/`fwkey` against a disk laid out like bib's, decrypting with dm.

**Interfaces:** `just image=juniper-minimal test-cryptroot` runs `sudo podman run --rm --privileged -v /dev:/dev -v ./tests:/tests:ro <image> /tests/cryptroot-loop.sh`, and exits non-zero on any failure. It needs `mkfs.vfat` (dosfstools), `mkfs.xfs`, `openssl` and `ssh-keygen` inside the image. The test checks for each at the start and fails with a clear message. If `mkfs.vfat` is missing, `dnf -y install dosfstools` in the throwaway container.

- [ ] **Step 1: Write the test.** Inside the container:
1. **Disk:**
   - A sparse 10 GiB file with a GPT made by an sfdisk script: p1 1 GiB type ESP (vfat, label `CIDATA`), p2 1 GiB XFS, p3 type `b921b045-1df0-41c3-af44-4c6f280d3fae` holding `mkfs.xfs -m uuid=$U -L root` (`U=66f85224-e922-4b9c-8854-731adda9f5c3`).
   - Make it like bib's by writing the GPT on an 8 GiB file, then `truncate -s 10G`.
   - Write 1 GiB of random files and a `sha256sum` list to p3.
   - `losetup -fP`.
2. **Ids and firmware stub:**
   - `JUNIPER_SYSFS=$W/sys` holds `block/loopN/device/cid` (only the id attribute; topology comes from the real `/sys`, I14).
   - A stub `rpi-fw-crypto` first on `PATH`: HMAC with key `juniper-test` via `openssl dgst -mac HMAC`, the genkey/status behaviours, and every call logged.
   - The cmdline goes in a **file**: `echo "root=UUID=$U" >"$W/cmdline"`, `JUNIPER_CMDLINE=$W/cmdline`.
   - CIDATA gets `juniper-encrypt` = `on` and `juniper-recovery.txt` = a throwaway `ssh-ed25519` key.
3. **Happy path:** run `cryptroot prepare`, then `cryptroot unlock`. Assert:
   - p3 is `crypto_LUKS`, label `juniper-root`;
   - token 0 has `root_uuid=$U`, `recovery=sealed`, `recipients=1`; token 1 is `juniper-recovery`;
   - keyslots are exactly 0 and 1; cipher `aes-xts-plain64`; sector size 512;
   - `/dev/mapper/juniper-root` has XFS UUID `$U`, mounts, and passes `sha256sum -c`;
   - p3 ends at the 10 GiB disk's last usable LBA, and the mapping is p3 minus 16 MiB;
   - `age -d -i key CIDATA/juniper-recovery.age | cryptsetup open --test-passphrase --key-file - p3` works, and so does the same with the token 1 ciphertext;
   - `grep -a` for the board passphrase and for `R` finds nothing in the image file, `/run` or `/tmp`.
4. **Kill points.** On a fresh disk each time, kill prepare with `kill -9` at each point, run prepare again, and assert the happy-path checks:
   1. **C1:** after `--init-only`, before `token import`. Hook: a `cryptsetup` wrapper on `PATH` that `exec`s the real binary but `sleep 30`s before `token import`; kill during the sleep.
   2. Mid-reencrypt: wait until `luksDump` shows `online-reencrypt`, then kill.
   3. **C3/I5:** after `age` wrote `.age.new`, before `luksAddKey`. Kill during a `sleep` hook. The rerun must end with exactly slots 0 and 1.
   4. After `luksAddKey`, before token `sealed`. The rerun must kill and re-add slot 1, still ending with exactly slots 0 and 1.
   5. After the max grow, before the record. The rerun records `encrypted`.
5. **Fail open:**
   - With `rpi-fw-crypto` returning `KEY_LOCKED`, p3 stays plain and **not grown** (ruling 6), `juniper-encrypt` says `not-encrypted:firmware key interface unavailable…`, there is no `genkey` in the log, and a second prepare changes nothing.
   - The same with `juniper-recovery.txt` holding only an `ecdsa-sha2-nistp256` key: `not-encrypted:no usable recovery recipient`, and `fwkey ensure` was never called (I7).
6. **Under tryboot:** with `JUNIPER_TRYBOOT_FLAG` holding big-endian 1 and token 0 `pending`, prepare doesn't touch the header (`luksDump` is identical before and after).
7. **Idempotence:** a second prepare on the encrypted disk changes nothing.
8. **Adiantum:** repeat step 3 with `JUNIPER_CPUINFO` pointing at a file without `aes`.

- [ ] **Step 2:** In CI, after `just test-image`, add `if: matrix.image == 'juniper-minimal'` and `just image=juniper-minimal test-cryptroot`. The runner is `ubuntu-24.04-arm` with sudo. If dm doesn't work inside rootful podman there, run the script on the host with the image's binaries copied out (`podman cp`), and note it in the PR.
- [ ] **Step 3:** Push and read `gh pr checks`. Commit `test: loop-device test of first-boot encryption, kill points and fail-open`.

---

### Task 7: Real-root reporting — state file, MOTD, pi-status, `juniper-metrics`; firstboot keeps the blob

**Files:**
- Create: `system_files/usr/libexec/juniper/encryption-status`, `system_files/usr/lib/systemd/system/juniper-encryption-status.service`
- Modify: `system_files/usr/libexec/juniper/metrics` (I4), `system_files/usr/libexec/juniper/motd`, `system_files/usr/share/juniper/just/pi.just`, `system_files/usr/libexec/juniper/firstboot`, `build_files/build.sh` (enable the unit), `tests/unit.sh`, `tests/image.sh`

**Facts:**
- `juniper-metrics` (#71) already owns `/var/lib/juniper/metrics/juniper.prom`. It rewrites the file atomically every 5 minutes, runs with `set -uo pipefail`, builds its output with `gauge NAME HELP VALUE`, and has the test helper `metrics_env` in `tests/unit.sh` (around line 2425).
- `enable-metrics` already passes `--collector.textfile.directory=/host/var/lib/juniper/metrics`, so no change is needed there.

**Interfaces:**
- `encryption-status` is a oneshot (`After=local-fs.target`, `Before=juniper-healthcheck.service juniper-metrics.service`). It writes **only** `/var/lib/juniper/encryption`:
  - from `/run/juniper/cryptroot`;
  - checked against the live device: `lsblk -no TYPE -s "$(findmnt -no SOURCE /sysroot)"` includes `crypt`;
  - with no `/run` file, it reads the CIDATA marker (via `cidata-device`, mounted read-only) to tell `flashed before encryption support` (no marker) from `prepare did not run` (marker present).
- `encryption-status --print` prints the `pi-status` line.
- `metrics` reads `/var/lib/juniper/encryption` (overridable as `$state_dir/encryption`) and adds three gauges. If the file is missing, `juniper_encrypted 0` is still emitted, so alerts fire:

```bash
enc=$state_dir/encryption
ev() { sed -n "s/^$1=//p" "$enc" 2>/dev/null | head -1; }
v=0; [[ $(ev state) == encrypted ]] && v=1
gauge juniper_encrypted "1 if the root filesystem is on LUKS2 (dm-crypt), else 0." "$v"
v=0; [[ $(ev key_lock) == locked ]] && v=1
gauge juniper_encryption_key_locked "1 if the firmware HMAC is locked after unlock (needs Pi 5 EEPROM >= 2026-06-17)." "$v"
v=0; [[ $(ev recovery) == sealed:* ]] && v=1
gauge juniper_encryption_recovery_sealed "1 if an age-sealed recovery keyslot exists." "$v"
```

- MOTD Warning rows (strip non-printables from `reason`):
  - when `state=not-encrypted`: `Storage NOT ENCRYPTED (<reason>): anyone holding this card can read its secrets. Reflash to encrypt.` in bold red;
  - when encrypted and `recovery` isn't `sealed:*` (C3): `Storage recovery key not sealed (<recovery>): only this Pi can unlock this card.`
- `pi-status`: `@/usr/libexec/juniper/encryption-status --print`. The lines are:
  - `Storage: encrypted (LUKS2 <cipher>, bound to this Pi and card; key lock: <key_lock>; recovery: sealed to <n> keys)`;
  - with `binding=board`: `…, bound to this Pi only (USB disk has no serial; a clone unlocks on this Pi); …`;
  - `Storage: NOT ENCRYPTED (<reason>). Reflash to encrypt.`
- `firstboot`: after the scrub, copy CIDATA's `juniper-recovery.age` to `/var/lib/juniper/recovery.age` (0644), if present. Its shred list is unchanged.

- [ ] **Step 1: Failing unit tests:**
  - `test_encryption_status_encrypted`;
  - `test_encryption_status_live_device_wins` (the `/run` file says encrypted but `lsblk` says part, giving `not-encrypted`, reason `root is not on dm-crypt`);
  - `test_encryption_status_legacy_device`;
  - `test_encryption_status_prepare_missing`;
  - `test_metrics_encryption_gauges` (with `metrics_env`: encrypted, locked=0, sealed=1; then no file, giving `juniper_encrypted 0`);
  - `test_metrics_keeps_existing_series` (image info still present);
  - `test_motd_warns_not_encrypted`;
  - `test_motd_warns_recovery_unsealed`;
  - `test_pi_status_board_only_wording`;
  - `test_firstboot_keeps_and_copies_recovery`.
- [ ] **Step 2:** Implement. Image tests: the unit is enabled, and `/usr/libexec/juniper/encryption-status` is executable.
- [ ] **Step 3:** Commit `feat: report encryption state in the MOTD, pi-status and metrics`.

---

### Task 8: `just flash` — `encrypt`, `recovery_key` (default off). **Steps 1–2 (render-cidata) are on the critical path**

**Files:**
- Modify: `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml`, `tests/unit.sh`

**Facts (F9):** age refuses `ecdsa-sha2-*` and `sk-*` recipients. `ssh-ed25519` and `ssh-rsa` work. `render-cidata`'s `KEY_PREFIXES` accepts all four kinds for login.

**Interfaces:**
- `render-cidata` adds `encrypt` and `recovery_key` to `KEYS`:
  - `encrypt` must be a YAML **boolean** (`true`/`false`; YAML 1.1 also reads unquoted `yes`/`no` as booleans). A string such as `"yes"` or `"maybe"` fails with `encrypt: true or false`. The **default is `False`** in this task (Task 14 flips it).
  - `recovery_key` must match `^age1[02-9ac-hj-np-z]{58}$`. A value starting `AGE-SECRET-KEY-1` fails with `recovery_key: that's an age private key; use its public key (age1...)`.
- Recipients are `[recovery_key]` if set, else the `ssh_keys` that start with `ssh-ed25519 ` or `ssh-rsa `.
- It writes to OUTDIR:
  - `juniper-encrypt`: `on` or `off`, mode 0644;
  - with `on`, `juniper-recovery.txt`: one recipient per line, mode 0644.
  - **An explicit `encrypt: true` with no recipients fails:** `encrypt: no recovery recipient: age can't encrypt to ecdsa or FIDO (sk-) SSH keys; add an ssh-ed25519 or ssh-rsa key to ssh_keys, or set recovery_key: age1...`.
- `flash.sh --write` copies `juniper-encrypt` and, if present, `juniper-recovery.txt` to CIDATA.
- The `flash.sh` summary gains `Encrypt:   yes (recovery: <n> SSH keys: <fingerprints>)` (fingerprints via `ssh-keygen -lf -`), `yes (recovery: age key age1…<last 6>)`, or `no (encrypt: false)` / `no (not requested)`. With `on`, it prints the spec's warning line exactly, just before `read -rp "Erase everything…"`.

- [ ] **Step 1: Failing unit tests:**
  - `test_render_cidata_encrypt_default_off`;
  - `test_render_cidata_encrypt_on_uses_ssh_recipients` (ed25519 + ecdsa + sk keys → only the ed25519 line);
  - `test_render_cidata_recovery_key_overrides`;
  - `test_render_cidata_encrypt_refuses_without_recipient`;
  - `test_render_cidata_rejects_bad_recovery_key` (`age1short`, and `AGE-SECRET-KEY-1…` with its specific message);
  - `test_render_cidata_encrypt_must_be_bool` (`encrypt: "yes"` and `encrypt: maybe` fail; `encrypt: true` and an unquoted `encrypt: yes` pass);
  - `test_flash_summary_and_warning` (factor the summary into `flash.sh --summary-only CONFIG CIDATA-DIR`).
- [ ] **Step 2 (critical path):** implement `render-cidata` and `examples/flash.yaml` (commented `encrypt:` and `recovery_key:`). The comments say:
  - your SSH key **file** is the recovery key;
  - FIDO/ECDSA keys can't be recipients;
  - an agent-only key can't decrypt.

  Commit `feat: render-cidata can request first-boot encryption (opt-in)`.
- [ ] **Step 3:** `flash.sh` summary, warning and copy. Commit `feat: just flash shows and writes the encryption request`.

---

### Task 9: Laptop-side recovery — `just unlock-card`

**Files:**
- Create: `disk/unlock-card`
- Modify: `Justfile`, `tests/unit.sh`

**Interfaces:** `just unlock-card DEVICE [IDENTITY]`, and `just unlock-card --close`.
1. `check-target DEVICE` refuses system disks.
2. Find the `juniper-root` partition (`lsblk -nrpo PATH,LABEL DEVICE`) and CIDATA.
3. Get the ciphertext, first that works:
   1. CIDATA mounted read-only via `udisksctl mount -b … -o ro`, file `juniper-recovery.age`;
   2. `run0 cryptsetup token export --token-id 1 PART`, taking the `age` field (`jq -r .age`; jq is available on the laptop) (I10).
4. Identity: the given one, else `~/.ssh/id_ed25519`, then `~/.ssh/id_rsa`.
5. `age -d -i IDENTITY <ciphertext> | run0 cryptsetup open --readonly --key-file - PART juniper-recovered`. If `run0` can't take piped stdin together with a polkit prompt, fall back to `sudo`; verify both in the step.
6. `run0 mount -o ro /dev/mapper/juniper-recovered /run/media/$USER/juniper-recovered`, then print the path and `--close`.

The passphrase only moves through the pipe.

- [ ] Tests with stubs (`lsblk`, `udisksctl`, `age`, `run0`, `cryptsetup`, `mount`):
  - pipe order and `--readonly`;
  - the token fallback when the CIDATA file is missing;
  - refusal of non-removable disks;
  - the error when neither copy exists: `no recovery data on this card (not encrypted, or both copies lost)`;
  - nothing under `$T` contains the passphrase.

  Commit `feat: just unlock-card, recover an encrypted card on a laptop`.

---

### Task 10: Re-bind — **deferred to #76** (ruling 5)

This is not part of the implementation PR. The spec's Recovery table says "not in v1". The unlock console hint mentions only `just unlock-card`.

---

### Task 11: `ujust switch` refuses images that can't unlock this root

**Files:**
- Modify: `Containerfile` (`LABEL org.juniper.cryptroot="v1"` in the `minimal` stage; `juniper` and `juniper-desktop` inherit it), `system_files/usr/libexec/juniper/switch-image`, `tests/unit.sh`, `.github/workflows/build.yml` (label check)

**Interfaces:**
- If `lsblk -no TYPE -s "$(findmnt -no SOURCE /sysroot)"` includes `crypt`, and `skopeo inspect --no-tags docker://IMAGE` lacks `.Labels["org.juniper.cryptroot"] == "v1"`, print `IMAGE can't unlock this encrypted root (no org.juniper.cryptroot label); tryboot would fall back anyway. Use --force to try.` and exit 1.
- **Check that `skopeo` is in the image** (`rpm -q skopeo`). If it isn't, use `podman image inspect` after a `podman pull`, or add `skopeo` to `build.sh`.

- [ ] Tests (stub `skopeo`/`lsblk`/`findmnt`): refuses without the label on an encrypted root; allows with it; plain roots are unaffected. CI: after the build, `podman image inspect … | jq -e '.[0].Labels["org.juniper.cryptroot"] == "v1"'`. Commit `feat: switch refuses images without encrypted-root support`.

---

### Task 12 (optional; can follow): `ujust recovery-reseal`

**Files:**
- Modify: `system_files/usr/share/juniper/just/pi.just`, `system_files/usr/libexec/juniper/cryptroot`, `tests/unit.sh`, `tests/cryptroot-loop.sh`

**Interfaces:**
- `ujust recovery-reseal` reads the new recipients (SSH public keys filtered as in Task 8, or `age1…`), validates them with `age -R - -o /dev/null </dev/null`, writes `CIDATA/juniper-reseal.txt`, and asks for a reboot.
- On a **confirmed** boot (not tryboot, I9), `cryptroot prepare` sees the request and:
  1. makes `R'` and runs `age` on it to `.age.new`;
  2. `luksKillSlot 1`, then `luksAddKey --key-slot 1`, authorised by the board passphrase (fixed slot 1, I5);
  3. replaces token 1 and the file;
  4. sets token 0 `recipients`, and removes the request.

  It reuses Task 4's seal helper.

- [ ] Tests mirror Task 4's seal tests, plus a loop-test kill point between `luksKillSlot` and `luksAddKey`. The board slot keeps the card unlockable, and the next boot completes the re-seal. Commit `feat: ujust recovery-reseal`.

---

### Task 12b: Docs

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `docs/upstream.md`, `docs/superpowers/STATUS.md`

- [ ] **README "Encryption at rest":**
  - what is protected (the spec's threat table, shortened), and that it is opt-in for now;
  - what first boot does;
  - the OTP write ("permanent; Raspberry Pi tools reuse this key rather than replace it; secure boot later can still use it");
  - the limitations: stolen board, evil maid, remote root can derive the key (ruling 4), USB disks without a serial are board-only (ruling 1), an SD card in a USB reader binds to the reader;
  - recovery with `just unlock-card` (re-bind is #76);
  - SSH key custody (a file, not an agent; or `recovery_key:`);
  - the warning about `rpi-otp-private-key -w -f`;
  - the alert `juniper_encrypted == 0 or juniper_encryption_recovery_sealed == 0`.
- [ ] **CHANGELOG** (Unreleased):
  - Added: opt-in encryption at rest (`encrypt: true`), `just unlock-card`, encryption metrics.
  - Changed: `lock_device_private_key=1`.

  Don't mention growpart: it is unchanged for plain cards.
- [ ] **docs/upstream.md:**
  - AlmaLinux RPi SIG: package `rpi-fw-crypto` for EL10, and ship `rpi-eeprom-firmware` 2026-06-17 or later (per-operation locks);
  - bootc-image-builder: identical filesystem UUIDs on every card of a release (F3).
- [ ] **STATUS.md:** sub-project C → "implementing (opt-in); hardware run pending".

  Commit `docs: encryption at rest (opt-in)`.

---

### Task 13 (needs the owner's Pi 5; then a Pi 4): Hardware acceptance

Run the spec's "Hardware test plan" steps 0–10 on a build of the merged implementation PR. Record the results in `docs/acceptance.md`: first-boot duration for each card, `cryptsetup status`, `get-key-status` before and after, the pull-the-plug result, `fio` numbers.

This run must settle:
1. that before-udev ordering works (Task 5 Step 4 has shown it already);
2. `genkey` on a blank board, or "existing key reused" and the key-usage value;
3. that `set-key-status` reports `unavailable` on EEPROM 2026-05-11 (ruling 4) and doesn't fail the boot;
4. that cloud-init `growpart` on the LUKS root reports NOCHANGE and the XFS still grows through `resizefs` (I1);
5. first-boot time. Above about 15 minutes, consider a smaller bib `minsize` for root (1.56 GiB of 6 GiB is used);
6. Pi 4: the `start4.elf` key interface (F5) and Adiantum throughput.

- [ ] If everything passes: README Tested hardware → "encryption ✅ tested <date> (Pi 5 / microSD)".

---

### Task 14 (after Task 13; separate small PR): Encrypt by default

**Files:**
- Modify: `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml`, `README.md`, `CHANGELOG.md`, `tests/unit.sh`

- [ ] `encrypt` defaults to `True`.
- [ ] **Default-on with no usable recipient** writes `juniper-encrypt` = `off`, the summary shows `Encrypt:   no (no usable recovery recipient: …)`, and it warns (ruling 3). An explicit `encrypt: true` still refuses.
- [ ] The warning line prints on every encrypting run. `encrypt: false` shows `Encrypt:   no (encrypt: false)`.
- [ ] Rename the default-off test to `…_default_on`, and add `test_render_cidata_default_on_without_recipient_writes_off`.
- [ ] README: "on by default; `encrypt: false` to skip".
- [ ] PR title `feat: encrypt new cards by default`.
