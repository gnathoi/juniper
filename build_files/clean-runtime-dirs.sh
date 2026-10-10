#!/usr/bin/env bash
# Package scriptlets leave state in /run and /tmp (cloud-init, selinux-policy, mdadm, samba,
# nvim, ...), which `bootc container lint` rejects. Remove what is on the image's own
# filesystem; never anything the build engine mounted there (e.g. /run/secrets).
set -euo pipefail

root_dev=$(stat -c %d /)
shopt -s nullglob dotglob
for p in /run/* /tmp/*; do
  if [[ $(stat -c %d "$p") == "$root_dev" ]] && ! mountpoint -q "$p" 2>/dev/null; then
    rm -rf --one-file-system "$p"
  fi
done
