#!/usr/bin/env bash
# Flash a signed Juniper release onto an SD card or USB disk, with first-boot settings
# (user, SSH keys, Tailscale key, Wi-Fi) from a config file (examples/flash.yaml):
#   flash.sh DEVICE CONFIG [latest | RELEASE-TAG | PATH.raw.xz]
# Downloads and cosign-verifies as you; only the write runs as root (run0, else sudo).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=gnathoi/juniper
pubkey=$here/../system_files/usr/share/pki/containers/juniper.pub

die() {
  echo "flash: $*" >&2
  exit 1
}

disk_identity() { lsblk -dbno SIZE,SERIAL,MODEL,WWN "$1" | tr -s ' '; }

if [[ ${1:-} == --write ]]; then
  # Root phase: flash.sh --write DEVICE IMAGE.raw.xz CIDATA-DIR IDENTITY
  dev=$2 xz=$3 cidata_src=$4 identity=$5
  # Via bash: under run0, SELinux won't let the service execute files in a home directory.
  bash "$here/check-target" "$dev"
  # The disk you confirmed, not whatever took its device name since (a swapped card).
  [[ $(disk_identity "$dev") == "$identity" ]] || die "$dev is no longer the disk you confirmed"
  for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  wipefs -a "$dev" >/dev/null
  xzcat "$xz" | dd of="$dev" bs=4M conv=fsync status=progress
  sync
  partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev"
  udevadm settle
  part=$(lsblk -nrpo PATH,LABEL "$dev" | awk '$2 == "CIDATA" {print $1; exit}')
  [[ -n $part ]] || die "no CIDATA partition on $dev after writing"
  mnt=$(mktemp -d)
  trap 'umount "$mnt" 2>/dev/null; rmdir "$mnt"' EXIT
  # Root-only: FAT has no permissions of its own, and these files hold the secrets.
  mount -o umask=077,nosuid,nodev,noexec "$part" "$mnt"
  cp "$cidata_src/user-data" "$mnt/user-data"
  if [[ -e $cidata_src/network-config ]]; then cp "$cidata_src/network-config" "$mnt/"; fi
  sync
  # The desktop may have auto-mounted the new partitions; leave the card safe to pull.
  for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  exit 0
fi

dev=$(readlink -f "${1:?usage: flash.sh DEVICE CONFIG [latest|TAG|PATH.raw.xz]}")
config=${2:?usage: flash.sh DEVICE CONFIG [latest|TAG|PATH.raw.xz]}
source=${3:-latest}

"$here/check-target" "$dev"
work=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/juniper-flash.XXXXXX")
trap 'rm -rf "$work"' EXIT
"$here/render-cidata" "$config" "$work/cidata"
image=$(python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get("image", "juniper"))' "$config")

if [[ -f $source ]]; then
  xz=$source
else
  api=https://api.github.com/repos/$repo/releases
  if [[ $source == latest ]]; then rel=$(curl -fsSL "$api/latest"); else rel=$(curl -fsSL "$api/tags/$source"); fi
  tag=$(jq -r .tag_name <<<"$rel")
  # juniper-YYYYMMDD.raw.xz, never juniper-minimal-*
  name=$(jq -r --arg i "$image" '.assets[].name | select(test("^" + $i + "-[0-9]+\\.raw\\.xz$"))' <<<"$rel" | head -1)
  [[ -n $name ]] || die "no $image disk image in release $tag"
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/juniper/$tag
  mkdir -p "$cache"
  for f in "$name" "$name.bundle"; do
    [[ -f $cache/$f ]] && continue
    echo "Downloading $f ($tag)"
    curl -fL --progress-bar -o "$cache/$f.part" "https://github.com/$repo/releases/download/$tag/$f"
    mv "$cache/$f.part" "$cache/$f"
  done
  xz=$cache/$name
fi
[[ -f $xz.bundle ]] || die "no signature bundle next to $xz"
# Every time, not just after download: the cache is only as trusted as this check.
cosign verify-blob --key "$pubkey" --bundle "$xz.bundle" "$xz"

python3 - "$work/cidata" <<'PY'
import os, sys, yaml
d = sys.argv[1]
ud = yaml.safe_load(open(os.path.join(d, "user-data")))
u = ud["users"][0]
print(f"Hostname:  {ud['hostname']}")
print(f"User:      {u['name']} ({len(u['ssh_authorized_keys'])} SSH keys)")
print(f"Timezone:  {ud.get('timezone', 'UTC')}")
print(f"Tailscale: {'auth key set' if 'write_files' in ud else 'none (log in later with ujust tailscale-up)'}")
nc = os.path.join(d, "network-config")
ssids = list(yaml.safe_load(open(nc))["network"]["wifis"]["wlan0"]["access-points"]) if os.path.exists(nc) else []
print(f"Wi-Fi:     {ssids[0] if ssids else 'none (Ethernet)'}")
PY
echo "Image:     $(basename "$xz")"
echo
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,LABEL,MOUNTPOINTS "$dev"
echo
identity=$(disk_identity "$dev")
read -rp "Erase everything on $dev and flash it? [y/N] " answer
[[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "not confirmed; nothing written"

# run0 (systemd/polkit) works for admins without sudo rights; JUNIPER_AS_ROOT overrides.
if [[ $(id -u) == 0 ]]; then
  as_root=()
elif [[ -n ${JUNIPER_AS_ROOT:-} ]]; then
  read -ra as_root <<<"$JUNIPER_AS_ROOT"
elif command -v run0 >/dev/null; then
  as_root=(run0)
else
  as_root=(sudo)
fi
# Through bash, not exec: run0's service may not execute files labelled user_home_t.
"${as_root[@]}" /usr/bin/bash "$here/flash.sh" --write "$dev" "$xz" "$work/cidata" "$identity"
echo "Done. Put the card in the Pi and power it on."
