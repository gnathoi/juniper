#!/usr/bin/env bash
# Smoke test executed inside a built image (no systemd running):
#   just image=juniper test-image   /   just image=juniper-minimal test-image
#   just image=juniper-desktop test-image
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Name the failing check: most of them are silent greps.
trap 'echo "image.sh:$LINENO: failed: $BASH_COMMAND" >&2' ERR

# shellcheck source=/dev/null
. /usr/lib/os-release
[[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-minimal || $IMAGE_ID == juniper-desktop ]] || {
  echo "unexpected IMAGE_ID: $IMAGE_ID"
  exit 1
}
grep -q '^PRETTY_NAME="Juniper' /usr/lib/os-release
grep -qx 'NAME="Juniper"' /usr/lib/os-release
grep -qx 'ID="almalinux"' /usr/lib/os-release # dnf, cloud-init and bootc key off ID
test -s /usr/share/licenses/juniper/LICENSE
test -s /usr/share/licenses/juniper/THIRD_PARTY.md
grep -q 'BSD 3-Clause' /usr/share/licenses/tailscale/LICENSE

# fail MSG: stop the image test with a message (a bare `set -e` exit prints nothing).
fail() {
  echo "image test: $*" >&2
  exit 1
}
need_cmds() {
  for cmd; do
    command -v "$cmd" >/dev/null || {
      echo "missing: $cmd"
      exit 1
    }
  done
}
need_enabled() {
  for unit; do
    [[ $(systemctl is-enabled "$unit") == enabled ]] || {
      echo "not enabled: $unit"
      exit 1
    }
  done
}

# --- shared (both images) ---
need_cmds tailscale tailscaled podman just jq rsync firewall-cmd cloud-init
# fzf comes from Homebrew on juniper (Brewfile), not the image (it's just's weak dependency).
if rpm -q fzf >/dev/null; then
  echo "fzf is in the image"
  exit 1
fi
need_enabled tailscaled.service firewalld.service avahi-daemon.service cloud-init.service \
  cloud-final.service podman-auto-update.timer
[[ $(systemctl is-enabled bootc-fetch-apply-updates.timer) == masked ]]
# Keep Count Me reporting functional, not masked (#104).
need_enabled rpm-ostree-countme.timer
[[ $(systemctl is-enabled rpm-ostree-countme.service) != masked ]]
# shellcheck disable=SC2016 # this unresolved DNF expression breaks countme
if grep -E '^[[:space:]]*metalink[[:space:]]*=' /etc/yum.repos.d/epel*.repo | grep -qF '${releasever_minor:+-z}'; then
  fail 'EPEL metalink still contains the countme-incompatible conditional'
fi
grep -q 'resize_what = "/var"' /usr/lib/python3*/site-packages/cloudinit/config/cc_resizefs.py
for k in rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot; do
  grep -q "$k" /usr/lib/bootc/kargs.d/10-juniper.toml
done

# Key-only SSH on every image, whatever cloud-init writes later (40-juniper.conf comes first,
# and sshd keeps the first value). sshd -T needs a host key: use a throwaway one.
t=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -f "$t/hostkey"
sshd_eff=$(sshd -T -h "$t/hostkey")
rm -rf "$t"
for opt in passwordauthentication kbdinteractiveauthentication; do
  grep -qx "$opt no" <<<"$sshd_eff" || {
    echo "sshd: $opt is not off"
    exit 1
  }
done

# Package repos trust only local keys (build_files/keys): every enabled repo, whichever file
# it's in, has signature checks on and nothing but file:///etc/pki/rpm-gpg/ keys (tests/
# repo-audit.sh parses the files strictly: truthy forms, continuation lines, extra keys). EPEL
# and Tailscale must be among them, and are checked against the pinned keys below.
repo_dirs=(/etc/yum.repos.d)
for d in /etc/distro.repos.d /usr/share/dnf5/repos.d; do
  [[ -d $d ]] && repo_dirs+=("$d")
done
"$(dirname "$0")/repo-audit.sh" -r epel -r tailscale-stable "${repo_dirs[@]}"
for want in gpgcheck=1 repo_gpgcheck=1 gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale; do
  grep -qx "$want" /etc/yum.repos.d/tailscale.repo
