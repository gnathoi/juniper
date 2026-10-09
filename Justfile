image_ref := "localhost/juniper"
version := `date -u +%Y%m%d`

# Lint and unit-test (same checks as CI's lint job)
check:
    pre-commit run --all-files

# Build the arm64 image as {{ image_ref }}:build (needs arm64 or qemu-user-static)
build:
    podman build --platform linux/arm64 \
      --build-arg IMAGE_REF={{ image_ref }} --build-arg IMAGE_VERSION={{ version }} \
      -t {{ image_ref }}:build .

# Rechunk :build into :latest and :{{ version }} (rootful podman storage)
rechunk:
    podman run --rm --privileged --security-opt label=disable \
      -v /var/lib/containers:/var/lib/containers \
      quay.io/centos-bootc/centos-bootc:stream10 \
      /usr/libexec/bootc-base-imagectl rechunk {{ image_ref }}:build {{ image_ref }}:latest
    podman tag {{ image_ref }}:latest {{ image_ref }}:{{ version }}

# Run tests/image.sh inside an image
test-image image=(image_ref + ":build"):
    podman run --rm --platform linux/arm64 -v ./tests:/tests:ro,z {{ image }} /tests/image.sh

# Build a flashable GPT .raw from a pushed image ref (root: loop devices)
build-raw ref out="juniper.raw":
    disk/build-raw.sh {{ ref }} {{ out }}
