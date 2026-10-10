# Juniper — project status (2026-10-10, evening)

Start here when picking the project up on another machine.

## Sub-projects

| | What | Spec | Plan | State |
|---|---|---|---|---|
| A | Images (`juniper-minimal`, `juniper`), CI, releases | `specs/2026-10-09-juniper-image-design.md` | `plans/2026-10-09-juniper-image-core.md` | Done and hardened. Task 11 (Pi 5 hardware acceptance) passed, including 7b; one unexplained first-boot hang to reproduce (see Next); results in `docs/acceptance.md` |
| B | Tailscale field in Raspberry Pi Imager (own-use fork) | `specs/2026-10-09-imager-tailscale-design.md` | `plans/2026-10-09-imager-tailscale.md` | **Parked** (2026-10-10): `just flash` covers it. Read the plan's "Parked" note before resuming |
| C | Encryption at rest (OTP-bound LUKS2 + recovery passphrase) | not written | not written | Needs a spike. Known: rpi-bootc-bootloader finds the FAT partition by rewriting the root device name, so set `MNTDEV` under LUKS; the initramfs keeps `crypt`; without Pi signed boot an OTP key protects a stolen card, not a stolen Pi |
| D | **Experimental `juniper-desktop` (niri)** | not written | not written | **Next, once A's remaining items are done** (owner decision 2026-10-10). Research below |

## Next, in order

1. **Investigate the one unexplained first-boot hang** (`docs/acceptance.md`, 7b′): flash `juniper-minimal` again, add `console=ttyAMA10,115200` to the entry's `cmdline.txt` (the FTDI cable is on the Pi 5 debug UART; with two `console=` the kernel only enabled ttyAMA0), boot **with Ethernet**, capture with `stty -F /dev/ttyUSB0 115200 raw -echo; cat /dev/ttyUSB0`. If it reproduces, the log shows the stuck unit.
2. Update the Pi to the release with #35 (initramfs) + #37 (binutils, flash fixes); check `ujust pi-eeprom` and the initramfs size; `ujust devbox`/`install-podlet` on a `juniper` install.
3. Delete the repo-level `SIGNING_SECRET` and `RELEASE_DEPLOY_KEY` (the `release` environment has its own since 2026-10-10 and the first release under it succeeded): `gh secret delete SIGNING_SECRET --repo gnathoi/juniper` and the same for `RELEASE_DEPLOY_KEY`.
4. Housekeeping: `gh auth refresh -h github.com -r write:packages,delete:packages` if not done; remove the `claude-probe` machine from the tailnet; `podman rm -f ts-probe`.
5. Sub-project D (below).

## What happened on 2026-10-10