done
# shellcheck disable=SC2016 # a literal dnf variable
grep -qxF 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-$releasever_major' /etc/yum.repos.d/epel.repo
# Every primary key in the file (subkeys follow their primary and are not listed), so an
# extra key slipped into a pinned file changes the output.
key_fpr() { GNUPGHOME=$(mktemp -d) gpg --show-keys --with-colons "$1" | awk -F: '$1 == "pub" {p = 1} $1 == "fpr" && p {print $10; p = 0}'; }
[[ $(key_fpr /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-10) == 7D8D15CBFC4E62688591FB2633D98517E37ED158 ]]
[[ $(key_fpr /etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale) == 2596A99EAAB33821893C0A79458CA832957F5868 ]]

need_enabled juniper-firstboot.service juniper-tailscale-join.service
test -x /usr/libexec/juniper/tailscale-join
test -x /usr/libexec/juniper/lan-ssh
test -x /usr/libexec/juniper/metrics
test -x /usr/libexec/juniper/encryption-status
need_enabled juniper-update.timer juniper-image-prune.timer juniper-metrics.timer juniper-reboot.timer juniper-healthcheck.service juniper-lan-ssh-status.service juniper-encryption-status.service
need_cmds rpi-bootc-bootloader
grep -qx 'TRYBOOT=1' /etc/rpi-bootc-bootloader/tryboot.conf
test -x /usr/libexec/juniper/bootloader
# The effective ExecStop list is exactly one command, our wrapper. rpi-bootc-bootloader's own
# drop-in already replaced the unit's `ostree admin finalize-staged` with the tool, which runs
# ostree admin finalize-staged itself, so that call must stay reachable through the tool.
# No systemd in the test container: resolve the list as systemd does (unit, then drop-ins in
# name order; an empty ExecStop= resets).
u=/usr/lib/systemd/system/ostree-finalize-staged.service
stops=()
for f in "$u" "$u".d/*.conf; do
  while IFS= read -r l; do
    case $l in
      ExecStop=) stops=() ;;
      ExecStop=*) stops+=("${l#ExecStop=}") ;;
    esac
  done <"$f"
done
[[ ${#stops[@]} == 1 && ${stops[0]} == '/usr/libexec/juniper/bootloader finalize-staged' ]]
grep -q 'ostree admin finalize-staged' /usr/bin/rpi-bootc-bootloader
grep -qx 'OnCalendar=Tue \*-\*-\* 04:00:00' /usr/lib/systemd/system/juniper-reboot.timer || {
  echo "reboot timer default is not Tue 04:00" >&2
  exit 1
}
systemd-analyze verify /usr/lib/systemd/system/juniper-*.service /usr/lib/systemd/system/juniper-*.timer
systemd-analyze verify /usr/lib/dracut/modules.d/90juniper-cryptroot/juniper-cryptroot-*.service
# prepare runs while udevd-control.socket exists but udevd doesn't: libdevmapper must not
# wait for udev there; unlock (after udevd) must keep udev sync.
grep -qx 'Environment=DM_DISABLE_UDEV=1' /usr/lib/dracut/modules.d/90juniper-cryptroot/juniper-cryptroot-prepare.service
if grep -q DM_DISABLE_UDEV /usr/lib/dracut/modules.d/90juniper-cryptroot/juniper-cryptroot-unlock.service; then
  echo "unlock must keep udev sync (no DM_DISABLE_UDEV)"
  exit 1
fi
# Ordering cycles only show up in a whole boot transaction (and verify still exits 0).
# cloud-init's generator adds cloud-init.target on first boot; cloud-final runs after
# multi-user.target, so nothing multi-user.target pulls in may order itself after it.
cycles=$(systemd-analyze verify multi-user.target cloud-init.target 2>&1 | grep 'ordering cycle' || true)
[[ -z $cycles ]] || {
  echo "$cycles"
  exit 1
}
# rpi-eeprom-update also needs strings (binutils), which rpi-eeprom does not require.
need_cmds rpi-eeprom-update lspci strings
# Trimmed initramfs (90-juniper.conf): ostree and crypt in, network root/VM/RAID/TPM out.
for img in /usr/lib/modules/*/initramfs.img; do
  mods=$(lsinitrd "$img" | sed -n '/^dracut modules:/,/^=/p')
  for m in ostree crypt systemd-initrd rootfs-block juniper-cryptroot; do grep -qx "$m" <<<"$mods"; done
  for m in nfs network-manager qemu lvm clevis fips btrfs; do
    if grep -qx "$m" <<<"$mods"; then
      echo "initramfs still has $m"
      exit 1
    fi
  done
  echo "initramfs size: $(stat -c %s "$img") bytes ($img)"
  (($(stat -c %s "$img") < 40 * 1024 * 1024))
  # Encrypted root (issue #50): the juniper-cryptroot module, its tools, units and modules.
  lsinitrd "$img" >"$tmp/inv"
  for f in usr/sbin/cryptsetup usr/bin/rpi-fw-crypto usr/bin/age usr/sbin/sfdisk usr/sbin/partx usr/sbin/blkid \
    usr/libexec/juniper/cryptroot usr/libexec/juniper/fwkey \
    usr/lib/systemd/system/juniper-cryptroot-prepare.service usr/lib/systemd/system/juniper-cryptroot-unlock.service \
    sysinit.target.wants/juniper-cryptroot-prepare.service initrd.target.wants/juniper-cryptroot-unlock.service \
    kernel/drivers/md/dm-crypt.ko kernel/drivers/md/dm-mod.ko kernel/crypto/adiantum.ko kernel/crypto/algif_skcipher.ko \
    arch/arm64/crypto/aes-ce-blk.ko usr/sbin/dmsetup usr/lib/udev/rules.d/10-dm.rules \
    usr/lib/udev/rules.d/13-dm-disk.rules usr/lib/udev/rules.d/95-dm-notify.rules; do
    grep -q "$f" "$tmp/inv" || {
      echo "initramfs lacks $f"
      exit 1
    }
  done
  # Every command cryptroot/fwkey can run resolves inside the unpacked initramfs. The list is
  # derived from the initramfs's own copies of the scripts (tests/script-commands.py, which
  # tests/unit.sh also checks against module-setup.sh), plus a fixed floor in case the
  # extractor ever under-reports. /usr/sbin is not merged into /usr/bin on EL10.
  rm -rf "$tmp/ir"
  mkdir "$tmp/ir"
  (cd "$tmp/ir" && lsinitrd --unpack "$img" >/dev/null)
  bash -n "$tmp/ir/usr/libexec/juniper/cryptroot"
  bash -n "$tmp/ir/usr/libexec/juniper/fwkey"
  derived=$(python3 "$(dirname "$0")/script-commands.py" "$tmp/ir/usr/libexec/juniper/cryptroot" "$tmp/ir/usr/libexec/juniper/fwkey")
  grep -qx wc <<<"$derived" # the extractor works (fwkey's firmware gate uses wc)
  for c in $derived cryptsetup rpi-fw-crypto age sfdisk partx blkid mount umount mkdir grep sed tr od readlink sync mv sleep modprobe env bash wc; do
    case $c in
      '$'*) continue ;; # function dispatch; tests/unit.sh allowlists these
      /*) p=$tmp/ir$c ;;
      *) p= ;;
    esac
    found=0
    for p in ${p:+"$p"} "$tmp/ir/usr/bin/$c" "$tmp/ir/usr/sbin/$c"; do
      if [[ -e $p || -L $p ]]; then found=1; fi
    done
    ((found)) || {
      echo "initramfs lacks command $c"
      exit 1
    }
  done
  rm -rf "$tmp/ir"
done
# rpi-eeprom ships only the tools; the bootloader images are in rpi-eeprom-firmware.
ls /usr/lib/firmware/raspberrypi/bootloader-2712/default/pieeprom-*.bin >/dev/null
ls /usr/lib/firmware/raspberrypi/bootloader-2711/default/pieeprom-*.bin >/dev/null
grep -qx 'BOOTFS=/boot/efi' /etc/default/rpi-eeprom-update
for kdir in /usr/lib/modules/*/; do
  grep -qx 'disable_splash=1' "$kdir/rpi-config.txt"
  # KMS graphics only on the desktop; the headless images keep displays off.
  if [[ $IMAGE_ID == juniper-desktop ]]; then
    grep -qx 'dtoverlay=vc4-kms-v3d' "$kdir/rpi-config.txt"
    grep -qx 'display_auto_detect=1' "$kdir/rpi-config.txt"
  else
    grep -qx 'display_auto_detect=0' "$kdir/rpi-config.txt"
    if grep -q 'vc4-kms' "$kdir/rpi-config.txt"; then
      echo "KMS overlay in a headless image"
      exit 1
    fi
  fi
