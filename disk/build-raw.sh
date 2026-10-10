#!/usr/bin/env bash
# Builds a flashable GPT .raw for Pi 4/5 from a pushed Juniper image (run as root):
#   build-raw.sh ghcr.io/gnathoi/juniper:latest juniper.raw [sha256:VERIFIED-DIGEST]
# With a digest, exactly that image is pulled and tagged as REF:TAG locally, so a tag moved
# after the signature check can't slip in, while the Pi still tracks REF:TAG for updates.
# bootc-image-builder makes the disk; then the image's rpi-bootc-bootloader copies Pi
# firmware, kernel and config into the CIDATA (FAT) partition, which bib can't do.
set -euo pipefail

ref=${1:?usage: build-raw.sh IMAGE_REF:TAG OUTPUT.raw [DIGEST]}
out=${2:?usage: build-raw.sh IMAGE_REF:TAG OUTPUT.raw [DIGEST]}
digest=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
cidata_src=$here/../system_files/usr/share/juniper/cidata
work=$(mktemp -d)
loop=

cleanup() {
  umount "$work/mnt" 2>/dev/null || true
  [[ -n $loop ]] && losetup -d "$loop"
  rm -rf "$work"
}
trap cleanup EXIT

if [[ -n $digest ]]; then
  podman pull "${ref%:*}@$digest"
  podman tag "${ref%:*}@$digest" "$ref"
else
  podman pull "$ref"
fi
cp "$here/bib-config.toml" "$work/config.toml"
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$work":/output -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b \
  --type raw --rootfs xfs --no-default-kernel-args --config /output/config.toml --local "$ref"
mv "$work/image/disk.raw" "$out"

loop=$(losetup -f --show -P "$out")
fatlabel "${loop}p1" CIDATA
mkdir -p "$work/mnt"
mount "${loop}p1" "$work/mnt"
cp "$cidata_src/user-data" "$cidata_src/meta-data" "$cidata_src/README.txt" "$work/mnt/"
# Inside the image: /tmp is the FAT partition; rpi-bootc-bootloader finds p1 itself from
# the /sysroot mount and writes config.txt + per-deployment kernel/dtbs.
podman run --rm --privileged -v /dev:/dev -v "$work/mnt":/tmp --entrypoint /bin/bash "$ref" -c \
  "mount ${loop}p3 /sysroot && mount ${loop}p2 /boot \
   && cp -a --no-preserve=links /usr/lib/ostree-boot/* /tmp/ \
   && rpi-bootc-bootloader sync"
echo "Wrote $out"
