# Juniper — project status (2026-10-09)

Start here when picking the project up on another machine.

## Sub-projects

| | What | Spec | Plan | State |
|---|---|---|---|---|
| A | Images (`juniper-minimal`, `juniper`), CI, release train | `specs/2026-10-09-juniper-image-design.md` | `plans/2026-10-09-juniper-image-core.md` | Tasks 1–10 done on `main`; Task 11 (Pi 5 hardware acceptance) pending |
| B | Tailscale field in Raspberry Pi Imager (fork, upstreamable) | `specs/2026-10-09-imager-tailscale-design.md` | `plans/2026-10-09-imager-tailscale.md` | Plan written, not started; no fork yet (see the plan's "Status and handoff") |
| C | Encryption at rest (OTP-bound LUKS2 + recovery passphrase, Pi 4/5) | not written | not written | Needs a feasibility spike first (OTP burn is irreversible; LUKS root with rpi-bootc-bootloader/ostree unproven) |

## A: what is left

1. Make both GHCR packages public (`juniper`, `juniper-minimal`): devices pull anonymously and the disk job verifies `:latest` anonymously.
2. First disk release: `gh workflow run build -f build_raw=true` on `main`; check both `.raw.xz` (< 2 GiB asset limit), `.bundle`s, `SHA256SUMS`, `os-list.json`, and runner disk headroom.
3. Task 11 on the Pi 5 (plan, Task 11), plus the final review's extra checks:
   - `bootc upgrade` works after first boot, and an unsigned tag under `ghcr.io/gnathoi` is rejected;
   - a deliberately broken update on a test ref falls back via tryboot;
   - power cut during first boot;
   - lockdown held past a DHCP lease renewal; IPv6 behaviour under the `drop` zone;
   - `sudo reboot` with a staged update keeps the current image (TRYBOOT=1); `ujust switch` juniper ↔ juniper-minimal applies it;
   - Tailscale's nftables rules coexist with firewalld (`sudo nft list ruleset`).
4. Watch the live-only behaviour: first Saturday Dependabot run (auto-merge of a workflow-file bump may be refused for `GITHUB_TOKEN` — fallback: GitHub App token or merge by hand) and the first Monday 02:00 UTC train.

## Decisions taken during execution (keep)

- Rollback uses rpi-bootc-bootloader firmware tryboot (`TRYBOOT=1`), not greenboot (needs GRUB). Health check fails closed: only a tryboot flag of exactly 1 triggers a fallback reboot.
- Two images from one Containerfile (`minimal` → `juniper` stage); dev tools only in `juniper`.
- Homebrew baked into `juniper` from `ghcr.io/ublue-os/brew` pinned by digest, cosign-verified in CI; Dependabot ignores it; bump with `just bump-brew`.
- Signatures: key-based cosign (public key `system_files/usr/share/pki/containers/juniper.pub`, private key only in the `SIGNING_SECRET` repo secret and the owner's password manager). Policy scoped to the namespace `ghcr.io/gnathoi`; no global reject (would break podman app pulls). The bootc origin is NOT switched to `--enforce-container-sigpolicy` (with the base's `insecureAcceptAnything` default that refuses every pull); the namespace policy still enforces on every update. cosign pinned to v2 (v3's bundle format is invisible to containers/image). SBOM attestations skip Rekor (too large); image signatures use it.
- Release train: Dependabot Saturday → green minor/patch/digest auto-merge (majors wait; draft = hold) → Monday 02:00 UTC publish + disk images + signed release → Pis reboot Tuesday 04:00 local (+≤90 min). Pushes to `main` never publish.
- Merge policy: squash merges.

## Known follow-ups (deliberately deferred)

- Before making the repo public: SHA-pin third-party actions in jobs that hold `SIGNING_SECRET`; pin `bootc-image-builder` and `centos-bootc:stream10` tool images by digest.
- Unit tests: set `JUNIPER_CLOUD_DIR` in `firstboot_env` (the label test currently touches the host's `/var/lib/cloud` through a stubbed `shred`; harmless unless tests run as root).
- README "switch from AlmaLinux": add `sudo reboot` for stock AlmaLinux sources (`apply-update` only exists on Juniper).
- Retry the rechunk step's `centos-bootc:stream10` pull; verify-then-pull of `:latest` is check-then-use on a mutable tag (pin the verified digest).
- `rd.emergency=reboot` covers the initramfs only; a real-root `emergency.target` still hangs under tryboot.
- Derive the CIDATA device from the `/sysroot` device instead of `blkid -L CIDATA`.
- If Dependabot `groups:` are ever enabled, make auto-merge stricter (group titles hide major bumps).
- Smaller items: lockdown could `--reload` before switching the default zone; a few test-strength and wording nits.