done
# rpi-fw-crypto + age (issue #50): the OTP-bound key and recovery sealing for root encryption.
need_cmds rpi-fw-crypto age cryptsetup sfdisk partx
# Each of these checks names what it got: a bare `set -e` failure in the smoke test is silent.
ldd /usr/bin/rpi-fw-crypto >"$tmp/ldd" 2>&1 || fail "ldd rpi-fw-crypto failed: $(cat "$tmp/ldd")"
# /lib64 is a symlink to usr/lib64, so the loader may report either path.
grep -Eq 'librpifwcrypto\.so\.0 => (/usr)?/lib64/' "$tmp/ldd" ||
  fail "librpifwcrypto.so.0 not resolved from /usr/lib64: $(cat "$tmp/ldd")"
usage=$({ rpi-fw-crypto 2>&1 || true; })
for sub in 'hmac --in' 'genkey' 'get-key-status' 'set-key-status'; do
  grep -q -- "$sub" <<<"$usage" || fail "rpi-fw-crypto lacks $sub; its usage: $usage"
done
test -s /usr/share/licenses/rpi-fw-crypto/LICENCE || fail "no rpi-fw-crypto LICENCE"
for kdir in /usr/lib/modules/*/; do
  # lock_device_private_key=1 must stay out: it is the old global lock (status bit 8), which on
  # firmware before 2026-06-17 also blocks genkey (error 4), so a blank board could never get
  # a key. fwkey applies the per-operation locks at runtime instead.
  if grep -q 'lock_device_private_key' "$kdir/rpi-config.txt"; then
    fail "lock_device_private_key in $kdir/rpi-config.txt blocks genkey on current firmware"
  fi
  if grep -q 'lock_device_key_write' "$kdir/rpi-config.txt"; then
    fail "lock_device_key_write breaks genkey"
  fi
done
for img in /usr/lib/modules/*/initramfs.img; do
  lsinitrd "$img" >"$tmp/inv" 2>"$tmp/inv.err" || fail "lsinitrd $img failed: $(head -c 2000 "$tmp/inv.err")"
  if grep -q 'kernel/x86/microcode' "$tmp/inv"; then
    fail "x86 microcode in the arm64 initramfs"
  fi
  echo "initramfs: $img: $(stat -c %s "$img") bytes"
