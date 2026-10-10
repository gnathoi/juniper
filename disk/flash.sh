#!/usr/bin/env bash
# Flash a signed Juniper release onto an SD card or USB disk, with first-boot settings
# (user, SSH keys, Tailscale key, Wi-Fi) from a config file (examples/flash.yaml):
#   flash.sh DEVICE CONFIG [latest | RELEASE-TAG | PATH.raw.xz]
# Downloads and cosign-verifies as you; only the write runs under sudo.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=gnathoi/juniper
pubkey=$here/../system_files/usr/share/pki/containers/juniper.pub

die() {
  echo "flash: $*" >&2
  exit 1
}

if [[ ${1:-} == --write ]]; then
  # Root phase: flash.sh --write DEVICE IMAGE.raw.xz CIDATA-DIR
  dev=$2 xz=$3 cidata_src=$4
  "$here/check-target" "$dev"
  for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  wipefs -a "$dev" >/dev/null
  xzcat "$xz" | dd of="$dev" bs=4M conv=fsync status=progress
  sync
  partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev"
  udevadm settle
  part=$(lsblk -nrpo PATH,LABEL "$dev" | awk '$2 == "CIDATA" {print $1; exit}')
  [[ -n $part ]] || die "no CIDATA partition on $dev after writing"
  mnt=$(mktemp -d)
  mount "$part" "$mnt"
  cp "$cidata_src/user-data" "$mnt/user-data"
  if [[ -e $cidata_src/network-config ]]; then cp "$cidata_src/network-config" "$mnt/"; fi
  sync
  umount "$mnt"
  rmdir "$mnt"
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
  tag=$source
  if [[ $tag == latest ]]; then tag=$(gh release view --repo "$repo" --json tagName -q .tagName); fi
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/juniper/$tag
  mkdir -p "$cache"
  # Dates start with 2: juniper-2* never matches juniper-minimal-*.
  gh release download "$tag" --repo "$repo" -D "$cache" --skip-existing \
    -p "$image-2*.raw.xz" -p "$image-2*.raw.xz.bundle"
  xz=$(find "$cache" -maxdepth 1 -name "$image-2*.raw.xz" | sort | tail -1)
  [[ -n $xz ]] || die "no $image disk image in release $tag"
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
read -rp "Everything on $dev will be erased. Type $dev to continue: " answer
[[ $answer == "$dev" ]] || die "not confirmed; nothing written"

sudo "$here/flash.sh" --write "$dev" "$xz" "$work/cidata"
echo "Done. Put the card in the Pi and power it on."
