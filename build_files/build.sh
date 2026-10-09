#!/usr/bin/env bash
# Builds the Juniper layer. Runs once inside the Containerfile with /ctx mounted.
set -xeuo pipefail

: "${IMAGE_REF:?}" "${IMAGE_VERSION:?}"

# --- files ---
cp -a /ctx/system_files/. /

# --- identity ---
sed -i '/^\(PRETTY_NAME\|VARIANT\|VARIANT_ID\|IMAGE_ID\|IMAGE_VERSION\)=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<EOT
PRETTY_NAME="Juniper ${IMAGE_VERSION} (AlmaLinux 10 bootc)"
VARIANT="Juniper"
VARIANT_ID=juniper
IMAGE_ID=juniper
IMAGE_VERSION=${IMAGE_VERSION}
EOT
