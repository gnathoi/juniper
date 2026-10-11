# Encryption at rest — design (sub-project C, issue #50 Phase 2)

Status: design and spike only (2026-10-11), revised the same day after the pre-flight review
and the rulings on #50. Owner decisions and rulings from issue #50 are folded in below.
Nothing here has run on hardware.

The spike looked at these, without running them:
- the published `ghcr.io/gnathoi/juniper-minimal:latest` image (arm64, digest
  `sha256:2916f838350b986775d6a6c150df480587d415b5493a32f600826e5e3a7480f0`, base
  `10.2.20261002.0`, kernel `6.12.96-20260724.v8.1.el10`);
- the `build-20261011` disk image.

It also ran `cryptsetup` 2.8 against image files on an x86 laptop. The pre-flight review
added checks against the cached build image at `4ff27c3`. Its evidence is in "Spike findings"
at the end. The implementation plan is `docs/superpowers/plans/2026-10-11-encryption.md`.

## Intent

A Juniper card taken out of its Pi yields only the public OS image. Wi-Fi passwords, SSH host
keys, Tailscale state, `/etc/shadow` and every workload's data under `/var` sit on a LUKS2
root partition. That partition unlocks unattended only in the Pi it was first booted in, and
only from that same card. If the board dies, the owner can still unlock the card on a laptop
with their SSH private key.

Success looks like this:

1. `just flash` a card as usual, with `encrypt: true` until the hardware run passes and by
   default after that. The first boot takes a few minutes longer, then the device behaves as
   it does today. `ujust pi-status` says "Storage: encrypted".
2. Put the card in a laptop and the root partition is `crypto_LUKS`. Nothing under `/etc` or
   `/var` is readable. The FAT partition holds the firmware, kernel and initramfs as today,
   plus `juniper-recovery.age`. The same ciphertext is also stored in the LUKS2 header.
3. Put the card in another Pi, or clone it to another card and boot that in the same Pi, and
   it doesn't unlock. A USB disk with no serial is the exception (ruling 1).
4. On a laptop, `just unlock-card /dev/sdX` with the owner's SSH key mounts the card's root.
5. If anything in the encryption path can't run (no firmware key interface, a failed call,
   no usable recovery recipient), the device boots unencrypted ("fail open"). It then says
   **NOT ENCRYPTED** loudly in the MOTD, `pi-status` and the metrics (`juniper_encrypted 0`).

## Non-goals

