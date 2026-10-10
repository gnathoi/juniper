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
  trap 'echo "flash: failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR
  dev=$2 xz=$3 cidata_src=$4 identity=$5
  # Via bash: under run0, SELinux won't let the service execute files in a home directory.
  bash "$here/check-target" "$dev"
  # The disk you confirmed, not whatever took its device name since (a swapped card).
  [[ $(disk_identity "$dev") == "$identity" ]] || die "$dev is no longer the disk you confirmed"
  for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  wipefs -a "$dev" >/dev/null
  xzcat "$xz" | dd of="$dev" bs=4M conv=fsync status=progress
  sync
  partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" || true
  # The kernel re-reads the new partition table and the desktop probes it; lsblk can briefly
  # fail (exit 32: device not found) while that happens.
  part=
  for _ in $(seq 1 10); do
    udevadm settle
    part=$(lsblk -nrpo PATH,LABEL "$dev" 2>/dev/null | awk '$2 == "CIDATA" {print $1; exit}') || true
    [[ -n $part ]] && break
    sleep 1
  done
  [[ -n $part ]] || die "no CIDATA partition on $dev after writing"
  mnt=$(mktemp -d)
  # Cleanup must never fail the run: the final loop below has usually unmounted it already.
  trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT
  # Root-only: FAT has no permissions of its own, and these files hold the secrets. The
  # desktop auto-mounts the new partitions right after the write: release them and retry.
  mounted=false
  for i in 1 2 3; do
    udevadm settle
    for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
    if mount -o umask=077,nosuid,nodev,noexec "$part" "$mnt"; then
      mounted=true
      break
    fi
    echo "flash: mounting $part failed (attempt $i of 3); retrying" >&2
    sleep $((2 * i))
  done
  $mounted || die "could not mount $part to write the first-boot files"
  cp "$cidata_src/user-data" "$mnt/user-data"
  if [[ -e $cidata_src/network-config ]]; then cp "$cidata_src/network-config" "$mnt/"; fi
  sync
  # The desktop may have auto-mounted the new partitions; leave the card safe to pull.
  for p in $(lsblk -nrpo PATH "$dev" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  exit 0
fi

# fetch_release SOURCE IMAGE: prints the path of the verified .raw.xz for IMAGE in release
# SOURCE (latest or a tag). A tag can be re-released the same day, so the cache is checked
# against the release's signed SHA256SUMS every time and stale files are fetched again.
fetch_release() {
  local source=$1 image=$2 api rel tag name cache want f
  api=https://api.github.com/repos/$repo/releases
  if [[ $source == latest ]]; then rel=$(curl -fsSL "$api/latest"); else rel=$(curl -fsSL "$api/tags/$source"); fi
  tag=$(jq -r .tag_name <<<"$rel")
  # juniper-YYYYMMDD.raw.xz, never juniper-minimal-*
  name=$(jq -r --arg i "$image" '.assets[].name | select(test("^" + $i + "-[0-9]+\\.raw\\.xz$"))' <<<"$rel" | head -1)
  [[ -n $name ]] || die "no $image disk image in release $tag"
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/juniper/$tag
  mkdir -p "$cache"
  get() {
    echo "Downloading $1 ($tag)" >&2
    curl -fL --progress-bar -o "$cache/$1.part" "https://github.com/$repo/releases/download/$tag/$1"
    mv "$cache/$1.part" "$cache/$1"
  }
  get SHA256SUMS
  get SHA256SUMS.bundle
  cosign verify-blob --key "$pubkey" --bundle "$cache/SHA256SUMS.bundle" "$cache/SHA256SUMS" >&2
  want=$(awk -v n="$name" '{f = $2; sub(/^\.\//, "", f)} f == n {print $1}' "$cache/SHA256SUMS")
  [[ -n $want ]] || die "$name is not in the release's SHA256SUMS"
  if [[ ! -f $cache/$name ]] || [[ $(sha256sum "$cache/$name" | cut -d' ' -f1) != "$want" ]]; then
    for f in "$name" "$name.bundle"; do get "$f"; done
  elif [[ ! -f $cache/$name.bundle ]]; then
    get "$name.bundle"
  fi
  [[ $(sha256sum "$cache/$name" | cut -d' ' -f1) == "$want" ]] || die "$name doesn't match SHA256SUMS"
  echo "$cache/$name"
}

if [[ ${1:-} == --fetch-only ]]; then
  # flash.sh --fetch-only [latest|TAG] [juniper|juniper-minimal]: download and verify only.
  xz=$(fetch_release "${2:-latest}" "${3:-juniper}")
  cosign verify-blob --key "$pubkey" --bundle "$xz.bundle" "$xz"
  echo "$xz"
  exit 0
fi

dev=$(readlink -f "${1:?usage: flash.sh DEVICE CONFIG [latest|TAG|PATH.raw.xz]}")
config=${2:?usage: flash.sh DEVICE CONFIG [latest|TAG|PATH.raw.xz]}
source=${3:-latest}

"$here/check-target" "$dev"
work=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/juniper-flash.XXXXXX")
trap 'rm -rf "$work"' EXIT
image=$(python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get("image", "juniper"))' "$config")
want_pw=$(python3 -c 'import sys, yaml; c = yaml.safe_load(open(sys.argv[1])) or {}; print("yes" if c.get("image") == "juniper-desktop" or c.get("password") == "prompt" else "no")' "$config")
if [[ $want_pw == yes ]]; then
  read -rsp "Password for the Pi's user (for the lock screen and sudo): " pw1 && echo
  read -rsp "Again: " pw2 && echo
  [[ $pw1 == "$pw2" ]] || die "passwords don't match; nothing written"
  ((${#pw1} >= 8)) || die "use at least 8 characters"
  # From stdin, so the shell never splits or expands it; only the hash goes any further.
  JUNIPER_PASSWORD_HASH=$(printf '%s' "$pw1" | openssl passwd -6 -stdin)
  export JUNIPER_PASSWORD_HASH
  unset pw1 pw2
fi
"$here/render-cidata" "$config" "$work/cidata"

if [[ -f $source ]]; then
  xz=$source
else
  xz=$(fetch_release "$source" "$image")
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
print(f"Password:  {'set' if 'passwd' in u else 'none (SSH keys only)'}")
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
