# Encryption at rest — design (sub-project C, issue #50 Phase 2)

Status: design and spike only (2026-10-11). Owner decisions from issue #50 (2026-10-11) are
folded in below. Nothing here has run on hardware. The spike looked at the published
`ghcr.io/gnathoi/juniper-minimal:latest` image (arm64, digest
`sha256:2916f838350b986775d6a6c150df480587d415b5493a32f600826e5e3a7480f0`, base
`10.2.20261002.0`, kernel `6.12.96-20260724.v8.1.el10`) and the `build-20261011` disk image,
without running them. It also ran `cryptsetup` 2.8 against image files on an x86 laptop. Its
evidence is in "Spike findings" at the end. The implementation plan is
`docs/superpowers/plans/2026-10-11-encryption.md`.

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
2. Put the card in a laptop and the root partition is `crypto_LUKS`. Nothing under `/etc`
   or `/var` is readable. The FAT partition holds the firmware, kernel and initramfs as
   today, plus `juniper-recovery.age`.
3. Put the card in another Pi, or clone it to another card and boot that in the same Pi, and
   it doesn't unlock.
4. On a laptop, `just unlock-card /dev/sdX` with the owner's SSH key mounts the card's root.
5. If anything in the encryption path can't run (no firmware key interface, a failed call,
   no usable recovery recipient, a USB disk with no serial), the device boots unencrypted
   ("fail open"). It then says **NOT ENCRYPTED** loudly in the MOTD, in `pi-status` and in
   the metrics (`juniper_encrypted 0`).

## Non-goals

