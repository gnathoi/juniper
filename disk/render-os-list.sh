#!/usr/bin/env bash
# Prints an rpi-imager OS list (one entry) for one image of a release.
#   render-os-list.sh IMAGE RAW RAW_XZ DOWNLOAD_URL VERSION
# IMAGE is juniper or juniper-minimal. CI merges the per-image lists into os-list.json.
set -euo pipefail

image=$1 raw=$2 xz=$3 url=$4 version=$5
case $image in
  juniper)
    name="Juniper"
    desc="Headless AlmaLinux bootc dev box: Tailscale, Podman, Distrobox, Homebrew"
    ;;
  juniper-minimal)
    name="Juniper Minimal"
    desc="Headless AlmaLinux bootc appliance base: Tailscale, Podman quadlets, auto-updates"
    ;;
  *)
    echo "unknown image: $image" >&2
    exit 1
    ;;
esac
jq -n \
  --arg name "$name" --arg desc "$desc" \
  --arg url "$url" --arg version "$version" \
  --arg sha "$(sha256sum "$raw" | cut -d' ' -f1)" \
  --argjson size "$(stat -c %s "$raw")" \
  --argjson dl "$(stat -c %s "$xz")" \
  --arg date "$(date -u +%F)" \
  --arg icon "${JUNIPER_ICON_URL:-https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-owner/juniper}/main/disk/icon.png}" \
  '{os_list: [{
     name: "\($name) \($version)",
     description: $desc,
     icon: $icon, url: $url,
     extract_size: $size, extract_sha256: $sha, image_download_size: $dl,
     release_date: $date,
     devices: ["pi5-64bit", "pi4-64bit"],
     init_format: "cloudinit",
     capabilities: ["tailscale", "passwordless_sudo"]
   }]}'
