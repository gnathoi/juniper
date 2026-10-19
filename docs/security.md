# Security: lost devices, encryption and signatures

## If a device is lost or stolen

The root filesystem is not encrypted unless you opted in (see [Encryption at rest](#encryption-at-rest)).
Whoever holds a plain card can read the Tailscale node state (a working tailnet node), SSH
host keys, Wi-Fi passwords, password hashes and workload data. The boot partition is unsigned
too, so a card that comes back may have been modified. Revoke in this order:

1. Remove the device in the Tailscale admin console. That revokes its node key. Devices
   that joined with a tagged auth key never expire on their own.
2. Revoking or expiring the auth key does not remove nodes that already joined with it.
   Revoke it too if the card never booted: its auth key is still on the FAT partition.
3. Change the Wi-Fi password, and any workload or API secrets the device held.
4. Remove its SSH host key from your `known_hosts`.
5. Reflash any card that comes back instead of trusting it.

What is verified: OS updates are signature-checked before they install. Nothing verifies
the boot chain on the card itself.

## Encryption at rest

Opt-in for now: set `encrypt: true` in flash.yaml (it becomes the default after the first
hardware run). On first boot the Pi encrypts the root filesystem (LUKS2) before anything
secret is written. It is bound to this board and this card, so it unlocks by itself only
here. A stolen card yields nothing: Wi-Fi passwords, SSH host keys, the Tailscale node
state, password hashes and workload data sit inside the encrypted root. First boot takes a
few extra minutes; don't cut the power (it resumes if you do). `ujust pi-status` says
"Storage: encrypted".

- **The one-time key.** If the board has no device key, first boot writes one into the Pi's
  one-time-programmable memory, once per board. It is permanent. Raspberry Pi tools reuse
  this key rather than replace it, and secure boot later (#73) can still use it.
  Never run `rpi-otp-private-key -w -f`: it corrupts the key and the card is then
  recoverable only with your recovery key.
- **Hardware.** Pi 5 only, with a bootloader EEPROM built 2026-01-21 or later (older ones
  have an HMAC lock-up bug). Otherwise the card stays plain, with a "NOT ENCRYPTED" warning.
  Update with `sudo rpi-eeprom-update -a` (the image ships 2026-05-11); an EEPROM update has
  no tryboot fallback. Pi 4 is unverified in v1: `fwkey` fails open, so the card stays
  plain. A card not written by `just flash`, or flashed with no usable recovery key, stays
  plain too.
- **Limits.** Anyone holding both the board and the card can unlock it until secure boot
  (#73); a card that is modified and returned can capture the key (evil maid, #73); root on
  the running device can derive the key. A USB disk with no serial binds to the board only,
  and an SD card in a USB reader binds to the reader.
- **Recovery.** The recovery key is age-encrypted to the SSH keys in flash.yaml (or
  `recovery_key:`, an age public key, instead). If the board dies, put the card in a Linux
  laptop and run `just unlock-card /dev/sdX [IDENTITY]` (default `~/.ssh/id_ed25519`, then
  `id_rsa`): it mounts the root read-only at `/run/media/$USER/juniper-recovered`;
  `just unlock-card --close` undoes it. Keep that SSH private key as a file: age can't use an
  agent or a hardware key.
- **Changing the recovery keys** (a lost laptop, a new key): on the Pi,
  `ujust recovery-reseal FILE` (`-` reads stdin) with ssh-ed25519, ssh-rsa or `age1…` public
  keys. The next boot seals a new recovery key to them and the old one stops working;
  `ujust recovery-reseal --status` or `--cancel` until then. A power cut during it is picked
  up by the next boot; the Pi's own key keeps the card unlockable throughout.
- **Moving a card to another Pi** (or to a `dd` clone on a new card): on the laptop,
  `just rebind-card /dev/sdX [IDENTITY]` adds a one-time key (keyslot 2, and
  `CIDATA/juniper-rebind.key`). The card's next confirmed boot, in whichever Pi it is in,
  replaces the old board's key with that Pi's key for that card, then removes the one-time
  key. A power cut at any step is picked up by the next boot. Until that boot, anyone holding
  the card can unlock it with that file, so keep it with you. Under tryboot nothing changes.
- **Alert.** `juniper_encrypted == 0 or juniper_encryption_recovery_sealed == 0` catches a
  device that is plain or whose recovery key isn't sealed yet (see
  [monitoring](operations.md#monitoring)).

## Image signatures

Every image, disk image and checksum is cosign-signed, and Pis only accept signed OS updates
for everything under `ghcr.io/gnathoi`: `/etc/containers/policy.json` requires a
`sigstoreSigned` signature from [`juniper.pub`](../system_files/usr/share/pki/containers/juniper.pub)
on every pull. `bootc status` shows the origin as `ostree-unverified-registry:`; that refers
to ostree's own (unused) GPG signing, not to this check.

### Your own images

Juniper only enforces signatures on its own namespace, so your images (a derived OS image or
a workload) are accepted unsigned until you say otherwise. Sign them with cosign and trust
your key on the device:

    ujust trust-images ghcr.io/you ~/cosign.pub    # images under ghcr.io/you need your signature
    ujust trust-images                             # list trusted namespaces and keys
    ujust untrust-images ghcr.io/you               # stop requiring it

From then on `bootc switch`, OS updates, podman pulls and `podman auto-update` refuse any
image under that namespace without your signature. Run it before switching to a derived
image and the first switch is verified too.

Where it lives: each trusted namespace is a small drop-in in `/etc/juniper/trusted-images.d/`,
its key in `/etc/pki/containers/`, and its `use-sigstore-attachments` setting in
`/etc/containers/registries.d/`. Juniper's own policy ships read-only in the image
(`/usr/share/juniper/containers/policy.json`), so it updates with every image, key rotations
included. At every boot, before anything pulls, `juniper-containers-policy.service` rebuilds
`/etc/containers/policy.json` from that base plus the drop-ins (validated first, previous copy
kept as `policy.json.bak`). If that fails at boot, the previous policy stays in force (it
fails closed). No drop-in can change a scope the base policy sets (Juniper's own namespace,
vendor entries) or anything under one; one that tries, or is invalid, is skipped and logged
(`journalctl -u juniper-containers-policy`). Don't edit `policy.json` by hand: it is rebuilt
at boot.

A derived image ships its trust as files instead: drop-ins and keys under
`/usr/lib/juniper/trusted-images.d/`, merged before the local ones (a local drop-in for the
same namespace wins), never `RUN trust-images` in the Containerfile. See
[the appliance example](../examples/appliance#signatures). For workloads, sign and
auto-update on a fleet, or pin by digest on a one-off: see
[the appliance example](../examples/appliance#workload-images-signed-or-pinned), which also
covers keeping app data safe across a rollback.
