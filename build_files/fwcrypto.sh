#!/usr/bin/env bash
# Builds rpi-fw-crypto (raspberrypi/utils rpifwcrypto/, not packaged for EL10) from the commit
# pinned in fwcrypto.lock. Runs in the Containerfile's fwcrypto stage; installs into /out,
# which build.sh copies into /usr.
set -euo pipefail

commit=$(sed -n 's/^commit=//p' /fwcrypto.lock)
sha256=$(sed -n 's/^sha256=//p' /fwcrypto.lock)
[[ $commit =~ ^[0-9a-f]{40}$ && $sha256 =~ ^[0-9a-f]{64}$ ]] || {
  echo "fwcrypto.lock: bad commit or sha256" >&2
  exit 1
}

dnf -y install gcc cmake gnutls-devel

curl -fsSLo /src.tgz "https://codeload.github.com/raspberrypi/utils/tar.gz/$commit"
echo "$sha256  /src.tgz" | sha256sum -c
cd /
tar xzf /src.tgz
cmake -S "utils-$commit/rpifwcrypto" -B /b -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib64 -DCMAKE_BUILD_TYPE=Release
cmake --build /b
DESTDIR=/out cmake --install /b
install -Dm0644 "utils-$commit/LICENCE" /out/usr/share/licenses/rpi-fw-crypto/LICENCE
