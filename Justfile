image := "juniper"
image_ref := "localhost/" + image
version := `date -u +%Y%m%d`
target := if image == "juniper-minimal" { "minimal" } else { "juniper" }

# Lint and unit-test (same checks as CI's lint job)
check:
    pre-commit run --all-files

# Build {{ image }} for arm64 as {{ image_ref }}:build (needs arm64 or qemu-user-static)
build:
    #!/usr/bin/bash
    set -euo pipefail
    # Pre-pull base images with retries: registries drop connections transiently.
    stages=$(grep -oiP '^FROM \S+ AS \K\S+' Containerfile || true)
    for img in $(grep -oP '^FROM \K\S+' Containerfile); do
      [[ $img == scratch ]] && continue
      grep -qixF "$img" <<<"$stages" && continue
      for i in 1 2 3; do
        podman pull --platform linux/arm64 "$img" && continue 2
        sleep $((10 * i))
      done
      echo "failed to pull $img" >&2
      exit 1
    done
    podman build --platform linux/arm64 --target {{ target }} \
      --build-arg IMAGE_REF={{ image_ref }} --build-arg IMAGE_NAME={{ image }} \
      --build-arg IMAGE_VERSION={{ version }} \
      -t {{ image_ref }}:build .

# Verify the cosign signature of the pinned ublue-os/brew image (CI runs this first)
verify-brew:
    cosign verify --key ci/ublue-brew.pub \
      "$(grep -oP '^FROM \Kghcr\.io/ublue-os/brew@sha256:[0-9a-f]{64}' Containerfile)" >/dev/null

# Move the Homebrew pin to ublue-os/brew's current :latest (rare: brew self-updates on device)
bump-brew:
    #!/usr/bin/bash
    set -euo pipefail
    digest=sha256:$(skopeo inspect --raw docker://ghcr.io/ublue-os/brew:latest | sha256sum | cut -d' ' -f1)
    sed -i -E "s|(ghcr\.io/ublue-os/brew@)sha256:[0-9a-f]{64}|\1$digest|" Containerfile
    just verify-brew
    git diff --stat Containerfile

# Rechunk :build into :latest and :{{ version }} (rootful podman storage)
rechunk:
    #!/usr/bin/bash
    set -euo pipefail
    tool=quay.io/centos-bootc/centos-bootc:stream10
    # Pull with retries first: a registry 502 mid-blob failed a main build (run 37999745485).
    for i in 1 2 3; do
      podman pull "$tool" && break
      [[ $i == 3 ]] && { echo "failed to pull $tool" >&2; exit 1; }
      sleep $((10 * i))
    done
    podman run --rm --privileged --security-opt label=disable \
      -v /var/lib/containers:/var/lib/containers \
      "$tool" \
      /usr/libexec/bootc-base-imagectl rechunk {{ image_ref }}:build {{ image_ref }}:latest
    podman tag {{ image_ref }}:latest {{ image_ref }}:{{ version }}

# Run tests/image.sh inside an image
test-image image=(image_ref + ":build"):
    podman run --rm --pull=never -v ./tests:/tests:ro,z {{ image }} /tests/image.sh

# Build a flashable GPT .raw from a pushed image ref (root: loop devices)
build-raw ref out="juniper.raw":
    disk/build-raw.sh {{ ref }} {{ out }}

# Assert the rechunked image has its own juniper (and, for juniper, homebrew) layers; print sizes
check-layers:
    #!/usr/bin/bash
    set -euo pipefail
    hist=$(podman history --no-trunc --format '{{{{.Size}}\t{{{{.CreatedBy}}' {{ image_ref }}:latest)
    echo "$hist"
    want=(juniper)
    [[ {{ image }} == juniper ]] && want+=(homebrew)
    for w in "${want[@]}"; do
      grep -qP "^(?!0B)[0-9.]+[kMG]?B\\s+$w\\s*$" <<<"$hist" || { echo "no $w layer" >&2; exit 1; }
    done
