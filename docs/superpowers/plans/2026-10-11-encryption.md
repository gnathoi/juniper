# Encryption at Rest Implementation Plan (issue #50 Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On first boot, a card flashed with `encrypt: true` encrypts its root partition in place with LUKS2. The key is derived from the Pi's OTP device key (through `rpi-fw-crypto`) plus the card's serial, and an age-sealed recovery keyslot goes to the owner's SSH keys. The device unlocks unattended on every boot, falls back through tryboot as today, and fails open (boots plain, with loud warnings) when anything in that path can't run. Encryption ships **gated off** (`encrypt: true` to opt in) until the owner's Pi 5 run passes; then a small PR flips the default.

**Architecture:** A Juniper dracut module, `90juniper-cryptroot`, adds two initramfs units:
- `juniper-cryptroot-prepare.service` runs **before udev**. It handles first-boot conversion, resume after power loss, offline keyslot work (recovery, re-bind, re-seal) and growing the partition.
- `juniper-cryptroot-unlock.service` runs **after udev**. It opens `/dev/mapper/juniper-root` and then locks the firmware key.

The logic lives in two unit-tested bash scripts in `/usr/libexec/juniper/`:
- `fwkey` wraps `rpi-fw-crypto`: probe, genkey only when the slot is blank, derive, lock, card id.
- `cryptroot` does the decisions, cryptsetup, sfdisk, age and state.

The kernel command line doesn't change (`root=UUID=` of the inner XFS). Other parts:
- a wrapper gives rpi-bootc-bootloader the right `MNTDEV`;
- `rpi-fw-crypto` is built in a Containerfile stage from a pinned upstream commit; `age` comes from EPEL;
- `just flash` writes `juniper-encrypt` and `juniper-recovery.txt` to CIDATA;
- reporting goes to `/var/lib/juniper/encryption`, the MOTD, `pi-status` and a node_exporter textfile.

**Tech Stack:** bootc/Containerfile on AlmaLinux 10 aarch64, dracut 107 (systemd initramfs), cryptsetup 2.8.1 (LUKS2 offline reencryption), raspberrypi/utils `rpifwcrypto`, age 1.3 (EPEL 10), bash, Python 3 (`render-cidata`), systemd units, the repo's `tests/unit.sh` (stubbed bash tests) and `tests/image.sh` (runs inside the built image in CI), and a new privileged loop-device test run in CI.

**Spec:** `docs/superpowers/specs/2026-10-11-encryption-design.md`. Read it first, especially "Spike findings" B1–B4 and F1–F10, which this plan cites inline.

## Global Constraints

- Owner decisions (spec):
  - stolen **card** only;
  - board OTP key plus card serial;
  - age recovery to the `flash.yaml` SSH keys (or `recovery_key:`);
  - fail open with NOT ENCRYPTED in the MOTD, `pi-status` and `juniper_encrypted 0`;
  - Pi 5 first, Pi 4 best-effort;
  - reflash only;
  - default **off** until Task 13 passes, then Task 14 flips it.
- **Key rules:**
  - Key id 1.
  - Probe with `hmac` on `juniper.probe.v1`. `genkey --key-id 1 --alg ec` **only** on `KEY_NOT_SET` (error 6).
  - Never `privkey`, `rpi-otp-private-key` or `vcmailbox 0x00030081`.
  - Never `set-key-usage`.
  - After unlock, one call: `set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED`. SIGN stays unlocked.
  - `lock_device_private_key=1` in the per-deployment `rpi-config.txt`. Never `lock_device_key_write=1`.
- **Derivation:** `msg = "juniper.luks.root.v1" 0x00 "<type>:<id>"`, passphrase = lowercase hex of the HMAC (64 characters). Card ids:
  - `mmc:` + `/sys/block/<disk>/device/cid`;
  - `nvme:` + `device/serial`, trimmed;
  - `usb:` + `idVendor:idProduct:serial`, where an empty serial fails open.
- **LUKS2 parameters:**
  - `--type luks2 --sector-size 512 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --label juniper-root`;
  - `aes-xts-plain64` with `--key-size 512` when `/proc/cpuinfo` lists `aes`, else `xchacha12,aes-adiantum-plain64` with `--key-size 256`;
  - `--reduce-device-size 32M`;
  - open with `--allow-discards`, mapper name `juniper-root`;
  - token type `juniper` carrying `root_uuid`, `binding`, `id_type`, `board_slot`, `recovery_slot` and `recovery` (`pending`|`sealed`).
- **Secrets never touch a disk.** The board passphrase and the recovery passphrase move only through pipes and `/dev/fd/N`. No temporary key files, not even in the initramfs.
- **Fail open is final.** A first boot that doesn't encrypt records `not-encrypted:<reason>` in `CIDATA/juniper-encrypt` and never retries.
- The headless images keep their behaviour when `encrypt` isn't set. These shared changes must be harmless on plain devices:
  - the `MNTDEV` wrapper;
  - `lock_device_private_key=1`;
  - growing the partition in the initramfs;
  - the reporting.

  The image tests verify all of them.
- Every commit subject and PR title starts with a conventional prefix (`feat:`, `fix:`, `docs:`, `ci:`, `test:`, `build:`, …). Merges are squash merges. Commit messages end with the session's `Co-Authored-By`/`Claude-Session` lines.
- `pre-commit run --all-files` and `tests/unit.sh` pass before every push. arm64 image checks run in CI: read `gh pr checks`.

## Review Focus

1. **The plaintext of either secret on any disk,** the FAT partition included. Test with `grep -r` over every test directory after each scenario (Tasks 3, 4, 6).
2. **An irreversible OTP write in the wrong case.** `genkey` must run only on `KEY_NOT_SET`, never on `KEY_LOCKED`, an unknown error or a missing `/dev/vcio`, and never when `encrypt` is off (Tasks 3, 4).
3. **Power loss at every step of first boot:**
   - after the header but before the token;
   - mid-reencrypt;
   - after the recovery keyslot but before `juniper-recovery.age`;
   - between growing the partition and recording the state.

   Each case must converge on the next boot (Task 6 runs them for real).
4. **A device that can't unlock** must fall back under tryboot and must not reboot in a tight loop otherwise (Task 5).
5. **The bootloader sync on a `/dev/mapper` root.** Without Task 1 every update silently stops reaching the firmware (B3).

---

## File structure

| Path | Responsibility | Task |
|---|---|---|
| `system_files/usr/libexec/juniper/bootloader` | `MNTDEV=$(cidata-device)` wrapper around rpi-bootc-bootloader | 1 |
| `system_files/usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf` | `ExecStop` uses the wrapper | 1 |
| `system_files/usr/libexec/juniper/healthcheck`, `apply-update` | call the wrapper | 1 |
| `Containerfile`, `build_files/fwcrypto.lock`, `build_files/fwcrypto.sh`, `Justfile` (`bump-fwcrypto`) | build `rpi-fw-crypto` from a pinned commit | 2 |
| `build_files/build.sh` | install `rpi-fw-crypto`, `age`; dracut config | 2, 5 |
| `system_files/usr/share/juniper/rpi-config.txt` | `lock_device_private_key=1` | 2 |
| `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf` | `early_microcode="no"`, `add_dracutmodules+=" juniper-cryptroot "` | 2, 5 |
| `THIRD_PARTY.md`, `/usr/share/licenses/rpi-fw-crypto/LICENCE` | BSD-3-Clause of raspberrypi/utils | 2 |
| `system_files/usr/libexec/juniper/fwkey` | key probe/ensure/derive/lock/card-id | 3 |
| `system_files/usr/libexec/juniper/cryptroot` | `prepare` and `unlock` logic | 4 |
| `system_files/usr/lib/dracut/modules.d/90juniper-cryptroot/{module-setup.sh,juniper-cryptroot-prepare.service,juniper-cryptroot-unlock.service}` | initramfs integration | 5 |
| `system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg` | `growpart: mode: off` | 4, 7 |
| `tests/cryptroot-loop.sh`, `.github/workflows/build.yml` | privileged loop-device test inside the built image | 6 |
| `system_files/usr/libexec/juniper/encryption-status`, `.../juniper-encryption-status.service` | state file and metrics | 7 |
| `system_files/usr/libexec/juniper/motd`, `.../just/pi.just`, `.../just/services.just` | reporting | 7 |
| `system_files/usr/libexec/juniper/firstboot` | keep `juniper-recovery.*`; copy the blob to `/var/lib/juniper` | 7 |
| `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml` | `encrypt`, `recovery_key`, CIDATA files, summary, warning | 8 |
| `Justfile` (`unlock-card`), `disk/unlock-card` | laptop-side recovery | 9 |
| `Justfile` (`rebind-card`), `disk/rebind-card`, `cryptroot` (rebind) | move to a new board or card | 10 (optional) |
| `system_files/usr/libexec/juniper/switch-image`, `Containerfile` `LABEL` | refuse images without the hook | 11 |
| `system_files/usr/share/juniper/just/pi.just` (`recovery-reseal`), `cryptroot` (reseal) | rotate recovery recipients | 12 (optional) |
| `README.md`, `CHANGELOG.md`, `docs/upstream.md`, `docs/superpowers/STATUS.md`, `docs/acceptance.md` | docs | 12b, 13 |
| `tests/unit.sh`, `tests/image.sh` | tests | every task |

