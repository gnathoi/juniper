# Building appliances on Juniper

See [examples/appliance](../examples/appliance): `FROM ghcr.io/gnathoi/juniper-minimal`, add
packages and quadlets, push, `bootc switch` the device to it. To require your own signature
on your images, see [your own images](security.md#your-own-images).

## Readiness checks for your workload

After an update, the boot health check keeps the new image only if the device is reachable
(a default route; once locked, Tailscale connected to its control plane and SSH over it) and
every health hook passes; under tryboot, anything else falls back to the previous image. Add
your own check, such as "a sample was stored in the last 10 minutes", as an executable that
exits 0 when ready:

- in your image: `/usr/lib/juniper/health.d/`
- on a device running plain quadlets: `/etc/juniper/health.d/`; only root-owned files that
  aren't group- or world-writable run, anything else is skipped and logged

Hooks run in name order at every boot, 15 seconds at most each, retried for about 7 minutes.
See [the example](../examples/appliance/health.d/50-sensor-sample).
