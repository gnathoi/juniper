# Hardware acceptance (Pi 5)

Results of the image-core plan's Task 11 on real hardware: a Raspberry Pi 5 with a 128 GB
SD card (SM128), Ethernet plus Wi-Fi, a tailnet with the `tag:edge-server` tag and an `ssh`
policy rule allowing members into it.

## 2026-10-10, first attempt: `build-20261009` (failed, fixed in #22)

Flashed with `dd`, `user-data`/`network-config` written by hand.

| Check | Result |
|---|---|
| Boots, user and SSH keys work (over the LAN) | pass |
| Tailscale join | **fail**: never ran |
| CIDATA and cloud-init cache scrub, health check | **fail**: never ran |
| Wi-Fi from `network-config` | **fail**: not configured |
| Hostname from `user-data` | **fail**: `pi5.lan` (the router's DNS name for the IP) |

Causes and fixes (#22):

- `juniper-tailscale-join`, `juniper-firstboot` and `juniper-healthcheck` were ordered
  `After=cloud-final.service`, which in cloud-init 24.4 runs `After=multi-user.target`;
  `multi-user.target` also pulled them in, so systemd deleted the jobs to break the cycle.
  CI now runs `systemd-analyze verify multi-user.target cloud-init.target` and fails on any
  ordering cycle (verify itself exits 0 on cycles).
- cloud-init 24.4 renders netplan v2 `wifis:` only through netplan, which AlmaLinux lacks:
  `juniper-wifi-import` converts them into NetworkManager keyfiles before NetworkManager.
- AlmaLinux's `prefer_fqdn_over_hostname` default: set to `false`.

A rehearsal first boot on the same Pi (`cloud-init clean`, fixed units under `/etc`) passed
before the image was rebuilt.

## 2026-10-10, second attempt: `build-20261010`

Flashed with `just flash /dev/mmcblk0 ~/.config/juniper/flash.yaml` (run0 for the write).

| Step | Check | Result |
|---|---|---|
| 1 | Flash, first boot, joins the tailnet | pass: joined ~90 s after power-on, tagged `tag:edge-server` (tagged devices have key expiry off) |
| 2 | `/etc/tailscale/authkey` gone | pass |
| 2 | CIDATA `user-data` is the secret-free template; `network-config` gone | pass (byte-identical to `/usr/share/juniper/cidata/user-data`) |
| 2 | cloud-init disabled; `firstboot.done`; no `tskey` in `/var/lib/cloud` | pass |
| 2 | `rootflags=noatime`; zram swap; watchdog 15 s; timezone | pass |
| 2 | Hostname `juniper`; 3 SSH keys; Wi-Fi and Ethernet both up | pass |
| 2 | No ordering cycles in the boot journal | pass |
| 3 | Lockdown: default zone `drop` on `end0` and `wlan0` (only 41641/udp), `tailscale0` trusted | pass |
| 3 | From the LAN: SSH and ping to both addresses time out | pass |
| 3 | `ujust lan-ssh on` opens LAN SSH; `off` closes it again | pass |
| 3 | No NetworkManager profile pins a firewall zone | pass |
| 3 | Tailscale's nftables rules coexist with firewalld | pass (12 `ts-` rules) |
| 3 | Tailscale SSH works through the policy's `ssh` rule | pass |
| — | **Unsigned image under `ghcr.io/gnathoi` rejected** | pass: `podman pull` and `bootc switch` both fail with "A signature was required, but no signature exists"; nothing staged; a signed `juniper-minimal` pulls fine |
| 6 | `ujust update-schedule 03:30` names the Pi's timezone; timer in the 03:30–05:00 window; restored to Tue 04:00 | pass |
| 7 | Login banner (Tailscale, Update, Tip); `ujust` recipes; `pi-status` | pass |
| 7 | `brew --version` in an interactive login shell; `distrobox`, `fastfetch` | pass |
| 7 | Hardened `enable-metrics` quadlet (from #30): runs as nobody, `CapEff` 0, `NoNewPrivs`; `:9100/metrics` over the tailnet | pass (installed by hand; recheck via `ujust` after #30 ships) |
| 4 | Update + tryboot | pass: `juniper-update.service` staged `build-20261010` (33 layers, 534 MB: the first build with `dnf upgrade`); `ujust update` booted it with `tryboot=1`; health check made `ostree-2` the default; a plain reboot stayed on it |
| 5 | Deliberately broken update falls back | pass: image built on the Pi with `tailscaled` masked, staged from containers-storage, booted via tryboot; health check failed after 20 tries (~5 m 40 s) and rebooted; firmware booted the previous image (`tryboot=0`, Tailscale up) 20 s later |
| 7 | `ujust devbox`, `ujust install-podlet` | not run (needs a `juniper` install; the card now holds `juniper-minimal`) |
| 7b | `juniper-minimal` | pass on the second attempt (Wi-Fi only, serial console on the debug UART): first boot 52.6 s, `NAME="Juniper"`, key/`network-config` scrubbed, CIDATA == template, cloud-init disabled, `tag:edge-server`, no distrobox/brew/fastfetch/zellij, no `devbox`/`brew-tools` recipes, status-only login banner; lockdown to `drop` at 19:34, LAN SSH and ping blocked. `ujust pi-eeprom` needed binutils (fixed in #37) |
| 7b′ | First `juniper-minimal` attempt | **unexplained hang**: Ethernet + Wi-Fi configured; no network at all; root partition never grown, CIDATA untouched, root XFS log dirty (so root was mounted), no persistent journal (stopped before `systemd-journal-flush`). The same image booted fine on the next attempt (Wi-Fi only, fresh flash). Open: retry with Ethernet and `console=ttyAMA10,115200` to capture it |
| — | `just flash` on real cards (#37) | three bugs found and fixed: EXIT trap's `umount` turned success into exit 32 (`set -e` applies in traps); stale same-tag cache; races with the desktop automounter. `run0` needs `/usr/bin/bash` (SELinux denies exec of `user_home_t`) |
| 5b | Update that drops into real-root emergency mode falls back (#32) | pass: required mount of a missing device → 90 s device timeout → `local-fs.target` failed → emergency → `juniper-emergency-fallback` "rebooting … in 60s" → back on the previous image (17:43 → 17:46) |
| — | Health check (#32): locked + Tailscale SSH → healthy; IPv6 route accepted | pass (Pi run of the new script; unit tests for the rest) |
| — | `cidata-device` on the Pi | pass: `/dev/mmcblk0p1` |
| — | `ujust pi-eeprom` (#34), check only | pass: "update available", CURRENT 2025-11-05, LATEST 2026-05-11 (not applied) |
| — | Brewfile tools (#34) via `brew bundle` | pass: zellij 0.45.1, neovim 0.12.6, btop, ripgrep, fzf in 25 s |
| — | Trimmed initramfs (#35) via tryboot | pass: entry initrd 28.8 MB (was 45.8 MB); initrd stage 3.00 s (was 4.28 s); no failed units |
| — | Release pipeline (#33) | pass: `sign` jobs in the `release` environment; `:latest` == `:sha-531a840` digest; disks from their run's digest; changelog pushed with the environment deploy key through the `main` ruleset |

Notes:

- `bootc status` shows the origin as `ostree-unverified-registry:`; enforcement comes from
  `/etc/containers/policy.json`, as the unsigned-image test shows.
- `ip`, `swapon` and similar live in `/usr/sbin`, which isn't on a normal user's `PATH` in
  Tailscale SSH sessions; root and the services have it.
- On the device, `dnf check-update` stops at the Tailscale repo ("Signing key not found")
  until its key is imported; it doesn't affect image updates.
- The base image (built 2026-10-02) had 66 package updates pending on 2026-10-10, 14
  Important and 19 Moderate security advisories; #30 applies them at build time.