done
# fwkey (issue #50): runs in the image without the firmware, and never touches it here.
test -x /usr/libexec/juniper/fwkey || fail "fwkey missing or not executable"
fwkey_probe=$(JUNIPER_VCIO=/nonexistent /usr/libexec/juniper/fwkey probe) ||
  fail "fwkey probe failed"
[[ $fwkey_probe == 'unavailable:no /nonexistent' ]] || fail "fwkey probe without vcio: $fwkey_probe"
fwkey_lock=$(JUNIPER_VCIO=/nonexistent /usr/libexec/juniper/fwkey lock) || fail "fwkey lock failed"
[[ $fwkey_lock == unavailable ]] || fail "fwkey lock without vcio: $fwkey_lock"
if /usr/libexec/juniper/fwkey card-id nosuchdisk0 >/dev/null 2>&1; then
  fail "fwkey card-id accepted a disk that is not in sysfs"
fi
# cryptroot (issue #50): runs in the image; with no root partition to find it does nothing.
test -x /usr/libexec/juniper/cryptroot || fail "cryptroot missing or not executable"
bash -n /usr/libexec/juniper/cryptroot || fail "cryptroot has a syntax error"
crdir=$(mktemp -d)
echo "root=UUID=00000000-0000-4000-8000-000000000000 rw" >"$crdir/cmdline"
for crcmd in prepare unlock; do
  JUNIPER_CMDLINE=$crdir/cmdline JUNIPER_ROOT_WAIT=0 JUNIPER_RUN_DIR=$crdir/run \
    JUNIPER_CIDATA_MNT=$crdir/cidata JUNIPER_CRYPTSETUP_LOCKDIR=$crdir/lock \
    /usr/libexec/juniper/cryptroot "$crcmd" 2>/dev/null || fail "cryptroot $crcmd without a root failed"
