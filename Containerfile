# Juniper: batteries-included headless bootc image for Raspberry Pi 4/5.
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files

FROM quay.io/almalinuxorg/almalinux-bootc-rpi:10@sha256:08b361228495c05656b1367fb41507a79ea9b7eca293f21bbc5e4801e3355337

# Published image ref without tag (e.g. ghcr.io/gnathoi/juniper) and date version.
ARG IMAGE_REF=localhost/juniper
ARG IMAGE_VERSION=dev

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,target=/var \
    /ctx/build_files/build.sh

RUN bootc container lint --fatal-warnings
