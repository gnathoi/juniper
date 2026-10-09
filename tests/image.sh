#!/usr/bin/env bash
# Smoke test executed inside the built image (no systemd running):
#   just test-image
set -euo pipefail

grep -qx 'IMAGE_ID=juniper' /usr/lib/os-release
grep -q '^PRETTY_NAME="Juniper' /usr/lib/os-release

echo "image smoke test: OK"
