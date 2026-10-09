# Create and enter a mutable Fedora dev container (distrobox) named devbox
devbox:
    distrobox create --yes --name devbox --image registry.fedoraproject.org/fedora-toolbox:latest
    distrobox enter devbox

# Install podlet (converts compose files / podman commands to quadlets) into ~/.local/bin
install-podlet:
    #!/usr/bin/bash
    set -euo pipefail
    asset=podlet-aarch64-unknown-linux-gnu
    url=https://github.com/containers/podlet/releases/latest/download/$asset.tar.xz
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSLo "$tmp/p.tar.xz" "$url"
    curl -fsSLo "$tmp/p.sha256" "$url.sha256"
    [[ $(sha256sum "$tmp/p.tar.xz" | cut -d' ' -f1) == $(cut -d' ' -f1 "$tmp/p.sha256") ]] || { echo "checksum mismatch" >&2; exit 1; }
    mkdir -p ~/.local/bin
    tar -xJf "$tmp/p.tar.xz" -C ~/.local/bin --strip-components=1 "$asset/podlet"
    ~/.local/bin/podlet --version
