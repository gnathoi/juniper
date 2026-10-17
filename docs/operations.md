# Running Juniper: updates, storage and monitoring

## Updates and fallback

A new release (signed images, disk images and release notes) is published every Monday at
02:00 UTC with that week's dependency and security updates. Pis download it daily and reboot
into it on Tuesday at 04:00 local time, within a 90-minute window; change that with
`ujust update-schedule`, or apply it now with `ujust update`.

The new image boots once through firmware tryboot and is kept only if the boot health check
passes (see [readiness checks](appliances.md#readiness-checks-for-your-workload)); otherwise,
or if the check itself fails, the Pi falls back to the previous image. A locked device that
can't reach Tailscale's control plane after an update falls back too. An image that fell back
once is retried at the next window; one that fails twice is held: the login status and
`ujust pi-status` say "update … failed its health check twice; waiting for a newer image",
and the next release proceeds as usual. To retry a held image anyway, run
`ujust update-unhold`: it prints the digests it cleared (or "nothing held") and the image is
tried again at the next window or by `ujust update`. The hold shows right away after the
second failed boot.

The kernel and Pi firmware arrive only when AlmaLinux rebuilds its base image, not with the
weekly updates; each release's notes state the kernel's build date and whether a newer one is
waiting, and `ujust pi-status` shows the running kernel's age.

How the weekly release is fed: each build applies pending AlmaLinux and EPEL package updates;
Dependabot bumps the base image digest and GitHub Actions (auto-merged when green, not major
versions); the desktop's COPR packages (`build_files/desktop.lock`) get a weekly
`bump-desktop` PR that a person reviews and merges; the Homebrew base image moves only with
`just bump-brew`.

## Storage on long-running devices

A full card is how an unattended device dies, so Juniper reserves some room and watches it:

- **Update check.** Before staging an update, the daily download checks that the filesystem
  holding the ostree repo has at least 2048 MiB free (override with `MIN_FREE_MB=<MiB>` in
  `/etc/juniper/update.conf`). If not, it prunes dangling podman images and checks again;
  if still short it skips that day's update (not a failure) and the next run retries. The
  login banner and `ujust pi-status` say so.
- **Weekly prune.** `juniper-image-prune.timer` runs `podman image prune -f` as root:
  dangling images only. It never touches volumes, containers or tagged images.
- **Journal.** Capped at 200M (`SystemMaxUse`), and it leaves the last 1G free
  (`SystemKeepFree`).
- **Warning.** The login banner and `ujust pi-status` warn when `/` has under 10% or 1 GiB
  free.

What the workload has to do itself: keep its data under `/var/lib/<app>`, apply retention in
the app (rotate or expire old data; Juniper never deletes it), and put high-volume data
(video, sensor logs, databases that grow without bound) on a separate USB disk.

## Monitoring

`ujust enable-metrics` runs Prometheus node_exporter as a quadlet on :9100, reachable over
Tailscale only as before (the access rules are unchanged; nothing new is exposed). Re-running
it on a device that already has it updates the existing quadlet and restarts the exporter,
which is how an existing device picks up the Juniper metrics below.

Every image writes `/var/lib/juniper/metrics/juniper.prom` every 5 minutes
(`juniper-metrics.timer`), and node_exporter serves it through its textfile collector. A
metric whose input is missing is left out rather than reported wrong.

| Metric | Meaning |
| --- | --- |
| `juniper_image_info{image,digest,version}` | 1 for the booted image |
| `juniper_staged_image_info{digest}` | 1 while an update is staged for the next reboot |
| `juniper_image_timestamp_seconds` | build time of the booted image |
| `juniper_healthy` | 1 if the health check passes right now (same probes as at boot, no side effects) |
| `juniper_health_last_ok_timestamp_seconds` | last boot whose health check confirmed the deployment |
| `juniper_update_held` | 1 if the staged update failed its health check twice and is held |
| `juniper_update_skipped_space` | 1 if the last update was skipped for lack of disk space |
| `juniper_tailscale_join_gave_up` | 1 if the first-boot Tailscale join gave up |
| `juniper_lan_ssh_legacy` | 1 if locked down but SSH is still open to every network |
| `juniper_locked` | 1 once locked down to Tailscale only |
| `juniper_time_synced` | 1 if the clock is NTP-synchronised |
| `juniper_encrypted` | 1 if the root filesystem is on LUKS2 |
| `juniper_encryption_requested` | 1 if encryption was requested at flash time (or the root is encrypted) |
| `juniper_encryption_key_locked`, `juniper_encryption_recovery_sealed` | only on an encrypted root: firmware key lock held; age-sealed recovery keyslot exists |
| `juniper_kernel_build_timestamp_seconds` | build time of the installed Pi kernel |

Example alert conditions:

- Node down or offline: `up{job="juniper"} == 0` (use the job name from your own scrape
  config). A device that is off, or off the tailnet, silently misses updates; this is how it
  shows up.
- Update stuck: `juniper_update_held == 1`.
- Clock wrong: `juniper_time_synced == 0` for 30 minutes.
- Unhealthy: `juniper_healthy == 0` for 30 minutes.
- Encryption requested but not active: `juniper_encryption_requested == 1 and juniper_encrypted == 0`.
- Image out of date: `time() - juniper_image_timestamp_seconds > 21 * 86400` (pick your N).

The login banner and `ujust pi-status` also warn "Clock not synchronised (NTP)" when the
clock is not synced, since a Pi has no battery-backed clock.