Unit-test conventions (read `tests/unit.sh` first):
- each `test_*` gets a fresh `$T`;
- `stub NAME BODY` puts a logging fake on `PATH`;
- `check "label" CMD…` asserts, with the `called`/`not_called`/`fails`/`stderr_has` helpers.

Scripts take `JUNIPER_*` environment overrides for every path (`/proc/cmdline`, `/sys`, `/dev`, CIDATA mount, `/run/juniper`), so tests never touch the host. `tests/image.sh` runs inside each built image in CI. arm64 images can't be built on the x86 laptop, so image-level checks are verified through `gh pr checks`.

Suggested PR split:
- **PR 1** = Task 1 (`fix:`). It is independently valuable.
- **PR 2** = Tasks 2–9, 11 and 12b (`feat:`, default off).
- **PR 3** = Task 10 and/or 12 if deferred.
- **PR 4** = Task 14 after Task 13.

---

### Task 1: rpi-bootc-bootloader gets `MNTDEV` from `cidata-device` (B3)

**Files:**
- Create: `system_files/usr/libexec/juniper/bootloader`, `system_files/usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf`
- Modify: `system_files/usr/libexec/juniper/healthcheck` (line 162), `system_files/usr/libexec/juniper/apply-update` (line 55), `tests/unit.sh`, `tests/image.sh`, `docs/upstream.md`

**Spike finding inline:** `rpi-bootc-bootloader` v0.0.8 (lines 214–225 and 346–372) runs `MNTDEV=$(mount | awk '$3=="/sysroot"{print $1}' | sed -E 's/[0-9]+$/1/')`. For `/dev/mapper/juniper-root` that names the root device itself:
- `finalize-staged` mounts the root XFS at `/tmp/mnt`, finds no `config-bootc-default.txt`, sets `RPI_ENABLED=false` and **skips the sync silently**;
- `sync` writes the firmware configs into the root filesystem.

The package's drop-in `ostree-finalize-staged.service.d/rpi-bootc-bootloader.conf` sets `ExecStop=/usr/bin/rpi-bootc-bootloader finalize-staged`.

**Interfaces:** Produces `/usr/libexec/juniper/bootloader ARGS…`, which behaves like `rpi-bootc-bootloader ARGS…` with `MNTDEV` set. It fails (exit 1, message) if `cidata-device` fails, rather than letting the script guess.

- [ ] **Step 1: Write the failing unit tests**

```bash
test_bootloader_wrapper_sets_mntdev() {
  stub cidata-device 'echo /dev/mmcblk0p1'
  stub rpi-bootc-bootloader 'echo "MNTDEV=$MNTDEV" >>"$CALLS"'
  JUNIPER_CIDATA_DEVICE=$T/bin/cidata-device "$LIBEXEC/bootloader" sync
  check "bootloader: passes args" called "rpi-bootc-bootloader sync"
  check "bootloader: MNTDEV from cidata-device" called "MNTDEV=/dev/mmcblk0p1"
}

test_bootloader_wrapper_fails_without_cidata() {
  stub cidata-device 'exit 1'
  check "bootloader: no CIDATA, no guess" fails env JUNIPER_CIDATA_DEVICE=$T/bin/cidata-device "$LIBEXEC/bootloader" sync
  check "bootloader: script not run" not_called "rpi-bootc-bootloader"
}

test_finalize_dropin_uses_wrapper() {
  local d=$ROOT/system_files/usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf
  check "finalize drop-in: resets ExecStop" grep -qx 'ExecStop=' "$d"
  check "finalize drop-in: wrapper" grep -qx 'ExecStop=/usr/libexec/juniper/bootloader finalize-staged' "$d"
}
```

Also update the existing healthcheck and apply-update tests so they expect `bootloader sync` / `bootloader tryreboot` (stub `bootloader` via `JUNIPER_BOOTLOADER`, default `/usr/libexec/juniper/bootloader`).

- [ ] **Step 2: Implement**

```bash
#!/usr/bin/env bash
# rpi-bootc-bootloader with the FAT partition named explicitly. Its own guess rewrites the
# /sysroot device name (sed 's/[0-9]+$/1/'), which names the root itself when root is on
# /dev/mapper (LUKS): finalize-staged then silently skips the sync. cidata-device walks
# partition/LUKS/LVM layers to the boot disk's CIDATA.
set -euo pipefail
MNTDEV=$("${JUNIPER_CIDATA_DEVICE:-/usr/libexec/juniper/cidata-device}") || {
  echo "bootloader: can't find this disk's CIDATA partition; not touching the firmware config" >&2
  exit 1
}
export MNTDEV
exec rpi-bootc-bootloader "$@"
```

