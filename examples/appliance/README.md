# Building an appliance on Juniper Minimal

Juniper Minimal gives you Tailscale-first networking with firewall lockdown, Podman
quadlets with nightly auto-update, signed nightly OS updates with firmware fallback, and
`ujust`. You add your packages and services:

1. Copy this directory, edit `Containerfile` and add your `*.container` quadlets, and a
   readiness hook in `health.d/` (see `50-sensor-sample`) so an update that breaks your
   workload falls back.
2. Build for arm64 and push to your registry (CI: copy Juniper's `build.yml` matrix leg).
3. Flash a Juniper Minimal disk image, then on the device:
   `ujust switch ghcr.io/you/sensor-box:latest` (a plain reboot keeps the current image;
   `ujust switch`/`ujust update` reboot into the new one) — from then on the device follows
   your image, with the same nightly update window and tryboot fallback.

**Signatures.** Juniper's policy only covers Juniper's own images, so a device switched
to your image accepts it unsigned. To enforce your own cosign key, add to your
Containerfile:

    COPY cosign.pub /usr/share/pki/containers/sensor-box.pub
    RUN jq --arg ref ghcr.io/you/sensor-box \
          '.transports.docker[$ref] = [{"type": "sigstoreSigned",
             "keyPath": "/usr/share/pki/containers/sensor-box.pub",
             "signedIdentity": {"type": "matchRepository"}}]' \
          /etc/containers/policy.json >/tmp/policy.json \
        && mv /tmp/policy.json /etc/containers/policy.json \
        && printf 'docker:\n  ghcr.io/you/sensor-box:\n    use-sigstore-attachments: true\n' \
          >/etc/containers/registries.d/sensor-box.yaml

Adding that policy entry is what enforces your signature on every update; switch with
`ujust switch ghcr.io/you/sensor-box:latest` once the signed image is pushed.