done
[[ ! -e $crdir/cidata && ! -e $crdir/lock ]] || fail "cryptroot touched CIDATA or cryptsetup without a root"
crrc=0
/usr/libexec/juniper/cryptroot bogus 2>/dev/null || crrc=$?
[[ $crrc == 2 ]] || fail "cryptroot usage error exited $crrc, not 2"
rm -rf "${crdir:?}"
# /dev/vcio stays root-only: it is the only barrier without the HMAC lock (ruling 4).
if grep -rlE 'vcio.*MODE|vcio.*GROUP' /usr/lib/udev/rules.d /etc/udev/rules.d 2>/dev/null; then
  echo "a udev rule widens /dev/vcio"
  exit 1
fi
need_enabled juniper-wifi-import.service juniper-firstboot-retry.service juniper-emergency-fallback.service
grep -qx 'prefer_fqdn_over_hostname: false' /etc/cloud/cloud.cfg.d/10-juniper-hostname.cfg
test -f /usr/share/juniper/cidata/user-data
[[ $(systemctl is-enabled juniper-lockdown.timer) == enabled ]]
firewall-offline-cmd --get-default-zone | grep -qx public

recipes=$(ujust --summary | tr ' ' '\n')
for r in update switch update-schedule lan-ssh tailscale-up tailscale-ssh toggle-motd enable-metrics pi-status pi-eeprom; do
  grep -qx "$r" <<<"$recipes" || {
    echo "missing recipe: $r"
    exit 1
  }
done
test -f /usr/share/bash-completion/completions/ujust
bash -c 'source /usr/share/bash-completion/bash_completion && _completion_loader ujust; complete -p ujust' | grep -q _ujust
# Capture first: `grep -q` exiting early would SIGPIPE motd under pipefail.
motd=$(HOME=/tmp /usr/libexec/juniper/motd)
grep -q 'Tailscale' <<<"$motd"

jq -e '[.transports.docker[][] | select(.type == "sigstoreSigned" and .keyPath == "/usr/share/pki/containers/juniper.pub")] | length == 1' /etc/containers/policy.json >/dev/null
# R8: scoped to the namespace, not one image, so juniper <-> juniper-minimal switches stay enforced.
jq -e '[.transports.docker | to_entries[] | select(.value[0].keyPath == "/usr/share/pki/containers/juniper.pub") | .key | contains("juniper") | not] == [true]' /etc/containers/policy.json >/dev/null
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/juniper.yaml
# The policy is generated from a base in /usr (updates with the image); /etc starts identical.
base=/usr/share/juniper/containers/policy.json
[[ $(<"$base") == "$(</etc/containers/policy.json)" ]] || {
  echo "/etc/containers/policy.json differs from the base policy" >&2
  exit 1
}
need_enabled juniper-containers-policy.service
# trust-images round trip on a scratch policy, generated from the real base and validated by the
# image's own skopeo.
for r in trust-images untrust-images; do grep -qx "$r" <<<"$recipes" || {
  echo "missing recipe: $r"
  exit 1
}; done
tdir=$(mktemp -d)
cp /etc/containers/policy.json "$tdir/policy.json"
mkdir "$tdir/registries.d"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | openssl pkey -pubout -out "$tdir/k.pub"
export JUNIPER_POLICY=$tdir/policy.json JUNIPER_REGISTRIES_D=$tdir/registries.d JUNIPER_KEY_DIR=$tdir/pki \
  JUNIPER_TRUST_DIR=$tdir/trusted-images.d