- **A stolen board** (board and card together). Without Raspberry Pi secure boot, whoever
  holds the board can boot their own code and ask the firmware for the same HMAC. That case
  waits for secure boot (#73) and is documented as a limitation.
- **Tampering ("evil maid").** The FAT and `/boot` partitions (firmware, `config.txt`,
  `cmdline.txt`, kernel, initramfs) stay unsigned and unencrypted. Someone who modifies the
  card and gives it back can capture the key. Only secure boot (#73) closes this.
- **A root attacker on a running device.** Root sees the decrypted filesystem. We narrow one
  thing only: after unlock the initramfs locks the firmware HMAC where the firmware allows
  it, so a later remote root can't derive the key and take it away.
- **Migrating existing devices in place.** Owner decision: reflash only. Existing devices
  report "not encrypted".
- **TPM HATs and Tang/clevis.** These are possible later phases (issue #50 §6).
- **Encrypting `/boot` or the FAT partition.** The firmware must read them.

## Owner decisions (issue #50, 2026-10-11)

| Topic | Decision |
|---|---|
| Scope v1 | Protect a stolen **card**. Board theft is a documented limitation until secure boot (#73) |
| Default | Encryption and OTP key provisioning are **on by default**. `encrypt: false` in `flash.yaml` skips both. `just flash` prints a one-line warning |
| Rollout | Merge with encryption **gated off** (opt-in with `encrypt: true`) until the owner's Pi 5 hardware test passes. A small follow-up PR then flips the default to on and adds the warning |
| OTP key | First boot provisions the board's OTP key if it has none (irreversible) with `rpi-fw-crypto genkey`, and reuses an existing key. Never read raw. Lock after unlock |
| Key binding | **Board OTP key + card serial**, so a cloned card won't unlock, even in the same board |
| Recovery | An offline recovery keyslot, **sealed with age to the SSH public keys already in `flash.yaml`** (age's `ssh-ed25519`/`ssh-rsa` recipients). An optional `recovery_key:` (an `age1…` public key) replaces them. Recovery is the owner's SSH private key on a laptop |
| Failure | **Fail open.** If first-boot encryption can't run, boot unencrypted with a loud NOT ENCRYPTED warning in the MOTD, `pi-status` and metrics (`juniper_encrypted 0`) |
| Hardware | **Pi 5 first.** Pi 4 is best-effort: encrypt only if the firmware key interface works, otherwise fail open and warn |
| Existing devices | **Reflash only.** `pi-status` reports "not encrypted" |
| Secure boot fusing | Not part of this (#73). #73 would reuse the same OTP key |

## Threat model

"Protected" means the attacker learns nothing beyond the public OS image and the boot files.

| Attacker has | Today | After this design | Notes |
|---|---|---|---|
| The card only (lost, stolen, discarded) | Everything: Wi-Fi PSK, SSH host keys, Tailscale node state, `/etc/shadow`, workload data | **Protected** | The FAT partition still holds whatever CIDATA secrets the first-boot scrub hadn't removed yet (existing exposure, #60) |
| An image or clone of the card, booted in the same Pi | Everything | **Protected** | The HMAC input includes the card serial (MMC CID, NVMe serial, USB serial) |
| The card plus another Pi | Everything | **Protected** | Different OTP key |
| The card plus `juniper-recovery.age` (it sits on the card's FAT partition) | n/a | **Protected** | It needs the owner's SSH private key |
| The card plus the owner's SSH private key | Everything | Everything | That is what recovery means. Keep SSH keys passphrase-protected. Rotate with `recovery-reseal` (plan, optional task) |
| Board and card together | Everything | **Everything** (documented) | Any code on the board can ask the firmware for the HMAC. #73 |
| The card, modified and returned (evil maid) | Everything | **Everything** (documented) | An unsigned initramfs on FAT can keep the key. #73 |
| Remote root on the running device | Everything live | Everything live | After unlock, `HMAC_LOCKED` stops root deriving the key for later offline use. That needs firmware that supports it (Pi 5 EEPROM 2026-06-17 or later; see Risks) |
| Wear-levelled remnants on the SD card | Secrets in old blocks | **Only the public OS image** | Encryption runs in the initramfs **before** cloud-init writes anything, so no secret is ever written to the root partition in plaintext |
| The flash host (the owner's laptop) | Sees the CIDATA secrets | Same, plus the public recovery recipients | It never sees the device key or the recovery passphrase. Both are made on the device |

## Key derivation

The OTP research (issue #50 comment, 2026-10-11) settles the details:

- **Interface:** `rpi-fw-crypto` (raspberrypi/utils `rpifwcrypto/`) over the `/dev/vcio`
  firmware mailbox. Key id **1**, the only one the firmware exposes on Pi 4 and Pi 5. It is
  shared with Raspberry Pi Connect and Raspberry Pi's own FDE tools.
- **Probe, then generate only if blank.** `rpi-fw-crypto hmac --key-id 1` runs on the fixed
  probe message `juniper.probe.v1`:
  - success: reuse the key. It may come from Connect, rpi-sb-provisioner or an earlier
    Juniper boot.
  - `KEY_NOT_SET` (error 6): `rpi-fw-crypto genkey --key-id 1 --alg ec`, then probe again.
    `genkey` makes a valid P-256 key inside the firmware. Linux never sees it.
  - `KEY_LOCKED` (4), any other error, or no `/dev/vcio`: **never write**. Fail open with
    the reason.

  The CLI exits with `-error` (so 250 for error 6) and prints `Last crypto error: N (…)`.
  The helper parses that line, not the exit code.
- **Never read raw.** No `privkey`, no `rpi-otp-private-key`, no `vcmailbox 0x00030081`.
  The image's per-deployment `rpi-config.txt` gains `lock_device_private_key=1`, so the raw
  read API is closed on every boot. That line costs nothing on unencrypted devices. **No**
  `lock_device_key_write=1`: it would make `genkey` fail.
- **Don't set the key-usage field.** It is an OTP write, and Connect's reaction to it is
  unknown.
- **Message (domain separated):**

  ```
  msg  = "juniper.luks.root.v1" || 0x00 || <id-type> || ":" || <card-id>
  pass = lowercase hex( HMAC-SHA256(OTP key 1, msg) )      # 64 characters
  ```

  `<id-type>:<card-id>` takes the first of these that applies to the disk holding the root
  partition, read from sysfs with no udev needed:
  - `mmc:` plus the contents of `/sys/block/mmcblkN/device/cid`. This is the same source
    as Raspberry Pi's `block-device-id`.
  - `nvme:` plus `/sys/block/nvmeXnY/device/serial` (spaces trimmed).
  - `usb:` plus `<idVendor>:<idProduct>:<serial>` of the USB device above the disk.
    `block-device-id` doesn't cover USB. With no non-empty serial attribute, fail open
    ("USB disk has no serial number"). Many adapters lack one or share it; see the owner
    questions.

  The label keeps Juniper's derivation apart from Raspberry Pi's (which is bare
  `block-device-id` output), so neither can produce the other's passphrase. `v1` leaves
  room to re-key later. The message is far below the firmware's 2048-byte limit.
- **Lock after unlock.** After `cryptsetup open` (and after any first-boot keyslot work),
  the initramfs runs one call,
  `rpi-fw-crypto set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED`. SIGN
  stays unlocked so Connect still works. Then `get-key-status 1` confirms bit 11
  (`HMAC_LOCKED`). The result goes to the status file as `key_lock=locked|unavailable`.
  Locks last until reboot. Anything that needs the HMAC (re-binding, re-sealing the
  recovery key) therefore happens in the initramfs.
- **LUKS2 parameters:**
  - Cipher: `aes-xts-plain64` with 512-bit keys when `/proc/cpuinfo` lists `aes` (Pi 5:
    ARMv8 crypto extensions). Otherwise `xchacha12,aes-adiantum-plain64` with 256-bit keys
    (Pi 4: no AES instructions).
  - Sector size 512: the bib-made XFS has 512-byte sectors and `cryptsetup` refuses 4096
    (spike).
  - Key derivation: `--pbkdf pbkdf2 --pbkdf-force-iterations 1000`. Both secrets are
    256-bit random values, so a slow KDF adds nothing and Argon2's memory cost would hurt
    in the initramfs.
  - `--label juniper-root`, and `--allow-discards` at open time. Discards reveal which
    blocks are in use, which is acceptable on SD.
  - A LUKS2 token of type `juniper` records `root_uuid` (the inner XFS UUID from
    `root=UUID=`), `binding` (`juniper.luks.root.v1`), `id_type`, the keyslot numbers of
    the board slot and the recovery slot, and `recovery` (`pending` or `sealed`).

## Boot and unlock flow (every boot)

The kernel command line does **not** change. `root=UUID=<xfs-uuid>` (the same in both
deployments; only `ostree=` differs) keeps working, because in-place encryption keeps the
inner XFS and its UUID. Each boot runs two initramfs units from Juniper's dracut module
`90juniper-cryptroot`. Systemd's own `systemd-cryptsetup` is not involved.

1. **`juniper-cryptroot-prepare.service`** runs before udev. It is ordered
   `Before=systemd-udevd.service systemd-udev-trigger.service`, after kernel modules.
   - It finds the root partition without udev. It takes `root=UUID=X` from
     `/proc/cmdline` and polls `blkid` for up to 30 s, which reads `/proc/partitions`
     directly. Storage drivers are built into the kernel, so no modules need loading.
   - It handles these cases:
     - first-boot encryption (next section);
     - a resume after power loss;
     - pending keyslot work on a LUKS partition, from its token and CIDATA request files:
       a recovery slot still `pending`, `juniper-rebind.key`, `juniper-reseal.txt`. These
       are offline header operations;
     - growing the partition. A plain XFS whose partition doesn't yet reach the end of
       the disk is grown on any device.
   - A partition that is already LUKS and complete, with nothing pending, needs nothing
     here. The usual cost is one `blkid` call and one token read.
   - It runs before udev because a first-boot conversion makes the root filesystem
     disappear and reappear under systemd. Doing it before udev means systemd only ever
     sees the final state. See "Why before udev" below.
2. **`juniper-cryptroot-unlock.service`** runs after udev
   (`After=systemd-udev-trigger.service`, `Before=initrd-root-device.target
   cryptsetup.target`).
   - If `root=UUID=X` resolves to a plain filesystem, it exits 0: an unencrypted device.
   - Otherwise it looks for `crypto_LUKS` partitions labelled `juniper-root` whose `juniper`
     token has `root_uuid == X`. For each one it derives the passphrase from that disk's
     id. The first candidate that opens becomes `/dev/mapper/juniper-root`
     (`cryptsetup open --allow-discards --key-file -`, with the passphrase on stdin).
     Every card of a release has the same XFS UUID, so more than one Juniper disk can
     match. Only this card's serial opens it.
   - It then locks the key and writes `/run/juniper/cryptroot` (state, cipher, key lock,
     recovery). `/run` carries over through switch-root. All keyslot work happens earlier,
     offline, in the prepare unit: first-boot recovery that was cut short, a re-bind
     request, a re-seal request.
   - udev then sees the inner XFS and creates `/dev/disk/by-uuid/X`. `sysroot.mount`
     proceeds unchanged, within the default 90 s device timeout, because unlock takes a
     couple of seconds.
3. **Unlock failure** (moved card, firmware error) leaves no root device, and the initramfs
   fails as it does today (`rd.emergency=reboot`). The unlock unit first retries three
   times, 10 s apart.
   - **Under tryboot** this falls back to the previous deployment.
   - **Otherwise** the device reboots, which can loop. The unit sleeps 5 minutes before
     failing on a normal boot, so a moved card doesn't spin. The console prints "this card
     is bound to another Raspberry Pi or another card; unlock it with the recovery key
     (just unlock-card) or re-bind it (just rebind-card)".
4. **After switch-root,** `juniper-encryption-status.service` copies the boot's state to
   `/var/lib/juniper/encryption` and the metrics file. It checks the live device too:
   `/sysroot` must sit on a `crypt` device.

### Why before udev

On first boot the root filesystem `X` is visible as plain XFS. `sysroot.mount` binds to its
device unit. Converting it after udev has seen it makes that device vanish for minutes, then
come back as a dm device. systemd would stop or fail the pending `sysroot.mount` job
(BindsTo), and the device job's 90 s timeout fires during a conversion of several minutes.
Before udev, there are no device units yet:

- the block device nodes come from devtmpfs (the drivers are built in);
- `/dev/vcio` is there (the driver is built in);
- `cryptsetup` reencrypts offline in user space with no dm devices;
- libdevmapper sees no udev and doesn't wait for it.

The normal unlock stays after udev, so the dm device gets proper udev processing. The plan
verifies this ordering first in a VM-free loop test and then on hardware.

## First-boot flow

All of this happens in the initramfs, before `sysroot.mount`, before cloud-init, and so
before any secret is written to the root partition. The CIDATA (FAT) partition is the one
on the same disk as the root partition: its GPT type is ESP and its label is `CIDATA`.

1. **Decide.** Read `juniper-encrypt` from CIDATA (`on` or `off`; `just flash` writes it)
   and `juniper-recovery.txt` (age recipients, public). If the file is missing (a card
   written by Imager or `dd`), the device stays plain with reason "not requested at flash
   time"; see the owner questions. If a kernel argument `juniper.encrypt=0` is present,
   the device also stays plain (a debugging escape hatch). For anything other than `on`,
   only grow the partition (step 7), record the reason and continue.
2. **Preconditions.** If any of these fails, fail open with its reason:
   - Exactly one partition carries `UUID=X`. Two attached Juniper cards from the same
     release share it.
   - The root partition is GPT type root-arm64 (`b921b045-…`) on the same disk as
     CIDATA.
   - The disk has a card id (above).
   - The disk has at least 64 MiB free past the root partition (any ≥16 GB card does).
   - `juniper-recovery.txt` has at least one recipient.
   - `/dev/vcio` exists, and the key probe gives a usable key, after `genkey` if it was
     blank.
3. **Grow by 64 MiB.** XFS can't shrink, and `--reduce-device-size` needs unused space at
   the end of the device.
   - `sfdisk --relocate gpt-bak-std` first: the bib image's backup GPT sits at 8 GiB, not
     at the end of the card.
   - Then `sfdisk -N 3` and `partx -u`.
4. **Encrypt in place, resumably.**
   - `cryptsetup reencrypt --encrypt --init-only --type luks2 --reduce-device-size 32M
     --label juniper-root …` writes the header (data offset 16 MiB). The passphrase comes
     from stdin and never touches a disk.
   - `cryptsetup token import` adds the `juniper` token with `recovery: pending`. A power
     cut is now recognisable on the next boot.
   - `cryptsetup reencrypt --resume-only` does the work. It moves and encrypts the 6 GiB
     partition (about 1.6 GiB of it is used, but every block is rewritten) with datashift
     resilience. Expect roughly 3–10 minutes on a decent SD card; the hardware test
     measures it.
   - The systemd watchdog keeps running (PID 1 feeds it). The unit has
     `TimeoutStartSec=infinity`.
5. **Power loss** during step 4 leaves a LUKS2 header with the `online-reencrypt-v2`
   requirement and our token. The next boot's prepare unit finds it by label and token
   (`root=UUID=X` no longer resolves to plain). It runs `cryptsetup repair` with the
   passphrase, which the spike showed is required after an interruption, then
   `reencrypt --resume-only`.
6. **Recovery keyslot.**
   - Generate `R` (32 random bytes as hex) in shell memory.
   - `cryptsetup luksAddKey`: the board passphrase goes in on stdin and `R` through a pipe
     (`/dev/fd/3`).
   - `age -R juniper-recovery.txt` encrypts `R` to `CIDATA/juniper-recovery.age`, also
     through a pipe. `sync`, then check that the file is non-empty and parses as age.
   - Set the token to `recovery: sealed` with the slot number.
   - `R` is never written to any file. If power is lost between the keyslot and the file,
     the next boot sees `recovery: pending`. It kills the half-made slot and repeats this
     step.
7. **Grow to the end of the disk.** Use `sfdisk -N 3` with the full size. The LUKS2 data
   segment is "whole device" (dynamic; confirmed in the spike), so opening it covers the
   new space without `cryptsetup resize`. Doing this before opening is deliberate:
   - `cryptsetup resize` on an active LUKS2 device needs the passphrase again;
   - with the HMAC locked, nothing after switch-root can supply it.

   The XFS grows after switch-root through cloud-init's `resizefs`, already patched to
   resize the filesystem holding `/var`. Juniper turns cloud-init's `growpart` off
   (`mode: off`), because the initramfs now grows the partition on every image, encrypted
   or not.
8. **Record.** Write `encrypted` (or `not-encrypted:<reason>`) to `CIDATA/juniper-encrypt`,
   so the decision is final and later boots skip it. Write the same to
   `/run/juniper/cryptroot`.
9. The unlock unit opens the device as on any boot. cloud-init then runs on the encrypted
   root, and `juniper-firstboot` scrubs the CIDATA secrets as today. The scrub leaves
   `juniper-recovery.age` and `juniper-recovery.txt` alone: both are public.

**Fail open is final.** Once the device boots plain, cloud-init writes secrets to it, so
encrypting later would leave plaintext remnants. There is no retry. Reflash to encrypt.

## Updates and rollback

- **The key doesn't depend on the deployment,** and the kernel command line doesn't change.
  Both deployments' initramfs carry `90juniper-cryptroot`, because `build.sh` regenerates
  the initramfs with Juniper's dracut config on every build. The tryboot entry boots
  exactly like the default one.
- **rpi-bootc-bootloader must be told where the FAT partition is.** Today it computes
  `MNTDEV` by rewriting the device mounted at `/sysroot` (`sed 's/[0-9]+$/1/'`). For
  `/dev/mapper/juniper-root` that names the root device itself.
  - `finalize-staged` then mounts the root XFS a second time at `/tmp/mnt` and finds no
    `config-bootc-default.txt`. It **silently skips** the bootloader sync, so a staged
    update never reaches the firmware.
  - `sync` (run by the health check) would write the firmware configs into the root
    filesystem.
  - Fix (plan Task 1, shipped first): Juniper's wrapper `/usr/libexec/juniper/bootloader`
    sets `MNTDEV=$(cidata-device)` and execs `rpi-bootc-bootloader`. It is used by the
    health check, by `apply-update`, and by an `ostree-finalize-staged.service` drop-in
    that replaces the package's `ExecStop`. `cidata-device` already walks
    partition/LUKS/LVM layers.
  - Report it upstream (docs/upstream.md has the entry).
- **Switching to an image without the hook** (an old Juniper, or stock AlmaLinux) would
  produce a deployment that can't unlock its root.
  - tryboot makes it fall back.
  - `ujust switch` also refuses on an encrypted device unless the target image carries the
    label `org.juniper.cryptroot=v1` (plan Task 11).
  - Images built `FROM juniper-minimal` inherit the module and the dracut config.
- **Kernel or base updates** rebuild the initramfs with the module. `tests/image.sh` checks
  every image's initramfs for it.
- **Size:**
  - The initramfs grows by roughly 13 MB uncompressed (cryptsetup and its libraries,
    rpi-fw-crypto with libgnutls, age, sfdisk), estimated **+5–6 MB** on today's 28.7 MB.
  - Dropping the x86 AMD microcode that dracut puts in the arm64 early cpio saves 0.3 MB
    (spike side finding).
  - The FAT and `/boot` partitions (1 GiB each) hold two entries easily.
  - The plan's image test sets a 40 MB budget.

## Recovery

| Situation | What the owner does |
|---|---|
| Read the data (dead board, lost Pi) | Put the card in a Linux laptop: `just unlock-card /dev/sdX [--identity ~/.ssh/id_ed25519]`. It reads `juniper-recovery.age` from the card's CIDATA partition, decrypts it with `age -d -i <ssh key>` (which asks for the key's passphrase), and pipes the result into `cryptsetup open --key-file -` and a read-only mount. The passphrase is never written to disk. Without the recipe: `age -d -i ~/.ssh/id_ed25519 /run/media/$USER/CIDATA/juniper-recovery.age \| sudo cryptsetup open /dev/sdX3 juniper-root --key-file -` |
| Move the card to a new Pi, or clone it to a bigger card | `just rebind-card /dev/sdX` on the laptop, using the recovery key. It adds a temporary random keyslot `T` and writes `T` to `CIDATA/juniper-rebind.key`. At the next boot the initramfs opens with `T`, kills the old board slot, adds a slot for the new board and card, then kills the `T` slot and shreds the file. `T` touches the FAT partition, but its slot is gone within that boot, so leftover copies are useless (plan Task 10, possibly a follow-up PR) |
| A copy of the sealed file for safekeeping | `scp` it from `/var/lib/juniper/recovery.age` (copied there at first boot) or from the CIDATA partition. It is ciphertext and only useful with the SSH key |
| SSH key lost or rotated | The old key still decrypts the old blob. `ujust recovery-reseal` writes a request with the new recipients to CIDATA. On the next boot the initramfs makes a new `R'`, adds it, kills the old recovery slot and replaces the blob (plan, optional Task 12). Until then, the old key is the recovery key |
| No recovery key at all | Reflash. The node is cattle |

age supports only `ssh-ed25519` and `ssh-rsa` SSH recipients, plus native `age1…` keys.

- It skips `ecdsa-sha2-*` and FIDO `sk-*` keys, both of which Juniper accepts for login. The
  spike confirmed this with age 1.3.2.
- If `ssh_keys` has no usable key and there is no `recovery_key:`, `just flash` refuses to
  write an encrypting card. The message names the fix.
- Decryption needs the private key **file**. A key that lives only in an agent or a password
  manager (1Password SSH agent, a YubiKey PIV key) can't decrypt. In that case, set
  `recovery_key:` to an `age1…` key whose identity file is stored somewhere safe. The README
  says so.

## Pi 4 behaviour (best-effort)

- **Cipher:** Adiantum (`xchacha12,aes-adiantum-plain64`). The kernel has `adiantum`,
  `chacha-neon`, `nhpoly1305-neon` and `poly1305-neon` as modules, and today's initramfs
  already carries them.
- **Firmware:** the key interface comes from `start4.elf` on the FAT partition, which
  rpi-bootc-bootloader never updates. It stays at the flashed version. The current image's
  `start4.elf` (built 2026-05-21, `bcm2711_2`) contains the `arm_crypto_hmac_sha256`,
  `arm_crypto_gen_ecdsa`, `get-key-status` and `set-key-status` handlers and
  `lock_device_private_key`. So cards flashed from current releases should have it. Older
  firmware, or a failed probe, means fail open with reason "firmware key interface
  unavailable".
- **Per-operation locks** (`HMAC_LOCKED`) appear only in the 2712 release notes, so expect
  `key_lock=unavailable` on Pi 4. Its `READ` lock comes from `lock_device_private_key=1`.
- Performance and first-boot time are bounded by the card's I/O, not the CPU (Adiantum runs
  at about 160–240 MiB/s on a Pi 4).

## Reporting: MOTD, pi-status, metrics

`/var/lib/juniper/encryption` (key=value, written at every boot by
`juniper-encryption-status`):

```
state=encrypted              # or not-encrypted
reason=                      # e.g. "firmware key interface unavailable", "not requested at flash time"
cipher=aes-xts-plain64
binding=board+mmc            # board+nvme, board+usb
key_lock=locked              # or unavailable
recovery=sealed:2            # number of age recipients, or none
```

- **MOTD:** nothing when the device is encrypted. Otherwise a red Warning row:
  `Storage NOT ENCRYPTED (<reason>): anyone holding this card can read its secrets. Reflash
  to encrypt.`
- **`ujust pi-status`:** `Storage: encrypted (LUKS2 aes-xts-plain64, bound to this Pi and
  card; key lock: locked; recovery: sealed to 2 keys)`. Or
  `Storage: NOT ENCRYPTED (<reason>). Reflash to encrypt.` A device flashed before this
  feature reports `NOT ENCRYPTED (flashed before encryption support)`.
- **Metrics:**
  - `ujust enable-metrics` gains node_exporter's textfile collector
    (`--collector.textfile.directory=/host/var/lib/juniper/metrics`).
  - `juniper-encryption-status` writes `juniper.prom` there with `juniper_encrypted 0|1`,
    `juniper_encryption_key_locked 0|1` and `juniper_encryption_recovery_sealed 0|1`.
  - Devices that already enabled metrics pick it up when they re-run
    `ujust enable-metrics`.

## `just flash`

New `flash.yaml` keys (both documented in `examples/flash.yaml`):

```yaml
# encrypt: true            # until the hardware run passes; after the flip: on unless `encrypt: false`
# recovery_key: age1...    # optional; replaces ssh_keys as the recovery recipients
```

- `render-cidata` writes the following to CIDATA. Neither file is secret.
  - `juniper-encrypt`: `on` or `off`.
  - `juniper-recovery.txt`: the `ssh-ed25519` and `ssh-rsa` lines from `ssh_keys`, or the
    `recovery_key`.
- The summary gains a line:
  `Encrypt:   yes (recovery: 2 SSH keys: SHA256:…, SHA256:…)` or `no (encrypt: false)`.
- With encryption on, it prints this one-line warning before the y/N question (owner
  decision):

  ```
  Encryption: on first boot this Pi writes a permanent device key into its one-time-programmable memory (if it has none) and encrypts this card to this Pi and this card; first boot takes a few minutes longer (don't cut power; it resumes if you do); recovery needs your SSH private key. Set encrypt: false to skip.
  ```

- It refuses `encrypt: true` with no age-compatible recipient. It refuses a `recovery_key`
  that isn't `age1` plus 58 bech32 characters.

## Hardware test plan (owner's Pi 5 first; then a Pi 4)

0. Run `ujust pi-eeprom apply` on the Pi 5 to reach EEPROM 2026-05-11 or later (the owner's
   reported 2025-11-05; 2026-01-21 fixed an HMAC lock-up). Record `vcgencmd
   bootloader_version`, and the OTP key status before flashing: `sudo rpi-fw-crypto
   get-key-status 1` from a `juniper` image built with the tool.
1. Flash `juniper-minimal` with `encrypt: true`.
   - Time the first boot over the serial console (`console=ttyAMA10,115200`). Check that
     `genkey` ran if the key was blank and was skipped otherwise.
   - Check that `pi-status` says encrypted, `cryptsetup status juniper-root` shows
     aes-xts, `juniper_encrypted 1`, and `get-key-status 1` shows `HMAC_LOCKED`. If the
     EEPROM can't lock, check that it reports `unavailable` instead.
2. Card in a laptop: the root partition is `crypto_LUKS`, and nothing readable comes back
   from `strings` on a sample of it. `just unlock-card` with the SSH key mounts it.
3. Pull the power at about 30% of the first-boot conversion (watch the serial console). The
   next boot resumes and completes, and the data is intact (cloud-init then completes and
   the user exists).
4. Clone the card with `dd` to a second card and boot it in the same Pi: it must **not**
   unlock. The console shows the re-bind hint, and the device doesn't spin in a tight
   reboot loop. Then run `just rebind-card` on the clone, if Task 10 is in, and it boots.
5. Move the original card to a second Pi (Pi 4 or another Pi 5): no unlock. Re-bind works.
6. Update via tryboot (`ujust update`): the bootloader sync reaches the FAT partition
   (`rpi-bootc-log.txt` on CIDATA, `tryboot.txt` updated), and the new deployment unlocks
   and becomes default. Then a deliberately broken update falls back.
7. Fail open: flash with `encrypt: true` on a board after making the key interface fail on
   purpose (for example, temporarily set `lock_device_key_write=1` with a blank slot on a
   spare board, if one is available, or simulate with the `juniper.encrypt=0` karg). The
   device boots plain, the MOTD warns, and `juniper_encrypted 0` with the reason.
8. `encrypt: false`: no OTP write (`get-key-status` unchanged), plain root, the warning
   explains "encrypt: false".
9. Performance: `fio` sequential and 4k random on the encrypted root against the same card
   unencrypted. Watch CPU during `podman pull`.
10. Pi 4 (best-effort): repeat 1, 2, 3 and 8. Record whether `set-key-status` locks HMAC.

## Rollout

1. **Implementation PR(s)** (plan Tasks 1–12) merge with `encrypt` **defaulting to false**.
   Nothing changes for anyone who doesn't set `encrypt: true`, apart from the
   always-harmless parts:
   - the MNTDEV wrapper;
   - `lock_device_private_key=1`;
   - growing the partition in the initramfs instead of in cloud-init;
   - the extra NOT ENCRYPTED reporting.
2. **The owner's Pi 5 hardware run** (plan Task 13).
3. **Flip PR** (plan Task 14, `feat: encrypt by default`): `render-cidata` defaults
   `encrypt` to on, the README and CHANGELOG say so, and the Tested-hardware cell moves.

## Spike findings (2026-10-11)

Evidence was gathered from the published image and disk image without running them on a Pi.
Blockers come first.

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| B1 | **Today's initramfs can't unlock LUKS.** The `crypt` and `dm` dracut modules are in, but `systemd-cryptsetup` isn't, so there is no `systemd-cryptsetup`, no generator, no `cryptsetup.target`, and no `cryptsetup` binary at all. The base image pulled `systemd-cryptsetup` in through clevis/tpm2-tss, which `90-juniper.conf` omits. `90crypt` installs `cryptsetup` only when systemd isn't in the initramfs. The drop-in's comment "Kept: … crypt/dm for LUKS" is therefore wrong in practice | `lsinitrd`: modules list has `crypt dm` and no `systemd-cryptsetup`; no `cryptsetup` or `systemd-cryptsetup` file; `dm-crypt.ko.xz`, `adiantum.ko.xz`, `aes-ce-blk.ko.xz` present. `01systemd-cryptsetup/module-setup.sh` and `90crypt/module-setup.sh` read in the image | Juniper's own dracut module installs `cryptsetup` (and its libraries) explicitly. We don't need systemd-cryptsetup |
| B2 | **`rpi-fw-crypto` isn't packaged for EL10 anywhere.** The AlmaLinux 10 `raspberrypi` repo has only firmware, kernel, userland, rpi-eeprom and sys-mods. It isn't in EPEL 10. COPR has `pbrobinson/rpi` `rpi-utils` (Fedora chroots only, 2026-02) and `lucamagrone/el10-pi` (CentOS Stream 10, 2025-09, unreviewed) | `dnf repoquery` on both repos (aarch64), COPR API search | Build it in a Containerfile stage from `raspberrypi/utils` at a pinned commit (latest `rpifwcrypto/` change: `61371fa`, 2026-06-17). Needs `gcc`, `cmake`, `gnutls-devel`. Upstream's "at least version 3.10" refers to CMake (`cmake_minimum_required(VERSION 3.10…)`), not gnutls, which corrects the options report: EL10's gnutls 3.8.10 is fine. gnutls is used only to SHA-256 a file for `sign`. Ask AlmaLinux's Raspberry Pi SIG to package it (docs/upstream.md) |
| B3 | **rpi-bootc-bootloader with root on `/dev/mapper`** mounts the root XFS as the "FAT" partition. `finalize-staged` then silently skips the sync, so updates never reach the firmware | `/usr/bin/rpi-bootc-bootloader` v0.0.8, lines 214–225 and 346–372 | A wrapper sets `MNTDEV=$(cidata-device)` for every call. Ship it first; it is harmless on plain devices |
| B4 | **Converting the root after udev races systemd's device handling** (BindsTo on the root device, 90 s device timeout) | Design analysis; boot cmdline `root=UUID=66f85224-… rw boot=UUID=… rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot ostree=…` from the disk image's BLS entry | First-boot conversion runs before udev; unlock runs after it. Needs verification on hardware (plan Task 13) and in the loop test |
| F1 | Kernel config has everything | `config-6.12.96-20260724.v8.1.el10`: `DM_CRYPT=m`, `BLK_DEV_DM=m`, `CRYPTO_ADIANTUM=m`, `CRYPTO_CHACHA20=m` (provides xchacha12/20), `CRYPTO_CHACHA20_NEON=m`, `CRYPTO_NHPOLY1305_NEON=m`, `CRYPTO_POLY1305_NEON=m`, `CRYPTO_AES_ARM64_CE(_BLK)=m`, `CRYPTO_XTS=y`, `RASPBERRYPI_FIRMWARE=y`, `BCM2835_MBOX=y`, `BCM_VCIO=y` (`/dev/vcio`; no `vcio_crypto` device, and `librpifwcrypto` falls back to `/dev/vcio`), `HW_RANDOM_BCM2835=y`, built-in `MMC_BCM2835`, `MMC_SDHCI_BRCMSTB`, `BLK_DEV_NVME`, `USB_STORAGE`, `USB_UAS`, `USB_XHCI_PCI`, `PCIE_BRCMSTB`, `VFAT_FS`, `NLS_CODEPAGE_437`; `XFS_FS=m`; `HCTR2` not set (not needed) | Nothing to change in the kernel. Storage and FAT work before udev |
| F2 | Packages | `cryptsetup-2.8.1`, `cryptsetup-libs`, `systemd-257` (with `systemd-cryptsetup`, `systemd-cryptenroll`), `gnutls-3.8.10`, `xfsprogs-6.16.0`, `cloud-utils-growpart`, `raspberrypi-userland` (`vcmailbox`), `rpi-eeprom(-firmware)-2026.05.11` are in the image. `age-1.3.1` is in EPEL 10 (Go binary; the age CLI is about 4.7 MB) | `age` comes from EPEL (already enabled, key pinned) |
| F3 | Disk layout | GPT: p1 1 GiB ESP type (CIDATA), p2 1 GiB XFS `/boot`, p3 6 GiB type root-arm64 `b921b045-1df0-41c3-af44-4c6f280d3fae`, ending at the last usable LBA of the 8 GiB image; backup GPT at 8 GiB. Root XFS: blocksize 4096, **sectsize 512**, 1.56 GiB used of 6 GiB. **Every card of a release has the same filesystem UUIDs** (bib generates them at build time) | Root found by `root=UUID=` and checked by GPT type. LUKS sector size 512. Ambiguity rules above. Relocate the backup GPT before growing |
| F4 | `cryptsetup` 2.8 offline in-place encryption works on an XFS image file grown by 32 MiB: `reencrypt --encrypt --type luks2 --reduce-device-size 32M` gives data offset 16 MiB and a **dynamic** (whole-device) segment, so growing the partition later needs no `resize`. **A killed run needs `cryptsetup repair` (with the passphrase) before `reencrypt --resume-only`**. Without a block device it also needs `--force-offline-reencrypt`; real partitions don't. `luksAddKey` for a second slot, `token import` of a custom `juniper` JSON token, and `open --test-passphrase` with the recovery key all work. Adiantum works the same way | Spike script on the laptop (cryptsetup 2.8.8; the image has 2.8.1) | The prepare unit does repair then resume. Without root on the laptop, data integrity after decryption couldn't be checked; the plan's privileged loop test in CI does that |
| F5 | Pi 4 `start4.elf` in the image (2026-05-21, `bcm2711_2`) contains the fw-crypto HMAC, genkey, key status and key-usage handlers | `strings` on `/usr/lib/ostree-boot/start4.elf` | Pi 4 probably works with cards flashed from current releases |
| F6 | Pi 5 EEPROM notes (shipped `bootloader-2712/release-notes.md`): rpifwcrypto preliminary support 2025-08-20, `genkey` 2025-09-25, HMAC lock-up fix 2026-01-21, user-OTP back door closed 2026-01-09. The package's newest is **2026-05-11**, before the 2026-06-17 fine-grained locks | release notes in `rpi-eeprom-firmware-2026.05.11` | Until AlmaLinux ships a newer `rpi-eeprom-firmware`, `HMAC_LOCKED` is unavailable on Pi 5. Report it; don't fail on it |
| F7 | The initramfs is 28.7 MB (`dracut --no-hostonly --reproducible`). Its early cpio carries **x86 AMD microcode** (`kernel/x86/microcode/AuthenticAMD.bin`, 0.3 MB) because `01-dist.conf` sets `early_microcode="yes"` | `lsinitrd` | Add `early_microcode="no"` to `90-juniper.conf` |
| F8 | `block-device-id` (Raspberry Pi's card id) covers MMC and NVMe only, not USB | `raspberrypi/block-device-id` `src/device.rs` | USB needs Juniper's own rule (serial attribute), or fails open |
| F9 | age refuses `ecdsa-sha2-nistp256` and `sk-ssh-ed25519@openssh.com` recipients ("ignoring unsupported SSH key"; "no recipients found"); `ssh-ed25519` and `ssh-rsa` decrypt fine | age 1.3.2 on the laptop | `just flash` filters and refuses as described |
| F10 | Watchdog: the initramfs includes `50-juniper-watchdog.conf` (`RuntimeWatchdogSec=15s`), so PID 1 keeps the hardware watchdog fed during a long conversion | `lsinitrd` | No change needed. A hung `cryptsetup` doesn't trip it either (PID 1 is alive): the conversion prints progress to the console, and Task 13 watches it on hardware |

## Risks

1. **First-boot ordering before udev** is the least-trodden part. The plan proves it on
   hardware before anything else depends on it. The fallback design is a dedicated
   first-boot reboot: convert, then `systemctl reboot`, before `sysroot.mount` is ever
   queued. It costs one reboot.
2. **`genkey` is irreversible, and its atomicity under power loss is undocumented.** A cut
   mid-write could leave an invalid key (`KEY_INVALID`): the device would fail open, and the
   board's key slot would be unusable for Connect too. The window is milliseconds; the
   README states the risk.
3. **No HMAC lock on Pi 5 until AlmaLinux ships EEPROM 2026-06-17 or later,** and probably
   none on Pi 4. A remote root attacker could derive the passphrase and later decrypt a
   stolen copy of the card. Same class as "root on a running device". Reported as
   `key_lock=unavailable`.
4. **The card serial as a binding** changes if the card is cloned or replaced. Re-binding
   needs the recovery key (by design). USB disks without a serial can't be bound.
5. **Recovery custody** depends on the owner keeping an SSH private key file (not just an
   agent). If none of the flash-time keys survive, the card is unrecoverable on another
   board.
6. **SD wear and time:** one full rewrite of 6 GiB on first boot. dm-crypt adds no write
   amplification afterwards. Pi 4 sustained I/O is bounded by the card.
7. **Packaging:** `rpi-fw-crypto` built by Juniper from a pinned commit needs manual bumps
   (`just bump-fwcrypto`). Dependabot can't see it.
8. **Two identical Juniper disks attached at boot** (same release, same UUIDs): the
   first-boot conversion refuses (fails open). Unlock tries each candidate and only the
   matching card opens. A plain device with two identical cards attached already has this
   ambiguity today.
9. **`rpi-otp-private-key -w -f`** run by hand ORs bits into the key, which corrupts it.
   The card is then unrecoverable on that board without the recovery key. The README warns.

## Questions for the owner (beyond the decisions above)

1. **USB boot disks:** bind to the USB serial when present and fail open when absent (as
   designed)? Or bind USB disks to the board only?
2. **Cards not written by `just flash`** (Imager, `dd`): stay unencrypted ("not requested at
   flash time") even after the default flips? They have no recovery recipients chosen at
   flash time.
3. **Recovery mandatory?** As designed, no recipient means no encryption: `just flash`
   refuses, and the image fails open. The alternative is to encrypt without recovery.
4. **Ship without the HMAC lock on Pi 5** until AlmaLinux packages EEPROM 2026-06-17 or
   later (reported as `key_lock=unavailable`)?
5. **Re-binding** (`just rebind-card`) in the first implementation, or as a follow-up?
6. **Growing the partition** moves from cloud-init into the initramfs for every image, so
   encrypted and plain devices take one path. OK?
