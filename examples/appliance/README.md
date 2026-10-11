# Building an appliance on Juniper Minimal

Juniper Minimal gives you Tailscale-first networking with firewall lockdown, Podman
quadlets with nightly auto-update, signed nightly OS updates with firmware fallback, and
`ujust`. You add your packages and services:

1. Copy this directory, edit `Containerfile` and add your `*.container` quadlets, and a
   readiness hook in `health.d/` (see [`50-sensor-sample`](health.d/50-sensor-sample)) so an
   update that breaks your workload falls back.
2. Build for arm64, push to your registry and sign it with cosign (CI: copy Juniper's
   `build.yml` matrix leg and its signing step).
3. Flash a Juniper Minimal disk image, then on the device trust your key and switch:

       ujust trust-images ghcr.io/you ~/cosign.pub
       ujust switch ghcr.io/you/sensor-box:latest

   A plain reboot keeps the current image; `ujust switch`/`ujust update` reboot into the new
   one. From then on the device follows your image, with the same nightly update window and
   tryboot fallback.

## Signatures

Juniper's policy covers only Juniper's own images, so without step 3's `trust-images` a device
switched to your image accepts it unsigned. `ujust trust-images NAMESPACE PUBKEY_FILE` makes
every image under that namespace need your cosign signature: `bootc switch` and every OS update,
and podman pulls of workloads, `podman auto-update` included. Run it before the first switch
and that switch is verified too. `ujust trust-images` lists what is trusted;
`ujust untrust-images ghcr.io/you` removes it.

Sign the way Juniper's CI does (cosign 2.x, `cosign sign --key ... IMAGE@DIGEST`). Podman reads
the classic `.sig` signatures; with cosign 3 add `--new-bundle-format=false
--use-signing-config=false`.

To ship the trust in the image as well (for devices you switch without running it first), add
to your Containerfile:

    COPY cosign.pub /tmp/cosign.pub
    RUN /usr/libexec/juniper/trust-images ghcr.io/you /tmp/cosign.pub && rm /tmp/cosign.pub

A device whose `/etc/containers/policy.json` was edited locally (by `trust-images` too) keeps
its own copy across updates, so a policy baked into a later image doesn't reach it.

## Workload images: signed or pinned

[`sensor.container`](sensor.container) pins its image by digest, so the device runs exactly
that image until you ship a new digest with your next OS image. Pick one per workload:

- **A fleet: sign and auto-update.** Build and sign the workload image under your namespace,
  trust it with `trust-images`, and use `Image=ghcr.io/you/sensor:latest` with
  `AutoUpdate=registry`. `podman auto-update` then only takes a new image with your signature.
- **A one-off device, or someone else's image: pin by digest.** `Image=...@sha256:...` never
  changes under you; bumping it means editing the quadlet (the file shows how to get the
  digest). Drop `AutoUpdate=` for a pinned image.

Avoid a mutable tag from a registry you don't control with `AutoUpdate=registry`: whoever
controls the tag controls what runs.

## Readiness

The image's health hook ([`health.d/50-sensor-sample`](health.d/50-sensor-sample)) passes only
once the sensor has logged a reading in this boot. After an OS update under tryboot, a failing
hook falls back to the previous image. See "Readiness checks for your workload" in the
[main README](../../README.md#readiness-checks-for-your-workload).

## Data and rollback

Firmware fallback rolls back the OS image, not your app's data under `/var` or in podman
volumes. If a new app version migrates its data and then the update falls back (or you pin the
old version again), the old version finds data it may not read. So:

- Version your data format, and have each release read the previous format: migrate forward
  in a way the previous release still tolerates, or keep the old copy until the new one is
  known good.
- Keep a copy before an app update. For a workload with a `sensor-data` volume, this in the
  quadlet exports it before every start, so before an updated image first touches it:

      [Service]
      ExecStartPre=-/bin/sh -c 'podman volume exists sensor-data && mkdir -p /var/lib/sensor-backup && podman volume export sensor-data -o /var/lib/sensor-backup/sensor-data.tar'

  To go back: stop the service, pin the previous image, empty the volume (`podman volume rm
  sensor-data && podman volume create sensor-data`), then
  `podman volume import sensor-data /var/lib/sensor-backup/sensor-data.tar`.

A real snapshot-and-restore mechanism tied to OS fallback is still open in #55.