/usr/libexec/juniper/trust-images ghcr.io/example "$tdir/k.pub" >/dev/null 2>&1
jq -e '.transports.docker["ghcr.io/example"][0].keyPath | endswith("/ghcr.io+example.pub")' "$tdir/policy.json" >/dev/null
test -f "$tdir/trusted-images.d/ghcr.io+example.json"
juniper_ns=$(jq -r '.transports.docker | to_entries[] | select(.value[0].keyPath == "/usr/share/pki/containers/juniper.pub") | .key' "$base")
if /usr/libexec/juniper/trust-images "$juniper_ns" "$tdir/k.pub" 2>/dev/null; then
  echo "trust-images changed Juniper's namespace" >&2
  exit 1
fi
# Hand-written drop-ins for Juniper's namespace, or a repo under it, are skipped by the generator.
printf '{"%s": [{"type": "sigstoreSigned", "keyPath": "%s"}]}\n' "$juniper_ns" "$tdir/k.pub" >"$tdir/trusted-images.d/evil.json"
printf '{"%s/juniper-minimal": [{"type": "sigstoreSigned", "keyPath": "%s"}]}\n' "$juniper_ns" "$tdir/k.pub" >"$tdir/trusted-images.d/evil2.json"
/usr/libexec/juniper/containers-policy 2>/dev/null
[[ $(jq -cS --arg ns "$juniper_ns" '.transports.docker[$ns]' "$tdir/policy.json") == "$(jq -cS --arg ns "$juniper_ns" '.transports.docker[$ns]' "$base")" ]]
jq -e --arg ns "$juniper_ns/juniper-minimal" '.transports.docker | has($ns) | not' "$tdir/policy.json" >/dev/null
rm "$tdir/trusted-images.d/evil.json" "$tdir/trusted-images.d/evil2.json"
/usr/libexec/juniper/trust-images --remove ghcr.io/example >/dev/null 2>&1
[[ $(<"$tdir/policy.json") == "$(<"$base")" ]]
unset JUNIPER_POLICY JUNIPER_REGISTRIES_D JUNIPER_KEY_DIR JUNIPER_TRUST_DIR
rm -rf "$tdir"

if [[ $IMAGE_ID == juniper || $IMAGE_ID == juniper-desktop ]]; then
  # --- full image only ---
  need_cmds distrobox fastfetch git zstd
  need_enabled brew-setup.service brew-update.timer brew-upgrade.timer
  # CLI tools come from Homebrew at first login, not the image.
  for f in zellij fzf atuin starship zoxide carapace; do
    grep -qx "brew \"$f\"" /usr/share/juniper/Brewfile
  done
  # The shell hooks parse, and stay inert with none of the tools installed yet
  bash -n /etc/profile.d/juniper-shell.sh
  test -s /usr/share/juniper/starship.toml
  test -s /usr/share/licenses/starship-preset/LICENSE
  if HOME=$(mktemp -d) TERM=xterm bash --norc --noprofile -i -c '. /etc/profile.d/juniper-shell.sh' 2>&1 |
    grep -v -e 'job control' -e 'process group' | grep -q .; then
    echo "juniper-shell.sh is noisy without its tools"
    exit 1
  fi
  [[ $(systemctl --global is-enabled juniper-brew-tools.service) == enabled ]]
  test -s /usr/share/homebrew.tar.zst
  test -f /etc/profile.d/brew.sh
  grep -q 'Apache License' /usr/share/licenses/ublue-os-brew/LICENSE
  just --justfile /usr/share/juniper/just/dev.just --summary | tr ' ' '\n' | grep -qx devbox
  for r in devbox install-podlet brew-tools toggle-shell; do
    grep -qx "$r" <<<"$recipes" || {
      echo "missing recipe: $r"
      exit 1
    }
  done
  fastfetch --config /etc/xdg/fastfetch/config.jsonc --pipe >/dev/null
else
  # --- minimal only: no developer tooling ---
  for cmd in distrobox fastfetch nvim tmux btop git; do
    if command -v "$cmd" >/dev/null; then
      echo "dev tool in minimal: $cmd"
      exit 1
    fi
  done
  test ! -e /usr/share/homebrew.tar.zst
  test ! -e /usr/share/juniper/just/dev.just
  test ! -e /etc/profile.d/juniper-shell.sh
  if grep -qx devbox <<<"$recipes"; then
    echo "dev recipe in minimal: devbox"
    exit 1
  fi