- **A stolen board** (board and card together). Without Raspberry Pi secure boot, whoever
  holds the board can boot their own code and ask the firmware for the same HMAC. That waits
  for secure boot (#73) and is documented as a limitation.
- **Tampering ("evil maid").** The FAT and `/boot` partitions (firmware, `config.txt`,
  `cmdline.txt`, kernel, initramfs) stay unsigned and unencrypted. Only secure boot (#73)
  closes this.
- **A root attacker on a running device.** Root sees the decrypted filesystem. It can also
  derive the passphrase, because the per-operation HMAC lock isn't available in the firmware
  AlmaLinux ships (ruling 4).
- **Migrating existing devices in place.** Reflash only. Existing devices report "not
  encrypted".
- **Re-binding a card to a new board or card.** This is deferred to #76
  (ruling 5). In v1, recovery means reading the data on a laptop.
- **TPM HATs, Tang/clevis, and encrypting `/boot` or FAT.**

## Owner decisions and rulings (issue #50, 2026-10-11)

| Topic | Decision |
|---|---|
| Scope v1 | Protect a stolen **card**. Board theft is a documented limitation until #73 |
| Default | **On by default** after the hardware run; `encrypt: false` in `flash.yaml` skips both encryption and the OTP write. `just flash` prints a one-line warning |
| Rollout | Merged **gated off** (opt-in with `encrypt: true`) until the owner's Pi 5 hardware test passes. A small follow-up PR then flips the default |
| OTP key | Provisioned on first boot if the board has none (irreversible), with `rpi-fw-crypto genkey`; an existing key is reused. Never read raw |
| Key binding | Board OTP key + card serial |
| Recovery | An offline recovery keyslot, sealed with age to the SSH public keys in `flash.yaml` (`ssh-ed25519`/`ssh-rsa`). An optional `recovery_key:` (`age1…`) replaces them. Recovery is the owner's SSH private key on a laptop |
| Failure | **Fail open.** Boot unencrypted with NOT ENCRYPTED in the MOTD, `pi-status` and metrics |
| Hardware | Pi 5 first; Pi 4 best-effort |
| Existing devices | Reflash only |
| Ruling 1 | **USB disk with no serial:** bind to the board key only and say so in `pi-status`. Cost: a clone of such a disk unlocks on the same board |
| Ruling 2 | **Cards not written by `just flash`** stay unencrypted, with the warning, even after the default flips |
| Ruling 3 | **No usable recovery recipient means no encryption.** Fail open with a warning; `just flash` says so up front |
| Ruling 4 | **No per-operation HMAC lock for now.** It needs Pi 5 EEPROM 2026-06-17 or later, which AlmaLinux doesn't ship yet. `lock_device_private_key=1` covers raw reads now. The `set-key-status` call is best-effort and reported |
| Ruling 5 | **Re-binding is deferred** to a follow-up issue |
| Ruling 6 | **The initramfs grows the partition only on the encrypting path.** Plain cards keep cloud-init `growpart`, so nothing changes for them |
| Ruling 7 | **EEPROM update before the hardware run** is recommended. It has no tryboot fallback, so the owner decides at the session |

## Threat model

"Protected" means the attacker learns nothing beyond the public OS image and the boot files.

| Attacker has | Today | After this design | Notes |
|---|---|---|---|
| The card only | Everything: Wi-Fi PSK, SSH host keys, Tailscale state, `/etc/shadow`, workload data | **Protected** | The FAT partition still holds CIDATA secrets until the first-boot scrub (existing exposure, #60) |
| An image or clone of the card, booted in the same Pi | Everything | **Protected** for SD and NVMe, and for USB disks with a serial. **Not protected** for USB disks with no serial (ruling 1, reported) | An SD card in a USB reader binds to the reader's serial, not the card's |
| The card plus another Pi | Everything | **Protected** | Different OTP key |
| The card plus `juniper-recovery.age` (on FAT and in the LUKS header) | n/a | **Protected** | It needs the owner's SSH private key |
| The card plus the owner's SSH private key | Everything | Everything | That is what recovery means. Re-seal with `recovery-reseal` (optional plan task) |
| Board and card together | Everything | **Everything** (documented) | #73 |
| The card, modified and returned (evil maid) | Everything | **Everything** (documented) | #73 |
| Remote root on the running device | Everything live | Everything live, **and it can derive the passphrase** for later offline use of a stolen copy | No per-operation HMAC lock yet (ruling 4). `/dev/vcio` is root-only (devtmpfs 0600; an image test keeps it that way) |
| Wear-levelled remnants on the SD card | Secrets in old blocks | **Only the public OS image** | Encryption runs in the initramfs **before** cloud-init writes anything. Any first boot that doesn't encrypt is recorded as final, so a card that has held plaintext secrets is never encrypted later (C2, I8) |
| The flash host | Sees CIDATA secrets | Same, plus the public recovery recipients | It never sees the device key or the recovery passphrase |

## Key derivation

The OTP research (issue #50, 2026-10-11) settles the details:

- **Interface:** `rpi-fw-crypto` (raspberrypi/utils `rpifwcrypto/`) through the `/dev/vcio`
  mailbox. Key id **1**, the only one exposed on Pi 4 and Pi 5. It is shared with Connect
  and Raspberry Pi's FDE tools.
- **Probe, then generate only if blank.**

  > **Superseded 2026-10-11:** probing with `hmac` wedged the firmware mailbox on EEPROM
  > 2025-11-05. The key is probed with `rpi-fw-crypto pubkey` (exit 250 = not set, the only
  > case that runs `genkey`). See "Hardware findings".

  ~~`rpi-fw-crypto hmac --key-id 1` runs on `juniper.probe.v1`: success reuses the key;
  `KEY_NOT_SET` (error 6) runs `genkey --key-id 1 --alg ec` and probes again.~~
  **Superseded 2026-10-11:** the probe is `rpi-fw-crypto pubkey`; exit 250 (not set) is the
  only case that runs `genkey`, then it probes again. `KEY_LOCKED` (4), any other error, or
  no `/dev/vcio`: **never write**. Fail open with the reason.

  The CLI exits with `-error` (250 for error 6) and prints `Last crypto error: N (…)`. Parse
  that line. **The probe and `genkey` run last among the first-boot preconditions,** so no
  OTP write ever happens before a fail-open (I7).
- **Never read raw.** No `privkey`, no `rpi-otp-private-key`, no `vcmailbox 0x00030081`.
  Every image's per-deployment `rpi-config.txt` gains `lock_device_private_key=1`. That
  covers `juniper-desktop`, which ships its own `rpi-config.txt` (I12). **No**
  `lock_device_key_write=1`: it would make `genkey` fail. **No** `set-key-usage`.
- **Message (domain separated):**

  ```
  msg  = "juniper.luks.root.v1" || 0x00 || <id-type> || ":" || <card-id>
  pass = lowercase hex( HMAC-SHA256(OTP key 1, msg) )   # exactly 64 bytes, no newline
  ```

  The passphrase bytes are exactly the 64 hex characters: `fwkey derive` prints them with
  `printf '%s'`, with no trailing newline, so any tool that recomputes the passphrase gets
  the same bytes. `<id-type>:<card-id>` is the first of these that applies to the disk
  holding the root partition. Ids are read from sysfs, so no udev is needed:
  - `mmc:` + `/sys/block/mmcblkN/device/cid` (as Raspberry Pi's `block-device-id`);
  - `nvme:` + `/sys/block/nvmeXnY/device/serial` (whitespace removed);
  - `usb:` + `<idVendor>:<idProduct>:<serial>` of the USB device above the disk, when
    `serial` is non-empty;
  - `board:` (empty id) for a USB disk with no serial (ruling 1). The binding is then
    `board`, and `pi-status` says "bound to this Pi only (USB disk has no serial; a clone
    unlocks on this Pi)".

  The label keeps Juniper's derivation apart from Raspberry Pi's (bare `block-device-id`
  output). `v1` leaves room to re-key.
- **Lock after unlock: best-effort (ruling 4).** After `cryptsetup open`, the initramfs runs
  `rpi-fw-crypto set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED`, leaving
  SIGN unlocked for Connect. Then `get-key-status 1` checks bit 11.
  - It records `key_lock=locked|unavailable`. **`unavailable` is the expected value today**
    (Pi 5 EEPROM up to 2026-05-11, and probably every Pi 4).
  - The call's result never fails the boot. It is volatile (it lasts until reboot) and
    harmless on firmware that ignores it.
  - Once AlmaLinux ships EEPROM 2026-06-17 or later, the same call starts working with no
    code change.
- **LUKS2 parameters:**
  - `aes-xts-plain64`, 512-bit key, when `/proc/cpuinfo` lists `aes` (Pi 5). Otherwise
    `xchacha12,aes-adiantum-plain64`, 256-bit key (Pi 4).
  - `--sector-size 512`: the bib XFS has 512-byte sectors and cryptsetup refuses 4096.
  - `--pbkdf pbkdf2 --pbkdf-force-iterations 1000`: both secrets are 256-bit random values.
  - `--label juniper-root`; `--allow-discards` at open time.
  - **Fixed keyslots: 0 is the board slot, 1 is the recovery slot** (I5).
  - LUKS2 token 0, type `juniper`, holds the JSON (all values strings, as LUKS2 requires
    `"keyslots":[]`):
    `{"type":"juniper","keyslots":[],"root_uuid":"<X>","binding":"juniper.luks.root.v1","id_type":"mmc|nvme|usb|board","recovery":"pending|sealed","recipients":"<n>"}`.
  - LUKS2 token 1, type `juniper-recovery`, holds the ASCII-armored age ciphertext of the
    recovery passphrase (`{"type":"juniper-recovery","keyslots":[],"age":"-----BEGIN AGE ENCRYPTED FILE-----\n…"}`).
    This is a second copy that survives losing the FAT file (I10). The 16 KiB default
    metadata area fits several recipients.
  - Unlock code ignores token fields it doesn't know.

## Boot and unlock flow (every boot)

The kernel command line does **not** change. `root=UUID=<xfs-uuid>` (the same in both
deployments; only `ostree=` differs) keeps working, because in-place encryption keeps the
inner XFS and its UUID. Two initramfs units come from Juniper's dracut module
`90juniper-cryptroot`; systemd's own `systemd-cryptsetup` isn't used.

1. **`juniper-cryptroot-prepare.service`** runs before udev (`Before=systemd-udevd.service
   systemd-udev-trigger.service`, after kernel modules).
   - It finds the root partition without udev: `root=UUID=X` from `/proc/cmdline`, and up to
     30 s of polling `blkid -c /dev/null -t UUID=X -o device`, which reads `/proc/partitions`.
     Storage drivers are built into the kernel.
   - CIDATA is mounted **read-only** and remounted read-write only for the moment a file is
     written. The CIDATA partition is the one labelled `CIDATA` on the same disk as the root
     partition.
   - Then it runs these steps in order. Each step is idempotent and skips itself when it has
     nothing to do (I6):
     1. **Find,** including a half-converted root (C1, below).
     2. **First-boot decision and conversion** for a plain root with marker `on`.
     3. **Resume** an interrupted reencryption.
     4. **Seal recovery** if the token says `pending`.
     5. **Grow** the partition to the end of the disk if this card is encrypted and the
        partition doesn't reach it yet.
     6. **Record** the state.
   - **Under tryboot, prepare writes nothing to the LUKS header** (I9). It doesn't resume,
     seal, grow or reseal; it logs "deferred until a confirmed boot". A header change made
     by a new deployment would survive the fallback. An interrupted first-boot conversion
     can't happen under tryboot, because tryboot is only used for updates.
   - On an encrypted card with nothing pending, the cost is one `blkid` call and one token
     read. On a plain card with no `on` marker, prepare does nothing (ruling 6).
2. **`juniper-cryptroot-unlock.service`** runs after udev (`After=systemd-udev-trigger.service`,
   `Before=initrd-root-device.target cryptsetup.target`).
   - If `root=UUID=X` resolves to a plain filesystem, it exits 0.
   - Otherwise it opens the first candidate that works: partitions with `LABEL=juniper-root`
     and `TYPE=crypto_LUKS` whose `juniper` token has `root_uuid == X`. For each, it runs
     `fwkey derive <disk> | cryptsetup open --allow-discards --key-file - <part> juniper-root`.
     Every card of a release has the same XFS UUID, but only this card's key opens it.
   - It then runs `fwkey lock` (best-effort) and writes `/run/juniper/cryptroot`: `state`,
     `cipher`, `binding` (from the token's `id_type`), `key_lock`, and `recovery` (from the
     token's `recovery` and `recipients`). `/run` carries over through switch-root.
   - udev then sees the inner XFS and creates `/dev/disk/by-uuid/X`; `sysroot.mount`
     proceeds unchanged.
3. **Unlock failure** (moved card, firmware error): three tries, 10 s apart.
   - **Under tryboot** (the existing big-endian u32 check from `emergency-fallback`), it exits
     1 at once. `OnFailure=emergency.target` and `rd.emergency=reboot` then reboot, and the
     firmware's one-shot tryboot returns to the default entry.
   - **On a normal boot,** it prints on the console: "this card is bound to another
     Raspberry Pi or another card; unlock it on a laptop with the recovery key (just
     unlock-card)". It then sleeps 120 s and exits 1. `dracut-initqueue`'s own "Could not
     boot" (rd.retry, about 180 s after udev-trigger) ends the boot around then anyway, so
     the device reboots about every 3 minutes, never in a tight loop.
4. **After switch-root,** `juniper-encryption-status.service` turns the boot's state into
   `/var/lib/juniper/encryption`. It checks the live device too (`/sysroot` must sit on a
   `crypt` device). Without a `/run` file it uses the CIDATA marker to tell "flashed before
   encryption support" from "prepare crashed".

### Why before udev

On first boot the root filesystem `X` is visible as plain XFS. `sysroot.mount` binds to its
device unit (BindsTo). If the root were converted after udev had seen it, that device would
vanish for minutes and come back as a dm device, and systemd would stop or fail the pending
`sysroot.mount`. Before udev there are no device units yet:
- the block device nodes come from devtmpfs (the drivers are built in);
- `/dev/vcio` is there (built-in driver);
- `cryptsetup` reencrypts offline in user space;
- libdevmapper sees no udev and doesn't wait for it.

The review confirmed one thing in the image: dracut's `rootfs-generator.sh` sets no job
timeout on the root device (`JobTimeoutSec=0`, `JobRunningTimeoutSec=0`) unless `rd.timeout`
is set, and `dracut-initqueue` starts only after udev-trigger. So a long conversion before
udev races no timer.

The normal unlock stays after udev, so the dm device gets proper udev processing. Task 5's
smoke test checks this ordering on the Pi 5 over serial before anything else depends on it.
The fallback, if it fails: end the conversion with `systemctl reboot`.

## First-boot flow (encrypting path)

All of this runs in the initramfs, before `sysroot.mount` and cloud-init, so before any
secret reaches the root partition.

1. **Decide.** Read `CIDATA/juniper-encrypt`:
   - `on`: try to encrypt (below);
   - `off`, missing, or anything else: do nothing at all (no grow, no fwkey). Unlock and
     status report "not encrypted" with the reason: `encrypt: false`, or "not requested at
     flash time" (ruling 2);
   - `converting`: a conversion was interrupted (C1, step 4);
   - `encrypted` or `not-encrypted:…`: already decided; do nothing.

   With the marker `on` and the kernel argument `juniper.encrypt=0`, prepare records
   `not-encrypted:juniper.encrypt=0` (final, I8) and continues plain.
2. **Fail-open guard (C2).** From here until the LUKS header exists, an `ERR`/`EXIT` trap
   records `not-encrypted:<step> failed` on any error, so the boot continues plain and the
   decision is final. Once the header is written, a failure leaves the marker at
   `converting`. The next boot then resumes; it never boots plain on a half-made header.
3. **Preconditions,** in this order. The first failure fails open with its reason:
   1. Exactly one partition carries `UUID=X`: "two disks carry this root filesystem".
   2. The root partition has GPT type root-arm64 (`b921b045-1df0-41c3-af44-4c6f280d3fae`)
      and is on the same disk as CIDATA.
   3. At least 64 MiB is free after the root partition (any card of 16 GB or more).
   4. `age -R CIDATA/juniper-recovery.txt -o /dev/null </dev/null` succeeds, which validates
      the recipients with no secret involved: "no usable recovery recipient" (C3, ruling 3).
   5. `fwkey card-id <disk>` succeeds. This always holds, because USB with no serial falls
      back to `board:`.
   6. **Last:** `fwkey ensure`. `/dev/vcio` must exist, and the probe must reuse a key or
      `genkey` a blank slot: "firmware key interface unavailable: <detail>" (I7).
4. **Mark and grow by 64 MiB.**
   - Write `converting` to `CIDATA/juniper-encrypt` (C1).
   - `sfdisk --relocate gpt-bak-std /dev/<disk>`: the image's backup GPT sits at 8 GiB, not
     at the end of the card.
   - Then grow the partition with an **absolute** size (I15): `cur` = the partition's sector
     count, and `echo "size=$((cur + 131072))" | sfdisk -N <n> --no-reread --no-tell-kernel
     /dev/<disk>`, then `partx -u -n <n> /dev/<disk>`.
5. **Encrypt in place, resumably.**
   1. `cryptsetup reencrypt --encrypt --init-only --type luks2 --key-slot 0
      --reduce-device-size 32M …` writes the header (data offset 16 MiB), with the
      passphrase on stdin. The fail-open guard is disarmed from here.
   2. ~~`cryptsetup token import --token-id 0` adds the `juniper` token.~~ Superseded 2026-10-11: see the note below step 5.
   3. `cryptsetup reencrypt --resume-only --progress-frequency 10` does the work: about
      3–10 minutes on SD for the 6 GiB partition (1.6 GiB used, every block rewritten).
      Progress goes to the serial console. The watchdog stays fed by PID 1, and the unit has
      `TimeoutStartSec=infinity`.
   > **Superseded 2026-10-11:** real cryptsetup refuses `token import` while the header is
   > marked for reencryption (a reboot loop on hardware). Token 0 is imported only after the
   > conversion completes (step 6's resume). See "Hardware findings".

6. **Interrupted runs** are recognised on the next boot:
   - **After the header, before the token (C1):** the root is LUKS with label `juniper-root`
     and no `juniper` token, on the CIDATA disk, with GPT type root-arm64 and marker
     `converting`. Prepare imports the token (root_uuid from the command line) and continues
     with step 6's resume.
   - **Mid-reencrypt** (header requirement `online-reencrypt-v2`): `cryptsetup repair` with
     the passphrase (the spike showed it is required), then `reencrypt --resume-only`.
   - **Plain XFS with marker `converting`:** the header was never written, and the previous
     boot never continued (the guard would have recorded otherwise). Retrying from step 3 is
     safe.
7. **Seal the recovery key.** C3 and I5 set the order:
   1. `R` = 32 random bytes as 64 hex characters, in shell memory only.
   2. `printf '%s' "$R" | age -R juniper-recovery.txt -a -o CIDATA/juniper-recovery.age.new`.
      If this fails, nothing has changed on the header; prepare logs it and retries next
      boot, and the status reports `recovery=pending` with a warning.
   3. If slot 1 is active (a cut-short earlier try), `cryptsetup luksKillSlot <part> 1`
      authorised by the board passphrase.
   4. `fwkey derive | cryptsetup luksAddKey --key-slot 1 --key-file - <part> /dev/fd/3
      3< <(printf '%s' "$R")`. `R` goes through a pipe; no here-string, no file.
   5. Import token 1 (`juniper-recovery`, the armored ciphertext). Then `mv` the `.new` file
      into place and `sync`. Set token 0 to `recovery: sealed` with `recipients: <n>`.
8. **Grow to the end of the disk:** `echo "size=+" | sfdisk -N <n> …`, then `partx -u`. The
   LUKS2 data segment is "whole device" (dynamic, confirmed in the spike), so opening covers
   the new space without `cryptsetup resize`. That command would need the passphrase after
   switch-root. The XFS grows after switch-root through cloud-init's `resizefs`, already
   patched for `/var`. cloud-init `growpart` stays configured as today. On a LUKS root it
   finds the partition already at full size (NOCHANGE); Task 13 confirms that on hardware.
9. **Record** `encrypted` in `CIDATA/juniper-encrypt` and `/run/juniper/cryptroot`. The
   "encrypted, nothing pending" path also records `encrypted` if the marker still says
   `converting` (a cut after the grow).
10. Unlock opens the device. cloud-init runs on the encrypted root, and `juniper-firstboot`
    scrubs the CIDATA secrets as today. It leaves `juniper-recovery.age`, `.txt` and
    `juniper-encrypt` alone (they are public), and copies `juniper-recovery.age` to
    `/var/lib/juniper/recovery.age`.

**Fail open is final.** Once a device boots plain, cloud-init writes secrets, so it is never
encrypted later. Reflash to encrypt.

## Updates and rollback

- **The key doesn't depend on the deployment,** and the kernel command line doesn't change.
  `build.sh` regenerates every image's initramfs with the module.
- **rpi-bootc-bootloader `MNTDEV`.** Its own guess (`sed 's/[0-9]+$/1/'` on the `/sysroot`
  device) names the root device itself for `/dev/mapper/juniper-root`.
  - `finalize-staged` then **silently skips** the sync, and `sync` would write the firmware
    configs into the root filesystem.
  - Fixed by PR #75 (plan Task 1): the `/usr/libexec/juniper/bootloader` wrapper sets
    `MNTDEV=$(cidata-device)`. The healthcheck, `apply-update` and an
    `ostree-finalize-staged.service` drop-in use it. Upstream honours an exported `MNTDEV`
    (verified at lines 214 and 347).
  - The booted deployment's unit runs finalize-staged, so the wrapper must be in the
    deployment that is running. Encrypted cards only exist on images that already have it.
- **No header writes under tryboot** (I9, above), so a fallback always returns to a header
  the old deployment can read.
- **Switching to an image without the hook** would produce a deployment that can't unlock.
  tryboot makes it fall back. `ujust switch` also refuses on an encrypted root unless the
  target carries the label `org.juniper.cryptroot=v1`.
- **Size:** about +13 MB uncompressed in the initramfs, an estimated **+5–6 MB** on today's
  28.7 MB. Dropping the x86 microcode saves 0.3 MB. The existing 35 MiB image-test cap
  becomes 40 MiB (I11).

## Recovery

| Situation | What the owner does |
|---|---|
| Read the data (dead board, lost Pi, moved card) | Put the card in a Linux laptop and run `just unlock-card /dev/sdX [IDENTITY]` (default `~/.ssh/id_ed25519`, then `id_rsa`). It reads `juniper-recovery.age` from CIDATA, or **from LUKS token 1 if the FAT copy is gone** (I10). It pipes `age -d -i IDENTITY` into `cryptsetup open --readonly --key-file -` and mounts the result read-only. By hand: `age -d -i ~/.ssh/id_ed25519 /run/media/$USER/CIDATA/juniper-recovery.age \| sudo cryptsetup open --readonly /dev/sdX3 juniper-recovered --key-file -` |
| Move the card to a new Pi, or clone it | **Not in v1** (ruling 5; #76). Copy the data off with `unlock-card`, then reflash |
| A copy of the sealed file for safekeeping | `scp` `/var/lib/juniper/recovery.age` from the running device. It is ciphertext, useful only with the SSH key |
| SSH key lost or rotated | The old key still decrypts the old blob. `ujust recovery-reseal` (optional plan task) asks the initramfs to replace slot 1 and both copies of the ciphertext at the next confirmed boot |
| No recovery key at all | Reflash. The node is cattle |

age supports only `ssh-ed25519` and `ssh-rsa` SSH recipients, plus native `age1…` keys. It
skips ECDSA and FIDO `sk-` keys (spike F9).

- With an explicit `encrypt: true` and no usable recipient, `just flash` refuses.
- With the default on and no usable recipient, it writes `off` and warns (ruling 3).
- Decryption needs the private key **file**. Keys held only in an agent or a password manager
  can't decrypt, so the README says to set `recovery_key:` in that case.

## Pi 4 behaviour (best-effort)

- **Cipher:** Adiantum. The kernel modules are present, and today's initramfs already
  carries them.
- **Firmware:** the key interface comes from `start4.elf` on FAT, which is never updated
  after flashing. The current image's `start4.elf` (2026-05-21) has the HMAC, genkey and
  key-status handlers. A failed probe means fail open with "firmware key interface
  unavailable".
- **Lock:** expect `key_lock=unavailable` (ruling 4).
- First-boot time is bounded by the card's I/O.

## Reporting: MOTD, pi-status, metrics

`/var/lib/juniper/encryption` (key=value). `juniper-encryption-status` writes it at every
boot from `/run/juniper/cryptroot` (written by unlock) and checks it against the live device:

```
state=encrypted              # or not-encrypted
reason=                      # e.g. "firmware key interface unavailable", "not requested at flash time"
cipher=aes-xts-plain64
binding=board+mmc            # board+nvme, board+usb, board (USB disk without a serial)
key_lock=unavailable         # or locked (expected unavailable until EEPROM ≥ 2026-06-17)
recovery=sealed:2            # sealed:<recipients>, pending, or none
```

- **MOTD:** a red Warning row when `state=not-encrypted`:
  `Storage NOT ENCRYPTED (<reason>): anyone holding this card can read its secrets. Reflash to encrypt.`
  There is also a Warning row when it is encrypted but `recovery≠sealed:*` (C3):
  `Storage recovery key not sealed (<recovery>): only this Pi can unlock this card.`
- **`ujust pi-status`:** for example
  `Storage: encrypted (LUKS2 aes-xts-plain64, bound to this Pi and card; key lock: unavailable; recovery: sealed to 2 keys)`.
  With `binding=board`: "bound to this Pi only (USB disk has no serial; a clone unlocks on
  this Pi)". Or `Storage: NOT ENCRYPTED (<reason>). Reflash to encrypt.`
- **Metrics:** the existing `juniper-metrics` script (#71), which owns
  `/var/lib/juniper/metrics/juniper.prom` and rewrites it every 5 minutes, reads
  `/var/lib/juniper/encryption` and emits three gauges (I4):
  - `juniper_encrypted 0|1`;
  - `juniper_encryption_key_locked 0|1`;
  - `juniper_encryption_recovery_sealed 0|1`.

  `ujust enable-metrics` already passes the textfile directory. Document the alert
  `juniper_encrypted == 0 or juniper_encryption_recovery_sealed == 0` in the README.

## `just flash`

New `flash.yaml` keys:

```yaml
# encrypt: true            # opt-in until the hardware run passes; then on unless `encrypt: false`
# recovery_key: age1...    # optional; replaces ssh_keys as the recovery recipients
```

- `render-cidata` writes to CIDATA:
  - `juniper-encrypt` (`on`/`off`);
  - with `on`, `juniper-recovery.txt`: the `ssh-ed25519` and `ssh-rsa` lines from
    `ssh_keys`, or the `recovery_key`.
- The summary gains `Encrypt:   yes (recovery: 2 SSH keys: SHA256:…, SHA256:…)` or
  `no (<why>)`.
- With encryption on, this warning prints before the y/N question:

  ```
  Encryption: on first boot this Pi writes a permanent device key into its one-time-programmable memory (if it has none) and encrypts this card to this Pi and this card; first boot takes a few minutes longer (don't cut power; it resumes if you do); recovery needs your SSH private key. Set encrypt: false to skip.
  ```

- An explicit `encrypt: true` with no age-compatible recipient refuses. After the flip, the
  default-on case writes `off` and warns instead. A `recovery_key` that isn't `age1` plus
  58 bech32 characters refuses.

## Hardware test plan (owner's Pi 5 first; then a Pi 4)

0. **EEPROM (ruling 7, the owner's call):** `ujust pi-eeprom apply` to reach 2026-05-11 is
   recommended (2026-01-21 fixed an HMAC lock-up), but it has no tryboot fallback. Record
   `vcgencmd bootloader_version`.
1. Flash `juniper-minimal` with `encrypt: true`. Over the serial console
   (`console=ttyAMA10,115200`):
   - time the first boot and watch the progress;
   - check that `genkey` ran only if the slot was blank;
   - check `pi-status` "encrypted", `cryptsetup status juniper-root`, `juniper_encrypted 1`,
     and `key_lock=unavailable` (expected).
2. Card in a laptop: the root is `crypto_LUKS`, and `strings` on a sample finds nothing.
   `just unlock-card` mounts it. Delete `juniper-recovery.age` from FAT (on a copy) and check
   that `unlock-card` still works from the token.
3. Pull the power at about 30% of the conversion: the next boot resumes and completes.
4. `dd` the card to a second card and boot it in the same Pi: **no** unlock, the console
   hint shows, and it reboots about every 3 minutes.
5. Move the original card to a second Pi: no unlock.
6. Run `ujust update` through tryboot: the bootloader sync reaches FAT, and the new
   deployment unlocks and becomes default. A deliberately broken update falls back. Prepare
   logs "deferred until a confirmed boot" under tryboot.
7. Fail open: flash with `encrypt: true` and add `juniper.encrypt=0` to the entry's
   `cmdline.txt` before the first boot. The device boots plain, `CIDATA/juniper-encrypt`
   says `not-encrypted:juniper.encrypt=0`, the MOTD warns, and `juniper_encrypted 0`.
   Removing the karg later doesn't encrypt.
8. `encrypt: false`: no OTP write, plain root, cloud-init `growpart` grew it as today.
9. Performance: `fio` on the encrypted root against the same card unencrypted.
10. Pi 4 (best-effort): repeat 1, 2, 3 and 8.

## Rollout

1. **PR #75** (plan Task 1): the `MNTDEV` wrapper, separate and harmless on plain roots.
2. **The implementation PR** (plan Tasks 2–9 and 11, 12b) merges with `encrypt`
   **defaulting to false**. Plain cards see only:
   - `lock_device_private_key=1`;
   - the NOT ENCRYPTED reporting.

   cloud-init growpart is unchanged.
3. **The owner's Pi 5 hardware run** (Task 13).
4. **Flip PR** (Task 14).

## Hardware findings (2026-10-11)

First runs on a Pi 5 changed three parts of the design above:

- **Firmware gate.** `hmac` on EEPROM 2025-11-05 locks up the mailbox. `fwkey` reads
  `/proc/device-tree/chosen/bootloader/build-timestamp` and requires at least 1769002727
  (pieeprom-2026-01-21) on a Pi 5; older firmware means no encryption and a warning. On a
  Pi 4 it fails open (unverified).
- **Probe with `pubkey`.** Exit 250 means the key is not set, the only case that runs
  `genkey`. Every `rpi-fw-crypto` call has a deadline; one that overruns writes a wedged
  marker and the boot fails open.
- **Superseded 2026-10-11: the config lock.** `lock_device_private_key=1` in `rpi-config.txt`
  (Ruling 4 and the "Never read raw" bullet) is gone. It sets the old global key lock (status
  bit 8, READ_LOCKED), which on EEPROM 2026-05-11 also blocks `genkey`: the serial log showed
  "genkey failed (firmware error 4)" and `get-key-status 1` read 0x101. A board with no key
  could never be provisioned. Per-operation locks (READ, GEN, HMAC) exist from 2026-06-17, and
  `fwkey lock` applies them at runtime after unlock. `fwkey` reports a status with bit 8 set
  on older firmware as `unavailable:key-locked-by-config` and doesn't try `genkey`.
- **Token 0 follows the conversion.** cryptsetup refuses `token import` while the header is
  marked for reencryption. The token is imported after the conversion completes. Until then
  the candidate is found by the `converting` marker, the GPT root type (root-arm64) and the
  CIDATA disk.

## Spike findings (2026-10-11)

Blockers come first. Rows marked "review" were added by the pre-flight review.

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| B1 | **Today's initramfs can't unlock LUKS.** `crypt` and `dm` are in, but `systemd-cryptsetup` isn't, so there is no `systemd-cryptsetup`, no generator, no `cryptsetup.target`, and no `cryptsetup` binary. The base got `systemd-cryptsetup` through clevis/tpm2-tss, which `90-juniper.conf` omits, and `90crypt` installs `cryptsetup` only without systemd | `lsinitrd`; the module scripts in the image | Juniper's own dracut module installs `cryptsetup` explicitly |
| B2 | **`rpi-fw-crypto` isn't packaged for EL10** (AlmaLinux 10 `raspberrypi` has only firmware, kernel, userland, rpi-eeprom and sys-mods; it isn't in EPEL 10; COPR has only `pbrobinson/rpi` for Fedora and the stale `lucamagrone/el10-pi`) | `dnf repoquery`, COPR API | Build it from `raspberrypi/utils` at a pinned commit (`rpifwcrypto/` last changed at `61371fa`, 2026-06-17). Upstream's "3.10" is the CMake minimum; EL10 gnutls 3.8.10 is fine |
| B3 | **rpi-bootc-bootloader with root on `/dev/mapper`** mounts the root XFS as "FAT", so `finalize-staged` silently skips the sync | v0.0.8 lines 214–225 and 346–372 | Wrapper (PR #75) |
| B4 | **Converting after udev races systemd's root-device handling** (BindsTo) | Design analysis. Review: dracut sets no root device timeout; initqueue starts after udev-trigger | Convert before udev, unlock after. Task 5 serial smoke test |
| F1 | Kernel has everything: `DM_CRYPT=m`, `CRYPTO_ADIANTUM=m`, `CRYPTO_CHACHA20(_NEON)=m`, `CRYPTO_NHPOLY1305_NEON=m`, `CRYPTO_AES_ARM64_CE(_BLK)=m`, `CRYPTO_XTS=y`, `CRYPTO_USER_API_SKCIPHER=m`, `RASPBERRYPI_FIRMWARE=y`, `BCM_VCIO=y`, `HW_RANDOM_BCM2835=y`; MMC, NVMe, USB storage/UAS/xHCI, PCIe and VFAT are built in; `XFS_FS=m` | `config-6.12.96-20260724.v8.1.el10` | No kernel change |
| F2 | `cryptsetup-2.8.1`, `systemd-257`, `gnutls-3.8.10`, `xfsprogs-6.16.0`, `rpi-eeprom(-firmware)-2026.05.11` are in the image; `age-1.3.1` is in EPEL 10 (the binary is about 4.7 MB) | rpmdb, repoquery | `age` from EPEL |
| F3 | GPT: p1 1 GiB CIDATA, p2 1 GiB `/boot`, p3 6 GiB root-arm64 ending at the image's last LBA; backup GPT at 8 GiB. Root XFS: 4 KiB blocks, **512-byte sectors**, 1.56 GiB of 6 GiB used. **Every card of a release has the same filesystem UUIDs** | GPT parse, `xfs_db` | Sector size 512; relocate the backup GPT; candidate rules |
| F4 | Offline `reencrypt --encrypt --reduce-device-size 32M` works and leaves a dynamic segment at a 16 MiB data offset. **A killed run needs `cryptsetup repair` before `--resume-only`.** `luksAddKey`, `token import` of custom JSON and `--test-passphrase` work | laptop, cryptsetup 2.8.8 | Repair, then resume. Integrity is checked in the Task 6 loop test |
| F5 | The Pi 4 `start4.elf` (2026-05-21) contains the fw-crypto handlers | `strings` | Pi 4 likely works |
| F6 | Pi 5 EEPROM: genkey from 2025-09-25, HMAC lock-up fix 2026-01-21; the package's newest is 2026-05-11, before the 2026-06-17 locks | the shipped release notes | Ruling 4 |
| F7 | The initramfs is 28.7 MB and its early cpio carries x86 `AuthenticAMD.bin` (`early_microcode="yes"`) | `lsinitrd` | `early_microcode="no"` |
| F8 | `block-device-id` covers MMC and NVMe, not USB | `src/device.rs` | USB rule; ruling 1 |
| F9 | age refuses ECDSA and FIDO `sk-` recipients | age 1.3.2 | `render-cidata` filter |
| F10 | PID 1 feeds the watchdog in the initramfs (`50-juniper-watchdog.conf` is included) | `lsinitrd` | No change |
| F11 (review) | `/dev/vcio` is root-only (devtmpfs 0600; no udev rule widens it). `af_alg`/`algif_skcipher` are in the initramfs only through `crypt`. `tests/image.sh` caps the initramfs at 35 MiB. `juniper-metrics` owns `juniper.prom`. `desktop.sh` replaces `rpi-config.txt` | the image at `4ff27c3` | Image test for `/dev/vcio`; explicit modules; cap 40 MiB; metrics in `juniper-metrics`; desktop config too |

## Risks

1. **Before-udev ordering** is the least-trodden part; it is proven over serial in Task 5.
2. **`genkey` atomicity under power loss** is undocumented. A torn write would leave the slot
   unusable, for Connect too. The window is milliseconds; the README states the risk.
3. **No HMAC lock** (ruling 4): a remote root can derive the passphrase.
4. **USB disks without a serial** are bound to the board only (ruling 1). An SD card in a USB
   reader binds to the reader's serial.
5. **Recovery custody:** an SSH key **file** must survive. The blob survives losing FAT
   (token copy).
6. **SD wear and time:** one 6 GiB rewrite on first boot.
7. **Packaging:** `rpi-fw-crypto` needs manual bumps (`just bump-fwcrypto`).
8. **Two identical Juniper disks attached:** the conversion fails open; unlock tries each
   candidate.
9. **`rpi-otp-private-key -w -f`** run by hand corrupts the key. Only recovery then works.
10. **Future (#73):** an EEPROM downgrade below 2025-08-20, or an HMAC lock set before Linux
    runs, stops board unlock. The recovery key still works. Note both in #73.