- First boot on hardware failed on `build-20261009`: an ordering cycle (`After=cloud-final`, which runs after `multi-user.target`) dropped the Tailscale join, the CIDATA scrub and the health check; Wi-Fi from `network-config` was ignored (cloud-init renders `wifis:` only via netplan); the hostname came from the router's DNS. Fixed in #22 with a CI cycle check (`systemd-analyze verify multi-user.target cloud-init.target`, grep, since verify exits 0).
- `just flash` (#24, #29): YAML config → CIDATA, signed download (curl, repo is public), target checks, y/N, `run0` (via `/usr/bin/bash`: SELinux denies run0's service exec of `user_home_t` scripts).
- Codex (gpt-6.1-sol) security review; fixes in #26 (SHA-pinned actions + lint hook, digest-pinned tool images, `just bump-tools`), #30 (firstboot retry, fork-PR lint, auto-merge bound to tested SHA, flash mount, pinned/confined node_exporter, README switch by digest, `dnf upgrade` for errata), #32 (emergency fallback, stronger health check, CIDATA from the boot disk), #33 (signing in a `release` environment job; `:latest` only ever names a signed digest; disks from their run's digest; serialized publishing; kernel-update warning).
- Repo public; ruleset "main: pull requests only" (squash, `lint` required, no force-push/deletion; the only bypass is deploy keys, i.e. the release job's `RELEASE_DEPLOY_KEY`); ruleset "v* tags: admins only"; private vulnerability reporting on; CONTRIBUTING.md.
- #34: `rpi-eeprom` + `rpi-eeprom-firmware`, `ujust pi-eeprom [status|apply]` (the Pi 5 reports 2025-11-05 → 2026-05-11 available; not applied), headless `rpi-config.txt` per boot entry, CLI tools via Brewfile (zellij, neovim, btop, ripgrep, fzf; tmux dropped), license texts + THIRD_PARTY.md source section, `NAME="Juniper"`.
- On the Pi 5: unsigned image rejected (`podman pull` and `bootc switch`), update via tryboot kept, broken update fell back, emergency-mode update fell back, LAN lockdown and `lan-ssh` work. See `docs/acceptance.md`.

Upstream candidates (AlmaLinux, rpi-bootc-bootloader) are tracked in `docs/upstream.md`; not filed yet.

## Sub-project D research (2026-10-10, subagent)

niri 26.04 and xwayland-satellite exist for epel-10-aarch64 in COPR (`yalter/niri`; `yselkowitz/wlroots-epel` also has sway, labwc, foot, waybar, fuzzel, swaylock, swaync; greetd in `yselkowitz/cosmic-epel`). AlmaLinux AppStream has the portals, PipeWire, Xwayland, Firefox ESR and a Mesa with vc4/v3d. The GPU needs `dtoverlay=vc4-kms-v3d` (in the per-entry `rpi-config.txt`, so tryboot covers it). Reference: github.com/zirconium-dev/zirconium (mkosi on Fedora, no Pi support; reuse its greetd/keyring/`local.kdl` patterns). Proposal: `FROM juniper`, niri + waybar/fuzzel/swaync, greetd auto-login, Pi 5 8 GB first. Estimate 2–4 days; ~+1 GB image; COPR dependency to pin or mirror.

## Decisions taken during execution (keep)

- Rollback uses rpi-bootc-bootloader firmware tryboot (`TRYBOOT=1`), not greenboot. Health check fails closed: only a tryboot flag of exactly 1 triggers a fallback reboot; so does real-root emergency mode (`juniper-emergency-fallback`).
- Two images from one Containerfile (`minimal` → `juniper`); dev tools only in `juniper`; personal CLI tools come from Homebrew (Brewfile), not the image.
- Homebrew from `ghcr.io/ublue-os/brew` pinned by digest, cosign-verified in CI; bump with `just bump-brew`. Tool images (bootc-image-builder, centos-bootc, node-exporter) pinned by digest; bump with `just bump-tools`. Actions pinned to SHAs.
- Signatures: key-based cosign v2; public key `system_files/usr/share/pki/containers/juniper.pub`; private key in the `release` environment's `SIGNING_SECRET` and the owner's password manager. Policy scoped to `ghcr.io/gnathoi`; bootc's origin stays `ostree-unverified-registry` because the namespace policy enforces (verified on hardware).
- Release: Dependabot Saturday → green minor/patch/digest auto-merge (majors wait) → Monday 02:00 UTC publish → Pis reboot Tuesday 04:00 local (+≤90 min). Pushes to `main` never publish.
- Every build runs `dnf upgrade` except the Pi kernel and firmware, which come with the base (dnf can't place a new kernel for ostree; see the base-limitations research). CI warns when the Pi repo's kernel is newer than the base's.
- Merge policy: squash; conventional prefixes on commit subjects and PR titles.

## Known follow-ups (deliberately deferred)

- Pi 4 GPU firmware on the FAT partition is never updated after flashing (only kernel/initrd/DTBs are per entry); a proper fix (`start_file`/`fixup_file` per tryboot entry) belongs upstream in rpi-bootc-bootloader.
- `just flash` is Linux-only.
- README's "switch from AlmaLinux" second step (`ujust switch …:latest` after a digest switch) is untested.
- If Dependabot `groups:` are ever enabled, make auto-merge stricter (group titles hide major bumps).
- Smaller items: lockdown could `--reload` before switching the default zone; `dnf check-update` on devices stops at the Tailscale repo's unimported key.