fi

if [[ $IMAGE_ID == juniper-desktop ]]; then
  # --- desktop only ---
  need_cmds niri niri-session xwayland-satellite Xwayland greetd dms-greeter dms qs matugen dgop \
    cliphist chezmoi xdg-terminal-exec foot swayidle pipewire wireplumber flatpak notify-send jq
  for cmd in waybar fuzzel swaylock swaync swaybg; do
    if command -v "$cmd" >/dev/null; then
      echo "replaced by DMS but still installed: $cmd"
      exit 1
    fi
  done
  rpm -q accountsservice qt6-qtmultimedia qt6-qtwayland material-symbols-fonts >/dev/null
  test -s /usr/share/juniper/wallpapers/juniper-berry.png
  need_enabled greetd.service
  systemd-analyze verify greetd.service
  # Login: dms-greeter as the unprivileged greeter user; a session only after PAM, typed wayland.
  grep -qx 'command = "dms-greeter --command niri --cache-dir /var/cache/dms-greeter"' /etc/greetd/config.toml
  grep -qx 'service = "greetd-spawn"' /etc/greetd/config.toml
  getent passwd greeter >/dev/null
  [[ $(id -u greeter) -lt 1000 ]]
  test -s /etc/pam.d/greetd-spawn
  if grep -q initial_session /etc/greetd/config.toml ||
    compgen -G '/usr/lib/systemd/system/greetd.service.d/*' >/dev/null ||
    compgen -G '/etc/systemd/system/greetd.service.d/*' >/dev/null; then
    echo "greetd auto-login, or a drop-in overriding /etc/greetd/config.toml"
    exit 1
  fi
  # dms-greeter's install labelled its paths with semanage in the build; the image must keep them
  [[ $(matchpathcon -n /var/lib/greeter) == *:user_home_dir_t:* ]]
  [[ $(matchpathcon -n /var/cache/dms-greeter) == *:cache_home_t:* ]]
  [[ $(matchpathcon -n /usr/bin/dms-greeter) == *:bin_t:* ]]
  # An update that doesn't bring greetd up is rolled back under tryboot (healthcheck hook).
  test -x /usr/lib/juniper/health.d/10-greetd
  grep -q '^GPGKey=' /etc/flatpak/remotes.d/flathub.flatpakrepo
  need_enabled juniper-flatpak-setup.timer juniper-flatpak-update.timer
  systemd-analyze verify juniper-flatpak-setup.timer juniper-flatpak-setup.service juniper-flatpak-update.service
  # The app download runs from its timer, outside the boot transaction: it must not delay
  # multi-user.target (cloud-final, then the first-boot secret scrub, wait for it).
  [[ $(systemctl is-enabled juniper-flatpak-setup.service) == static ]] || {
    echo "juniper-flatpak-setup.service is wanted by a boot target"
    exit 1
  }
  # The reboot window waits for an idle desktop (checked by file: no running systemd in CI).
  test -e /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf
  grep -q '^ExecCondition=/usr/libexec/juniper/desktop-idle$' \
    /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf
  test -x /usr/libexec/juniper/desktop-idle
  need_enabled juniper-reboot-retry.timer
  systemd-analyze verify juniper-reboot-retry.service
  # ...and only while automatic reboots are on (`ujust update-schedule off` disables the timer).
  grep -qx 'ExecCondition=/usr/bin/systemctl is-enabled --quiet juniper-reboot.timer' \
    /usr/lib/systemd/system/juniper-reboot-retry.service
  niri validate -c /usr/share/juniper/niri/juniper.kdl
  niri validate -c /etc/niri/config.kdl
  [[ $(systemctl --global is-enabled dms.service) == enabled ]]
  test -x /usr/libexec/juniper/desktop-idle-hint
  test ! -e /usr/libexec/juniper/desktop-idle-lock
  grep -qx foot.desktop /usr/share/xdg-terminal-exec/xdg-terminals.list
  # Juniper's dotfiles: a fresh home gets a valid niri config and DMS settings that keep the
  # update path and the network quiet; a file the user already has is kept.
  [[ $(systemctl --global is-enabled juniper-dots-init.service) == enabled ]]
  [[ $(systemctl --global is-enabled juniper-dots-update.timer) == enabled ]]
  t=$(mktemp -d)
  (umask 077 && mkdir -p "$t/home/.config/foot")
  echo '# mine' >"$t/home/.config/foot/foot.ini"
  (umask 022 && HOME=$t/home /usr/libexec/juniper/dots init)
  [[ $(stat -c %a "$t/home/.config") == 700 && $(stat -c %a "$t/home/.local") == 700 ]]
  niri validate -c "$t/home/.config/niri/config.kdl"
  grep -qx '# mine' "$t/home/.config/foot/foot.ini"
  s=$t/home/.config/DankMaterialShell/settings.json
  [[ $(jq -c '[.weatherEnabled, .useAutoLocation, .updaterHideWidget, .updaterCustomCommand, .acLockTimeout]' "$s") == '[false,false,true,"ujust update",600]' ]]
  [[ $(jq -r .wallpaperPath "$t/home/.local/state/DankMaterialShell/session.json") == /usr/share/juniper/wallpapers/juniper-berry.png ]]
  HOME=$t/home /usr/libexec/juniper/desktop-lock-idle off >/dev/null
  [[ $(jq .acLockTimeout "$s") == 0 ]]
  rm -rf "$t"
  for r in desktop-lock-idle dots-update dots-reset toggle-auto-dots flatpak-setup; do
    grep -qx "$r" <<<"$recipes" || {
      echo "missing recipe: $r"
      exit 1
    }
  done
  if grep -qx desktop-config <<<"$recipes"; then
    echo "desktop-config is gone (chezmoi writes the niri config)"
    exit 1
  fi
  ls /usr/lib64/dri/v3d_dri.so /usr/lib64/dri/vc4_dri.so >/dev/null
  ls /usr/lib/modules/*/kernel/drivers/gpu/drm/v3d/v3d.ko* >/dev/null
  # The COPRs are build-time only: devices never pull from them.
  if ls /etc/yum.repos.d/*copr* 2>/dev/null; then
    echo "COPR repo left in the image"
    exit 1
  fi
  # Every COPR package is exactly the locked version (epoch-aware: dms-greeter-1:1.6.2-3.el10)
  test -s /usr/share/juniper/desktop.lock
  while read -r nevr; do
    name=${nevr%-*-*}
    have=$(rpm -q --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}\n' "$name" | sed 's/-(none):/-/; s/-0:/-/')
    [[ $have == "$nevr" ]] || {
      echo "not the locked version: $nevr (have $have)"
      exit 1
    }
  done </usr/share/juniper/desktop.lock
  cycles=$(systemd-analyze verify graphical.target cloud-init.target 2>&1 | grep 'ordering cycle' || true)
  [[ -z $cycles ]] || {
    echo "$cycles"
    exit 1
  }
else
  if command -v niri >/dev/null || [[ -e /usr/share/juniper/just/desktop.just ]]; then
    echo "desktop content in a headless image"
    exit 1
  fi
  if ls /etc/flatpak/remotes.d/flathub.flatpakrepo /usr/lib/systemd/system/juniper-flatpak-* 2>/dev/null; then
    echo "flatpak units or remote in a headless image"
    exit 1
  fi
  if [[ -e /usr/lib/systemd/system/juniper-reboot.service.d/10-desktop-idle.conf ||
    -e /usr/libexec/juniper/desktop-idle ||
    -e /usr/lib/systemd/system/juniper-reboot-retry.timer ||
    -e /usr/lib/systemd/system/juniper-reboot-retry.service ]]; then
    echo "desktop idle-reboot gate in a headless image"
    exit 1
  fi
  # The base defaults to graphical.target; nothing graphical starts without a display manager.
  if [[ -e /etc/systemd/system/display-manager.service ]]; then
    echo "display manager enabled in a headless image"
    exit 1
  fi
  if [[ -e /usr/lib/juniper/health.d ]]; then
    echo "health hooks in a headless image"
    exit 1
  fi
fi

echo "image smoke test: OK ($IMAGE_ID)"
