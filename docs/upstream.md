# Upstream candidates

Problems found while building and testing Juniper that belong to projects we build on. Not
filed yet (owner decision, 2026-10-10). Before filing, reproduce on the **unmodified**
`quay.io/almalinuxorg/almalinux-bootc-rpi:10` image where noted, and search for an existing
issue.

## AlmaLinux (bootc-images-rpi, or the Raspberry Pi SIG packages)

### `rpi-eeprom` packaging

- `rpi-eeprom-update` calls `strings` (lines 132, 225, 398 in 2026.05.11) but the package
  doesn't require `binutils`: "strings not found. Try installing the binutils package." on a
  Pi 5. Verified from the RPM metadata (`rpm -qp --requires`).
- The tools package ships no bootloader images; they're in `rpi-eeprom-firmware`. Easy to miss.
- On bootc the firmware partition is mounted at `/boot/efi`, so `BOOTFS` must be set in
  `/etc/default/rpi-eeprom-update`; the image could ship that.
- Where: the package lives in AlmaLinux's `raspberrypi` repo; likely the Raspberry Pi SIG's
  package tracker rather than bootc-images-rpi. Juniper's fix: #34, #37.

### Kernel updates in derived images

- `dnf upgrade` of `raspberrypi2-kernel4`/`raspberrypi2-firmware` in a container build can't
  work: the posttrans only moves `kernel-*.img` to `/usr/lib/modules/$kver/vmlinuz` when files
  sit in `/usr/lib/ostree-boot` (rpm-ostree compose), and otherwise runs dracut into `/boot`.
  rpi-bootc-bootloader also assumes one kernel (`ls modules | head -n 1`). So derived images
  only get kernel updates when the base is rebuilt.
- Ask: document it, or make the scriptlets work for container builds.
- Juniper's workaround: `dnf upgrade --exclude='raspberrypi2-kernel*' --exclude='raspberrypi2-firmware*'`
  plus a CI warning when the repo has a newer kernel (#30, #33).

### Generic initramfs (comment on issue #13 "Shrink base image")

- The base ships a generic 46 MB initramfs (`hostonly=no`, plus virtiofs, lvm, fips, tpm2-tss,
  clevis, nss-softokn, network root, all console fonts). A Pi-specific dracut drop-in made it
  29 MB and the initrd stage 4.28 s → 3.00 s on a Pi 5, and regenerating it in the build
  keeps it in step with upgraded systemd/ostree. Juniper: #35
  (`system_files/usr/lib/dracut/dracut.conf.d/90-juniper.conf`).

### Wi-Fi from `network-config` is ignored (comment on issue #19 "rpi-imager")

- cloud-init 24.4 renders netplan v2 `wifis:` only through netplan, which EL doesn't ship
  ("Wifi configuration is only available to distros with netplan rendering support"), so the
  Wi-Fi that Raspberry Pi Imager writes does nothing. Matters for #19. The root cause is
  cloud-init's NetworkManager renderer; it may also deserve a cloud-init issue. Juniper's
  workaround: `juniper-wifi-import` (#22).
- Related: AlmaLinux's `prefer_fqdn_over_hostname` default makes cloud-init use the router's
  DNS name for the DHCP address instead of `hostname:` from user-data. Juniper sets it to
  `false` (#22).

### Daily build failing since 2026-10-07

- The `Build` workflow has failed every day from 2026-10-07 to at least 2026-10-10 (a
  Debian/dpkg error on the runner; see `gh run list -R AlmaLinux/bootc-images-rpi`). No issue
  existed on 2026-10-10. Check it's still failing before filing.

## kfox1111/rpi-bootc-bootloader

- **Pi 4 firmware never updated:** only kernel, initrd, DTBs, overlays and `rpi-config.txt`
  are per boot entry (`process_path()`), so `start4.elf`/`fixup4.dat` on the FAT stay at
  their flashed version and aren't covered by tryboot. Possible fix: per-entry
  `start_file`/`fixup_file` in `tryboot.txt` and the default config (check how they interact
  with `os_prefix`).
- **LUKS:** the FAT partition is found by rewriting the `/sysroot` device name
  (`sed 's/[0-9]+$/1/'`), which fails for `/dev/mapper/*`; `MNTDEV` works around it. Deriving
  it from the disk under `/sysroot` (as Juniper's `cidata-device` does) would be more robust.
- **Real-root emergency mode under tryboot never falls back** (PID 1 keeps the watchdog fed).
  Juniper's `juniper-emergency-fallback` (#32, tested on a Pi 5) could be offered upstream.
- `config.txt` is only written if missing, so template changes never reach existing devices.
