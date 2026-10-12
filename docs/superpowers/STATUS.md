# Juniper — project status (2026-10-12, evening)

Start here when picking the project up on another machine.

## Sub-projects

| | What | Spec | Plan | State |
|---|---|---|---|---|
| A | Images (`juniper-minimal`, `juniper`), CI, releases | `specs/2026-10-09-juniper-image-design.md` | `plans/2026-10-09-juniper-image-core.md` | Done and hardened; second release `build-20261011` passed hardware acceptance (#79). Task 11 (Pi 5 hardware acceptance) passed, including 7b; one unexplained first-boot hang to reproduce (see Next); results in `docs/acceptance.md` |
| B | Tailscale field in Raspberry Pi Imager (own-use fork) | `specs/2026-10-09-imager-tailscale-design.md` | `plans/2026-10-09-imager-tailscale.md` | **Parked** (2026-10-10): `just flash` covers it. Read the plan's "Parked" note before resuming |
| C | Encryption at rest (OTP-bound LUKS2 root + age recovery keyslot), issue #50 Phase 0 + Phase 2 | `specs/2026-10-11-encryption-design.md` | `plans/2026-10-11-encryption.md` | **Shipped opt-in (`encrypt: true`, #78) and hardware-verified on the owner's Pi 5** (EEPROM 2026-05-11; `docs/acceptance.md`): encrypts on first boot (~3.5 min), unlocks unattended, tryboot both ways, laptop recovery works. Fixes from the run: #86 (config.txt key lock blocked genkey), #87 (`unlock-card` stdin). 2026-10-12: #83's M1–M5 and Task 11 done (#91–#96), **re-bind shipped** (`just rebind-card`, #99, loop-tested). Before flipping the default (Task 14), the owner's hardware checks: single-command `unlock-card` and `rebind-card` on a laptop, a re-bind into a second Pi (or a `dd` clone), and the clone check |
| D | **Experimental `juniper-desktop` (niri)** | `specs/2026-10-10-juniper-desktop-design.md` | `plans/2026-10-10-juniper-desktop.md` | **Published as experimental** (#49 merged 2026-10-11: signed image, disk image, release assets; not in `os-list.json`). Boots to greetd's text login; niri after authentication. Hardware desktop test pending a micro-HDMI cable (#58); then the Tested-hardware cell. Research below |

## Next, in order

0. **Owner hardware checks for encryption** (gate for Task 14, encrypt by default): on the laptop, `just unlock-card /dev/sdX` as one command (after #87), then `just rebind-card /dev/sdX` and boot the card in another Pi, or boot a `dd` clone (`juniper-rebind.key` gone afterwards; `ujust pi-status` says encrypted). Also: a `dd` clone without re-bind must *not* unlock in the same Pi.
1. **Investigate the one unexplained first-boot hang** (`docs/acceptance.md`, 7b′): flash `juniper-minimal` again, add `console=ttyAMA10,115200` to the entry's `cmdline.txt` (the FTDI cable is on the Pi 5 debug UART; with two `console=` the kernel only enabled ttyAMA0), boot **with Ethernet**, capture with `stty -F /dev/ttyUSB0 115200 raw -echo; cat /dev/ttyUSB0`. If it reproduces, the log shows the stuck unit.
2. Delete the repo-level `SIGNING_SECRET` and `RELEASE_DEPLOY_KEY` (the `release` environment has its own since 2026-10-10 and the first release under it succeeded): `gh secret delete SIGNING_SECRET --repo gnathoi/juniper` and the same for `RELEASE_DEPLOY_KEY`.
3. Housekeeping: `gh auth refresh -h github.com -r write:packages,delete:packages` if not done; the `claude-probe` container (ephemeral key, in-memory state) drops off the tailnet when removed: `podman rm -f claude-probe`.
4. Sub-project D (below). The Pi 5 is on `juniper` (switched from `juniper-minimal`, hostname `juniper-minimal`).

## What happened on 2026-10-12

Merged: #90–#100. Closed: #76, #77, #89.

- **#89 health check failed after boot**: bash `$SECONDS` follows the wall clock, and chrony stepped the RTC-less Pi's clock by 11.3 M s mid-check, so the deadline expired after one try. Now on `/proc/uptime` (#90). Under tryboot this would have rolled back a healthy update.
- **bash 5.2 quirk** (the image's and CI's bash): a failed `x=$(<file)` exits the whole script under `set -e`, `|| return 1` notwithstanding. Made the loop-device test flaky on main and could cut `cryptroot prepare` short; `$(<` is now banned in shipped scripts by a unit test (#97).
- Encryption follow-ups (#83): host-side key validation in `just flash` (bech32 checksum, SSH key data, RSA ≥ 2048; #91), firmware-aware unlock hint (#92), flash warning wording (#93), no disk changed while another card of the release is attached (#94; the boot disk can't be told apart), `ujust switch` refuses images without `org.juniper.cryptroot=v1` on an encrypted root (#95), fwkey wedge comment (#96).
- **Re-bind** (#76, #99): `just rebind-card` adds a one-time slot-2 key; the next confirmed boot in any Pi swaps slot 0 to that Pi's key and removes it; power-cut safe; waits for a usable firmware key on a new board. Loop test: 7 scenarios, real cryptsetup.
- Container policy (#98, closes #77): wildcard scopes cover ports; removed drop-ins and hand edits logged correctly; boot ordering verified on the Pi.
- Loop harness (#100): `no_leak` fails on unreadable paths, token set checked exactly, plaintext canary must be gone from the raw disk.
- #55's done items ticked (#72 had shipped them); a real data snapshot/restore stays open.
- Owner decisions open: bounded remote log shipping for #54 (package and protocol), whether a first-boot firmware wedge should be retried rather than final (#83 M4), `ujust recovery-reseal` (Task 12, optional).

## What happened on 2026-10-11

Merged: #49 (juniper-desktop), #59, #60, #62-#67, #69-#72, #74, #75, #78, #82, #86, #87. Closed: #51, #52, #53, #61, #68, #79, #81, #84.

Hardening done today:

- Tailscale auth key deleted after 14 days or on rejection (#60); tailnet ACL least-privilege, pinned EPEL/Tailscale keys, `wifi.country` validation (#59).
- `ujust lan-ssh` scoped to on-link networks, with expiry and IPv6 (#63).
- Health-check safety net: probe timeouts, fallback on failure, readiness hooks, two-strike digest quarantine (#62, #82); `ujust update-unhold`.
- Storage budgets: free-space check before updates, weekly image prune, low-space warnings (#65).
- Pi kernel age in release notes, CI summary and `pi-status` (#70); status metrics for node_exporter and clock-sync warning (#71).
- `ujust trust-images` for signed workloads and derived images (#72); `ujust` tab completion (#67); lost/stolen-device doc (#64).
- Encryption design and plan (#74), opt-in encryption (#78), MNTDEV bootloader wrapper (#75), config-lock and `unlock-card` fixes (#86, #87).

Hardware: `build-20261011` (#79) and opt-in encryption (#84) passed on the Pi 5; see `docs/acceptance.md`.

## Open roadmap

- #54, #55 (remainders); #56 (delivery path); #57 (canary, deferred by the owner).
- #73 secure boot (deferred); #83 (remaining: owner hardware checks, `root_wait`, Task 12 optional, then Task 14 default-on); #85 (YubiKey recovery, low priority).
- #58 desktop hardware test (micro-HDMI cable).

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