`zz-juniper.conf` (it sorts after the package's `rpi-bootc-bootloader.conf`):

```ini
[Service]
ExecStop=
ExecStop=/usr/libexec/juniper/bootloader finalize-staged
```

`healthcheck`: `"${JUNIPER_BOOTLOADER:-/usr/libexec/juniper/bootloader}" sync`. `apply-update`: `exec "${JUNIPER_BOOTLOADER:-…}" tryreboot`. `tryreboot` doesn't mount, but use the wrapper anyway for consistency.

- [ ] **Step 3: Image test.** In `tests/image.sh` (shared section):

```bash
test -x /usr/libexec/juniper/bootloader
systemctl cat ostree-finalize-staged.service | grep -qx 'ExecStop=/usr/libexec/juniper/bootloader finalize-staged'
```

- [ ] **Step 4:** In `docs/upstream.md` under rpi-bootc-bootloader, change the LUKS bullet from "fails" to "Juniper wraps it (#PR)". Run `tests/unit.sh` and pre-commit, then commit `fix: give rpi-bootc-bootloader the boot disk's FAT partition explicitly`.
- [ ] **Step 5 (needs the owner's Pi, any image):** after merge, run one `ujust update` on the Pi 5. Check that `rpi-bootc-log.txt` on CIDATA is fresh and that `tryboot.txt` names the new entry. No behaviour change is expected on a plain root.

---

### Task 2: Build `rpi-fw-crypto`; ship `age`; lock raw key reads; trim the initramfs (B2, F2, F7)

**Files:**
- Create: `build_files/fwcrypto.lock`, `build_files/fwcrypto.sh`
- Modify: `Containerfile`, `build_files/build.sh`, `Justfile`, `system_files/usr/share/juniper/rpi-config.txt`, `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf`, `THIRD_PARTY.md`, `tests/image.sh`

**Spike findings inline:**
- `rpi-fw-crypto` isn't in AlmaLinux 10 `raspberrypi`, EPEL 10, or any maintained EL10 COPR.
- `raspberrypi/utils` `rpifwcrypto/` was last changed at `61371fa` (2026-06-17). It is two C files plus CMake, and `find_package(GnuTLS REQUIRED)`.
- The README's "at least version 3.10" is CMake's minimum. EL10's gnutls 3.8.10 is fine, and gnutls is only used to SHA-256 a file in `sign`.
- `librpifwcrypto` opens `/dev/vcio_crypto`, then `/dev/vcio`. The kernel has `BCM_VCIO=y`, so `/dev/vcio` exists.
- `age-1.3.1` is in EPEL 10.
- The initramfs early cpio carries x86 `AuthenticAMD.bin` because `01-dist.conf` sets `early_microcode="yes"`.

**Interfaces:** Produces:
- `/usr/bin/rpi-fw-crypto` and `/usr/lib64/librpifwcrypto.so.0*` in every image;
- `/usr/bin/age`;
- `lock_device_private_key=1` in every `/usr/lib/modules/*/rpi-config.txt`;
- `just bump-fwcrypto`.

- [ ] **Step 1: Failing image tests** (shared section of `tests/image.sh`):

```bash
need_cmds rpi-fw-crypto age cryptsetup sfdisk partx
ldd /usr/bin/rpi-fw-crypto | grep -q 'librpifwcrypto.so.0 => /usr/lib64/'
rpi-fw-crypto 2>&1 | grep -q 'hmac --in'          # usage text; no mailbox needed
test -s /usr/share/licenses/rpi-fw-crypto/LICENCE
for kdir in /usr/lib/modules/*/; do
  grep -qx 'lock_device_private_key=1' "$kdir/rpi-config.txt"
  if grep -q 'lock_device_key_write' "$kdir/rpi-config.txt"; then
    echo "lock_device_key_write would make genkey fail"; exit 1
  fi
done
if lsinitrd /usr/lib/modules/*/initramfs.img | grep -q 'kernel/x86/microcode'; then
  echo "x86 microcode in the arm64 initramfs"; exit 1
fi
```

- [ ] **Step 2: Pinned source.** Create `build_files/fwcrypto.lock`:

```
# raspberrypi/utils, rpifwcrypto/ only. Bump with `just bump-fwcrypto` (prints the diff of rpifwcrypto/).
commit=61371fa…            # full 40-character SHA of the commit
sha256=…                   # of https://codeload.github.com/raspberrypi/utils/tar.gz/<commit>
```

`just bump-fwcrypto`:
- resolves `master`'s latest commit touching `rpifwcrypto/` through the GitHub API;
- downloads the tarball and computes its SHA-256;
- prints `git diff` of `rpifwcrypto/` between the old and new commits (from two extracted tarballs);
- rewrites the lock.

- [ ] **Step 3: Builder stage.** In the `Containerfile`, add a stage before `minimal` on the **same base digest**, so glibc and gnutls match:

```dockerfile
FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b3612… AS fwcrypto
COPY build_files/fwcrypto.lock build_files/fwcrypto.sh /
RUN /fwcrypto.sh
```

`build_files/fwcrypto.sh`:
1. `dnf -y install gcc cmake gnutls-devel`.
2. Download the pinned tarball and check its SHA-256 against the lock (fail closed).
3. `cmake -S utils-<commit>/rpifwcrypto -B /b -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib64 -DCMAKE_BUILD_TYPE=Release`, then `cmake --build /b`, then `DESTDIR=/out cmake --install /b`.
4. Copy the repo `LICENCE` to `/out/usr/share/licenses/rpi-fw-crypto/LICENCE`.

In the `minimal` stage's `RUN`, add `--mount=type=bind,from=fwcrypto,source=/out,target=/fwcrypto`. In `build.sh`, after the packages and **before** the dracut loop:

```bash
cp -a /fwcrypto/usr/. /usr/
dnf -y install age            # EPEL (key pinned above); only /usr/bin/age is used
```

and add `/usr/bin/rpi-fw-crypto /usr/lib64/librpifwcrypto.so*` to the `tag juniper` layer list.

- [ ] **Step 4:** Append `lock_device_private_key=1` to `system_files/usr/share/juniper/rpi-config.txt`, with the comment `# Firmware refuses raw reads of the OTP device key (rpi-fw-crypto privkey); HMAC/sign still work.` Add `early_microcode="no"` to `90-juniper.conf`, with the comment `# dracut puts x86 AMD microcode in the early cpio otherwise (0.3 MB).` Add a `THIRD_PARTY.md` row: raspberrypi/utils rpifwcrypto, BSD-3-Clause, source URL plus the pinned commit.
- [ ] **Step 5:** Push and read `gh pr checks` (the arm64 build and `tests/image.sh`). Record the initramfs size in the PR body (expected about 28.4 MB, before Task 5 adds anything). Commit `build: rpi-fw-crypto from a pinned upstream commit, age, raw OTP key reads locked`.

---

### Task 3: `fwkey` — probe, ensure, derive, lock, card id

**Files:**
- Create: `system_files/usr/libexec/juniper/fwkey`
- Modify: `tests/unit.sh`

**Spike findings inline:**
- `rpi-fw-crypto` exits with `-last_error` (so `KEY_NOT_SET` = 6 exits 250) and prints `Last crypto error: N (…)` on stderr. Parse that line.
- Error codes (`rpifwcrypto.h`): 3 `KEY_NOT_FOUND`, 4 `KEY_LOCKED`, 5 `KEY_OTP_ERROR`, 6 `KEY_NOT_SET`, 7 `KEY_INVALID`, 8 `NOT_SUPPORTED`, 10 `KEY_NOT_BLANK`.
- `hmac --in FILE` accepts `/dev/stdin` and allows at most 2048 bytes. `--outform hex` prints 64 hex characters.
- `get-key-status` prints `Key 1 status: 0x%08x (…)`, with `HMAC_LOCKED` = bit 11.

**Interfaces:**

| Command | Output | Exit |
|---|---|---|
| `fwkey probe` | `ok`, `not-set`, `locked` or `unavailable:<text>` | 0 |
| `fwkey ensure` | `ok` (existing), `generated` or `unavailable:<text>`. Runs `genkey` **only** after `probe` says `not-set`, then probes again | 0 if a key is usable, else 1 |
| `fwkey card-id DISK` (for example `mmcblk0`) | `mmc:<cid>`, `nvme:<serial>` or `usb:<vid>:<pid>:<serial>` | 1 if there is no id |
| `fwkey derive DISK` | 64 lowercase hex characters on stdout (the passphrase) | 1 on any failure; nothing printed |
| `fwkey lock` | `locked` or `unavailable` | 0 |

Environment: `JUNIPER_SYSFS` (default `/sys`), `JUNIPER_VCIO` (default `/dev/vcio`), `RPI_FW_CRYPTO` (default `rpi-fw-crypto`).

- [ ] **Step 1: Failing unit tests.** Use a stub `rpi-fw-crypto` driven by `$T/fw.mode` (`ok`|`not-set`|`locked`|`novcio`|`gen-fails`). For `hmac` the stub computes `openssl dgst -sha256 -mac HMAC -macopt key:juniper-test` over stdin and saves the exact input bytes to `$T/hmac.in`.

```bash
fwkey_env() {
  export JUNIPER_SYSFS=$T/sys JUNIPER_VCIO=$T/vcio
  : >"$JUNIPER_VCIO"
  mkdir -p "$T/sys/block/mmcblk0/device"
  echo 0353445344333247803a1b2c3d014e00 >"$T/sys/block/mmcblk0/device/cid"
  # shellcheck disable=SC2016
  stub rpi-fw-crypto 'mode=$(cat "$T/fw.mode" 2>/dev/null || echo ok)
case $1 in
  hmac) tee "$T/hmac.in" >/dev/null </dev/stdin   # whatever --in names; tests pass /dev/stdin
        case $mode in
          ok) openssl dgst -sha256 -mac HMAC -macopt key:juniper-test -r "$T/hmac.in" | cut -c1-64 ;;
          not-set|gen-fails) echo "Last crypto error: 6 (Key is all zeros)" >&2; exit 250 ;;
          locked) echo "Last crypto error: 4 (locked)" >&2; exit 252 ;;
        esac ;;
  genkey) [[ $mode == gen-fails ]] && { echo "Last crypto error: 10 (not blank)" >&2; exit 246; }
          echo ok >"$T/fw.mode"; echo "Successfully generated ECDSA key in slot 1" ;;
  set-key-status) echo "Set key 1 status to 0x00001b01 (...)" ;;
  get-key-status) echo "Key 1 status: 0x00001b01 (...)" ;;
esac'
}

test_fwkey_derive_message_is_domain_separated() {
  fwkey_env
  out=$("$LIBEXEC/fwkey" derive mmcblk0)
  check "fwkey: 64 hex chars" grep -Eqx '[0-9a-f]{64}' <<<"$out"
  check "fwkey: exact HMAC input" cmp -s "$T/hmac.in" <(printf 'juniper.luks.root.v1\0mmc:0353445344333247803a1b2c3d014e00')
}

test_fwkey_genkey_only_when_not_set() {
  fwkey_env; echo not-set >"$T/fw.mode"
  check "fwkey: generated" test "$("$LIBEXEC/fwkey" ensure)" = generated
  check "fwkey: genkey called once" test "$(grep -c '^rpi-fw-crypto genkey --key-id 1 --alg ec$' "$CALLS")" = 1
}

test_fwkey_never_writes_when_locked_or_unknown() {
  for mode in locked novcio; do
    fwkey_env; echo $mode >"$T/fw.mode"; [[ $mode == novcio ]] && rm -f "$JUNIPER_VCIO"
    check "fwkey ($mode): ensure fails" fails "$LIBEXEC/fwkey" ensure
    check "fwkey ($mode): no genkey" not_called "rpi-fw-crypto genkey"
  done
}

test_fwkey_never_reads_raw_key() {
  fwkey_env; echo not-set >"$T/fw.mode"
  "$LIBEXEC/fwkey" ensure >/dev/null; "$LIBEXEC/fwkey" derive mmcblk0 >/dev/null; "$LIBEXEC/fwkey" lock >/dev/null
  check "fwkey: no privkey" not_called "rpi-fw-crypto privkey"
  check "fwkey: no key-usage write" not_called "set-key-usage"
  check "fwkey: no vcmailbox" not_called "vcmailbox"
}

test_fwkey_lock_is_one_call_sign_unlocked() {
  fwkey_env
  check "fwkey: locked" test "$("$LIBEXEC/fwkey" lock)" = locked
  check "fwkey: one call, four flags" called "rpi-fw-crypto set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED"
  check "fwkey: SIGN stays unlocked" not_called "SIGN_LOCKED"
}

test_fwkey_lock_unavailable_when_bit_not_set() { … get-key-status prints 0x00000101 → "unavailable" … }
test_fwkey_card_id_nvme_and_usb() { … nvme serial trimmed; usb with serial; usb without serial fails … }
test_fwkey_derive_fails_closed() { … hmac error → exit 1 and empty stdout … }
```

- [ ] **Step 2: Implement `fwkey`.** The core:

```bash
#!/usr/bin/env bash
# The Pi's OTP device key through the firmware (rpi-fw-crypto, key id 1), for the LUKS root.
# Never reads the raw key (no privkey); generates one only when the slot is blank; locks it
# after use. Issue #50; spec docs/superpowers/specs/2026-10-11-encryption-design.md.
set -euo pipefail
sysfs=${JUNIPER_SYSFS:-/sys}
vcio=${JUNIPER_VCIO:-/dev/vcio}
fw=${RPI_FW_CRYPTO:-rpi-fw-crypto}
label='juniper.luks.root.v1'

fw_error() { sed -n 's/^Last crypto error: \([0-9]*\).*/\1/p' <<<"$1" | head -1; }

hmac() { # stdin: message; stdout: hex
  "$fw" hmac --in /dev/stdin --key-id 1 --outform hex
}

probe() {
  [[ -e $vcio ]] || { echo "unavailable:no $vcio"; return; }
  local both out err
  # One capture of stdout+stderr, no temporary file; a valid HMAC is a single 64-hex line.
  both=$(printf 'juniper.probe.v1' | hmac 2>&1) || true
  out=$(printf '%s\n' "$both" | grep -Ex '[0-9a-f]{64}' | head -1) || true
  if [[ $out =~ ^[0-9a-f]{64}$ ]]; then echo ok; return; fi
  err=$(fw_error "$both")
  case $err in
    6) echo not-set ;;
    4) echo locked ;;
    *) echo "unavailable:firmware error ${err:-none}" ;;
  esac
}

card_id() { # DISK (kernel name, no /dev)
  local d=$sysfs/block/$1 v
  if [[ -r $d/device/cid ]] && v=$(tr -d '[:space:]' <"$d/device/cid") && [[ -n $v ]]; then echo "mmc:$v"; return; fi
  if [[ $1 == nvme* && -r $d/device/serial ]] && v=$(tr -d '[:space:]' <"$d/device/serial") && [[ -n $v ]]; then echo "nvme:$v"; return; fi
  # USB: walk up from the block device to the usb_device that has idVendor/serial.
  local p; p=$(readlink -f "$d/device")
  while [[ $p == "$sysfs"/* && ! -r $p/idVendor ]]; do p=${p%/*}; done
  if [[ -r $p/serial ]] && v=$(tr -d '[:space:]' <"$p/serial") && [[ -n $v ]]; then
    echo "usb:$(cat "$p/idVendor"):$(cat "$p/idProduct"):$v"; return
  fi
  return 1
}
# derive: id=$(card_id "$2") || exit 1; out=$(printf '%s\0%s' "$label" "$id" | hmac 2>/dev/null) || exit 1
#         [[ $out =~ ^[0-9a-f]{64}$ ]] || exit 1; printf '%s\n' "$out"
# ensure / lock / dispatcher as specified in the table above.
```

No temporary files anywhere in `fwkey`, even for the (non-secret) probe: one pattern throughout. Add a unit test that runs every subcommand with `TMPDIR=$T/tmp` and asserts it stays empty.

- [ ] **Step 3:** Run `tests/unit.sh`, `shellcheck` and `shfmt`. Commit `feat: fwkey, the OTP device key helper for the encrypted root`.

---

### Task 4: `cryptroot` — prepare (pre-udev) and unlock (post-udev)

**Files:**
- Create: `system_files/usr/libexec/juniper/cryptroot`
- Modify: `system_files/etc/cloud/cloud.cfg.d/10-juniper-growpart.cfg`, `tests/unit.sh`

**Spike findings inline:**
- The boot command line is `root=UUID=66f85224-… rw boot=UUID=… rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot ostree=/ostree/boot.1/…`, the same in every deployment except `ostree=`. **Every card of a release has the same UUIDs.**
- GPT layout:
  - p1 ESP-type CIDATA, 1 GiB;
  - p2 XFS `/boot`, 1 GiB;
  - p3 type `b921b045-1df0-41c3-af44-4c6f280d3fae` (root-arm64), 6 GiB, ending at the image's last usable LBA. The backup GPT sits at 8 GiB.
- The XFS has `sectsize = 512`, so cryptsetup refuses `--sector-size 4096`.
- Offline `reencrypt --encrypt --reduce-device-size 32M` gives data offset 16 MiB and a whole-device segment.
- **A killed run needs `cryptsetup repair` before `--resume-only`.**
- `/run/cryptsetup` must exist (cryptsetup's lock directory; no tmpfiles in this initramfs).

**Interfaces:**

`cryptroot prepare` (initramfs, before udev; exit 0 unless the system must not continue):
1. Find the root:
   - `X` comes from `root=UUID=` in `$JUNIPER_CMDLINE` (default `/proc/cmdline`).
   - Poll `blkid -t UUID=X -o device` for up to `$JUNIPER_ROOT_WAIT` seconds (30).
   - If there is no plain match, look for `blkid -t LABEL=juniper-root -t TYPE=crypto_LUKS -o device` partitions whose `juniper` token has `root_uuid == X`.
2. Find CIDATA on the same disk: the partition with label `CIDATA`. Mount it read-write at `$JUNIPER_CIDATA_MNT` (`/run/juniper/cidata`) and unmount on exit.
3. Pick the case:

   | Root found | CIDATA `juniper-encrypt` | Action |
   |---|---|---|
   | plain XFS | `on` | first-boot encryption (spec steps 2–8). On any precondition failure: `record not-encrypted:<reason>`, grow, continue |
   | plain XFS | `off`, missing, or anything else | grow; `record not-encrypted:<reason>` if not already recorded |
   | plain XFS | `encrypted` (impossible) | `record not-encrypted:state mismatch`; continue |
   | LUKS, `online-reencrypt-v2` requirement | any | `repair` then `reencrypt --resume-only` (passphrase from `fwkey derive`) |
   | LUKS, token `recovery: pending` | any | kill `recovery_slot` if set, redo the recovery step |
   | LUKS, `juniper-rebind.key` on CIDATA | any | Task 10 |
   | LUKS, `juniper-reseal.txt` on CIDATA | any | Task 12 |
   | LUKS, complete, nothing pending | any | grow if not at the end of the disk |
   | none | any | exit 0 (the normal root wait will fail, as today) |
4. Write `/run/juniper/cryptroot` (key=value, as in the spec's status file).

`cryptroot unlock` (initramfs, after udev):
1. If `root=UUID=X` resolves to a plain filesystem, write `state=not-encrypted` (keep the reason prepare wrote) and exit 0.
2. Otherwise, for each matching LUKS candidate: `fwkey derive <disk> | cryptsetup open --allow-discards --key-file - <dev> juniper-root`. Stop at the first success.
3. Then `fwkey lock` and update `/run/juniper/cryptroot`.
4. On failure, retry three times, 10 s apart. Then:
   - under tryboot (`/proc/device-tree/chosen/bootloader/tryboot` == 1), exit 1 at once;
   - otherwise print the re-bind hint on `/dev/console`, `sleep $JUNIPER_UNLOCK_FAIL_DELAY` (300), and exit 1.

Environment overrides for tests: `JUNIPER_CMDLINE`, `JUNIPER_SYSFS`, `JUNIPER_CIDATA_MNT`, `JUNIPER_RUN_DIR`, `JUNIPER_CPUINFO`, `JUNIPER_TRYBOOT_FLAG`, `JUNIPER_ROOT_WAIT`, `JUNIPER_UNLOCK_FAIL_DELAY`, `JUNIPER_FWKEY`.

The first-boot sequence the script must run (secrets only through pipes):

```bash
encrypt_first_boot() { # $1=partition $2=disk (kernel name) $3=part number
  local part=$1 disk=$2 n=$3 cipher keysize
  if grep -qw aes "${JUNIPER_CPUINFO:-/proc/cpuinfo}"; then cipher=aes-xts-plain64 keysize=512
  else cipher=xchacha12,aes-adiantum-plain64 keysize=256; fi
  mkdir -p /run/cryptsetup
  sfdisk --relocate gpt-bak-std "/dev/$disk"
  grow_part "$disk" "$n" +64M                 # sfdisk -N, then partx -u
  "$fwkey" derive "$disk" | cryptsetup reencrypt --batch-mode --encrypt --init-only \
    --type luks2 --reduce-device-size 32M --cipher "$cipher" --key-size "$keysize" \
    --sector-size 512 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --label juniper-root --key-file - "$part"
  token_write "$part" pending                 # cryptsetup token import --json-file -
  "$fwkey" derive "$disk" | cryptsetup reencrypt --batch-mode --resume-only --key-file - "$part"
  seal_recovery "$part" "$disk"
  grow_part "$disk" "$n" max
  record encrypted
}

seal_recovery() { # never writes R anywhere but the keyslot and the age file
  local part=$1 disk=$2 r
  r=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  # R reaches cryptsetup through a pipe (process substitution), never a here-string
  "$fwkey" derive "$disk" | cryptsetup luksAddKey --batch-mode --pbkdf pbkdf2 \
    --pbkdf-force-iterations 1000 --key-file - "$part" /dev/fd/3 3< <(printf '%s' "$r")
  printf '%s' "$r" | age -R "$cidata/juniper-recovery.txt" -o "$cidata/juniper-recovery.age.new"
  unset r
  sync; mv "$cidata/juniper-recovery.age.new" "$cidata/juniper-recovery.age"; sync
  token_write "$part" sealed
}
```

Bash here-strings (`<<<`) and here-documents can be backed by a temporary file, which would put `R` on a disk, so the code above uses `3< <(printf '%s' "$r")` (process substitution is a pipe). The new slot number is read back from `luksDump` and stored in the token. Unit-test it by stubbing `cryptsetup` to record `readlink /proc/self/fd/3`, which must be `pipe:[…]`.

- [ ] **Step 1: Failing unit tests.** Each test builds a fake world under `$T`:
- `$T/cmdline` with `root=UUID=U1`;
- `$T/sys/block/mmcblk0/device/cid`;
- a `blkid` stub answering from `$T/blkid.db`;
- stubs for `cryptsetup`, `sfdisk`, `partx`, `age` and `mount`/`umount` (the CIDATA directory is just `$T/cidata`);
- `fwkey` stubbed via `JUNIPER_FWKEY` (`derive` prints a fixed 64-hex string; `ensure` prints according to `$T/fw.mode`).

```bash
test_cryptroot_first_boot_encrypts_in_order() {
  cryptroot_env plain on
  "$LIBEXEC/cryptroot" prepare
  check "prepare: relocate backup GPT first" grep -n 'sfdisk --relocate gpt-bak-std /dev/mmcblk0' "$CALLS"
  check "prepare: init-only before resume" order "cryptsetup reencrypt --batch-mode --encrypt --init-only" "cryptsetup reencrypt --batch-mode --resume-only"
  check "prepare: token before the long run" order "cryptsetup token import" "--resume-only"
  check "prepare: sector size 512" called "--sector-size 512"
  check "prepare: aes on a cpu with aes" called "--cipher aes-xts-plain64 --key-size 512"
  check "prepare: recovery sealed" test -s "$T/cidata/juniper-recovery.age"
  check "prepare: grows to max last" order "cryptsetup luksAddKey" "sfdisk -N 3"   # second sfdisk -N
  check "prepare: state recorded" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prepare: passphrase never on disk" not_grep_dir "$(fake_pass)" "$T"
}
test_cryptroot_adiantum_without_aes() { … cpuinfo without aes → xchacha12,aes-adiantum-plain64 256 … }
test_cryptroot_off_only_grows() { … juniper-encrypt=off → no fwkey ensure, no cryptsetup, grow called, state "not-encrypted:encrypt: false" … }
test_cryptroot_missing_marker_not_requested() { … no file → "not-encrypted:not requested at flash time"; no fwkey calls … }
test_cryptroot_fails_open_on_key_unavailable() { … fwkey ensure → unavailable → no cryptsetup; state reason contains "firmware key interface unavailable" … }
test_cryptroot_fails_open_two_root_candidates() { … blkid returns two devices for UUID=U1 → no encryption, reason "two disks carry this root filesystem" … }
test_cryptroot_fails_open_no_recipients() { … empty juniper-recovery.txt → reason "no recovery recipient" … }
test_cryptroot_fails_open_usb_without_serial() { … fwkey card-id fails → reason "disk has no serial number" … }
test_cryptroot_fail_open_is_final() { … state already "not-encrypted:…" → second prepare with marker on does nothing but grow … }
test_cryptroot_resume_runs_repair_first() { … LUKS with requirement → "cryptsetup repair" then "--resume-only" … }
test_cryptroot_recovery_pending_redone() { … token recovery pending with recovery_slot=1 → luksKillSlot 1, then luksAddKey, age, token sealed … }
test_cryptroot_recovery_passphrase_via_pipe() { … cryptsetup stub records readlink /proc/self/fd/3 → pipe:[…] … }
test_cryptroot_unlock_plain_is_noop() { … }
test_cryptroot_unlock_tries_each_candidate() { … two LUKS candidates; first fails to open, second opens; fwkey lock called once after open … }
test_cryptroot_unlock_failure_under_tryboot_exits_fast() { … tryboot flag 1, open fails → exit 1, no sleep 300 … }
test_cryptroot_unlock_failure_normal_boot_delays() { … JUNIPER_UNLOCK_FAIL_DELAY=1; console hint printed … }
```

Add a tiny `order A B` helper next to `called` in `tests/unit.sh` (the first line matching A comes before the first line matching B).

- [ ] **Step 2: Implement `cryptroot`** per the interfaces above.

Helpers:
- `grow_part DISK N SIZE`, using `sfdisk -N` with `--no-reread --no-tell-kernel`, then `partx -u -n N`;
- `token_read`/`token_write`, using `cryptsetup token export --token-id 0` / `token import --token-id 0 --token-replace` with JSON built by `printf` (no `jq` in the initramfs: keep the JSON flat and parse it with `sed`);
- `record STATE`, which writes `$cidata/juniper-encrypt` and `$run/cryptroot`.

Messages go to `/dev/kmsg` and the console prefixed `juniper-cryptroot:`, so they appear on the serial console and in `journalctl -b`.

- [ ] **Step 3:** In `10-juniper-growpart.cfg`, set `growpart: {mode: "off"}` with the comment `# The initramfs grows the root partition (juniper-cryptroot prepare), before a LUKS root is opened; cloud-init resizefs still grows the XFS.` In `tests/image.sh`, replace any growpart expectation with `grep -q 'mode: "off"'`, and keep the `resize_what = "/var"` check.
- [ ] **Step 4:** Run the unit tests, shellcheck and shfmt. Commit `feat: cryptroot, first-boot LUKS2 encryption and unlock logic`.

---

### Task 5: Dracut module and initramfs units (B1, B4, F10)

**Files:**
- Create: `system_files/usr/lib/dracut/modules.d/90juniper-cryptroot/module-setup.sh`, `…/juniper-cryptroot-prepare.service`, `…/juniper-cryptroot-unlock.service`
- Modify: `system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf`, `build_files/build.sh` (tag layer), `tests/image.sh`

**Spike findings inline:**
- B1: today's initramfs has `crypt dm` but **no** `systemd-cryptsetup` module and **no** `cryptsetup` binary.
  - The base image got `systemd-cryptsetup` through clevis/tpm2-tss, which Juniper omits.
  - `90crypt` installs `cryptsetup` only without systemd.
  - Fix the misleading comment in `90-juniper.conf` too.
- Already in today's initramfs: `dm-crypt.ko.xz`, `adiantum`, `chacha-neon`, `nhpoly1305-neon`, `aes-ce-blk`, `aes-neon-bs`, `blkid`, `losetup`, `dmsetup`, `keyctl`, `findmnt`, and `libcrypto` (for cryptsetup).
- Its size today is 28.7 MB. Estimated additions, uncompressed:
  - cryptsetup, libcryptsetup, libpopt, libpwquality, libjson-c: about 1.2 MB;
  - rpi-fw-crypto with libgnutls, p11-kit, unistring, tasn1 and idn2: about 6.7 MB;
  - age: 4.7 MB;
  - sfdisk with libfdisk, libsmartcols and readline: about 0.8 MB;
  - in total about **+5–6 MB** compressed.
- F10: `50-juniper-watchdog.conf` is in the initramfs, so PID 1 feeds the watchdog during the long run.

- [ ] **Step 1: Failing image tests:**

```bash
img=$(echo /usr/lib/modules/*/initramfs.img)
inv=$(lsinitrd "$img")
for f in usr/sbin/cryptsetup usr/bin/rpi-fw-crypto usr/bin/age usr/sbin/sfdisk usr/sbin/partx \
  usr/libexec/juniper/cryptroot usr/libexec/juniper/fwkey \
  usr/lib/systemd/system/juniper-cryptroot-prepare.service \
  usr/lib/systemd/system/juniper-cryptroot-unlock.service \
  'kernel/drivers/md/dm-crypt.ko' 'kernel/crypto/adiantum.ko' 'arch/arm64/crypto/aes-ce-blk.ko'; do
  grep -q "$f" <<<"$inv" || { echo "initramfs lacks $f"; exit 1; }
done
grep -q 'initrd.target.wants/juniper-cryptroot-unlock.service' <<<"$inv"
grep -q 'sysinit.target.wants/juniper-cryptroot-prepare.service' <<<"$inv"
size=$(stat -c %s "$img")
(( size < 40 * 1024 * 1024 )) || { echo "initramfs is $((size / 1048576)) MB (budget 40)"; exit 1; }
# every library the new binaries need is inside (lsinitrd --unpack into a temp dir, then
# ldd within chroot? no: arm64 CI runs the image natively, so check with ldd on the unpacked tree)
```

- [ ] **Step 2: The module:**

```bash
#!/usr/bin/bash
# Juniper: LUKS2 root bound to the Pi's OTP key (issue #50). See /usr/libexec/juniper/cryptroot.
check() { require_binaries cryptsetup rpi-fw-crypto age sfdisk partx blkid || return 1; return 0; }
depends() { echo dm systemd; }
installkernel() { hostonly='' instmods dm_crypt adiantum xchacha12 chacha_generic chacha-neon nhpoly1305-neon aes-ce-blk aes-neon-bs xts; }
install() {
  inst_multiple cryptsetup rpi-fw-crypto age sfdisk partx blkid od tr sed head cut readlink sync mv sleep
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
Description=Juniper encrypted root: first-boot encryption, resume, keyslot work, grow
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
TimeoutStartSec=10min
StandardOutput=journal+console
```

`juniper.encrypt=0` on the kernel command line is handled inside `cryptroot prepare` (no conversion; resume, keyslot work and growing still run), not with a unit `Condition`, so a half-done conversion is never stranded. In `90-juniper.conf`: `add_dracutmodules+=" juniper-cryptroot "`, and rewrite the header comment: "crypt/dm are kept for dm-crypt modules; LUKS unlock is Juniper's own juniper-cryptroot module (the base pulled systemd-cryptsetup in through clevis/tpm2-tss, which we omit)".

- [ ] **Step 3:** Push and read `gh pr checks`. Record the new initramfs size in the PR body. Commit `feat: initramfs module for the encrypted root`.
- [ ] **Step 4 (needs the owner's Pi 5; do it early, before Tasks 7–12 are polished):** an ordering smoke test.
  1. Flash a branch build with `encrypt: true` (Task 8's `render-cidata` change, or write `juniper-encrypt`/`juniper-recovery.txt` onto CIDATA by hand after `just flash`).
  2. Boot with the serial console (`console=ttyAMA10,115200` in the entry's `cmdline.txt`).
  3. Confirm prepare ran before `systemd-udevd` (`journalctl -b -o short-monotonic -u juniper-cryptroot-prepare -u systemd-udevd`), the conversion completed, the unlock opened `juniper-root`, and `sysroot.mount` mounted with no device-timeout messages.

  **If this fails, switch to the spec's fallback:** prepare ends a conversion with `systemctl reboot`, so the following boot is a plain unlock boot. Re-test before continuing.

---

### Task 6: Privileged loop-device test of the real scripts (CI)

**Files:**
- Create: `tests/cryptroot-loop.sh`
- Modify: `Justfile` (`test-cryptroot`), `.github/workflows/build.yml` (a step after `test-image` in the arm64 build job, `juniper-minimal` only)

**Why:** the unit tests stub cryptsetup. This test runs the image's own cryptsetup 2.8.1, sfdisk, age and the real `cryptroot`/`fwkey` against a disk image laid out like bib's, decrypting with dm. The spike couldn't do that without root.

**Interfaces:** `just image=juniper-minimal test-cryptroot` runs `sudo podman run --rm --privileged -v /dev:/dev -v ./tests:/tests:ro IMAGE /tests/cryptroot-loop.sh`. It exits non-zero on any failure.

- [ ] **Step 1: Write the test.** Inside the container:
1. Build a sparse 10 GiB file with a GPT like bib's (sfdisk script):
   - p1 1 GiB ESP type, vfat label `CIDATA`;
   - p2 1 GiB XFS;
   - p3 6 GiB of type root-arm64, holding an XFS made with `mkfs.xfs -m uuid=<U> -L root`.

   Write 1 GiB of random files plus their checksums to p3. Then truncate the backup GPT position as in the real image (create the GPT at 8 GiB, then `truncate -s 10G`).
2. `losetup -fP`. Provide a fake sysfs tree under `$W/sys` with `block/loopN/device/cid`, and point `JUNIPER_SYSFS` at it.
3. Put a stub `rpi-fw-crypto` first on `PATH`: HMAC with a fixed test key via `openssl dgst -mac HMAC`, plus the genkey/status behaviours. Write `CIDATA/juniper-encrypt` = `on`, and `juniper-recovery.txt` holding a throwaway `ssh-ed25519` public key.
4. Run `JUNIPER_CMDLINE=<(echo root=UUID=$U) … /usr/libexec/juniper/cryptroot prepare`, then `cryptroot unlock`, against the loop device. Assert:
   - p3 is `crypto_LUKS`, label `juniper-root`, with the `juniper` token (`root_uuid=$U`, `recovery: sealed`), cipher `aes-xts-plain64`, sector 512;
   - `/dev/mapper/juniper-root` exists and its XFS UUID is `$U`;
   - mounting it gives files that match their checksums;
   - p3 ends at the last usable LBA of 10 GiB, and the mapping size is p3 minus 16 MiB;
   - `age -d -i <throwaway key> CIDATA/juniper-recovery.age | cryptsetup open --test-passphrase --key-file - p3` succeeds;
   - `grep -a` for the board passphrase and for `R` finds nothing on the image file or anywhere in `/run` or `/tmp`.
5. **Interruption:**
   - On a fresh image, run prepare in the background, wait until `cryptsetup luksDump` shows `online-reencrypt-v2`, then `kill -9`. Run prepare again: it must repair, resume, finish, and leave the data intact.
   - Repeat with the kill landing between `luksAddKey` and the `.age` file: put a `sleep 5` hook on `age` via `PATH`, and kill during it. The next prepare must redo recovery and end with exactly one recovery slot.
6. **Fail open:** with `rpi-fw-crypto` returning `KEY_LOCKED`, prepare leaves p3 plain, grows it, writes `not-encrypted:…` to `juniper-encrypt`, and never calls `genkey`. The stub logs calls.
7. **Idempotence:** a second `prepare` on the encrypted image changes nothing (compare `luksDump` before and after).
8. **Adiantum:** repeat steps 1–4 with `JUNIPER_CPUINFO` pointing at a file without `aes`.

- [ ] **Step 2:** Wire it into CI: after `just test-image`, `if: matrix.image == 'juniper-minimal'`, run `just image=juniper-minimal test-cryptroot`. The runner is `ubuntu-24.04-arm` with sudo, so loop and dm work. If dm doesn't work under the runner's podman, fall back to running on the host with the image's binaries extracted (`podman cp`). Note it in the PR.
- [ ] **Step 3:** Push and read `gh pr checks`. Commit `test: loop-device test of first-boot encryption, resume and fail-open`.

---

### Task 7: Real-root reporting — state file, MOTD, pi-status, metrics; firstboot keeps the blob

**Files:**
- Create: `system_files/usr/libexec/juniper/encryption-status`, `system_files/usr/lib/systemd/system/juniper-encryption-status.service`
- Modify: `system_files/usr/libexec/juniper/motd`, `system_files/usr/share/juniper/just/pi.just`, `system_files/usr/share/juniper/just/services.just`, `system_files/usr/libexec/juniper/firstboot`, `build_files/build.sh` (enable the unit), `tests/unit.sh`, `tests/image.sh`

**Interfaces:**
- `encryption-status` (oneshot, `After=local-fs.target`, `Before=juniper-healthcheck.service`) reads `/run/juniper/cryptroot`. It checks it against the live device (`lsblk -no TYPE` of the device under `/sysroot` includes `crypt`) and writes:
  - `/var/lib/juniper/encryption` (the spec's format);
  - `/var/lib/juniper/metrics/juniper.prom`, atomically (write `.tmp`, then `mv`).

  A device flashed before this feature (no `/run` file, plain root) gets `reason=flashed before encryption support`.
- The MOTD shows a Warning row only when `state=not-encrypted`.
- `pi-status` prints one `Storage:` line.
- `enable-metrics` adds `--collector.textfile.directory=/host/var/lib/juniper/metrics` to the `Exec=` line.

- [ ] **Step 1: Failing unit tests:**

```bash
test_encryption_status_encrypted() {
  export JUNIPER_RUN_DIR=$T/run; mkdir -p "$T/run"
  printf 'state=encrypted\ncipher=aes-xts-plain64\nbinding=board+mmc\nkey_lock=locked\nrecovery=sealed:2\n' >"$T/run/cryptroot"
  stub lsblk 'echo crypt'
  "$LIBEXEC/encryption-status"
  check "status: file" grep -qx 'state=encrypted' "$JUNIPER_STATE_DIR/encryption"
  check "status: metric" grep -qx 'juniper_encrypted 1' "$JUNIPER_STATE_DIR/metrics/juniper.prom"
  check "status: lock metric" grep -qx 'juniper_encryption_key_locked 1' "$JUNIPER_STATE_DIR/metrics/juniper.prom"
}
test_encryption_status_live_device_wins() { … run file says encrypted but lsblk says part → state=not-encrypted, reason "root is not on dm-crypt" … }
test_encryption_status_legacy_device() { … no run file, plain → reason "flashed before encryption support", juniper_encrypted 0 … }
test_motd_warns_not_encrypted() { … state file not-encrypted + reason → motd output has "NOT ENCRYPTED" and the reason; encrypted → no Storage warning … }
test_firstboot_keeps_recovery_files() { … CIDATA has juniper-recovery.age/.txt/juniper-encrypt → still there after firstboot; recovery.age copied to $JUNIPER_STATE_DIR/recovery.age … }
test_metrics_quadlet_has_textfile_collector() { grep -q -- '--collector.textfile.directory=/host/var/lib/juniper/metrics' "$ROOT/system_files/usr/share/juniper/just/services.just"; }
```

- [ ] **Step 2: Implement.**
  - MOTD row: `row Warning "$(printf '\e[1;31mStorage NOT ENCRYPTED\e[0m (%s): anyone holding this card can read its secrets. Reflash to encrypt.' "$reason")"`.
  - `pi-status`: `@/usr/libexec/juniper/encryption-status --print`, which formats the line from the state file. Strip non-printables from `reason` everywhere it is shown (it came from CIDATA).
  - `firstboot`: after the scrub, `install -m 0644 "$cidata_dir/juniper-recovery.age" "$state_dir/recovery.age"` if present. The scrub's `shred` list stays the same; add a comment saying the recovery files are public.
- [ ] **Step 3:** Image tests: the unit is enabled, the metrics directory comes from tmpfiles (`d /var/lib/juniper/metrics 0755 root root -`), and node_exporter's user can read it. Commit `feat: report encryption state in the MOTD, pi-status and metrics`.

---

### Task 8: `just flash` — `encrypt`, `recovery_key`, CIDATA files, summary, warning (default off)

**Files:**
- Modify: `disk/render-cidata`, `disk/flash.sh`, `examples/flash.yaml`, `tests/unit.sh`

**Spike finding inline (F9):** age refuses `ecdsa-sha2-*` and `sk-*` recipients ("ignoring unsupported SSH key … no recipients found"). `ssh-ed25519` and `ssh-rsa` work. Juniper's `KEY_PREFIXES` accepts all four kinds for login.

**Interfaces:**
- `render-cidata` accepts `encrypt` (a boolean; **default `False` in this task**, flipped in Task 14) and `recovery_key` (it must match `^age1[02-9ac-hj-np-z]{58}$`).
- It writes to OUTDIR: `juniper-encrypt` (`on`|`off`, mode 0644) and, when on, `juniper-recovery.txt` (one recipient per line).
- It prints the summary data on stderr as `encrypt=yes recipients=N fingerprints=…`, or uses an extra output file read by `flash.sh`.
- `flash.sh --write` copies both files to CIDATA.

- [ ] **Step 1: Failing unit tests** (in the style of `test_render_cidata_*`):

```bash
test_render_cidata_encrypt_default_off() { … no encrypt key → juniper-encrypt == off, no juniper-recovery.txt … }
test_render_cidata_encrypt_on_uses_ssh_recipients() { … ssh_keys ed25519 + ecdsa + sk → recovery file has only the ed25519 line … }
test_render_cidata_recovery_key_overrides() { … recovery_key: age1… → file has exactly that line, no ssh keys … }
test_render_cidata_encrypt_refuses_without_recipient() { … only ecdsa/sk keys, no recovery_key → fails; stderr_has "age can't encrypt to ecdsa or FIDO" … }
test_render_cidata_rejects_bad_recovery_key() { … "age1short" and "AGE-SECRET-KEY-1…" → fail; a secret key gets a specific "that's a private key" message … }
test_render_cidata_encrypt_must_be_bool() { … encrypt: "yes" → fail (YAML 1.1 'yes' is bool true; string "maybe" fails) … }
test_flash_summary_and_warning() { … run flash.sh's summary block (factor it into a function callable with --summary-only CONFIG) → output has "Encrypt:   yes" and the exact warning line from the spec … }
```

- [ ] **Step 2: Implement.**
  - Add `"encrypt", "recovery_key"` to `KEYS`.
  - Recipients are `[k for k in keys if k.startswith(("ssh-ed25519 ", "ssh-rsa "))]`, or `[recovery_key]`.
  - Fingerprints are computed by `ssh-keygen -lf -` in `flash.sh`, for display only.
  - `flash.sh` prints the spec's warning line just before `read -rp "Erase everything…"`.
  - `examples/flash.yaml` gains the commented `encrypt:` and `recovery_key:` with three lines of explanation:
    - your SSH key file is the recovery key;
    - FIDO and ECDSA keys can't be used;
    - an agent-only key can't decrypt.
- [ ] **Step 3:** Commit `feat: just flash can request first-boot encryption (opt-in for now)`.

---

### Task 9: Laptop-side recovery — `just unlock-card`

**Files:**
- Create: `disk/unlock-card`
- Modify: `Justfile`, `tests/unit.sh`, `README.md` (recovery section, Task 12b)

**Interfaces:** `just unlock-card DEVICE [IDENTITY]`:
1. Refuses system disks (reuse `check-target`).
2. Finds CIDATA and the `juniper-root` partition on DEVICE.
3. Mounts CIDATA read-only (as the user, through `udisksctl`, else via `run0`) to read `juniper-recovery.age`.
4. Runs `age -d -i IDENTITY` (default `~/.ssh/id_ed25519`, then `id_rsa`) piped into `run0 cryptsetup open --readonly --key-file - PART juniper-recovered`.
5. Mounts the result read-only at `/run/media/$USER/juniper-recovered` and prints where it is and how to close it (`just unlock-card --close`).

The passphrase only ever moves through the pipe.

- [ ] **Step 1: Failing tests** with stubs for `lsblk`, `age`, `run0`, `cryptsetup`, `mount`:
  - the pipe order;
  - `--readonly`;
  - refusal of non-removable disks;
  - a clear error when `juniper-recovery.age` is missing ("this card was not encrypted, or its CIDATA partition was wiped; try a copy of recovery.age");
  - nothing written under `$T` that contains the passphrase.
- [ ] **Step 2:** Implement, then commit `feat: just unlock-card, recover an encrypted card on a laptop`.

---

### Task 10 (optional for the first PR; owner question 5): Re-bind to a new board or card

**Files:**
- Create: `disk/rebind-card`
- Modify: `Justfile`, `system_files/usr/libexec/juniper/cryptroot` (`rebind` in prepare), `tests/unit.sh`, `tests/cryptroot-loop.sh`

**Interfaces:**
- On the laptop, `just rebind-card DEVICE [IDENTITY]`:
  1. Decrypts `R`.
  2. Creates a random `T` and runs `cryptsetup luksAddKey` (old key `R`, new key `T`, both through pipes).
  3. Writes `T` to `CIDATA/juniper-rebind.key` (mode 0600 on FAT means nothing; the file is short-lived by design).
- On the device, `cryptroot prepare`, seeing `juniper-rebind.key` on a LUKS root:
  1. `fwkey ensure`.
  2. Opens the header with `T` (`--test-passphrase`).
  3. Kills `board_slot`, then adds the new board passphrase, using `T` to authorise.
  4. Updates the token (`board_slot`, `id_type`).
  5. Kills the `T` slot, then `shred -u`s the file.

  The order means a power cut always leaves a working slot (`T` or the new board slot) until the end.

- [ ] Tests (unit and loop):
  - re-binding a card "moved" to a new fake board key opens with the new key and not the old;
  - `T` no longer opens it;
  - the file is gone;
  - an interrupted re-bind converges.

  Commit `feat: re-bind an encrypted card to a new Pi or card`.

---

### Task 11: `ujust switch` refuses images that can't unlock this root

**Files:**
- Modify: `Containerfile` (`LABEL org.juniper.cryptroot="v1"` in the `minimal` stage; inherited by `juniper` and `juniper-desktop`), `system_files/usr/libexec/juniper/switch-image`, `tests/unit.sh`, `tests/image.sh`

**Interfaces:** if `/sysroot` sits on a `crypt` device and `skopeo inspect docker://IMAGE` lacks `Labels["org.juniper.cryptroot"] == "v1"`, `switch-image` prints why and exits 1. `--force` overrides it, and the message says tryboot would fall back anyway.

- [ ] Tests (stub `skopeo` and `lsblk`): refuses without the label on an encrypted root; allows with it; plain roots are unaffected. Image test: `podman inspect` isn't available inside, so check the label in the CI step after build (`podman image inspect … | jq -e '.[0].Labels["org.juniper.cryptroot"] == "v1"'`). Commit `feat: switch refuses images without encrypted-root support`.

---

### Task 12 (optional; can follow): `ujust recovery-reseal`

**Files:**
- Modify: `system_files/usr/share/juniper/just/pi.just`, `system_files/usr/libexec/juniper/cryptroot`, `tests/unit.sh`

**Interfaces:**
- `ujust recovery-reseal` reads new recipients: SSH public keys or an `age1…` key, with the same filter as `render-cidata`.
- It writes `CIDATA/juniper-reseal.txt` (public) and asks to reboot.
- `cryptroot prepare` then:
  1. makes `R'`;
  2. runs `luksAddKey` (authorised by the board passphrase);
  3. writes `juniper-recovery.age.new`, then `mv`s it into place;
  4. kills the old `recovery_slot`;
  5. updates the token and removes the request file.

- [ ] Tests mirror Task 4's recovery tests. Commit `feat: ujust recovery-reseal`.

---

### Task 12b: Docs

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `docs/upstream.md`, `docs/superpowers/STATUS.md`, `docs/acceptance.md`

- [ ] **README:**
  - **"Encryption at rest"** section: what is protected (the spec's threat table, shortened), opt-in for now, what first boot does, the OTP write ("permanent; Raspberry Pi tools reuse this key rather than replace it; secure boot later can still use it"), the stolen-board and evil-maid limitations, recovery with `just unlock-card`, re-bind, the warning about `rpi-otp-private-key -w -f`, and SSH key custody (a key file, not an agent).
  - Extend the revocation runbook from Phase 0.
- [ ] **CHANGELOG** (Unreleased):
  - Added: opt-in encryption at rest (`encrypt: true`), `just unlock-card`.
  - Changed: the initramfs grows the root partition; rpi-bootc-bootloader gets `MNTDEV`; `lock_device_private_key=1`.
- [ ] **docs/upstream.md:**
  - AlmaLinux RPi SIG: package `raspberrypi-utils`/`rpi-fw-crypto` for EL10, and ship `rpi-eeprom-firmware` with the 2026-06-17 locks;
  - rpi-bootc-bootloader: the LUKS `MNTDEV` entry now points at Juniper's wrapper;
  - bootc-image-builder: identical filesystem UUIDs on every card of a release (F3), worth an issue about randomising them at first boot.
- [ ] **STATUS.md:** sub-project C row → spec and plan links, state "implementing (opt-in); hardware run pending".

  Commit `docs: encryption at rest (opt-in)`.

---

### Task 13 (needs the owner's Pi 5; then a Pi 4): Hardware acceptance

Run the spec's "Hardware test plan" steps 0–10 on a build of the merged PR 2. Record the results in `docs/acceptance.md`:
- first-boot duration for each card;
- `cryptsetup status` output;
- `get-key-status` before and after;
- the pull-the-plug result;
- `fio` numbers.

Things this run must settle (each was open after the spike):
1. Before-udev ordering works on real hardware (Task 5 Step 4 should already have shown it).
2. The `genkey` path on a blank board, if the owner has one. Otherwise record "existing key reused" and the key-usage value.
3. Whether `set-key-status … HMAC_LOCKED` takes effect on EEPROM 2026-05-11. Expected: no, so it reports `unavailable`.
4. The first-boot time on the owner's card. If it is above about 15 minutes, consider making bib's root partition smaller (`minsize`): only 1.56 GiB of the 6 GiB is used.
5. Pi 4: that the `start4.elf` key interface works (F5), the Adiantum throughput, and whether HMAC locking works.

- [ ] If everything passes, set README Tested hardware → "encryption ✅ tested <date> (Pi 5 / microSD)".

---

### Task 14 (after Task 13; separate small PR): Encrypt by default

**Files:**
- Modify: `disk/render-cidata` (`encrypt` default `True`), `examples/flash.yaml`, `README.md`, `CHANGELOG.md`, `tests/unit.sh`

- [ ] Flip `test_render_cidata_encrypt_default_off` to `…_default_on`. Make sure the flash warning line prints on every default run. Make the `encrypt: false` path print `Encrypt:   no (encrypt: false)`. README: "on by default; `encrypt: false` to skip". PR title `feat: encrypt new cards by default`.
