# rpi-imager Tailscale customisation — design (sub-project B)

Status: approved in brainstorming 2026-10-09, awaiting written-spec review.
Lives in a fork of `raspberrypi/rpi-imager`; written to be upstreamable.

## Intent

Let a user paste a Tailscale auth key into rpi-imager so the flashed OS joins their
tailnet on first boot. Juniper (sub-project A) is the first consumer, but the feature must
be distro-neutral so Raspberry Pi can accept it upstream.

## Contract

- New OS-list capability `"tailscale"`, added to the schema enum in
  `doc/json-schema/os-list-schema.json` and documented in `doc/os_customisation_formats.md`.
- Meaning: **the OS ships Tailscale preinstalled**. Imager never installs it.
- Supported `init_format`s in the first PR: `cloudinit`, `cloudinit-rpi`. `systemd`
  (firstrun.sh) and `rpi-preseed` (needs a `[tailscale]` section in rpi-preseed upstream)
  are listed as follow-ups in the PR description, not implemented.

## Generated cloud-init

Appended by `CustomisationGenerator::generateCloudInitUserData` when the step is enabled:

```yaml
write_files:
  - path: /etc/tailscale/authkey
    permissions: "0600"
    owner: root:root
    content: "<key, yamlEscapeString>"
runcmd:
  - systemctl enable --now tailscaled
  - tailscale up --auth-key=file:/etc/tailscale/authkey [--ssh] [--hostname=<hostname>] [--login-server=<url>] && shred -u /etc/tailscale/authkey
```

- `shred` only on success: runcmd does not stop on failure, and the key must survive a
  failed join so the OS can retry (Juniper's `juniper-firstboot.service` does). On other
  OSes a failed join leaves a root-only `0600` key file behind; documented in help text.

- Merges into existing `write_files`/`runcmd` sections rather than emitting duplicates.
- Every interpolated value goes through the existing `shellQuote`/`yamlEscapeString` helpers.
- `--hostname` comes from the existing hostname step; omitted when unset.

## Wizard step (`TailscaleCustomizationStep.qml`)

Shown only when the selected OS has the `tailscale` capability, placed after the Pi
Connect step. Follows that step's structure and accessibility patterns.

- Enable toggle.
- Auth key: masked field; must match `^tskey-auth-[A-Za-z0-9-]+$`, otherwise inline error and
  Next disabled.
- "Enable Tailscale SSH" checkbox (adds `--ssh`).
- Collapsed "Advanced": control server URL (`https://` only; for Headscale).
- Help text: use a one-time, pre-approved, expiring key; it is stored unencrypted on the
  card until first boot.

## Secret handling

- Key is held in memory only: never written to QSettings, never restored on next launch.
- Not included in telemetry.
- Redacted in debug logging: `imagewriter.cpp` currently logs the full cloud-init payload
  (`qDebug() << "Cloudinit:" << cloudinit`). Replace the key with `<redacted>` before
  logging (and do the same for the existing Wi-Fi password while there).
- CLI: `--tailscale-authkey-file <path>` (plus `--tailscale-ssh`, `--tailscale-login-server`),
  so the key never appears in `ps`.

## Tests

- `src/test/customization_generator_test.cpp`: output for key only / key + SSH + hostname
  + login server; escaping of hostile values; no Tailscale output without the capability;
  merging with Pi Connect and Wi-Fi runcmds.
- Redaction test for the logging path.
- Extend `src/test/fuzz/fuzz_customisation_gen.cpp` with the new fields.
- QML test for the step's validation (pattern after `tst_os_selection_step.qml`).

## Distribution until upstream lands

- Fork CI builds the AppImage (existing `create-appimage.sh`).
- Juniper's release attaches `os-list.json` with `init_format: "cloudinit"`,
  `capabilities: ["tailscale", "passwordless_sudo"]`, devices pi4/pi5 64-bit. Users run
  `rpi-imager --repo <url>`.
- Without the fork, users edit the commented Tailscale block in `CIDATA/user-data` (same YAML).
