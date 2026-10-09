# Juniper: headless bootc images for Raspberry Pi 4/5.
#   --target minimal  -> juniper-minimal (appliance base: build FROM this)
#   --target juniper  -> juniper (minimal + developer tools)
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files
COPY system_files_dev /system_files_dev

# Homebrew tarball + setup/update units (Bluefin's), pinned by digest. CI checks ublue's
# cosign signature (`just verify-brew`); Dependabot ignores it; bump with `just bump-brew`.
FROM ghcr.io/ublue-os/brew@sha256:2aaf87e3757466bc28d056505a651c7ca5c56fd28f6ff709b34f3f5dbc860e89 AS brew

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b361228495c05656b1367fb41507a79ea9b7eca293f21bbc5e4801e3355337 AS minimal

# Published image ref without tag (e.g. ghcr.io/gnathoi/juniper), image name and date version.
ARG IMAGE_REF=localhost/juniper-minimal
ARG IMAGE_NAME=juniper-minimal
ARG IMAGE_VERSION=dev

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var \
    /ctx/build_files/build.sh

RUN bootc container lint --fatal-warnings

FROM minimal AS juniper

COPY --from=brew /system_files /

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=brew,source=/system_files,target=/brew \
    --mount=type=tmpfs,target=/var \
    /ctx/build_files/dev.sh

RUN bootc container lint --fatal-warnings
