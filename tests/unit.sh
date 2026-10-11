#!/usr/bin/env bash
# Unit tests for system_files/usr/libexec/juniper/*. Real commands (bootc, tailscale,
# firewall-cmd, systemctl, ...) are replaced by stubs on PATH that append their argv to
# $CALLS. Run: tests/unit.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC2034 # used by the tests added in later tasks
LIBEXEC=$ROOT/system_files/usr/libexec/juniper
LIBEXEC_DESKTOP=$ROOT/system_files_desktop/usr/libexec/juniper
ORIG_PATH=$PATH
ORIG_TMPDIR=${TMPDIR-}
fails=0

setup() {
  # a test may export TMPDIR into its own (now deleted) $T
  if [[ -n $ORIG_TMPDIR ]]; then export TMPDIR=$ORIG_TMPDIR; else unset TMPDIR; fi
  # ...and the overrides fwkey/cryptroot tests export; a later test must never inherit them
  unset JUNIPER_SYSFS JUNIPER_VCIO JUNIPER_CMDLINE JUNIPER_BLOCK_SYSFS JUNIPER_CIDATA_MNT \
    JUNIPER_RUN_DIR JUNIPER_CPUINFO JUNIPER_TRYBOOT_FLAG JUNIPER_ROOT_WAIT \
    JUNIPER_UNLOCK_FAIL_DELAY JUNIPER_FWKEY JUNIPER_CONSOLE JUNIPER_CRYPTSETUP_LOCKDIR FAKE_PASS \
    JUNIPER_DT JUNIPER_FWKEY_WEDGED JUNIPER_FWKEY_DEADLINE
  T=$(mktemp -d)
  export CALLS=$T/calls JUNIPER_STATE_DIR=$T/state
  mkdir -p "$T/bin" "$JUNIPER_STATE_DIR"
  : >"$CALLS"
  for cmd in bootc tailscale firewall-cmd systemctl ip bootloader \
    mount umount blkid chown timedatectl; do
    stub "$cmd" ''
  done
  # shellcheck disable=SC2016 # expands inside the stub
  stub shred 'for a; do [[ $a == -* || $a == "$T"/* ]] || { echo "shred outside test dir: $a" >&2; exit 1; }; done
if [[ $1 == -u ]]; then rm -f "$2"; fi'
  export JUNIPER_BOOTLOADER=bootloader
  export PATH=$T/bin:$ORIG_PATH
}

# stub NAME BODY: fake command that logs "NAME args..." to $CALLS, then runs BODY.
stub() {
  # shellcheck disable=SC2016 # $* and $CALLS expand when the stub runs
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
called() { grep -qF -- "$1" "$CALLS"; }
not_called() { ! called "$1"; }
not_grep_dir() { ! grep -rq -- "$1" "$2"; }
check() {
  if "${@:2}"; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    sed 's/^/     calls: /' "$CALLS"
    fails=$((fails + 1))
  fi
}

test_harness_works() {
  stub bootc 'echo hi'
  check "harness: stub output" test "$(bootc status)" = hi
  check "harness: call logged" called "bootc status"
}

firstboot_env() {
  export JUNIPER_SHARE=$T/share JUNIPER_CIDATA_DIR=$T/cidata \
    JUNIPER_CLOUD_DISABLED=$T/cloud-init.disabled JUNIPER_CLOUD_DIR=$T/cloud
  mkdir -p "$JUNIPER_SHARE/cidata" "$JUNIPER_CIDATA_DIR"
  echo "#cloud-config template" >"$JUNIPER_SHARE/cidata/user-data"
  echo "secret wifi" >"$JUNIPER_CIDATA_DIR/network-config"
  echo "secret tskey" >"$JUNIPER_CIDATA_DIR/user-data"
}

test_firstboot_scrubs_cidata() {
  firstboot_env
  "$LIBEXEC/firstboot"
  check "firstboot: network-config removed" test ! -e "$JUNIPER_CIDATA_DIR/network-config"
  check "firstboot: user-data replaced by template" grep -q template "$JUNIPER_CIDATA_DIR/user-data"
  check "firstboot: no secrets left on CIDATA" not_grep_dir secret "$JUNIPER_CIDATA_DIR"
  check "firstboot: cloud-init disabled" test -e "$JUNIPER_CLOUD_DISABLED"
  check "firstboot: marked done" test -e "$JUNIPER_STATE_DIR/firstboot.done"
}

test_firstboot_env_never_touches_host_cloud_dir() {
  firstboot_env
  check "firstboot env: cloud dir is under the test dir" test "${JUNIPER_CLOUD_DIR#"$T"/}" != "$JUNIPER_CLOUD_DIR"
}

# Disabling cloud-init stops cloud-init.target, which is what starts firstboot: it must come
# last, or a failure/power cut in between leaves cached secrets with no automatic retry.
test_firstboot_keeps_cloud_init_until_cache_purged() {
  firstboot_env
  mkdir -p "$JUNIPER_CLOUD_DIR/instances/iid-1"
  echo "secret tskey" >"$JUNIPER_CLOUD_DIR/instances/iid-1/user-data.txt"
  # shellcheck disable=SC2016 # expands inside the stub
  stub shred 'if [[ $2 == */instances/* ]]; then exit 1; fi; if [[ $1 == -u ]]; then rm -f "$2"; fi'
  "$LIBEXEC/firstboot" 2>/dev/null || true
  check "firstboot: cloud-init still enabled after a failed purge" test ! -e "$JUNIPER_CLOUD_DISABLED"
  check "firstboot: not marked done after a failed purge" test ! -e "$JUNIPER_STATE_DIR/firstboot.done"
}

test_firstboot_rerun_after_power_loss() {
  firstboot_env
  "$LIBEXEC/firstboot"
  "$LIBEXEC/firstboot"
  check "firstboot rerun: still scrubbed" not_grep_dir secret "$JUNIPER_CIDATA_DIR"
  check "firstboot rerun: marked done" test -e "$JUNIPER_STATE_DIR/firstboot.done"
}

test_firstboot_mounts_cidata_of_boot_disk() {
  firstboot_env
  unset JUNIPER_CIDATA_DIR
  stub cidata-device 'echo /dev/mmcblk0p1'
  export JUNIPER_CIDATA_DEVICE=cidata-device
  # mount is stubbed, so the trap's rmdir fails on the non-empty dir; keep it under $T
  TMPDIR=$T "$LIBEXEC/firstboot" || true
  check "firstboot: finds CIDATA on the boot disk" called "cidata-device"
  check "firstboot: no global label lookup" not_called "blkid -L CIDATA"
  check "firstboot: mounts it" called "mount /dev/mmcblk0p1"
  check "firstboot: unmounts it" called "umount"
}

test_firstboot_purges_cloud_init_cache() {
  firstboot_env
  export JUNIPER_CLOUD_DIR=$T/cloud
  local i=$JUNIPER_CLOUD_DIR/instances/iid-1
  mkdir -p "$i"
  echo "secret tskey" >"$i/user-data.txt"
  echo "secret tskey" >"$i/user-data.txt.i"
  echo "secret tskey" >"$i/cloud-config.txt"
  echo "secret tskey" >"$i/obj.pkl"
  echo keep >"$i/datasource"
  "$LIBEXEC/firstboot"
  check "firstboot: cached user-data removed" not_grep_dir secret "$JUNIPER_CLOUD_DIR"
  check "firstboot: cache files gone" test ! -e "$i/user-data.txt" -a ! -e "$i/user-data.txt.i" \
    -a ! -e "$i/cloud-config.txt" -a ! -e "$i/obj.pkl"
  check "firstboot: other instance files kept" test -e "$i/datasource"
}

test_lockdown_waits_for_join() {
  stub tailscale "echo '{\"BackendState\":\"NeedsLogin\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: firewall untouched before join" not_called firewall-cmd
  check "lockdown: not marked" test ! -e "$JUNIPER_STATE_DIR/locked"
}

test_lockdown_never_fires_without_tailscale() {
  stub tailscale 'exit 1'
  "$LIBEXEC/lockdown"
  check "lockdown: tailscale broken -> LAN stays open" not_called firewall-cmd
}

test_lockdown_locks_once_running() {
  stub tailscale "echo '{\"BackendState\":\"Running\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: tailscale0 trusted" called "firewall-cmd --permanent --zone=trusted --add-interface=tailscale0"
  check "lockdown: direct peers allowed" called "firewall-cmd --permanent --zone=drop --add-port=41641/udp"
  check "lockdown: default zone drop" called "firewall-cmd --set-default-zone=drop"
  check "lockdown: reloaded" called "firewall-cmd --reload"
  check "lockdown: marked" test -e "$JUNIPER_STATE_DIR/locked"
  check "lockdown: timer retired" called "systemctl disable --now juniper-lockdown.timer"
}

test_lockdown_only_once() {
  touch "$JUNIPER_STATE_DIR/locked"
  stub tailscale "echo '{\"BackendState\":\"Running\"}'"
  "$LIBEXEC/lockdown"
  check "lockdown: idempotent" not_called firewall-cmd
}

test_apply_update_without_staged() {
  stub bootc 'echo "{\"status\":{\"staged\":null}}"'
  "$LIBEXEC/apply-update"
  check "apply-update: no staged -> no reboot" not_called "bootloader"
}

test_apply_update_with_staged() {
  stub bootc 'echo "{\"status\":{\"staged\":{\"image\":{}}}}"'
  "$LIBEXEC/apply-update"
  check "apply-update: staged -> tryreboot" called "bootloader tryreboot"
}

test_bootloader_wrapper_sets_mntdev() {
  stub cidata-device 'echo /dev/mmcblk0p1'
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-bootc-bootloader 'echo "MNTDEV=$MNTDEV" >>"$CALLS"'
  JUNIPER_CIDATA_DEVICE=$T/bin/cidata-device "$LIBEXEC/bootloader" sync
  check "bootloader: passes args" called "rpi-bootc-bootloader sync"
  check "bootloader: MNTDEV from cidata-device" called "MNTDEV=/dev/mmcblk0p1"
}

test_bootloader_wrapper_falls_back_without_cidata() {
  stub cidata-device 'exit 1'
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-bootc-bootloader 'echo "MNTDEV=${MNTDEV-unset}" >>"$CALLS"'
  MNTDEV=/dev/stale JUNIPER_CIDATA_DEVICE=$T/bin/cidata-device "$LIBEXEC/bootloader" sync 2>/dev/null
  check "bootloader: cidata failure still runs the tool" called "rpi-bootc-bootloader sync"
  check "bootloader: fallback leaves MNTDEV unset" called "MNTDEV=unset"
  check "bootloader: fallback warns" stderr_has "own detection" env JUNIPER_CIDATA_DEVICE="$T/bin/cidata-device" "$LIBEXEC/bootloader" sync
}

test_bootloader_wrapper_falls_back_on_empty_output() {
  stub cidata-device 'true'
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-bootc-bootloader 'echo "MNTDEV=${MNTDEV-unset}" >>"$CALLS"'
  JUNIPER_CIDATA_DEVICE=$T/bin/cidata-device "$LIBEXEC/bootloader" sync 2>/dev/null
  check "bootloader: empty output runs the tool" called "rpi-bootc-bootloader sync"
  check "bootloader: empty output leaves MNTDEV unset" called "MNTDEV=unset"
}

test_finalize_dropin_uses_wrapper() {
  local d=$ROOT/system_files/usr/lib/systemd/system/ostree-finalize-staged.service.d/zz-juniper.conf
  check "finalize drop-in: resets ExecStop" grep -qx 'ExecStop=' "$d"
  check "finalize drop-in: wrapper" grep -qx 'ExecStop=/usr/libexec/juniper/bootloader finalize-staged' "$d"
}

sched() { "$LIBEXEC/update-schedule" "$@"; }

test_update_schedule_day_and_time() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  stub timedatectl 'echo Europe/London'
  out=$(sched wed 03:30)
  check "schedule: weekly drop-in" grep -qx 'OnCalendar=Wed \*-\*-\* 03:30:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: resets OnCalendar first" grep -qx 'OnCalendar=' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: timer re-enabled" called "systemctl enable --now juniper-reboot.timer"
  check "schedule: daemon-reload" called "systemctl daemon-reload"
  check "schedule: names day, time, timezone" grep -q 'Wed.*03:30.*Europe/London' <<<"$out"
}

# A deferral recorded before `off` must not count after a later `on`: the hourly retry would
# see it as past the 7-day cap and reboot an in-use desktop.
test_update_schedule_change_clears_deferral() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  for args in off "tue 04:00" "05:00"; do
    echo 1999000000 >"$JUNIPER_STATE_DIR/reboot-deferred-since"
    echo 1999000000 >"$JUNIPER_STATE_DIR/reboot-notified"
    # shellcheck disable=SC2086 # split into DAY and TIME on purpose
    sched $args >/dev/null
    check "schedule '$args': deferral marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
    check "schedule '$args': notice marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-notified"
  done
  check "schedule: no state dir is fine" env JUNIPER_STATE_DIR="$T/none" "$LIBEXEC/update-schedule" off
}

test_update_schedule_daily() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  sched daily 03:30
  check "schedule: daily drop-in" grep -qx 'OnCalendar=\*-\*-\* 03:30:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_day_case_insensitive() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  sched SaT 01:00
  check "schedule: case-insensitive day" grep -qx 'OnCalendar=Sat \*-\*-\* 01:00:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_time_only_keeps_day() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  sched fri 03:30
  sched 05:00
  check "schedule: time-only keeps weekday" grep -qx 'OnCalendar=Fri \*-\*-\* 05:00:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
  sched daily 03:30
  sched 06:00
  check "schedule: time-only keeps daily" grep -qx 'OnCalendar=\*-\*-\* 06:00:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_time_only_defaults_tue() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  sched 05:00
  check "schedule: time-only, no drop-in -> Tue" grep -qx 'OnCalendar=Tue \*-\*-\* 05:00:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_rejects_bad_input() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  for bad in 24:00 3:30 03:3 '03:30;reboot' now 'funday 04:00' 'tue 4:00' tue 'tue 04:00 extra'; do
    # shellcheck disable=SC2016,SC2086 # $0/$@ expand in the inner bash; $bad splits into args on purpose
    check "schedule: rejects '$bad'" bash -c '"$0" "$@" 2>/dev/null; [[ $? == 2 ]]' "$LIBEXEC/update-schedule" $bad
  done
  check "schedule: nothing written" test ! -e "$JUNIPER_DROPIN_DIR/schedule.conf"
}

test_update_schedule_off() {
  "$LIBEXEC/update-schedule" off
  check "schedule off: timer disabled" called "systemctl disable --now juniper-reboot.timer"
}

test_dependabot_update_type() {
  local c=$ROOT/.github/scripts/dependabot-update-type.sh
  check "dependabot: major" test "$("$c" 'Bump actions/checkout from 4 to 7')" = major
  check "dependabot: minor" test "$("$c" 'Bump foo/bar from 4.1.0 to 4.2.1')" = minor-or-patch
  check "dependabot: v3 -> v3.1" test "$("$c" 'Bump foo/bar from v3 to v3.1')" = minor-or-patch
  # shellcheck disable=SC2016 # literal backticks
  check "dependabot: digest" test "$("$c" 'Bump almalinux/almalinux-bootc from `08b3612` to `9a1c2d3`')" = other
  check "dependabot: unparseable" test "$("$c" 'Update stuff')" = other
}

changelog_env() {
  C=$ROOT/.github/scripts/changelog.sh
  printf '%s\n' '# Changelog' '' '## Unreleased' '' '### Added' '' '- Thing A' '  wrapped.' '' \
    '### Fixed' '' '- Bug B' '' '## build-20261009 (2026-10-09)' '' '- First.' >"$T/built.md"
  # main gained an entry after the built commit
  sed 's/^  wrapped\.$/&\n- Thing C/' "$T/built.md" >"$T/main.md"
  "$C" unreleased "$T/built.md" >"$T/notes"
}

test_changelog_stamp() {
  changelog_env
  "$C" stamp "$T/main.md" build-20261016 2026-10-16 "$T/notes"
  printf '%s\n' '# Changelog' '' '## Unreleased' '' '### Added' '' '- Thing C' '' \
    '## build-20261016 (2026-10-16)' '' '### Added' '' '- Thing A' '  wrapped.' '' '### Fixed' '' \
    '- Bug B' '' '## build-20261009 (2026-10-09)' '' '- First.' >"$T/want.md"
  check "changelog: stamp moves built entries, keeps later ones" diff "$T/want.md" "$T/main.md"
  check "changelog: section = released notes" diff "$T/notes" <("$C" section "$T/main.md" build-20261016)
  cp "$T/main.md" "$T/once.md"
  "$C" stamp "$T/main.md" build-20261016 2026-10-16 "$T/notes"
  check "changelog: rerun of the same commit is a no-op" diff "$T/once.md" "$T/main.md"
}

test_changelog_same_day_release() {
  changelog_env
  "$C" stamp "$T/main.md" build-20261016 2026-10-16 "$T/notes"
  "$C" unreleased "$T/main.md" >"$T/notes2"
  "$C" stamp "$T/main.md" build-20261016 2026-10-16 "$T/notes2"
  check "changelog: one section per tag" test "$(grep -c '^## build-20261016' "$T/main.md")" = 1
  check "changelog: second release added to it" grep -qx -- '- Thing C' <("$C" section "$T/main.md" build-20261016)
  check "changelog: Unreleased emptied" test -z "$("$C" unreleased "$T/main.md")"
}

test_changelog_empty_unreleased() {
  printf '%s\n' '## Unreleased' '' '## build-20261009 (2026-10-09)' '' '- First.' >"$T/c.md"
  cp "$T/c.md" "$T/orig.md"
  "$ROOT/.github/scripts/changelog.sh" unreleased "$T/c.md" >"$T/notes"
  check "changelog: nothing unreleased" test ! -s "$T/notes"
  "$ROOT/.github/scripts/changelog.sh" stamp "$T/c.md" build-20261016 2026-10-16 "$T/notes"
  check "changelog: empty stamp is a no-op" diff "$T/orig.md" "$T/c.md"
}

test_changelog_repo_file() {
  check "changelog: CHANGELOG.md has Unreleased" grep -qx '## Unreleased' "$ROOT/CHANGELOG.md"
}

# tailscale status --json of a locked device that is up and connected to the control plane.
# shellcheck disable=SC2089,SC2090 # JSON text, echoed verbatim by the stubs
export TS_ONLINE='{"BackendState":"Running","Self":{"Online":true}}'

health_env() {
  export JUNIPER_HEALTH_TRIES=1 JUNIPER_HEALTH_INTERVAL=0 JUNIPER_TRYBOOT_FLAG=$T/tryboot \
    JUNIPER_HEALTH_D=$T/health.d JUNIPER_HEALTH_LOCAL_D=$T/local.d \
    JUNIPER_HEALTH_PROBE_TIMEOUT=2 JUNIPER_HEALTH_PROBE_KILL=1
}

test_healthcheck_healthy_confirms() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: healthy -> make booted the firmware default" called "bootloader sync"
}

test_healthcheck_unhealthy_tryboot_falls_back() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: unhealthy tryboot -> reboot" called "systemctl reboot"
  check "health: unhealthy -> no sync" not_called "bootloader sync"
}

test_healthcheck_first_boot_no_network_no_loop() {
  health_env
  "$LIBEXEC/healthcheck" || true
  check "health: unhealthy normal boot -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_requires_tailscale_once_locked() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  stub tailscale "echo '{\"BackendState\":\"NeedsLogin\"}'"
  "$LIBEXEC/healthcheck" || true
  check "health: locked + tailscale down -> fall back" called "systemctl reboot"
}

test_healthcheck_normal_boot_flag_zero_no_reboot() {
  health_env
  printf '\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: flag 0 unhealthy -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_normal_boot_flag_empty_no_reboot() {
  health_env
  : >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: empty flag unhealthy -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_normal_boot_flag_8_zero_bytes_no_reboot() {
  health_env
  printf '\x00\x00\x00\x00\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: 8 zero bytes unhealthy -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_healthy_tryboot_confirms() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: healthy tryboot -> sync" called "bootloader sync"
  check "health: healthy tryboot -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_ipv6_only_route_is_healthy() {
  health_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub ip 'if [[ $* == *-6* ]]; then echo "default via fe80::1 dev end0 proto ra"; fi'
  "$LIBEXEC/healthcheck"
  check "health: IPv6-only default route -> healthy" called "bootloader sync"
}

# Once locked, SSH over the tailnet is the only way in: Tailscale Running isn't enough.
test_healthcheck_locked_requires_ssh_over_tailnet() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "{\"BackendState\":\"Running\"}" ;; debug) echo "{\"RunSSH\":false}" ;; esac'
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl 'if [[ $1 == is-active ]]; then echo inactive; exit 3; fi'
  "$LIBEXEC/healthcheck" || true
  check "health: locked, no Tailscale SSH, no sshd -> fall back" called "systemctl reboot"
}

test_healthcheck_locked_tailscale_ssh_is_healthy() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "$TS_ONLINE" ;; debug) echo "{\"RunSSH\":true}" ;; esac'
  "$LIBEXEC/healthcheck"
  check "health: locked + Tailscale SSH -> healthy" called "bootloader sync"
  check "health: locked + Tailscale SSH -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_locked_sshd_is_healthy() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "$TS_ONLINE" ;; debug) echo "{\"RunSSH\":false}" ;; esac'
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl 'if [[ $1 == is-active ]]; then echo active; fi'
  "$LIBEXEC/healthcheck"
  check "health: locked + sshd (ujust tailscale-ssh off) -> healthy" called "bootloader sync"
}

test_healthcheck_hook_failure_falls_back_under_tryboot() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 1\n' >"$JUNIPER_HEALTH_D/10-greetd" && chmod +x "$JUNIPER_HEALTH_D/10-greetd"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck" || true
  check "health: failing hook under tryboot -> reboot" called "systemctl reboot"
}

test_healthcheck_names_failing_hook() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 1\n' >"$JUNIPER_HEALTH_D/10-greetd" && chmod +x "$JUNIPER_HEALTH_D/10-greetd"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  check "health: failing hook named" stderr_has "health hook 10-greetd failed" "$LIBEXEC/healthcheck"
  check "health: final message mentions image health hooks" stderr_has "image health hook" "$LIBEXEC/healthcheck"
}

# A hung hook must not stall the check past the unit's timeout (no fallback then).
test_healthcheck_hung_hook_times_out() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d JUNIPER_HEALTH_HOOK_TIMEOUT=1
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexec sleep 30\n' >"$JUNIPER_HEALTH_D/10-hang" && chmod +x "$JUNIPER_HEALTH_D/10-hang"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: hung hook killed after its timeout" test $((SECONDS - start)) -lt 10
  check "health: hung hook under tryboot -> reboot" called "systemctl reboot"
}

# A hook that hangs on every try (say a wedged D-Bus) must still reach the tryboot fallback
# before juniper-healthcheck.service's TimeoutStartSec kills the check. The hook ignores
# SIGTERM, so only timeout's -k gets rid of it.
test_healthcheck_always_hanging_hook_still_falls_back() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d JUNIPER_HEALTH_TRIES=1000 JUNIPER_HEALTH_HOOK_TIMEOUT=1 \
    JUNIPER_HEALTH_HOOK_KILL=1 JUNIPER_HEALTH_DEADLINE=3
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/bash\ntrap "" TERM\nsleep 30\n' >"$JUNIPER_HEALTH_D/10-hang" && chmod +x "$JUNIPER_HEALTH_D/10-hang"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: always-hanging hook -> deadline reached in time" test $((SECONDS - start)) -lt 15
  check "health: always-hanging hook under tryboot -> reboot" called "systemctl reboot"
}

test_healthcheck_deadline_below_unit_timeout() {
  local unit=$ROOT/system_files/usr/lib/systemd/system/juniper-healthcheck.service
  local t d k
  t=$(sed -n 's/^TimeoutStartSec=\([0-9]*\)min$/\1/p' "$unit")
  # shellcheck disable=SC2016 # literal ${...} in the script's text
  d=$(sed -n 's/^deadline=${JUNIPER_HEALTH_DEADLINE:-\([0-9]*\)}$/\1/p' "$LIBEXEC/healthcheck")
  # shellcheck disable=SC2016 # literal ${...} in the script's text
  k=$(sed -n 's/^hook_timeout=${JUNIPER_HEALTH_HOOK_TIMEOUT:-\([0-9]*\)}$/\1/p' "$LIBEXEC/healthcheck")
  check "health: per-hook timeout at most 15s" test "${k:-99}" -le 15
  # One more try can start just before the deadline: leave it a minute and more.
  check "health: deadline well below TimeoutStartSec" test $((${d:-9999} + 90)) -le $((${t:-0} * 60))
}

test_healthcheck_passing_hook_and_no_hooks() {
  health_env
  export JUNIPER_HEALTH_D=$T/health.d
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: no hook dir -> healthy" called "bootloader sync"
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 0\n' >"$JUNIPER_HEALTH_D/10-ok" && chmod +x "$JUNIPER_HEALTH_D/10-ok"
  : >"$CALLS"
  "$LIBEXEC/healthcheck"
  check "health: passing hook -> healthy" called "bootloader sync"
}

# A hung probe must not stall a try either: a wedged tailscaled (or ip, or systemctl) is killed
# after the probe timeout, and the try counts as unhealthy. The stubs ignore SIGTERM.
hang='trap "" TERM; sleep 30'
test_healthcheck_hanging_tailscale_still_falls_back() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  stub tailscale "$hang"
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: hung tailscale killed after the probe timeout" test $((SECONDS - start)) -lt 10
  check "health: hung tailscale under tryboot -> reboot" called "systemctl reboot"
  check "health: hung tailscale -> no sync" not_called "bootloader sync"
}

test_healthcheck_hanging_ip_still_falls_back() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip "$hang"
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: hung ip killed after the probe timeout" test $((SECONDS - start)) -lt 10
  check "health: hung ip under tryboot -> reboot" called "systemctl reboot"
}

test_healthcheck_hanging_systemctl_probe_still_falls_back() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "$TS_ONLINE" ;; debug) echo "{\"RunSSH\":false}" ;; esac'
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl 'if [[ $1 == is-active ]]; then trap "" TERM; sleep 30; fi'
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: hung systemctl is-active killed after the probe timeout" test $((SECONDS - start)) -lt 10
  check "health: hung systemctl probe under tryboot -> reboot" called "systemctl reboot"
}

# Local hooks (/etc/juniper/health.d) for quadlet users who don't build images. Only files
# owned by root (JUNIPER_HEALTH_LOCAL_OWNER here, so a non-root test run can own them) and not
# group- or world-writable run; anything else is skipped and logged.
local_hook() { # NAME BODY [MODE]
  mkdir -p "$JUNIPER_HEALTH_LOCAL_D"
  chmod 755 "$JUNIPER_HEALTH_LOCAL_D"
  printf '#!/bin/sh\n%s\n' "$2" >"$JUNIPER_HEALTH_LOCAL_D/$1"
  chmod "${3:-755}" "$JUNIPER_HEALTH_LOCAL_D/$1"
}
local_env() {
  health_env
  export JUNIPER_HEALTH_LOCAL_OWNER
  JUNIPER_HEALTH_LOCAL_OWNER=$(id -u)
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
}

test_healthcheck_local_hook_failure_falls_back() {
  local_env
  local_hook 50-sensor 'exit 1'
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: failing local hook under tryboot -> reboot" called "systemctl reboot"
  check "health: failing local hook named" stderr_has "health hook 50-sensor failed" "$LIBEXEC/healthcheck"
  check "health: failing local hook -> no sync" not_called "bootloader sync"
}

test_healthcheck_local_hook_pass_is_healthy() {
  local_env
  local_hook 50-sensor 'exit 0'
  "$LIBEXEC/healthcheck"
  check "health: passing local hook ran" test -x "$JUNIPER_HEALTH_LOCAL_D/50-sensor"
  check "health: passing local hook -> sync" called "bootloader sync"
}

test_healthcheck_local_hooks_run_sorted() {
  local_env
  local_hook 20-b "echo b >>$T/order"
  local_hook 10-a "echo a >>$T/order"
  "$LIBEXEC/healthcheck"
  check "health: local hooks run in sorted order" test "$(tr -d '\n' <"$T/order")" = ab
}

test_healthcheck_local_hook_world_writable_skipped() {
  local_env
  local_hook 50-unsafe 'exit 1' 777
  check "health: world-writable local hook logged" stderr_has "skipping local health hook 50-unsafe" "$LIBEXEC/healthcheck"
  check "health: world-writable local hook skipped -> healthy" called "bootloader sync"
  check "health: world-writable local hook skipped -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_local_hook_group_writable_skipped() {
  local_env
  local_hook 50-unsafe 'exit 1' 775
  "$LIBEXEC/healthcheck" 2>/dev/null
  check "health: group-writable local hook skipped -> healthy" called "bootloader sync"
}

test_healthcheck_local_hook_wrong_owner_skipped() {
  local_env
  # Files and the directory share one ownership check; a non-root run can't chown a single file,
  # so the whole directory (and its hook) is owned by "someone else" here.
  JUNIPER_HEALTH_LOCAL_OWNER=$(($(id -u) + 1))
  local_hook 50-notroot 'exit 1'
  check "health: wrong-owner local hooks logged" stderr_has "skipping local health hook" "$LIBEXEC/healthcheck"
  check "health: wrong-owner local hook skipped -> healthy" called "bootloader sync"
}

test_healthcheck_local_hook_unsafe_dir_skipped() {
  local_env
  local_hook 50-sensor 'exit 1'
  chmod 777 "$JUNIPER_HEALTH_LOCAL_D"
  check "health: unsafe local hook dir logged" stderr_has "skipping local health hooks" "$LIBEXEC/healthcheck"
  check "health: unsafe local hook dir skipped -> healthy" called "bootloader sync"
}

test_healthcheck_local_hook_symlink_skipped() {
  local_env
  printf '#!/bin/sh\nexit 1\n' >"$T/elsewhere" && chmod 755 "$T/elsewhere"
  mkdir -p "$JUNIPER_HEALTH_LOCAL_D" && chmod 755 "$JUNIPER_HEALTH_LOCAL_D"
  ln -s "$T/elsewhere" "$JUNIPER_HEALTH_LOCAL_D/50-link"
  check "health: symlinked local hook logged" stderr_has "skipping local health hook 50-link" "$LIBEXEC/healthcheck"
  check "health: symlinked local hook skipped -> healthy" called "bootloader sync"
}

test_healthcheck_local_hook_timeout() {
  local_env
  export JUNIPER_HEALTH_HOOK_TIMEOUT=1 JUNIPER_HEALTH_HOOK_KILL=1
  local_hook 50-hang 'trap "" TERM; sleep 30'
  local start=$SECONDS
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: hung local hook killed after the hook timeout" test $((SECONDS - start)) -lt 10
  check "health: hung local hook under tryboot -> reboot" called "systemctl reboot"
  unset JUNIPER_HEALTH_HOOK_TIMEOUT JUNIPER_HEALTH_HOOK_KILL
}

test_example_appliance_health_hook() {
  local h=$ROOT/examples/appliance/health.d/50-sensor-sample
  check "example: appliance health hook is executable" test -x "$h"
  check "example: appliance health hook documented in README" grep -q '/etc/juniper/health.d' "$ROOT/README.md"
}

# Locked: Tailscale must also be connected to its control plane (.Self.Online), or the update
# falls back (the decided offline policy).
locked_ts_env() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "$TS_STATUS" ;; debug) echo "{\"RunSSH\":true}" ;; esac'
}

test_healthcheck_locked_requires_control_connection() {
  locked_ts_env
  TS_STATUS='{"BackendState":"Running","Self":{"Online":false}}' "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: locked, control offline -> fall back" called "systemctl reboot"
  check "health: locked, control offline -> no sync" not_called "bootloader sync"
}

test_healthcheck_locked_missing_online_is_unhealthy() {
  locked_ts_env
  TS_STATUS='{"BackendState":"Running"}' "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "health: locked, no Self.Online -> fall back" called "systemctl reboot"
}

test_healthcheck_locked_control_online_is_healthy() {
  locked_ts_env
  TS_STATUS=$TS_ONLINE "$LIBEXEC/healthcheck"
  check "health: locked, control online -> sync" called "bootloader sync"
  check "health: locked, control online -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_unlocked_ignores_control_connection() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  stub tailscale "echo '{\"BackendState\":\"Running\",\"Self\":{\"Online\":false}}'"
  "$LIBEXEC/healthcheck"
  check "health: not locked, control offline -> still healthy (LAN SSH works)" called "bootloader sync"
}

# juniper-healthcheck.service failing for any reason (killed at TimeoutStartSec, crashed, OOM)
# starts juniper-healthcheck-fallback.service: `healthcheck --fallback` reboots under tryboot
# only, with no probes and no retries.
test_healthcheck_fallback_mode_reboots_under_tryboot() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck" --fallback 2>/dev/null
  check "health fallback: tryboot -> reboot" called "systemctl reboot"
  check "health fallback: no probes" not_called "ip "
  check "health fallback: never confirms" not_called "bootloader sync"
}

test_healthcheck_fallback_mode_normal_boot_does_nothing() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  printf '\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  check "health fallback: normal boot exits 0" "$LIBEXEC/healthcheck" --fallback
  check "health fallback: normal boot -> no reboot" not_called "systemctl reboot"
  check "health fallback: normal boot -> no sync" not_called "bootloader sync"
  rm -f "$JUNIPER_TRYBOOT_FLAG"
  check "health fallback: no flag exits 0" "$LIBEXEC/healthcheck" --fallback
  check "health fallback: no flag -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_rejects_unknown_argument() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  check "health: unknown argument fails" fails "$LIBEXEC/healthcheck" --bogus
  check "health: unknown argument -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_unit_has_fallback_on_failure() {
  local u=$ROOT/system_files/usr/lib/systemd/system
  check "health unit: OnFailure= the fallback" \
    grep -qx 'OnFailure=juniper-healthcheck-fallback.service' "$u/juniper-healthcheck.service"
  check "fallback unit: runs healthcheck --fallback" \
    grep -qx 'ExecStart=/usr/libexec/juniper/healthcheck --fallback' "$u/juniper-healthcheck-fallback.service"
}

# Two strikes: a digest that fails its health check under tryboot gets a strike in
# $JUNIPER_STATE_DIR/bad-digests ("DIGEST COUNT BOOT_ID"; /var survives the fallback) and is
# retried at the next window. A second failure, on another boot, quarantines it: held until a
# newer digest is staged.
BAD=sha256:$(printf 'b%.0s' {1..64})
NEW=sha256:$(printf 'c%.0s' {1..64})
booted_digest() { stub bootc "echo '{\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"$1\"}}}}'"; }
strikes() { awk -v d="$1" '$1 == d {print $2}' "$JUNIPER_STATE_DIR/bad-digests" 2>/dev/null; }
# fail_boot BOOT_ID: a failed tryboot of $BAD on that boot (the OnFailure= fallback path).
fail_boot() {
  echo "$1" >"$JUNIPER_BOOT_ID_FILE"
  "$LIBEXEC/healthcheck" --fallback 2>/dev/null
}
strike_env() {
  health_env
  export JUNIPER_BOOT_ID_FILE=$T/boot_id
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  booted_digest "$BAD"
}

test_healthcheck_first_failure_records_a_strike() {
  strike_env
  echo boot-1 >"$JUNIPER_BOOT_ID_FILE"
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  check "strikes: first failure -> one strike" test "$(strikes "$BAD")" = 1
  check "strikes: still reboots" called "systemctl reboot"
}

# The main check falls back, exits 1, and OnFailure= then runs --fallback on the same boot:
# still one strike, or a single failure would quarantine.
test_healthcheck_one_strike_per_boot() {
  strike_env
  echo boot-1 >"$JUNIPER_BOOT_ID_FILE"
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  fail_boot boot-1
  check "strikes: main check + OnFailure fallback on one boot -> one strike" test "$(strikes "$BAD")" = 1
  check "strikes: listed once" test "$(grep -c "^$BAD " "$JUNIPER_STATE_DIR/bad-digests")" = 1
}

test_healthcheck_second_failure_quarantines() {
  strike_env
  fail_boot boot-1
  fail_boot boot-2
  check "strikes: second failure on another boot -> two strikes" test "$(strikes "$BAD")" = 2
}

test_healthcheck_normal_boot_records_nothing() {
  strike_env
  printf '\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" 2>/dev/null || true
  fail_boot boot-1
  check "strikes: normal boot records nothing" test ! -e "$JUNIPER_STATE_DIR/bad-digests"
}

# A full /var (the rewrite fails) must not wipe the strike history.
test_healthcheck_failed_strike_write_keeps_history() {
  strike_env
  echo "$NEW 1 boot-0" >"$JUNIPER_STATE_DIR/bad-digests"
  stub tail 'exit 1'
  fail_boot boot-1
  check "strikes: failed write keeps the old list" test "$(cat "$JUNIPER_STATE_DIR/bad-digests")" = "$NEW 1 boot-0"
  check "strikes: failed write still reboots" called "systemctl reboot"
}

# A failed `rpi-bootc-bootloader sync` on a normal boot fails the unit; the OnFailure= fallback
# must still leave a normal boot alone.
test_healthcheck_failed_sync_normal_boot_no_reboot() {
  strike_env
  printf '\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  stub bootloader 'exit 1'
  check "health: failed sync fails the check" fails "$LIBEXEC/healthcheck"
  fail_boot boot-1
  check "health: failed sync + fallback on a normal boot -> no reboot" not_called "systemctl reboot"
  check "health: failed sync on a normal boot -> no strike" test ! -e "$JUNIPER_STATE_DIR/bad-digests"
}

test_healthcheck_fallback_unit_has_timeout() {
  check "fallback unit: explicit TimeoutStartSec" grep -qx 'TimeoutStartSec=2min' \
    "$ROOT/system_files/usr/lib/systemd/system/juniper-healthcheck-fallback.service"
}

# Never hold on data we can't trust: a malformed staged digest or a corrupt list proceeds.
test_apply_update_malformed_digest_proceeds() {
  printf 'sha256:zz 2 boot-1\n' >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest 'sha256:zz'
  "$LIBEXEC/apply-update" >/dev/null
  check "apply-update: malformed staged digest -> proceeds" called "bootloader tryreboot"
  check "apply-update: malformed staged digest -> not held" test ! -e "$JUNIPER_STATE_DIR/update-held"
}

test_apply_update_corrupt_list_proceeds() {
  printf '\x00\xff garbage\n%s lots boot-1\n\n' "$BAD" >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest "$BAD"
  "$LIBEXEC/apply-update" >/dev/null
  check "apply-update: corrupt bad-digests -> proceeds" called "bootloader tryreboot"
  check "apply-update: corrupt bad-digests -> not held" test ! -e "$JUNIPER_STATE_DIR/update-held"
}

test_healthcheck_quarantine_is_bounded() {
  strike_env
  local i
  for i in 0 1 2 3 4 5 6 7 8 9; do echo "sha256:$(printf "$i%.0s" {1..64}) 2 old"; done >"$JUNIPER_STATE_DIR/bad-digests"
  fail_boot boot-1
  check "strikes: keeps the last 10" test "$(wc -l <"$JUNIPER_STATE_DIR/bad-digests")" = 10
  check "strikes: newest kept" test "$(tail -n1 "$JUNIPER_STATE_DIR/bad-digests")" = "$BAD 1 boot-1"
  check "strikes: oldest dropped" fails grep -q "sha256:0000" "$JUNIPER_STATE_DIR/bad-digests"
}

test_healthcheck_quarantine_ignores_bad_bootc_output() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  # shellcheck disable=SC2016 # a literal, never expanded
  booted_digest 'sha256:nope$(reboot)'
  "$LIBEXEC/healthcheck" --fallback 2>/dev/null
  check "quarantine: malformed digest not recorded" test ! -s "$JUNIPER_STATE_DIR/bad-digests"
  check "quarantine: malformed digest -> still reboots" called "systemctl reboot"
  : >"$CALLS"
  stub bootc "$hang"
  local start=$SECONDS
  "$LIBEXEC/healthcheck" --fallback 2>/dev/null
  check "quarantine: hung bootc doesn't stall the fallback" test $((SECONDS - start)) -lt 10
  check "quarantine: hung bootc -> still reboots" called "systemctl reboot"
}

staged_digest() { stub bootc "echo '{\"status\":{\"staged\":{\"image\":{\"imageDigest\":\"$1\"}}}}'"; }

test_apply_update_one_strike_still_applies() {
  echo "$BAD 1 boot-1" >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest "$BAD"
  local out
  out=$("$LIBEXEC/apply-update")
  check "apply-update: one strike -> retried (tryreboot)" called "bootloader tryreboot"
  check "apply-update: one strike -> not held" test ! -e "$JUNIPER_STATE_DIR/update-held"
  check "apply-update: one strike logged" grep -q "1 failed attempt" <<<"$out"
}

test_apply_update_skips_quarantined_digest() {
  echo "$BAD 2 boot-2" >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest "$BAD"
  local out
  out=$("$LIBEXEC/apply-update")
  check "apply-update: quarantined digest -> no tryreboot" not_called "bootloader"
  check "apply-update: quarantined digest logged" grep -q "update $BAD failed its health check twice; waiting for a newer image" <<<"$out"
  check "apply-update: quarantine shown (update-held)" grep -q "failed its health check" "$JUNIPER_STATE_DIR/update-held"
}

# End to end: two failed tryboots of one digest hold it; the next digest goes ahead.
test_two_strikes_then_newer_digest() {
  strike_env
  fail_boot boot-1
  staged_digest "$BAD"
  "$LIBEXEC/apply-update" >/dev/null
  check "two strikes: after the first failure the update is retried" called "bootloader tryreboot"
  : >"$CALLS"
  booted_digest "$BAD"
  fail_boot boot-2
  staged_digest "$BAD"
  "$LIBEXEC/apply-update" >/dev/null
  check "two strikes: after the second failure it is held" not_called "bootloader"
  check "two strikes: held is shown" test -s "$JUNIPER_STATE_DIR/update-held"
  staged_digest "$NEW"
  "$LIBEXEC/apply-update" >/dev/null
  check "two strikes: a newer digest proceeds" called "bootloader tryreboot"
  check "two strikes: a newer digest clears held" test ! -e "$JUNIPER_STATE_DIR/update-held"
}

test_apply_update_newer_digest_proceeds() {
  echo "$BAD 2 boot-2" >"$JUNIPER_STATE_DIR/bad-digests"
  echo "update $BAD failed its health check twice; waiting for a newer image" >"$JUNIPER_STATE_DIR/update-held"
  staged_digest "$NEW"
  "$LIBEXEC/apply-update"
  check "apply-update: newer digest -> tryreboot" called "bootloader tryreboot"
  check "apply-update: newer digest clears update-held" test ! -e "$JUNIPER_STATE_DIR/update-held"
}

test_apply_update_held_mode() {
  echo "$BAD 2 boot-2" >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest "$BAD"
  check "apply-update --held: quarantined -> exit 0" "$LIBEXEC/apply-update" --held
  staged_digest "$NEW"
  check "apply-update --held: newer -> exit 1" fails "$LIBEXEC/apply-update" --held
  echo "$NEW 1 boot-1" >>"$JUNIPER_STATE_DIR/bad-digests"
  check "apply-update --held: one strike -> exit 1" fails "$LIBEXEC/apply-update" --held
  check "apply-update --held: never reboots" not_called "bootloader"
}

test_apply_update_check_mode_never_reboots() {
  echo "$BAD 2 boot-2" >"$JUNIPER_STATE_DIR/bad-digests"
  staged_digest "$BAD"
  "$LIBEXEC/apply-update" --check >/dev/null
  check "apply-update --check: quarantined -> update-held" grep -q "$BAD" "$JUNIPER_STATE_DIR/update-held"
  staged_digest "$NEW"
  "$LIBEXEC/apply-update" --check >/dev/null
  check "apply-update --check: newer -> update-held cleared" test ! -e "$JUNIPER_STATE_DIR/update-held"
  check "apply-update --check: never reboots" not_called "bootloader"
}

test_update_service_refreshes_quarantine_status() {
  check "juniper-update: refreshes update-held after staging" grep -qx \
    'ExecStartPost=-/usr/libexec/juniper/apply-update --check' \
    "$ROOT/system_files/usr/lib/systemd/system/juniper-update.service"
}

test_motd_shows_quarantined_update() {
  stub fastfetch ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl '[[ $* != *is-failed* ]]'
  echo "update $BAD failed its health check; waiting for a newer image" >"$JUNIPER_STATE_DIR/update-held"
  check "motd: quarantined update shown" grep -q "update $BAD failed its health check" <<<"$("$LIBEXEC/motd" 2>/dev/null)"
}

test_pi_status_shows_quarantined_update() {
  check "pi-status: shows update-held" grep -q '/var/lib/juniper/update-held' \
    "$ROOT/system_files/usr/share/juniper/just/pi.just"
}

test_healthcheck_probe_timeout_is_short() {
  local p
  # shellcheck disable=SC2016 # literal ${...} in the script's text
  p=$(sed -n 's/^probe_timeout=${JUNIPER_HEALTH_PROBE_TIMEOUT:-\([0-9]*\)}$/\1/p' "$LIBEXEC/healthcheck")
  check "health: per-probe timeout at most 10s" test "${p:-99}" -le 10
}

# Real-root emergency mode under tryboot: PID 1 keeps the watchdog fed, so nothing would
# reboot into the previous deployment without this.
test_emergency_fallback_reboots_under_tryboot() {
  export JUNIPER_TRYBOOT_FLAG=$T/tryboot JUNIPER_EMERGENCY_DELAY=0
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/emergency-fallback" >/dev/null 2>&1
  check "emergency: tryboot -> reboot" called "systemctl reboot"
}

test_emergency_fallback_stays_on_normal_boot() {
  export JUNIPER_TRYBOOT_FLAG=$T/tryboot JUNIPER_EMERGENCY_DELAY=0
  printf '\x00\x00\x00\x00' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/emergency-fallback" >/dev/null 2>&1
  check "emergency: normal boot -> stay for the console" not_called "systemctl reboot"
  rm -f "$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/emergency-fallback" >/dev/null 2>&1
  check "emergency: no flag -> stay" not_called "systemctl reboot"
}

# lsblk_tree: stub findmnt (the /sysroot source) and lsblk (inverse tree, disk partitions).
cidata_tree() {
  stub findmnt "echo $1"
  stub lsblk "$2"
}

test_cidata_device_on_boot_disk() {
  # shellcheck disable=SC2016 # expands inside the stub
  cidata_tree /dev/mmcblk0p3 'case "$*" in
    *-s*) printf "/dev/mmcblk0p3 part\n/dev/mmcblk0 disk\n" ;;
    *mmcblk0*) printf "/dev/mmcblk0 \n/dev/mmcblk0p1 CIDATA\n/dev/mmcblk0p2 boot\n/dev/mmcblk0p3 root\n" ;;
    *) printf "/dev/sda1 CIDATA\n" ;;
  esac'
  check "cidata: partition on the boot disk" test "$("$LIBEXEC/cidata-device")" = /dev/mmcblk0p1
}

test_cidata_device_through_luks() {
  # shellcheck disable=SC2016 # expands inside the stub
  cidata_tree /dev/mapper/root 'case "$*" in
    *-s*) printf "/dev/mapper/root crypt\n/dev/mmcblk0p3 part\n/dev/mmcblk0 disk\n" ;;
    *mmcblk0*) printf "/dev/mmcblk0 \n/dev/mmcblk0p1 CIDATA\n/dev/mmcblk0p3 \n" ;;
  esac'
  check "cidata: found through a LUKS root" test "$("$LIBEXEC/cidata-device")" = /dev/mmcblk0p1
}

test_cidata_device_ambiguous_or_missing() {
  # shellcheck disable=SC2016 # expands inside the stub
  cidata_tree /dev/mmcblk0p3 'case "$*" in
    *-s*) printf "/dev/mmcblk0p3 part\n/dev/mmcblk0 disk\n" ;;
    *) printf "/dev/mmcblk0p1 CIDATA\n/dev/mmcblk0p4 CIDATA\n" ;;
  esac'
  check "cidata: two on the boot disk -> refuse" fails "$LIBEXEC/cidata-device"
  # shellcheck disable=SC2016 # expands inside the stub
  cidata_tree /dev/mmcblk0p3 'case "$*" in
    *-s*) printf "/dev/mmcblk0p3 part\n/dev/mmcblk0 disk\n" ;;
    *) printf "/dev/mmcblk0p1 boot\n" ;;
  esac'
  check "cidata: none on the boot disk -> refuse" fails "$LIBEXEC/cidata-device"
}

brew_env() {
  export JUNIPER_BREW_PREFIX=$T/linuxbrew JUNIPER_BREWFILE=$T/Brewfile JUNIPER_BREW_STATE=$T/brew-state
  mkdir -p "$JUNIPER_BREW_PREFIX/bin"
  echo 'brew "zellij"' >"$JUNIPER_BREWFILE"
  # shellcheck disable=SC2016 # expands inside the stub
  printf '#!/usr/bin/env bash\necho "brew $*" >>"$CALLS"\n' >"$JUNIPER_BREW_PREFIX/bin/brew"
  chmod +x "$JUNIPER_BREW_PREFIX/bin/brew"
}

test_brew_tools_installs_brewfile_once() {
  brew_env
  "$ROOT/system_files_dev/usr/libexec/juniper/brew-tools" >/dev/null
  check "brew-tools: brew bundle with the shipped Brewfile" called "brew bundle --file=$JUNIPER_BREWFILE"
  check "brew-tools: marked done" test -e "$JUNIPER_BREW_STATE/brew-tools.done"
  : >"$CALLS"
  "$ROOT/system_files_dev/usr/libexec/juniper/brew-tools" --first-login >/dev/null
  check "brew-tools: first-login run skipped once done" not_called "brew bundle"
  "$ROOT/system_files_dev/usr/libexec/juniper/brew-tools" >/dev/null
  check "brew-tools: explicit run (ujust brew-tools) always runs" called "brew bundle"
}

test_brew_tools_skips_without_writable_brew() {
  brew_env
  rm -rf "$JUNIPER_BREW_PREFIX"
  check "brew-tools: no Homebrew -> skip, not fail" "$ROOT/system_files_dev/usr/libexec/juniper/brew-tools" --first-login
  check "brew-tools: no Homebrew -> not marked done" test ! -e "$JUNIPER_BREW_STATE/brew-tools.done"
}

test_render_os_list() {
  printf 'rawbytes' >"$T/j.raw"
  printf 'xz' >"$T/j.raw.xz"
  "$ROOT/disk/render-os-list.sh" juniper "$T/j.raw" "$T/j.raw.xz" https://example/j.raw.xz 20261009 >"$T/os.json"
  check "os-list: url" jq -e '.os_list[0].url == "https://example/j.raw.xz"' "$T/os.json"
  check "os-list: name" jq -e '.os_list[0].name == "Juniper 20261009"' "$T/os.json"
  check "os-list: extract_size" jq -e '.os_list[0].extract_size == 8' "$T/os.json"
  # shellcheck disable=SC2016 # $h is a jq variable
  check "os-list: sha256 of raw" jq -e --arg h "$(sha256sum "$T/j.raw" | cut -d' ' -f1)" '.os_list[0].extract_sha256 == $h' "$T/os.json"
  check "os-list: cloudinit + tailscale capability" jq -e '.os_list[0].init_format == "cloudinit" and (.os_list[0].capabilities | index("tailscale"))' "$T/os.json"
  check "os-list: pi4+pi5 only" jq -e '.os_list[0].devices == ["pi5-64bit","pi4-64bit"]' "$T/os.json"
}

test_render_os_list_minimal() {
  printf 'rawbytes' >"$T/m.raw"
  printf 'xz' >"$T/m.raw.xz"
  "$ROOT/disk/render-os-list.sh" juniper-minimal "$T/m.raw" "$T/m.raw.xz" https://example/m.raw.xz 20261009 >"$T/os.json"
  check "os-list minimal: name" jq -e '.os_list[0].name == "Juniper Minimal 20261009"' "$T/os.json"
  check "os-list minimal: no dev tools claimed" jq -e '.os_list[0].description | test("Homebrew") | not' "$T/os.json"
}

test_render_os_list_rejects_unknown_image() {
  printf 'x' >"$T/x.raw"
  # shellcheck disable=SC2016 # $0/$1 expand in the inner bash
  check "os-list: unknown image rejected" bash -c '! "$0" nope "$1" "$1" u v 2>/dev/null' "$ROOT/disk/render-os-list.sh" "$T/x.raw"
}

wifi_env() {
  export JUNIPER_CIDATA_DIR=$T/cidata JUNIPER_NM_DIR=$T/nm JUNIPER_MODPROBE_DIR=$T/modprobe
  mkdir -p "$JUNIPER_CIDATA_DIR"
}
nm_file() { echo "$JUNIPER_NM_DIR/juniper-wifi-$1.nmconnection"; }
# NetworkManager keyfile value of KEY in [SECTION] of FILE
kf() { awk -F= -v s="[$2]" -v k="$3" '/^\[/{in_s=($0==s)} in_s && $1==k {sub(/^[^=]*=/,""); print}' "$1"; }

# Raspberry Pi Imager's shape: renderer key beside the interfaces, quoted SSID with spaces.
test_wifi_import_imager_network_config() {
  wifi_env
  cat >"$JUNIPER_CIDATA_DIR/network-config" <<'EOF'
network:
  version: 2
  wifis:
    renderer: networkd
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: "GB"
      access-points:
        "My Home Network":
          password: "hunter2hunter2"
EOF
  "$LIBEXEC/wifi-import"
  f=$(nm_file 1)
  check "wifi: keyfile written" test -f "$f"
  check "wifi: keyfile mode 600" test "$(stat -c %a "$f" 2>/dev/null)" = 600
  check "wifi: type wifi" test "$(kf "$f" connection type)" = wifi
  check "wifi: interface wlan0" test "$(kf "$f" connection interface-name)" = wlan0
  check "wifi: id is the SSID" test "$(kf "$f" connection id)" = "My Home Network"
  check "wifi: ssid as bytes" test "$(kf "$f" wifi ssid)" = \
    "77;121;32;72;111;109;101;32;78;101;116;119;111;114;107;"
  check "wifi: wpa-psk" test "$(kf "$f" wifi-security key-mgmt)" = wpa-psk
  check "wifi: psk" test "$(kf "$f" wifi-security psk)" = hunter2hunter2
  check "wifi: dhcp" test "$(kf "$f" ipv4 method)" = auto
  check "wifi: regulatory domain" grep -qx 'options cfg80211 ieee80211_regdom=GB' \
    "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
}

test_wifi_import_open_hidden_network() {
  wifi_env
  printf 'version: 2\nwifis:\n  wlan0:\n    access-points:\n      cafe:\n        hidden: true\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  "$LIBEXEC/wifi-import"
  f=$(nm_file 1)
  check "wifi open: hidden" test "$(kf "$f" wifi hidden)" = true
  check "wifi open: no security section" not_grep_dir 'wifi-security' "$JUNIPER_NM_DIR"
  check "wifi open: no regdom file" test ! -e "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
}

test_wifi_import_escapes_psk() {
  wifi_env
  # shellcheck disable=SC2016 # literal YAML
  printf 'network:\n  version: 2\n  wifis:\n    wlan0:\n      access-points:\n        x:\n          password: " a\\\\b\\\\nc "\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  "$LIBEXEC/wifi-import"
  # GKeyFile escaping: edge spaces \s, backslash \\.
  check "wifi: psk escaped" test "$(kf "$(nm_file 1)" wifi-security psk)" = '\sa\\b\\nc\s'
}

test_wifi_import_nothing_to_do() {
  wifi_env
  "$LIBEXEC/wifi-import"
  check "wifi: no network-config, no keyfile" test ! -e "$JUNIPER_NM_DIR"
  printf 'network:\n  version: 2\n  ethernets:\n    end0:\n      dhcp4: true\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  "$LIBEXEC/wifi-import"
  check "wifi: ethernet-only, no keyfile" test ! -e "$JUNIPER_NM_DIR"
}

test_wifi_import_no_cidata() {
  wifi_env
  rmdir "$JUNIPER_CIDATA_DIR"
  check "wifi: missing CIDATA is not an error" "$LIBEXEC/wifi-import"
}

test_wifi_import_rerun_replaces() {
  wifi_env
  printf 'version: 2\nwifis:\n  wlan0:\n    access-points:\n      a:\n        password: "12345678"\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  "$LIBEXEC/wifi-import"
  "$LIBEXEC/wifi-import"
  check "wifi rerun: one keyfile" test "$(find "$JUNIPER_NM_DIR" -type f | wc -l)" = 1
}

# A regulatory domain lands in a root-owned modprobe config: a newline there would add an
# `install` directive (a command run at the next module load). The cidata can be hand-made.
test_wifi_import_rejects_bad_regdom() {
  wifi_env
  printf 'version: 2\nwifis:\n  wlan0:\n    regulatory-domain: "GB\\ninstall cfg80211 /bin/sh -c id"\n    access-points:\n      a:\n        password: "12345678"\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  check "wifi: newline regdom -> no modprobe file" stderr_has "regulatory-domain" "$LIBEXEC/wifi-import"
  check "wifi: newline regdom not written" test ! -e "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
  check "wifi: network still imported" test -f "$(nm_file 1)"
  local bad
  for bad in '"G\x01"' 'GBR' '"0B"' '""'; do
    rm -rf "$JUNIPER_MODPROBE_DIR"
    printf 'version: 2\nwifis:\n  wlan0:\n    regulatory-domain: %s\n    access-points:\n      a: {}\n' "$bad" \
      >"$JUNIPER_CIDATA_DIR/network-config"
    "$LIBEXEC/wifi-import" >/dev/null 2>&1
    check "wifi: regdom $bad not written" test ! -e "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
  done
  # Case folding must not turn non-ASCII into letters: "ß".upper() is "SS", "ﬀ".upper() is "FF".
  for bad in '"ß"' '"ﬀ"' '"ıı"'; do
    rm -rf "$JUNIPER_MODPROBE_DIR"
    printf 'version: 2\nwifis:\n  wlan0:\n    regulatory-domain: %s\n    access-points:\n      a: {}\n' "$bad" \
      >"$JUNIPER_CIDATA_DIR/network-config"
    "$LIBEXEC/wifi-import" >/dev/null 2>&1
    check "wifi: non-ASCII regdom $bad not written" test ! -e "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
  done
  printf 'version: 2\nwifis:\n  wlan0:\n    regulatory-domain: "de"\n    access-points:\n      a: {}\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  "$LIBEXEC/wifi-import" >/dev/null
  check "wifi: lowercase regdom uppercased" grep -qx 'options cfg80211 ieee80211_regdom=DE' \
    "$JUNIPER_MODPROBE_DIR/juniper-wifi-regdom.conf"
}

# The interface name is written into the keyfile unescaped: only real Linux names pass.
test_wifi_import_rejects_bad_interface() {
  wifi_env
  printf 'version: 2\nwifis:\n  "wlan0\\n[ipv4]\\nmethod=manual":\n    access-points:\n      a: {}\n  wlan0123456789abc:\n    access-points:\n      b: {}\n  "..":\n    access-points:\n      c: {}\n  wlan1:\n    access-points:\n      d: {}\n' \
    >"$JUNIPER_CIDATA_DIR/network-config"
  check "wifi: bad interface logged" stderr_has "interface" "$LIBEXEC/wifi-import"
  check "wifi: only the valid interface imported" test "$(find "$JUNIPER_NM_DIR" -type f | wc -l)" = 1
  check "wifi: valid interface kept" test "$(kf "$(nm_file 1)" connection interface-name)" = wlan1
  check "wifi: no injected section" not_grep_dir 'method=manual' "$JUNIPER_NM_DIR"
}

# fails CMD...: CMD exits non-zero (stderr hidden). stderr_has PATTERN CMD...: CMD's stderr matches.
fails() { ! "$@" 2>/dev/null; }
stdout_has() {
  local out
  out=$("${@:2}" 2>/dev/null)
  grep -q -- "$1" <<<"$out"
}
not_stdout_has() { ! stdout_has "$@"; }
not_stderr_has() { ! stderr_has "$@"; }
# Capture first: `grep -q` exiting early would SIGPIPE the command before it finishes its work.
stderr_has() {
  local err
  err=$({ "${@:2}" 2>&1 >/dev/null || true; })
  grep -q -- "$1" <<<"$err"
}

# yq-free YAML lookups for the flash tests: yget FILE PYTHON-EXPR (d is the parsed document)
yget() { python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

flash_config() {
  cat >"$T/flash.yaml" <<'EOF'
hostname: pi-one
user: nat
timezone: Europe/London
ssh_keys:
  - ssh-ed25519 AAAAC3one laptop
  - ssh-ed25519 AAAAC3two yubikey
tailscale_authkey: tskey-auth-abc123
wifi:
  ssid: 'My "Home" Network: 5G'
  password: 'p#ss: word'
  country: GB
EOF
  chmod 600 "$T/flash.yaml"
}

test_render_cidata_user_data() {
  flash_config
  "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out"
  local u=$T/out/user-data
  check "cidata: cloud-config header" test "$(head -1 "$u")" = "#cloud-config"
  check "cidata: user-data mode 600" test "$(stat -c %a "$u" 2>/dev/null)" = 600
  check "cidata: hostname" test "$(yget "$u" 'd["hostname"]')" = pi-one
  check "cidata: user" test "$(yget "$u" 'd["users"][0]["name"]')" = nat
  check "cidata: wheel" test "$(yget "$u" 'd["users"][0]["groups"]')" = "['wheel']"
  check "cidata: passwordless sudo" test "$(yget "$u" 'd["users"][0]["sudo"]')" = "['ALL=(ALL) NOPASSWD:ALL']"
  check "cidata: both ssh keys" test "$(yget "$u" 'len(d["users"][0]["ssh_authorized_keys"])')" = 2
  check "cidata: timezone" test "$(yget "$u" 'd["timezone"]')" = Europe/London
  check "cidata: tailscale key file" test "$(yget "$u" '[(f["path"], f["permissions"], f["content"]) for f in d["write_files"]]')" = \
    "[('/etc/tailscale/authkey', '0600', 'tskey-auth-abc123')]"
}

test_render_cidata_network_config() {
  flash_config
  "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out"
  local n=$T/out/network-config
  check "cidata: network-config mode 600" test "$(stat -c %a "$n" 2>/dev/null)" = 600
  check "cidata: wifi ssid + password" test "$(yget "$n" 'd["network"]["wifis"]["wlan0"]["access-points"]')" = \
    "{'My \"Home\" Network: 5G': {'password': 'p#ss: word'}}"
  check "cidata: regulatory domain" test "$(yget "$n" 'd["network"]["wifis"]["wlan0"]["regulatory-domain"]')" = GB
  # The same importer path the image uses must accept it.
  JUNIPER_CIDATA_DIR=$T/out JUNIPER_NM_DIR=$T/nm JUNIPER_MODPROBE_DIR=$T/mp "$LIBEXEC/wifi-import" >/dev/null
  check "cidata: image imports it" grep -q '^id=My "Home" Network: 5G$' "$T/nm/juniper-wifi-1.nmconnection"
}

# wifi.country ends up in a root-owned modprobe config on the device: two letters only.
test_render_cidata_wifi_country() {
  local base='user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nwifi:\n  ssid: home\n  country: %s\n'
  # shellcheck disable=SC2059 # base is the format
  printf "$base" gb >"$T/lower.yaml"
  "$ROOT/disk/render-cidata" "$T/lower.yaml" "$T/o1" 2>/dev/null
  check "cidata: lowercase country uppercased" \
    test "$(yget "$T/o1/network-config" 'd["network"]["wifis"]["wlan0"]["regulatory-domain"]')" = GB
  local c i=0
  for c in '"GB\ninstall cfg80211 /bin/sh"' '"G\x01"' '"G\tB"' GBR '"G"' '"12"' 44 '"ß"' '"ﬀ"' '"ıı"'; do
    i=$((i + 1))
    # shellcheck disable=SC2059 # base is the format
    printf "$base" "$c" >"$T/bad$i.yaml"
    check "cidata: country $c refused" stderr_has "wifi: country" \
      "$ROOT/disk/render-cidata" "$T/bad$i.yaml" "$T/out$i"
    check "cidata: country $c -> no network-config" test ! -e "$T/out$i/network-config"
  done
  # YAML 1.1 reads an unquoted NO (Norway) as false: say so instead of dropping it.
  # shellcheck disable=SC2059 # base is the format
  printf "$base" NO >"$T/no.yaml"
  check "cidata: unquoted NO explained" stderr_has "quote" "$ROOT/disk/render-cidata" "$T/no.yaml" "$T/ono"
}

test_render_cidata_minimal_config() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/flash.yaml"
  "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out" 2>/dev/null
  check "cidata minimal: no network-config" test ! -e "$T/out/network-config"
  check "cidata minimal: hostname defaults to juniper" test "$(yget "$T/out/user-data" 'd["hostname"]')" = juniper
  check "cidata minimal: no write_files" test "$(yget "$T/out/user-data" '"write_files" in d')" = False
}

test_render_cidata_authkey_file() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\ntailscale_authkey_file: key.txt\n' >"$T/flash.yaml"
  printf 'tskey-auth-fromfile\n' >"$T/key.txt"
  "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out"
  check "cidata: key from file (relative to config, stripped)" test \
    "$(yget "$T/out/user-data" 'd["write_files"][0]["content"]')" = tskey-auth-fromfile
}

test_render_cidata_password_hash() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/flash.yaml"
  hash=$(printf '%s' 'a pass "word" with $ and ü' | openssl passwd -6 -stdin)
  JUNIPER_PASSWORD_HASH=$hash "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out" 2>/dev/null
  check "cidata: hashed password set" test "$(yget "$T/out/user-data" 'd["users"][0]["passwd"]')" = "$hash"
  check "cidata: password not locked" test "$(yget "$T/out/user-data" 'd["users"][0]["lock_passwd"]')" = False
}

# Owner decision 2026-10-11: with a password set, sudo asks for it; without, NOPASSWD.
test_render_cidata_sudo_follows_password() {
  local good
  good=$(printf '%s' 'fake pass' | openssl passwd -6 -stdin)
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/desk.yaml"
  JUNIPER_PASSWORD_HASH=$good "$ROOT/disk/render-cidata" "$T/desk.yaml" "$T/o1" 2>/dev/null
  check "cidata: password -> sudo asks for it" \
    test "$(yget "$T/o1/user-data" 'd["users"][0]["sudo"]')" = "['ALL=(ALL) ALL']"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/headless.yaml"
  "$ROOT/disk/render-cidata" "$T/headless.yaml" "$T/o2" 2>/dev/null
  check "cidata: no password -> NOPASSWD sudo" \
    test "$(yget "$T/o2/user-data" 'd["users"][0]["sudo"]')" = "['ALL=(ALL) NOPASSWD:ALL']"
}

test_render_cidata_desktop_needs_password() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/flash.yaml"
  check "cidata: desktop without a password refused" stderr_has "needs a password" \
    "$ROOT/disk/render-cidata" "$T/flash.yaml" "$T/out"
}

test_render_cidata_refuses_plaintext_and_bad_hash() {
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\npassword: hunter2\n' >"$T/plain.yaml"
  check "cidata: plain-text password refused" stderr_has "password: prompt" \
    "$ROOT/disk/render-cidata" "$T/plain.yaml" "$T/out1"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/ok.yaml"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\npassword: prompt\n' >"$T/okp.yaml"
  # shellcheck disable=SC2016  # a literal crypt hash
  check "cidata: non-SHA-512 hash refused" fails env JUNIPER_PASSWORD_HASH='$1$abc$def' \
    "$ROOT/disk/render-cidata" "$T/okp.yaml" "$T/out2"
  check "cidata: headless without password still fine" "$ROOT/disk/render-cidata" "$T/ok.yaml" "$T/out3"
}

test_render_cidata_hash_only_when_asked_for() {
  local good
  good=$(printf '%s' 'fake pass' | openssl passwd -6 -stdin)
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/headless.yaml"
  JUNIPER_PASSWORD_HASH=$good "$ROOT/disk/render-cidata" "$T/headless.yaml" "$T/o1" 2>/dev/null
  check "cidata: stray hash ignored on a headless config" test "$(yget "$T/o1/user-data" '"passwd" in d["users"][0] or "lock_passwd" in d["users"][0]')" = False
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\npassword: prompt\n' >"$T/prompt.yaml"
  JUNIPER_PASSWORD_HASH=$good "$ROOT/disk/render-cidata" "$T/prompt.yaml" "$T/o2" 2>/dev/null
  check "cidata: password: prompt uses the hash" test "$(yget "$T/o2/user-data" 'd["users"][0]["passwd"]')" = "$good"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\nimage: juniper-desktop\n' >"$T/desk.yaml"
  # shellcheck disable=SC2016  # a literal crypt hash
  check "cidata: short-body hash refused" fails env JUNIPER_PASSWORD_HASH='$6$salt$abc' "$ROOT/disk/render-cidata" "$T/desk.yaml" "$T/o3"
  check "cidata: empty hash refused for desktop" fails env JUNIPER_PASSWORD_HASH= "$ROOT/disk/render-cidata" "$T/desk.yaml" "$T/o4"
}

test_render_cidata_rejects_bad_config() {
  printf 'ssh_keys: [ssh-ed25519 AAAAC3x me]\n' >"$T/nouser.yaml"
  printf 'user: me\n' >"$T/nokeys.yaml"
  printf 'user: me\nssh_keys: [not-a-key]\n' >"$T/badkey.yaml"
  printf 'user: me\nssh_keys: [ssh-ed25519 AAAAC3x me]\ntailscale_authkey: hunter2\n' >"$T/badts.yaml"
  for c in nouser nokeys badkey badts; do
    check "cidata: rejects $c" fails "$ROOT/disk/render-cidata" "$T/$c.yaml" "$T/out-$c"
  done
}

enc_config() { # enc_config FILE 'extra yaml lines'
  printf 'user: me\nssh_keys:\n  - ssh-ed25519 AAAAC3ed25519 a@b\n  - ecdsa-sha2-nistp256 AAAAE2ecdsa c@d\n  - sk-ssh-ed25519@openssh.com AAAAsk e@f\n%s\n' "$2" >"$1"
  chmod 600 "$1"
}
AGE_PUB=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqx

test_render_cidata_encrypt_default_off() {
  enc_config "$T/e.yaml" ""
  "$ROOT/disk/render-cidata" "$T/e.yaml" "$T/o"
  check "encrypt: marker off" test "$(cat "$T/o/juniper-encrypt")" = off
  check "encrypt: no recovery file when off" test ! -e "$T/o/juniper-recovery.txt"
  check "encrypt: marker mode 0644" test "$(stat -c %a "$T/o/juniper-encrypt")" = 644
}

test_render_cidata_encrypt_on_uses_ssh_recipients() {
  enc_config "$T/e.yaml" "encrypt: true"
  "$ROOT/disk/render-cidata" "$T/e.yaml" "$T/o"
  check "encrypt: marker on" test "$(cat "$T/o/juniper-encrypt")" = on
  check "encrypt: only the ed25519 key" test "$(cat "$T/o/juniper-recovery.txt")" = "ssh-ed25519 AAAAC3ed25519 a@b"
  check "encrypt: recovery mode 0644" test "$(stat -c %a "$T/o/juniper-recovery.txt")" = 644
  enc_config "$T/rsa.yaml" "encrypt: true"
  sed -i 's/^  - ssh-ed25519.*/  - ssh-rsa AAAArsa r@s/' "$T/rsa.yaml"
  "$ROOT/disk/render-cidata" "$T/rsa.yaml" "$T/o2"
  check "encrypt: ssh-rsa accepted" test "$(cat "$T/o2/juniper-recovery.txt")" = "ssh-rsa AAAArsa r@s"
}

test_render_cidata_recovery_key_overrides() {
  enc_config "$T/e.yaml" "encrypt: true
recovery_key: $AGE_PUB"
  "$ROOT/disk/render-cidata" "$T/e.yaml" "$T/o"
  check "recovery_key replaces SSH recipients" test "$(cat "$T/o/juniper-recovery.txt")" = "$AGE_PUB"
}

test_render_cidata_encrypt_refuses_without_recipient() {
  printf 'user: me\nencrypt: true\nssh_keys:\n  - ecdsa-sha2-nistp256 AAAAE2ecdsa c@d\n  - sk-ssh-ed25519@openssh.com AAAAsk e@f\n' >"$T/n.yaml"
  chmod 600 "$T/n.yaml"
  check "encrypt: no recipient refused" fails "$ROOT/disk/render-cidata" "$T/n.yaml" "$T/o"
  check "encrypt: no-recipient message" stderr_has "no recovery recipient" "$ROOT/disk/render-cidata" "$T/n.yaml" "$T/o"
  sed -i 's/^encrypt: true/encrypt: false/' "$T/n.yaml"
  check "encrypt: false with only FIDO keys is fine" "$ROOT/disk/render-cidata" "$T/n.yaml" "$T/o3"
}

test_render_cidata_rejects_bad_recovery_key() {
  enc_config "$T/e1.yaml" "encrypt: true
recovery_key: age1short"
  check "recovery_key: short refused" fails "$ROOT/disk/render-cidata" "$T/e1.yaml" "$T/o1"
  enc_config "$T/e2.yaml" "encrypt: true
recovery_key: AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
  check "recovery_key: private key refused" fails "$ROOT/disk/render-cidata" "$T/e2.yaml" "$T/o2"
  check "recovery_key: private key message" stderr_has "that's an age private key" "$ROOT/disk/render-cidata" "$T/e2.yaml" "$T/o2"
}

test_render_cidata_encrypt_must_be_bool() {
  local v
  for v in '"yes"' maybe; do
    enc_config "$T/b.yaml" "encrypt: $v"
    check "encrypt: $v refused" fails "$ROOT/disk/render-cidata" "$T/b.yaml" "$T/ob"
    check "encrypt: $v message" stderr_has "encrypt: true or false" "$ROOT/disk/render-cidata" "$T/b.yaml" "$T/ob"
  done
  for v in true yes; do
    enc_config "$T/b.yaml" "encrypt: $v"
    check "encrypt: $v accepted" "$ROOT/disk/render-cidata" "$T/b.yaml" "$T/ok-$v"
  done
}

test_flash_summary_and_warning() {
  local out
  enc_config "$T/e.yaml" "encrypt: true"
  "$ROOT/disk/render-cidata" "$T/e.yaml" "$T/o"
  stub ssh-keygen 'cat >/dev/null; echo "256 SHA256:fakeprint a@b (ED25519)"'
  out=$("$ROOT/disk/flash.sh" --summary-only "$T/e.yaml" "$T/o")
  check "summary: encrypt yes with fingerprint" grep -qF "Encrypt:   yes (recovery: 1 SSH keys: SHA256:fakeprint)" <<<"$out"
  check "summary: warning" grep -qF "Encryption: on first boot this Pi writes a permanent device key" <<<"$out"
  check "summary: warning ends" grep -qF "recovery needs your SSH private key. Set encrypt: false to skip." <<<"$out"
  enc_config "$T/e2.yaml" "encrypt: true
recovery_key: ${AGE_PUB}"
  "$ROOT/disk/render-cidata" "$T/e2.yaml" "$T/o2"
  out=$("$ROOT/disk/flash.sh" --summary-only "$T/e2.yaml" "$T/o2")
  check "summary: age key tail" grep -qF "Encrypt:   yes (recovery: age key age1…${AGE_PUB: -6})" <<<"$out"
  enc_config "$T/e3.yaml" "encrypt: false"
  "$ROOT/disk/render-cidata" "$T/e3.yaml" "$T/o3"
  out=$("$ROOT/disk/flash.sh" --summary-only "$T/e3.yaml" "$T/o3")
  check "summary: encrypt: false" grep -qF "Encrypt:   no (encrypt: false)" <<<"$out"
  check "summary: no warning when off" not_stdout_has "Encryption: on first boot" echo "$out"
  enc_config "$T/e4.yaml" ""
  "$ROOT/disk/render-cidata" "$T/e4.yaml" "$T/o4"
  out=$("$ROOT/disk/flash.sh" --summary-only "$T/e4.yaml" "$T/o4")
  check "summary: not requested" grep -qF "Encrypt:   no (not requested)" <<<"$out"
}

# lsblk_json JSON: stub lsblk to print JSON (the -J output check-target asks for)
lsblk_json() { stub lsblk "cat <<'EOF'
$1
EOF"; }

test_check_target_automounted_sd_card_ok() {
  lsblk_json '{"blockdevices":[{"path":"/dev/mmcblk0","type":"disk","rm":false,"tran":"mmc","mountpoints":[null],
    "children":[{"path":"/dev/mmcblk0p1","type":"part","mountpoints":["/run/media/nat/bootfs"]},
                {"path":"/dev/mmcblk0p2","type":"part","mountpoints":["/run/media/nat/rootfs"]}]}]}'
  check "target: auto-mounted SD card accepted" "$ROOT/disk/check-target" /dev/mmcblk0
}

test_check_target_usb_reader_ok() {
  lsblk_json '{"blockdevices":[{"path":"/dev/sdb","type":"disk","rm":true,"tran":"usb","mountpoints":[null]}]}'
  check "target: blank USB disk accepted" "$ROOT/disk/check-target" /dev/sdb
}

test_check_target_refuses_system_disks() {
  lsblk_json '{"blockdevices":[{"path":"/dev/nvme0n1","type":"disk","rm":false,"tran":"nvme","mountpoints":[null],
    "children":[{"path":"/dev/nvme0n1p1","type":"part","mountpoints":["/boot/efi"]}]}]}'
  check "target: nvme refused" fails "$ROOT/disk/check-target" /dev/nvme0n1
  # util-linux 2.41 lists mapped devices on the disk before the disk itself.
  lsblk_json '{"blockdevices":[{"path":"/dev/mapper/luks-x","type":"crypt","rm":false,"tran":null,"mountpoints":["/var/home"]},
    {"path":"/dev/sde","type":"disk","rm":true,"tran":"usb","mountpoints":[null],
     "children":[{"path":"/dev/sde1","type":"part","mountpoints":[null],
       "children":[{"path":"/dev/mapper/luks-x","type":"crypt","mountpoints":["/var/home"]}]}]}]}'
  check "target: mapped-first listing still refused for the right reason" \
    stderr_has "in use by /dev/mapper/luks-x" "$ROOT/disk/check-target" /dev/sde
  lsblk_json '{"blockdevices":[{"path":"/dev/sdc","type":"disk","rm":true,"tran":"usb","mountpoints":[null],
    "children":[{"path":"/dev/sdc1","type":"part","mountpoints":["/var/home"]}]}]}'
  check "target: USB disk in system use refused" fails "$ROOT/disk/check-target" /dev/sdc
  lsblk_json '{"blockdevices":[{"path":"/dev/sdd","type":"disk","rm":true,"tran":"usb","mountpoints":[null],
    "children":[{"path":"/dev/sdd1","type":"part","mountpoints":[null],
      "children":[{"path":"/dev/mapper/x","type":"crypt","mountpoints":[null]}]}]}]}'
  check "target: disk holding a mapped device refused" fails "$ROOT/disk/check-target" /dev/sdd
  lsblk_json '{"blockdevices":[{"path":"/dev/sda","type":"disk","rm":false,"tran":"sata","mountpoints":[null]}]}'
  check "target: internal SATA refused" fails "$ROOT/disk/check-target" /dev/sda
  lsblk_json '{"blockdevices":[{"path":"/dev/mmcblk0p1","type":"part","rm":false,"tran":null,"mountpoints":[null]}]}'
  check "target: partition refused" fails "$ROOT/disk/check-target" /dev/mmcblk0p1
}

# greetd shows its text login (agreety) first; niri starts only after PAM authentication.
test_greetd_login_prompt_first() {
  local c=$ROOT/system_files_desktop/etc/greetd/config.toml
  check "greetd: no auto-login (no initial_session)" fails grep -q initial_session "$c"
  check "greetd: agreety starts niri-session" grep -qx 'command = "agreety --cmd niri-session"' "$c"
  check "greetd: greeter runs as greetd" grep -qx 'user = "greetd"' "$c"
  check "greetd: no lock-first spawn in niri defaults" fails grep -q lock-first \
    "$ROOT/system_files_desktop/usr/share/juniper/niri/juniper.kdl"
}

test_desktop_idle_lock() {
  export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config
  stub swayidle ''
  "$LIBEXEC_DESKTOP/desktop-idle-lock"
  check "idle-lock: locks after 10 min" called "swayidle -w timeout 600 swaylock -f"
  mkdir -p "$XDG_CONFIG_HOME/juniper" && touch "$XDG_CONFIG_HOME/juniper/no-idle-lock"
  : >"$CALLS"
  "$LIBEXEC_DESKTOP/desktop-idle-lock"
  check "idle-lock: off -> idle hint only" called "swayidle -w idlehint 1800"
  check "idle-lock: off -> no lock" not_called "swaylock"
}

test_flatpak_setup_installs_apps_once() {
  stub flatpak ''
  stub runuser ''
  "$LIBEXEC_DESKTOP/flatpak-setup" >/dev/null
  check "flatpak: installs Firefox and Bazaar from flathub" \
    called "flatpak install --system --noninteractive --or-update flathub org.mozilla.firefox io.github.kolunmi.Bazaar"
  check "flatpak: marked done" test -e "$JUNIPER_STATE_DIR/flatpak-setup.done"
}

test_flatpak_setup_offline_retries() {
  stub flatpak 'exit 1'
  check "flatpak: failure is reported" fails "$LIBEXEC_DESKTOP/flatpak-setup"
  check "flatpak: failure not marked done (retried next boot)" test ! -e "$JUNIPER_STATE_DIR/flatpak-setup.done"
}

idle_env() {
  export JUNIPER_NOW=2000000000 JUNIPER_APPLY_UPDATE=$LIBEXEC/apply-update
  stub bootc 'echo "{\"status\":{\"staged\":{}}}"'
  stub runuser ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub loginctl 'case "$1" in
    list-sessions) echo "3 1000 nat seat0 tty1" ;;
    show-session) case "$4" in Type) echo wayland ;; Active) echo yes ;; IdleHint) echo "${IDLE:-no}" ;; esac ;;
  esac'
}

test_desktop_idle_defers_active_session() {
  idle_env
  check "idle: active desktop -> skip" fails "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: first deferral recorded" test "$(cat "$JUNIPER_STATE_DIR/reboot-deferred-since")" = 2000000000
}

test_desktop_idle_proceeds_when_idle_or_nothing_staged() {
  idle_env
  IDLE=yes "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: idle session -> reboot" test $? = 0
  stub bootc 'echo "{\"status\":{\"staged\":null}}"'
  check "idle: nothing staged -> no deferral" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: nothing staged -> marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_cap() {
  idle_env
  mkdir -p "$JUNIPER_STATE_DIR"
  echo $((2000000000 - 7 * 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: deferred 7 days -> reboot anyway" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: cap clears the marker" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_under_cap_keeps_deferring() {
  idle_env
  echo $((2000000000 - 6 * 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: deferred 6 days -> still skip" fails "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: marker kept" test -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_idle_clears_marker() {
  idle_env
  echo $((2000000000 - 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: idle again -> reboot" env IDLE=yes "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: idle -> marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_fails_toward_reboot() {
  idle_env
  echo garbage >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: garbled marker -> reboot" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: garbled marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
  idle_env
  stub loginctl 'exit 1'
  check "idle: loginctl failing -> reboot" "$LIBEXEC_DESKTOP/desktop-idle"
}

test_desktop_idle_notify_is_best_effort() {
  idle_env
  stub runuser 'exit 1'
  stub getent 'exit 2'
  rc=0
  "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || rc=$?
  check "idle: notify trouble still exits 1 (skip, not error)" test $rc = 1
}

# One "update ready" notice when the deferral starts, then at most one a day (the hourly retry
# runs the same check), with the real deadline: first deferral + 7 days.
notify_env() {
  idle_env
  export JUNIPER_USER_BUS=$T/bus
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$JUNIPER_USER_BUS"
  # shellcheck disable=SC2016 # expands inside the stub
  stub getent '[[ "$1 $2" == "passwd 1000" ]] && echo "nat:x:1000:1000::/var/home/nat:/bin/bash"'
}

test_desktop_idle_notifies_once_with_deadline() {
  notify_env
  local deadline
  deadline=$(date -d @$((2000000000 + 7 * 86400)) '+%a %-d %b %H:%M')
  "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  check "notify: first deferral -> notice for uid 1000" called "runuser -u nat"
  check "notify: on uid 1000's session bus" called "DBUS_SESSION_BUS_ADDRESS=unix:path=$T/bus"
  check "notify: shows the deadline" called "$deadline"
  : >"$CALLS"
  JUNIPER_NOW=$((2000000000 + 3600)) "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  check "notify: hourly retry -> no repeat" not_called "runuser"
  JUNIPER_NOW=$((2000000000 + 86400 + 60)) "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  check "notify: a day later -> one reminder" called "runuser -u nat"
  check "notify: reminder keeps the first deadline" called "$deadline"
}

test_desktop_idle_notify_resets_after_reboot_allowed() {
  notify_env
  "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  IDLE=yes "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null
  check "notify: allowed reboot clears the notice marker" test ! -e "$JUNIPER_STATE_DIR/reboot-notified"
  : >"$CALLS"
  JUNIPER_NOW=$((2000000000 + 3600)) "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  check "notify: a new deferral notifies again" called "runuser -u nat"
}

# A held (quarantined) update won't be applied: no "Update ready" notice, no deferral. The
# window's apply-update then declines it.
test_desktop_idle_held_update_no_notice_no_deferral() {
  notify_env
  echo "$BAD 2 boot-2" >"$JUNIPER_STATE_DIR/bad-digests"
  stub bootc "echo '{\"status\":{\"staged\":{\"image\":{\"imageDigest\":\"$BAD\"}}}}'"
  check "idle: held update -> no deferral (exit 0)" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: held update -> no notice" not_called "runuser"
  check "idle: held update -> no deferral recorded" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
  echo $((2000000000 - 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || true
  check "idle: held update -> an old deferral isn't extended" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_one_strike_still_defers() {
  notify_env
  echo "$BAD 1 boot-1" >"$JUNIPER_STATE_DIR/bad-digests"
  stub bootc "echo '{\"status\":{\"staged\":{\"image\":{\"imageDigest\":\"$BAD\"}}}}'"
  check "idle: one strike, desktop in use -> defer" fails "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: one strike -> notice sent" called "runuser -u nat"
}

test_desktop_idle_any_active_nonidle_session_defers() {
  idle_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub loginctl 'case "$1" in
    list-sessions) printf "3 1000 nat seat0 tty1\n4 1000 nat seat0 tty2\n" ;;
    show-session) case "$4" in Type) echo wayland ;; Active) echo yes ;; IdleHint) [[ $2 == 3 ]] && echo yes || echo no ;; esac ;;
  esac'
  check "idle: one idle + one busy session -> skip" fails "$LIBEXEC_DESKTOP/desktop-idle"
}

test_desktop_idle_ignores_non_graphical_sessions() {
  idle_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub loginctl 'case "$1" in
    list-sessions) echo "5 1000 nat seat0 pts/0" ;;
    show-session) case "$4" in Type) echo tty ;; Active) echo yes ;; IdleHint) echo no ;; esac ;;
  esac'
  check "idle: ssh/tty-only session -> reboot" "$LIBEXEC_DESKTOP/desktop-idle"
}

test_desktop_idle_future_marker() {
  idle_env
  echo $((2000000000 + 86400)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: future marker -> reboot" "$LIBEXEC_DESKTOP/desktop-idle"
  check "idle: future marker cleared" test ! -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

test_desktop_idle_cap_boundaries() {
  idle_env
  echo $((2000000000 - 7 * 86400 - 1800)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: 7d+30min (hourly retry) -> reboot" "$LIBEXEC_DESKTOP/desktop-idle"
  echo $((2000000000 - 7 * 86400 + 1)) >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  check "idle: 1s short of 7d -> skip" fails "$LIBEXEC_DESKTOP/desktop-idle"
}

test_desktop_idle_leading_zero_marker() {
  idle_env
  echo "0$((2000000000 - 86400))" >"$JUNIPER_STATE_DIR/reboot-deferred-since"
  rc=0
  "$LIBEXEC_DESKTOP/desktop-idle" >/dev/null || rc=$?
  check "idle: leading-zero marker read as decimal (skip, marker kept)" test "$rc" = 1 -a -e "$JUNIPER_STATE_DIR/reboot-deferred-since"
}

# `ujust update-schedule off` disables juniper-reboot.timer; the hourly retry must honour it.
test_reboot_retry_honours_update_schedule_off() {
  local u=$ROOT/system_files_desktop/usr/lib/systemd/system/juniper-reboot-retry.service
  check "retry: skipped while automatic reboots are off" \
    grep -qx 'ExecCondition=/usr/bin/systemctl is-enabled --quiet juniper-reboot.timer' "$u"
  check "retry: that check comes before the idle check" \
    test "$(grep -m1 '^ExecCondition=' "$u")" = 'ExecCondition=/usr/bin/systemctl is-enabled --quiet juniper-reboot.timer'
  check "update-schedule off: disables juniper-reboot.timer" \
    grep -q 'systemctl disable --now juniper-reboot.timer' "$LIBEXEC/update-schedule"
}

switch_env() {
  export USER=nat T JUNIPER_APPLY_UPDATE=apply-update
  # shellcheck disable=SC2016 # expands inside the stub
  stub sudo '"$@"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then echo "nat ${PW_STATUS:-LK} 2026-10-10 0 99999 7 -1"; else echo set >"$T/pw-set"; fi'
  stub apply-update ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub getent '[[ "$1 $2" == "passwd 1000" && -z ${NO_UID_1000:-} ]] && echo "nat:x:1000:1000::/var/home/nat:/bin/bash" || exit 2'
}

test_switch_desktop_without_password_asks_first() {
  switch_env
  # Status flips to PS once passwd has run.
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then [[ -e $T/pw-set ]] && s=PS || s=LK; echo "nat $s 2026-10-10 0 99999 7 -1"; else touch "$T/pw-set"; fi'
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest >/dev/null
  check "switch: asked for a password" called "passwd nat"
  check "switch: then switched" called "bootc switch ghcr.io/gnathoi/juniper-desktop:latest"
}

test_switch_desktop_refuses_if_still_no_password() {
  switch_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then echo "nat LK 2026-10-10 0 99999 7 -1"; fi'
  check "switch: still no password -> no switch" fails "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest
  check "switch: nothing staged" not_called "bootc switch"
}

# The desktop logs in uid 1000 at the screen: that account's password counts, whoever runs it.
test_switch_desktop_as_root_checks_uid_1000() {
  switch_env
  export USER=root
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then [[ -e $T/pw-set ]] && s=PS || s=LK; echo "$2 $s 2026-10-10 0 99999 7 -1"; else touch "$T/pw-set"; fi'
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest >/dev/null
  check "switch as root: checks uid 1000's password" called "passwd -S nat"
  check "switch as root: sets uid 1000's password" called "passwd nat"
  check "switch as root: never root's" not_called "passwd root"
  check "switch as root: then switched" called "bootc switch ghcr.io/gnathoi/juniper-desktop:latest"
}

test_switch_desktop_other_user_checks_uid_1000() {
  switch_env
  export USER=alice
  # nat (uid 1000) has a password; alice doesn't matter.
  # shellcheck disable=SC2016 # expands inside the stub
  stub passwd 'if [[ $1 == -S ]]; then [[ $2 == nat ]] && s=PS || s=LK; echo "$2 $s 2026-10-10 0 99999 7 -1"; else touch "$T/pw-set"; fi'
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest >/dev/null
  check "switch, second user: checks uid 1000" called "passwd -S nat"
  check "switch, second user: not the caller" not_called "passwd -S alice"
  check "switch, second user: no password prompt" test ! -e "$T/pw-set"
  check "switch, second user: switched" called "bootc switch ghcr.io/gnathoi/juniper-desktop:latest"
}

test_switch_desktop_refuses_without_uid_1000() {
  switch_env
  check "switch: no uid 1000 -> refused with a reason" stderr_has "uid 1000" \
    env NO_UID_1000=1 "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-desktop:latest
  check "switch: no uid 1000 -> nothing staged" not_called "bootc switch"
}

test_switch_headless_needs_no_password() {
  switch_env
  "$LIBEXEC/switch-image" ghcr.io/gnathoi/juniper-minimal:latest >/dev/null
  check "switch: headless -> no password check" not_called "passwd -S"
  check "switch: headless switched" called "bootc switch ghcr.io/gnathoi/juniper-minimal:latest"
}

# --- trust-images + containers-policy: Juniper's base policy plus per-namespace drop-ins ---
trust_env() {
  export JUNIPER_POLICY_BASE=$T/base/policy.json JUNIPER_POLICY=$T/containers/policy.json \
    JUNIPER_TRUST_DIR=$T/trusted-images.d JUNIPER_TRUST_DIR_USR=$T/usr-trusted-images.d \
    JUNIPER_REGISTRIES_D=$T/containers/registries.d \
    JUNIPER_KEY_DIR=$T/pki JUNIPER_OWN_KEY=/usr/share/pki/containers/juniper.pub \
    JUNIPER_CONTAINERS_POLICY=$LIBEXEC/containers-policy
  mkdir -p "$T/base" "$JUNIPER_REGISTRIES_D"
  cat >"$JUNIPER_POLICY_BASE" <<'EOF'
{
  "default": [{"type": "insecureAcceptAnything"}],
  "transports": {
    "docker": {
      "registry.redhat.io": [{"type": "sigstoreSigned", "keyPath": "/etc/pki/sigstore/SIGSTORE-redhat-release3",
        "rekorPublicKeyPath": "/etc/pki/sigstore/REKOR-signing-key"}],
      "ghcr.io/gnathoi": [{"type": "sigstoreSigned", "keyPath": "/usr/share/pki/containers/juniper.pub",
        "signedIdentity": {"type": "matchRepository"}}]
    },
    "docker-daemon": {"": [{"type": "insecureAcceptAnything"}]}
  }
}
EOF
  cp "$JUNIPER_POLICY_BASE" "$JUNIPER_POLICY"
  printf 'docker:\n  ghcr.io/gnathoi:\n    use-sigstore-attachments: true\n' >"$JUNIPER_REGISTRIES_D/juniper.yaml"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$T/cosign.key" 2>/dev/null
  openssl pkey -in "$T/cosign.key" -pubout -out "$T/cosign.pub"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null |
    openssl pkey -pubout -out "$T/other.pub"
  # skopeo parses the policy strictly and only then trips over the dummy source name. This one
  # rejects any policy that mentions ghcr.io/skopeo-rejects.
  # shellcheck disable=SC2016 # expands inside the stub
  stub skopeo 'if grep -q skopeo-rejects "$2"; then echo "Error loading trust policy: bad" >&2; else echo "Invalid source name juniper-policy-check:" >&2; fi; exit 1'
  cp "$JUNIPER_POLICY" "$T/policy.orig"
}
trust() { "$LIBEXEC/trust-images" "$@"; }
# shellcheck disable=SC2120 # --check is passed through check
gen() { "$LIBEXEC/containers-policy" "$@"; }
pol() { jq -c "$1" "$JUNIPER_POLICY"; }
ns_entry() { jq -c --arg ns "$1" '.transports.docker[$ns]' "$JUNIPER_POLICY"; }
juniper_entry_kept() { test "$(ns_entry ghcr.io/gnathoi)" = "$(jq -c '.transports.docker["ghcr.io/gnathoi"]' "$JUNIPER_POLICY_BASE")"; }
others_kept() { # everything but transports.docker["$1"] is as in the base
  test "$(jq -cS --arg ns "$1" 'del(.transports.docker[$ns])' "$JUNIPER_POLICY")" = \
    "$(jq -cS --arg ns "$1" 'del(.transports.docker[$ns])' "$JUNIPER_POLICY_BASE")"
}
dropin() { # FILE NAMESPACE [JSON-REQUIREMENTS]
  local r='[{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/x.pub"}]'
  mkdir -p "$JUNIPER_TRUST_DIR"
  jq -n --arg ns "$2" --argjson r "${3:-$r}" '{($ns): $r}' >"$JUNIPER_TRUST_DIR/$1"
}

test_containers_policy_base_only() {
  trust_env
  echo '{"default": [{"type": "reject"}], "transports": {"docker": {}}}' >"$JUNIPER_POLICY"
  gen 2>/dev/null
  check "policy: base alone is copied byte for byte" cmp -s "$JUNIPER_POLICY" "$JUNIPER_POLICY_BASE"
  check "policy: previous kept as .bak" grep -q reject "$JUNIPER_POLICY.bak"
  check "policy: 0644" test "$(stat -c %a "$JUNIPER_POLICY")" = 644
  rm "$JUNIPER_POLICY.bak"
  gen 2>/dev/null
  check "policy: unchanged -> not rewritten" test ! -e "$JUNIPER_POLICY.bak"
  check "policy: no temp files left" test -z "$(find "$T/containers" -name '*.tmp')"
}

test_containers_policy_merges_dropin() {
  trust_env
  dropin a.json ghcr.io/you
  gen 2>/dev/null
  check "policy: drop-in merged" test "$(ns_entry ghcr.io/you)" = '[{"type":"sigstoreSigned","keyPath":"/etc/pki/containers/x.pub"}]'
  check "policy: base entries kept" others_kept ghcr.io/you
  check "policy: validated by skopeo" called "skopeo --policy"
}

test_containers_policy_protects_juniper() {
  trust_env
  dropin 1.json ghcr.io/gnathoi '[{"type": "sigstoreSigned", "keyPath": "/tmp/evil.pub"}]'
  dropin 2.json ghcr.io/gnathoi/juniper '[{"type": "sigstoreSigned", "keyPath": "/tmp/evil.pub"}]'
  dropin 3.json registry.redhat.io
  dropin 4.json ghcr.io/you
  check "policy: Juniper drop-in logged" stderr_has "1.json: ghcr.io/gnathoi is at or under ghcr.io/gnathoi, .*: Juniper's own namespace" gen
  check "policy: drop-in under Juniper's namespace logged" stderr_has "2.json: ghcr.io/gnathoi/juniper is at or under ghcr.io/gnathoi, .*Juniper's own" gen
  check "policy: base namespace drop-in logged" stderr_has "3.json: registry.redhat.io is at or under registry.redhat.io, which the image's base policy sets; " gen
  check "policy: Juniper entry intact" juniper_entry_kept
  check "policy: no entry under Juniper's namespace" test "$(ns_entry ghcr.io/gnathoi/juniper)" = null
  check "policy: base entries intact" others_kept ghcr.io/you
  check "policy: the valid drop-in still applied" test "$(pol '.transports.docker["ghcr.io/you"][0].type')" = '"sigstoreSigned"'
}

test_containers_policy_skips_invalid_dropins() {
  trust_env
  mkdir -p "$JUNIPER_TRUST_DIR"
  echo '{not json' >"$JUNIPER_TRUST_DIR/broken.json"
  echo '{"a.io/x": [{"type": "sigstoreSigned"}], "b.io/y": [{"type": "sigstoreSigned"}]}' >"$JUNIPER_TRUST_DIR/two.json"
  dropin badns.json 'ghcr.io/You'
  dropin weak.json ghcr.io/weak '[{"type": "insecureAcceptAnything"}]'
  dropin empty.json ghcr.io/empty '[]'
  dropin strict.json ghcr.io/skopeo-rejects
  dropin dup1.json ghcr.io/dup
  dropin dup2.json ghcr.io/dup
  dropin ok.json ghcr.io/ok
  local d
  for d in broken two badns weak empty strict; do
    check "policy: invalid drop-in $d logged" stderr_has "$d.json: .*skipped" gen
  done
  check "policy: duplicate namespace logged" stderr_has "dup2.json: ghcr.io/dup is already set by .*dup1.json" gen
  check "policy: only valid drop-ins merged" test "$(pol '.transports.docker | keys | sort')" = \
    '["ghcr.io/dup","ghcr.io/gnathoi","ghcr.io/ok","registry.redhat.io"]'
  check "policy: generation still succeeds" gen
  check "policy: --check accepts a good drop-in" gen --check "$JUNIPER_TRUST_DIR/ok.json"
  check "policy: --check refuses a weak one" fails gen --check "$JUNIPER_TRUST_DIR/weak.json"
}

test_containers_policy_follows_base() {
  trust_env
  dropin a.json ghcr.io/you
  gen 2>/dev/null
  # A new image ships a changed base: a rotated Juniper key path and a new vendor entry.
  jq '.transports.docker["ghcr.io/gnathoi"][0].keyPaths = ["/usr/share/pki/containers/juniper.pub", "/usr/share/pki/containers/juniper-2.pub"]
    | del(.transports.docker["ghcr.io/gnathoi"][0].keyPath)
    | .transports.docker["quay.io/vendor"] = [{"type": "reject"}]' "$T/policy.orig" >"$JUNIPER_POLICY_BASE"
  gen 2>/dev/null
  check "base change: new Juniper entry in force" test "$(pol '.transports.docker["ghcr.io/gnathoi"][0].keyPaths | length')" = 2
  check "base change: new base entry in force" test "$(pol '.transports.docker["quay.io/vendor"][0].type')" = '"reject"'
  check "base change: drop-in kept" test "$(pol '.transports.docker["ghcr.io/you"][0].type')" = '"sigstoreSigned"'
}

test_containers_policy_bad_base_keeps_policy() {
  trust_env
  echo '{not json' >"$JUNIPER_POLICY_BASE"
  check "bad base: fails" fails gen
  check "bad base: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
  echo '{"default": [{"type": "insecureAcceptAnything"}], "transports": {"docker": {"ghcr.io/skopeo-rejects": []}}}' >"$JUNIPER_POLICY_BASE"
  check "base skopeo rejects: fails" fails gen
  check "base skopeo rejects: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
}

test_containers_policy_drops_hand_edits() {
  trust_env
  jq '.transports.docker["ghcr.io/hand"] = [{"type": "reject"}]' "$T/policy.orig" >"$JUNIPER_POLICY"
  check "hand edit: dropping logged" stderr_has 'dropping docker "ghcr.io/hand"' gen
  check "hand edit: gone" test "$(ns_entry ghcr.io/hand)" = null
}

test_trust_images_adds_namespace() {
  trust_env
  trust ghcr.io/you "$T/cosign.pub" >/dev/null 2>&1
  local key=$JUNIPER_KEY_DIR/ghcr.io+you.pub
  check "trust: key installed" cmp -s <(openssl pkey -pubin -in "$key" -outform DER) <(openssl pkey -pubin -in "$T/cosign.pub" -outform DER)
  check "trust: key 0644" test "$(stat -c %a "$key")" = 644
  check "trust: drop-in written" test "$(jq -c . "$JUNIPER_TRUST_DIR/ghcr.io+you.json")" = \
    "{\"ghcr.io/you\":[{\"type\":\"sigstoreSigned\",\"keyPath\":\"$key\",\"signedIdentity\":{\"type\":\"matchRepository\"}}]}"
  check "trust: sigstoreSigned entry in policy" test "$(ns_entry ghcr.io/you)" = \
    "[{\"type\":\"sigstoreSigned\",\"keyPath\":\"$key\",\"signedIdentity\":{\"type\":\"matchRepository\"}}]"
  check "trust: base entries kept" others_kept ghcr.io/you
  check "trust: backup of the previous policy" cmp -s "$JUNIPER_POLICY.bak" "$T/policy.orig"
  check "trust: base untouched" cmp -s "$JUNIPER_POLICY_BASE" "$T/policy.orig"
  check "trust: sigstore attachments on" grep -qx '  ghcr.io/you:' "$JUNIPER_REGISTRIES_D/ghcr.io+you.yaml"
  check "trust: sigstore attachments true" grep -qx '    use-sigstore-attachments: true' "$JUNIPER_REGISTRIES_D/ghcr.io+you.yaml"
  check "trust: juniper.yaml untouched" test "$(cat "$JUNIPER_REGISTRIES_D/juniper.yaml")" = "$(printf 'docker:\n  ghcr.io/gnathoi:\n    use-sigstore-attachments: true')"
  check "trust: no temp files left" test -z "$(find "$T/containers" "$JUNIPER_KEY_DIR" "$JUNIPER_TRUST_DIR" -name '*.tmp*')"
}

test_trust_images_replaces_idempotently() {
  trust_env
  trust ghcr.io/you/app "$T/cosign.pub" >/dev/null 2>&1
  trust ghcr.io/you/app "$T/cosign.pub" >/dev/null 2>&1
  check "trust twice: one entry" test "$(pol '.transports.docker["ghcr.io/you/app"] | length')" = 1
  check "trust twice: one drop-in" test "$(find "$JUNIPER_TRUST_DIR" -type f | wc -l)" = 1
  local before
  before=$(cat "$JUNIPER_POLICY")
  trust ghcr.io/you/app "$T/other.pub" >/dev/null 2>&1
  check "re-key: policy unchanged (same path)" test "$(cat "$JUNIPER_POLICY")" = "$before"
  check "re-key: new key installed" cmp -s <(openssl pkey -pubin -in "$JUNIPER_KEY_DIR/ghcr.io+you+app.pub" -outform DER) <(openssl pkey -pubin -in "$T/other.pub" -outform DER)
  check "re-key: base entries kept" others_kept ghcr.io/you/app
  check "trust: refuses a namespace the base sets" stderr_has "base policy sets" trust registry.redhat.io "$T/cosign.pub"
}

test_trust_images_lists() {
  trust_env
  trust ghcr.io/you "$T/cosign.pub" >/dev/null 2>&1
  trust registry.example.com:5000/team "$T/other.pub" >/dev/null 2>&1
  dropin zz-skipped.json ghcr.io/gnathoi/x
  cp "$JUNIPER_POLICY" "$T/policy.before"
  check "list: ours" stdout_has "^ghcr.io/you  *$JUNIPER_KEY_DIR/ghcr.io+you.pub$" trust
  check "list: port namespace" stdout_has "^registry.example.com:5000/team  *$JUNIPER_KEY_DIR/registry.example.com=5000+team.pub$" trust
  check "list: Juniper's own, marked" stdout_has "^ghcr.io/gnathoi  */usr/share/pki/containers/juniper.pub (Juniper)" trust
  check "list: image entries marked" stdout_has "^registry.redhat.io .*(image)" trust
  check "list: skipped drop-in shown" stdout_has "^ghcr.io/gnathoi/x .*not applied" trust
  check "list: changes nothing" cmp -s "$JUNIPER_POLICY" "$T/policy.before"
}

test_trust_images_removes() {
  trust_env
  trust ghcr.io/you "$T/cosign.pub" >/dev/null 2>&1
  trust ghcr.io/other "$T/other.pub" >/dev/null 2>&1
  trust --remove ghcr.io/you >/dev/null 2>&1
  check "untrust: entry gone" test "$(ns_entry ghcr.io/you)" = null
  check "untrust: drop-in gone" test ! -e "$JUNIPER_TRUST_DIR/ghcr.io+you.json"
  check "untrust: key gone" test ! -e "$JUNIPER_KEY_DIR/ghcr.io+you.pub"
  check "untrust: registries.d file gone" test ! -e "$JUNIPER_REGISTRIES_D/ghcr.io+you.yaml"
  check "untrust: other trusted namespace kept" test "$(pol '.transports.docker["ghcr.io/other"][0].type')" = '"sigstoreSigned"'
  check "untrust: Juniper entry kept" juniper_entry_kept
  check "untrust: unknown namespace fails" stderr_has "not trusted" trust --remove ghcr.io/nobody
  check "untrust: refuses a base namespace" stderr_has "base policy sets" trust --remove registry.redhat.io
  trust --remove ghcr.io/other >/dev/null 2>&1
  check "untrust all: back to the base byte for byte" cmp -s "$JUNIPER_POLICY" "$JUNIPER_POLICY_BASE"
}

test_trust_images_refuses_juniper_namespace() {
  trust_env
  check "trust: refuses Juniper's namespace" stderr_has "Juniper" trust ghcr.io/gnathoi "$T/cosign.pub"
  check "trust: refuses a repo under it" fails trust ghcr.io/gnathoi/juniper "$T/cosign.pub"
  check "untrust: refuses Juniper's namespace" stderr_has "Juniper" trust --remove ghcr.io/gnathoi
  check "untrust: refuses a repo under it" fails trust --remove ghcr.io/gnathoi/juniper-minimal
  check "juniper: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
  check "juniper: no key installed" test ! -e "$JUNIPER_KEY_DIR"
  check "juniper: no drop-in" test ! -e "$JUNIPER_TRUST_DIR"
}

test_trust_images_rejects_bad_namespace() {
  trust_env
  local bad
  for bad in '' 'you/app' 'ghcr.io/You' 'ghcr.io/you/app:latest' 'ghcr.io/you@sha256:abc' \
    '*.example.com' 'ghcr.io/*' 'ghcr.io/you/' 'ghcr.io//you' '-x.io/a' 'ghcr.io/a b' 'ghcr.io/../x' "ghcr.io/a\$(id)"; do
    check "trust: rejects namespace '$bad'" stderr_has "namespace" trust "$bad" "$T/cosign.pub"
  done
  check "bad namespace: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
  check "trust: accepts localhost:5000/x" trust localhost:5000/x "$T/cosign.pub"
}

test_trust_images_rejects_bad_key() {
  trust_env
  echo 'not a key' >"$T/junk.pub"
  check "trust: rejects a non-PEM file" stderr_has "PEM public key" trust ghcr.io/you "$T/junk.pub"
  check "trust: rejects a private key" stderr_has "private key" trust ghcr.io/you "$T/cosign.key"
  check "trust: rejects a missing file" fails trust ghcr.io/you "$T/missing.pub"
  sed 's/A/B/g' "$T/cosign.pub" >"$T/mangled.pub"
  check "trust: rejects a mangled key" fails trust ghcr.io/you "$T/mangled.pub"
  check "trust: needs both arguments" fails trust ghcr.io/you
  check "bad key: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
  check "bad key: nothing installed" test ! -e "$JUNIPER_KEY_DIR/ghcr.io+you.pub" -a ! -e "$JUNIPER_REGISTRIES_D/ghcr.io+you.yaml" -a ! -e "$JUNIPER_TRUST_DIR"
}

test_trust_images_refuses_invalid_policy() {
  trust_env
  check "invalid: refused" stderr_has "invalid" trust ghcr.io/skopeo-rejects "$T/cosign.pub"
  check "invalid: policy untouched" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
  check "invalid: nothing installed" test ! -e "$JUNIPER_KEY_DIR" -a ! -e "$JUNIPER_TRUST_DIR"
  echo '{not json' >"$JUNIPER_POLICY_BASE"
  check "broken base: refused" fails trust ghcr.io/you "$T/cosign.pub"
  check "broken base: policy left as it was" cmp -s "$JUNIPER_POLICY" "$T/policy.orig"
}

# registries.d: a scope declared in two files is an error that breaks every pull.
test_trust_images_keeps_existing_registries_d_entry() {
  trust_env
  printf 'docker:\n  ghcr.io/you/sensor-box:\n    use-sigstore-attachments: true\n' >"$JUNIPER_REGISTRIES_D/sensor-box.yaml"
  check "existing scope: noted" stdout_has "sensor-box.yaml" trust ghcr.io/you/sensor-box "$T/cosign.pub"
  check "existing scope: no second file" test ! -e "$JUNIPER_REGISTRIES_D/ghcr.io+you+sensor-box.yaml"
  check "existing scope: still trusted" test "$(pol '.transports.docker["ghcr.io/you/sensor-box"][0].type')" = '"sigstoreSigned"'
}

test_trust_images_recipes() {
  local j=$ROOT/system_files/usr/share/juniper/just/update.just
  check "recipe: trust-images wraps the script" grep -q '/usr/libexec/juniper/trust-images' "$j"
  check "recipe: untrust-images uses --remove" grep -q 'trust-images --remove' "$j"
  check "recipe: listing needs no sudo" grep -q 'if namespace == "" { "" } else { "sudo" }' "$j"
}

# Any scope the base sets, in any transport and whatever its key format, protects itself and what
# sits under it (by path component); broader scopes stay allowed.
test_containers_policy_guards_every_base_scope() {
  trust_env
  # Juniper rotated to keyPaths; a vendor scope in another transport; a hostname wildcard.
  jq '.transports.docker["ghcr.io/gnathoi"] = [{"type": "sigstoreSigned", "keyPaths": ["/usr/share/pki/containers/juniper.pub", "/usr/share/pki/containers/juniper-2.pub"],
        "signedIdentity": {"type": "matchRepository"}}]
    | .transports.atomic = {"quay.io/vendor": [{"type": "reject"}]}
    | .transports.docker["*.example.com"] = [{"type": "reject"}]' "$T/policy.orig" >"$JUNIPER_POLICY_BASE"
  dropin a.json ghcr.io/gnathoi/juniper-minimal '[{"type": "sigstoreSigned", "keyPath": "/tmp/evil.pub"}]'
  dropin b.json registry.redhat.io/ubi9
  dropin c.json quay.io/vendor/app
  dropin d.json a.example.com/x
  dropin e.json ghcr.io/gnathoi2
  dropin f.json ghcr.io
  check "guard: keyPaths-rotated Juniper sub-scope logged" stderr_has "a.json: .*under ghcr.io/gnathoi, .*Juniper's own namespace" gen
  check "guard: sub-scope of another base entry logged" stderr_has "b.json: .*under registry.redhat.io" gen
  check "guard: scope of another transport logged" stderr_has "c.json: .*under quay.io/vendor, .*(atomic)" gen
  check "guard: hostname wildcard logged" stderr_has "d.json: .*under \\*.example.com" gen
  check "guard: Juniper sub-scope not merged" test "$(ns_entry ghcr.io/gnathoi/juniper-minimal)" = null
  check "guard: base sub-scope not merged" test "$(ns_entry registry.redhat.io/ubi9)" = null
  check "guard: prefix that isn't a component (gnathoi2) allowed" test "$(pol '.transports.docker["ghcr.io/gnathoi2"][0].type')" = '"sigstoreSigned"'
  check "guard: broader scope (ghcr.io) allowed" test "$(pol '.transports.docker["ghcr.io"][0].type')" = '"sigstoreSigned"'
  # shellcheck disable=SC2016 # jq variables
  check "guard: every base scope unchanged" jq -e --slurpfile b "$JUNIPER_POLICY_BASE" '. as $n | $b[0].transports
    | to_entries | all(.key as $t | .value | to_entries | all(.key as $s | $n.transports[$t][$s] == .value))' "$JUNIPER_POLICY"
  check "guard: --protected names the scope" stdout_has "under ghcr.io/gnathoi, .*Juniper's own" gen --protected ghcr.io/gnathoi/juniper-minimal
  check "guard: --protected is quiet for a free namespace" fails gen --protected ghcr.io/gnathoi2
  check "trust: refuses keyPaths-rotated Juniper sub-scope" stderr_has "Juniper's own namespace" trust ghcr.io/gnathoi/juniper-minimal "$T/cosign.pub"
  check "trust: refuses base sub-scope" stderr_has "base policy sets" trust registry.redhat.io/ubi9 "$T/cosign.pub"
  check "trust: allows ghcr.io/gnathoi2" trust ghcr.io/gnathoi2/app "$T/cosign.pub"
}

# Derived images ship drop-ins (and keys) under /usr; a local drop-in for the same scope wins.
test_containers_policy_image_dropins() {
  trust_env
  mkdir -p "$JUNIPER_TRUST_DIR_USR/keys"
  cp "$T/cosign.pub" "$JUNIPER_TRUST_DIR_USR/keys/you.pub"
  printf '{"ghcr.io/you": [{"type": "sigstoreSigned", "keyPath": "%s"}]}\n' "$JUNIPER_TRUST_DIR_USR/keys/you.pub" >"$JUNIPER_TRUST_DIR_USR/you.json"
  printf '{"ghcr.io/shared": [{"type": "sigstoreSigned", "keyPath": "/usr/image.pub"}]}\n' >"$JUNIPER_TRUST_DIR_USR/shared.json"
  echo '{"default": [{"type": "reject"}]}' >"$JUNIPER_TRUST_DIR_USR/default.json"
  printf '{"ghcr.io/gnathoi/x": [{"type": "sigstoreSigned", "keyPath": "/tmp/evil.pub"}]}\n' >"$JUNIPER_TRUST_DIR_USR/evil.json"
  dropin shared.json ghcr.io/shared '[{"type": "sigstoreSigned", "keyPath": "/etc/local.pub"}]'
  check "image drop-in: local override logged" stderr_has "shared.json: overrides the image's .*shared.json for ghcr.io/shared" gen
  check "image drop-in: guarded like local ones" stderr_has "evil.json: .*Juniper's own namespace" gen
  check "image drop-in: merged" test "$(pol '.transports.docker["ghcr.io/you"][0].keyPath')" = "\"$JUNIPER_TRUST_DIR_USR/keys/you.pub\""
  check "image drop-in: local one wins" test "$(pol '.transports.docker["ghcr.io/shared"][0].keyPath')" = '"/etc/local.pub"'
  check "image drop-in: default tightened to reject" test "$(pol '.default')" = '[{"type":"reject"}]'
  check "image drop-in: Juniper entry intact" juniper_entry_kept
  check "list: image drop-in marked" stdout_has "^ghcr.io/you .*(image drop-in)" trust
  check "trust: refuses a namespace an image drop-in sets" stderr_has "already trusted by .*you.json" trust ghcr.io/you "$T/other.pub"
  check "untrust: an image drop-in isn't trust-images'" stderr_has "trusted by .*you.json, not by trust-images" trust --remove ghcr.io/you
}

test_containers_policy_default_only_tightens() {
  trust_env
  mkdir -p "$JUNIPER_TRUST_DIR_USR"
  echo '{"default": [{"type": "insecureAcceptAnything"}]}' >"$JUNIPER_TRUST_DIR_USR/loose.json"
  dropin local-default.json default '[{"type": "reject"}]'
  check "default: loosening refused" stderr_has "loose.json: the default can only be tightened" gen
  check "default: local drop-in can't set it" stderr_has "local-default.json: only an image drop-in" gen
  check "default: unchanged" test "$(pol '.default')" = '[{"type":"insecureAcceptAnything"}]'
}

test_containers_policy_logs_hand_edited_default_and_transports() {
  trust_env
  jq '.default = [{"type": "reject"}] | .transports["docker-daemon"][""] = [{"type": "reject"}]' "$T/policy.orig" >"$JUNIPER_POLICY"
  check "hand edit: default change logged" stderr_has 'default \[{"type":"reject"}\] replaced' gen
  jq '.transports["docker-daemon"][""] = [{"type": "reject"}]' "$T/policy.orig" >"$JUNIPER_POLICY"
  check "hand edit: other transport logged" stderr_has 'different docker-daemon "" entry' gen
  check "hand edit: base restored" cmp -s "$JUNIPER_POLICY" "$JUNIPER_POLICY_BASE"
}

test_containers_policy_check_warns_missing_key() {
  trust_env
  dropin nokey.json ghcr.io/you '[{"type": "sigstoreSigned", "keyPath": "/nonexistent/key.pub"}]'
  check "--check: missing key warned" stderr_has "warning: key /nonexistent/key.pub doesn't exist" gen --check "$JUNIPER_TRUST_DIR/nokey.json"
  check "--check: still accepted" gen --check "$JUNIPER_TRUST_DIR/nokey.json"
}

test_trust_images_refuses_namespace_of_other_dropin() {
  trust_env
  dropin hand.json ghcr.io/you
  check "trust: other local drop-in for it refused" stderr_has "already trusted by .*hand.json" trust ghcr.io/you "$T/cosign.pub"
  check "trust: nothing installed" test ! -e "$JUNIPER_KEY_DIR/ghcr.io+you.pub"
}

# The generated policy must be in place before anything pulls, and follow a new image's base.
test_containers_policy_unit() {
  local u=$ROOT/system_files/usr/lib/systemd/system/juniper-containers-policy.service
  check "policy unit: runs the generator" grep -qx 'ExecStart=/usr/libexec/juniper/containers-policy' "$u"
  check "policy unit: early, before every service" grep -q '^Before=.*sysinit.target' "$u"
  check "policy unit: before updates and auto-update" grep -q '^Before=.*juniper-update.service.*podman-auto-update.service' "$u"
  check "policy unit: enabled at build" grep -q 'juniper-containers-policy.service' "$ROOT/build_files/build.sh"
  check "build: base policy shipped in /usr" grep -q '/usr/share/juniper/containers/policy.json' "$ROOT/build_files/build.sh"
}

ts_join_env() {
  export JUNIPER_TAILSCALE_KEY=$T/authkey JUNIPER_NOW=2000000000 JUNIPER_NTP_SYNCED=yes
  echo "tskey-auth-secret" >"$JUNIPER_TAILSCALE_KEY"
  # A Pi without an RTC stamps files with a bogus clock; the key's mtime must not matter.
  touch -d @0 "$JUNIPER_TAILSCALE_KEY"
}
ts_since() { echo "$1" >"$JUNIPER_STATE_DIR/tailscale-join-since"; }

test_tailscale_join_success_shreds_key() {
  ts_join_env
  : >"$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  ts_since 1999999000
  check "ts join: success exits 0" "$LIBEXEC/tailscale-join"
  check "ts join: joins with ssh and the key file" called "tailscale up --ssh --auth-key=file:$JUNIPER_TAILSCALE_KEY --timeout=120s"
  check "ts join: success shreds the key" test ! -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: success clears a stale marker" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  check "ts join: success clears the since file" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-since"
}

test_tailscale_join_network_failure_keeps_key() {
  ts_join_env
  stub tailscale 'echo "timeout waiting for the backend" >&2; exit 1'
  check "ts join: network failure exits non-zero (systemd retries)" fails "$LIBEXEC/tailscale-join"
  check "ts join: network failure keeps the key" test -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: network failure writes no marker" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
}

test_tailscale_join_rejected_key_gives_up() {
  local msg
  for msg in "invalid key: API key does not exist" \
    "invalid key: API key tskey-abc not valid" \
    "backend error: invalid key: unable to validate API key" \
    "backend error: invalid key: invalid API token"; do
    ts_join_env
    stub tailscale "echo '$msg' >&2; exit 1"
    check "ts join: '$msg' exits 0 (no retry)" "$LIBEXEC/tailscale-join"
    check "ts join: '$msg' shreds the key" test ! -e "$JUNIPER_TAILSCALE_KEY"
    check "ts join: '$msg' writes marker" grep -q rejected "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
    rm -f "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  done
}

test_tailscale_join_loose_words_in_network_error_keep_key() {
  ts_join_env
  stub tailscale 'echo "x509: invalid certificate; key exchange timed out" >&2; exit 1'
  check "ts join: loose 'invalid'/'key' words in a network error fail" fails "$LIBEXEC/tailscale-join"
  check "ts join: ... and keep the key" test -e "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_unsynced_clock_never_expires() {
  ts_join_env
  export JUNIPER_NTP_SYNCED=no
  ts_since 1
  stub tailscale 'echo "no route to host" >&2; exit 1'
  check "ts join: unsynced clock + old since fails (retry)" fails "$LIBEXEC/tailscale-join"
  check "ts join: unsynced clock keeps the key" test -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: unsynced clock gives no marker" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  unset JUNIPER_NTP_SYNCED
}

test_tailscale_join_synced_clock_records_then_expires() {
  ts_join_env
  stub tailscale 'echo "no route to host" >&2; exit 1'
  fails "$LIBEXEC/tailscale-join" || true
  check "ts join: first synced attempt records the time" test "$(cat "$JUNIPER_STATE_DIR/tailscale-join-since")" = 2000000000
  check "ts join: first attempt keeps the key (mtime 1970 irrelevant)" test -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: 15 days later gives up" env JUNIPER_NOW=$((2000000000 + 15 * 86400)) "$LIBEXEC/tailscale-join"
  check "ts join: old key shredded" test ! -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: marker has the reason" grep -q "older than 14 days" "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  check "ts join: give-up clears the since file" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-since"
}

test_tailscale_join_13_days_keeps_key() {
  ts_join_env
  ts_since $((2000000000 - 13 * 86400))
  stub tailscale 'echo "no route to host" >&2; exit 1'
  check "ts join: 13 days + network failure fails" fails "$LIBEXEC/tailscale-join"
  check "ts join: 13 days keeps the key" test -e "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_future_since_rewritten() {
  ts_join_env
  ts_since 2999999999
  stub tailscale 'exit 1'
  fails "$LIBEXEC/tailscale-join" || true
  check "ts join: future since is rewritten" test "$(cat "$JUNIPER_STATE_DIR/tailscale-join-since")" = 2000000000
  check "ts join: future since keeps the key" test -e "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_max_days_override() {
  ts_join_env
  ts_since 1999999999
  check "ts join: max days override gives up" env JUNIPER_TAILSCALE_KEY_MAX_DAYS=0 "$LIBEXEC/tailscale-join"
  check "ts join: override shreds" test ! -e "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_undeletable_key_retries() {
  ts_join_env
  ts_since 1
  stub shred 'exit 1'
  stub rm 'exit 1'
  check "ts join: key that cannot be deleted exits non-zero" fails "$LIBEXEC/tailscale-join"
  check "ts join: no 'deleted' marker while the key survives" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  /usr/bin/rm -f "$T/bin/rm" # the runner cleanup needs the real rm
}

test_tailscale_join_shred_failure_falls_back_to_rm() {
  ts_join_env
  stub shred 'exit 1'
  check "ts join: shred failure still succeeds via rm" "$LIBEXEC/tailscale-join"
  check "ts join: key removed by the fallback" test ! -e "$JUNIPER_TAILSCALE_KEY"
}

test_motd_shows_tailscale_gave_up_only_when_disconnected() {
  echo "key rejected on 2033-05-18" >"$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  stub tailscale 'exit 1'
  check "motd: gave-up shown with recovery" stdout_has "ujust tailscale-up" "$LIBEXEC/motd"
  check "motd: gave-up reason shown" stdout_has "key rejected on 2033-05-18" "$LIBEXEC/motd"
  stub tailscale 'echo 100.64.0.1'
  check "motd: connected hides the stale marker" not_stdout_has "not joined" "$LIBEXEC/motd"
}

# --- lan-ssh ---
# fw_fake: stateful firewall-cmd for the drop zone. Files under $T/fw hold permanent and
# runtime rich rules/services; --reload copies permanent over runtime (dropping --timeout rules).
fw_fake() {
  export T
  export JUNIPER_RUN_DIR=$T/run
  mkdir -p "$T/fw"
  : >"$T/fw/perm_rich" && : >"$T/fw/run_rich" && : >"$T/fw/perm_svc" && : >"$T/fw/run_svc"
  # shellcheck disable=SC2016 # expands inside the stub
  stub firewall-cmd 'cfg=run
for a; do case $a in
  --permanent) cfg=perm ;;
  --add-rich-rule=*) if grep -qxF -- "${a#*=}" "$T/fw/${cfg}_rich"; then echo "Warning: ALREADY_ENABLED" >&2; else echo "${a#*=}" >>"$T/fw/${cfg}_rich"; fi ;;
  --remove-rich-rule=*) grep -vxF -- "${a#*=}" "$T/fw/${cfg}_rich" >"$T/fw/tmp" || true; mv "$T/fw/tmp" "$T/fw/${cfg}_rich" ;;
  --list-rich-rules) cat "$T/fw/${cfg}_rich" ;;
  --add-service=*) echo "${a#*=}" >>"$T/fw/${cfg}_svc" ;;
  --remove-service=*) grep -vxF -- "${a#*=}" "$T/fw/${cfg}_svc" >"$T/fw/tmp" || true; mv "$T/fw/tmp" "$T/fw/${cfg}_svc" ;;
  --query-service=*) grep -qxF -- "${a#*=}" "$T/fw/${cfg}_svc"; exit $? ;;
  --reload) cp "$T/fw/perm_rich" "$T/fw/run_rich"; cp "$T/fw/perm_svc" "$T/fw/run_svc" ;;
esac; done'
}
lan_ip_fixture() {
  stub ip 'case "$*" in
  "-j route show scope link") cat <<J
[{"dst":"169.254.0.0/16","dev":"eth0","scope":"link","metric":1002},
 {"dst":"192.168.1.0/24","dev":"eth0","protocol":"kernel","scope":"link","prefsrc":"192.168.1.20"},
 {"dst":"100.100.0.0/16","dev":"tailscale0","scope":"link"},
 {"dst":"10.9.0.0/16","dev":"wlan0","gateway":"10.9.0.1","scope":"link"},
 {"dst":"172.16.5.0/24","dev":"lo","scope":"link"}]
J
  ;;
  "-j -6 route show") cat <<J
[{"dst":"2001:db8:1::/64","dev":"eth0","protocol":"ra","metric":100},
 {"dst":"fe80::/64","dev":"eth0","protocol":"kernel"},
 {"dst":"fd7a:115c:a1e0::/48","dev":"tailscale0","protocol":"kernel"},
 {"dst":"2001:db8:9::/64","dev":"wlan0","gateway":"fe80::1","protocol":"ra"},
 {"dst":"default","dev":"eth0","gateway":"fe80::1","protocol":"ra"}]
J
  ;;
esac'
}
lan_ip_virt_fixture() {
  stub ip 'case "$*" in
  "-j route show scope link") echo "[{\"dst\":\"192.168.1.0/24\",\"dev\":\"eth0\"},{\"dst\":\"10.88.0.0/16\",\"dev\":\"podman0\"},{\"dst\":\"172.17.0.0/16\",\"dev\":\"docker0\"},{\"dst\":\"192.168.122.0/24\",\"dev\":\"virbr0\"},{\"dst\":\"10.244.1.0/24\",\"dev\":\"cni0\"},{\"dst\":\"10.1.0.0/24\",\"dev\":\"cali123\"},{\"dst\":\"10.2.0.0/24\",\"dev\":\"flannel.1\"},{\"dst\":\"10.3.0.0/24\",\"dev\":\"veth1\"}]" ;;
  "-j -6 route show") echo "[{\"dst\":\"fd00:1::/64\",\"dev\":\"podman1\"}]" ;;
esac'
}
lan_rule() { printf 'rule family="%s" source address="%s" service name="ssh" accept' "$1" "$2"; }
lan_setup() {
  fw_fake
  lan_ip_fixture
}
perm_has() { grep -qxF -- "$(lan_rule "$1" "$2")" "$T/fw/perm_rich"; }
run_has() { grep -qxF -- "$(lan_rule "$1" "$2")" "$T/fw/run_rich"; }

test_lan_ssh_on_defaults_to_onlink_networks() {
  lan_setup
  check "lan-ssh on: runs" "$LIBEXEC/lan-ssh" on
  check "lan-ssh on: v4 on-link" perm_has ipv4 192.168.1.0/24
  check "lan-ssh on: v4 link-local" perm_has ipv4 169.254.0.0/16
  check "lan-ssh on: v6 on-link global /64" perm_has ipv6 2001:db8:1::/64
  check "lan-ssh on: v6 link-local fe80::/10" perm_has ipv6 fe80::/10
  check "lan-ssh on: drop zone" called "--zone=drop --permanent --add-rich-rule"
  check "lan-ssh on: reloaded" called "firewall-cmd --reload"
  check "lan-ssh on: prints sources" stdout_has "192.168.1.0/24" "$LIBEXEC/lan-ssh" on
}

test_lan_ssh_on_excludes_tailscale_lo_and_gatewayed() {
  lan_setup
  "$LIBEXEC/lan-ssh" on >/dev/null
  check "lan-ssh on: no tailscale0 v4" not_grep_dir 100.100.0.0 "$T/fw"
  check "lan-ssh on: no tailscale0 v6" not_grep_dir fd7a "$T/fw"
  check "lan-ssh on: no loopback iface" not_grep_dir 172.16.5.0 "$T/fw"
  check "lan-ssh on: no gatewayed v4 route" not_grep_dir 10.9.0.0 "$T/fw"
  check "lan-ssh on: no gatewayed v6 route" not_grep_dir 2001:db8:9 "$T/fw"
  check "lan-ssh on: no default route" not_grep_dir '0.0.0.0/0\|::/0' "$T/fw"
  check "lan-ssh on: never an unscoped service" not_called "--add-service"
}

test_lan_ssh_on_skips_broad_onlink_route() {
  lan_setup
  stub ip 'case "$*" in "-j route show scope link") echo "[{\"dst\":\"0.0.0.0/0\",\"dev\":\"wwan0\"},{\"dst\":\"10.0.0.0/24\",\"dev\":\"eth0\"}]" ;; esac'
  "$LIBEXEC/lan-ssh" on >/dev/null 2>&1
  check "lan-ssh on: on-link default route skipped" not_grep_dir '0.0.0.0/0' "$T/fw"
  check "lan-ssh on: other route kept" perm_has ipv4 10.0.0.0/24
}

test_lan_ssh_on_skips_container_bridges() {
  lan_setup
  lan_ip_virt_fixture
  "$LIBEXEC/lan-ssh" on >/dev/null
  check "lan-ssh on: real interface kept" perm_has ipv4 192.168.1.0/24
  for n in 10.88.0 172.17 192.168.122 10.244.1 10.1.0 10.2.0 10.3.0 fd00:1; do
    check "lan-ssh on: container/VM net $n skipped" not_grep_dir "$n" "$T/fw"
  done
}

test_lan_ssh_on_is_quiet_about_existing_rules() {
  lan_setup
  "$LIBEXEC/lan-ssh" on 10.1.0.0/24 >/dev/null
  check "lan-ssh on: rerun has no ALREADY_ENABLED noise" not_stderr_has ALREADY_ENABLED "$LIBEXEC/lan-ssh" on 10.1.0.0/24
}

test_lan_ssh_on_no_networks_fails() {
  lan_setup
  stub ip 'echo "[]"'
  check "lan-ssh on: nothing on-link is an error" fails "$LIBEXEC/lan-ssh" on
  check "lan-ssh on: nothing added" not_called "add-rich-rule"
}

test_lan_ssh_on_explicit_cidrs() {
  lan_setup
  check "lan-ssh on CIDR: runs" "$LIBEXEC/lan-ssh" on 10.1.2.0/24 fd00:1::/64 192.168.5.7
  check "lan-ssh on CIDR: v4" perm_has ipv4 10.1.2.0/24
  check "lan-ssh on CIDR: v6" perm_has ipv6 fd00:1::/64
  check "lan-ssh on CIDR: host becomes /32" perm_has ipv4 192.168.5.7/32
  check "lan-ssh on CIDR: no on-link lookup" not_called "ip -j"
  check "lan-ssh on CIDR: nothing else added" not_grep_dir 192.168.1.0 "$T/fw"
}

test_lan_ssh_rejects_bad_and_broad_cidrs() {
  lan_setup
  check "lan-ssh: garbage CIDR refused" fails "$LIBEXEC/lan-ssh" on not-a-cidr
  check "lan-ssh: injection refused" fails "$LIBEXEC/lan-ssh" on '10.0.0.0/24" accept'
  check "lan-ssh: 0.0.0.0/0 refused" fails "$LIBEXEC/lan-ssh" on 0.0.0.0/0
  check "lan-ssh: ::/0 refused" fails "$LIBEXEC/lan-ssh" on ::/0
  check "lan-ssh: /7 refused" fails "$LIBEXEC/lan-ssh" on 10.0.0.0/7
  check "lan-ssh: v6 /15 refused" fails "$LIBEXEC/lan-ssh" on 2000::/15
  check "lan-ssh: one bad CIDR refuses all" fails "$LIBEXEC/lan-ssh" on 10.0.0.0/24 bogus
  check "lan-ssh: refusal says why" stderr_has "too broad" "$LIBEXEC/lan-ssh" on 0.0.0.0/0
  check "lan-ssh: refusals changed nothing" not_called "add-rich-rule"
  check "lan-ssh: explicit fe80::/10 allowed" "$LIBEXEC/lan-ssh" on fe80::/10
  check "lan-ssh: /8 allowed" "$LIBEXEC/lan-ssh" on 10.0.0.0/8
  check "lan-ssh: v6 /16 allowed" "$LIBEXEC/lan-ssh" on 2001::/16
  check "lan-ssh: --force allows broad" "$LIBEXEC/lan-ssh" on --force 0.0.0.0/0
  check "lan-ssh: --force still validates" fails "$LIBEXEC/lan-ssh" on --force nonsense
}

test_lan_ssh_on_replaces_stale_sources_and_legacy() {
  lan_setup
  echo ssh >"$T/fw/perm_svc"
  echo ssh >"$T/fw/run_svc"
  lan_rule ipv4 10.77.0.0/24 >"$T/fw/perm_rich"
  echo >>"$T/fw/perm_rich"
  "$LIBEXEC/lan-ssh" on 192.168.1.0/24 >/dev/null
  check "lan-ssh on: stale source removed" not_grep_dir 10.77.0.0 "$T/fw"
  check "lan-ssh on: legacy permanent service removed" test ! -s "$T/fw/perm_svc"
  check "lan-ssh on: legacy runtime service removed" test ! -s "$T/fw/run_svc"
  check "lan-ssh on: new source present" perm_has ipv4 192.168.1.0/24
}

test_lan_ssh_for_is_runtime_with_timeout() {
  lan_setup
  check "lan-ssh for: runs" "$LIBEXEC/lan-ssh" for 30m
  check "lan-ssh for: timeout passed" called "--timeout=30m"
  check "lan-ssh for: runtime rule" run_has ipv4 192.168.1.0/24
  check "lan-ssh for: not permanent" test ! -s "$T/fw/perm_rich"
  check "lan-ssh for: no reload (would drop it)" not_called "firewall-cmd --reload"
  check "lan-ssh for: hours accepted" "$LIBEXEC/lan-ssh" for 2h 10.0.0.0/24
  check "lan-ssh for: explicit CIDR timed" run_has ipv4 10.0.0.0/24
  : >"$CALLS"
  "$LIBEXEC/lan-ssh" for 1h 172.20.0.0/16 >/dev/null
  check "lan-ssh for: CIDR rule carries timeout" called "--add-rich-rule=rule family=\"ipv4\" source address=\"172.20.0.0/16\" service name=\"ssh\" accept --timeout=1h"
}

test_lan_ssh_for_rejects_bad_duration() {
  lan_setup
  check "lan-ssh for: missing duration" fails "$LIBEXEC/lan-ssh" for
  check "lan-ssh for: junk duration" fails "$LIBEXEC/lan-ssh" for soon
  check "lan-ssh for: zero duration" fails "$LIBEXEC/lan-ssh" for 0m
  check "lan-ssh for: bare number needs a unit" fails "$LIBEXEC/lan-ssh" for 30
  check "lan-ssh for: injection duration" fails "$LIBEXEC/lan-ssh" for '5m --permanent'
  check "lan-ssh for: nothing added" not_called "add-rich-rule"
}

test_lan_ssh_for_keeps_permanent_rules_untimed() {
  lan_setup
  "$LIBEXEC/lan-ssh" on 192.168.1.0/24 >/dev/null
  : >"$CALLS"
  "$LIBEXEC/lan-ssh" for 10m 192.168.1.0/24 >/dev/null
  check "lan-ssh for: already-permanent rule gets no timeout" not_called "--timeout"
}

test_lan_ssh_for_reports_rules_already_open() {
  lan_setup
  "$LIBEXEC/lan-ssh" for 1h 10.2.0.0/24 >/dev/null
  check "lan-ssh for: rerun says already open temporarily" stdout_has "already open temporarily" "$LIBEXEC/lan-ssh" for 5m 10.2.0.0/24
  check "lan-ssh for: rerun doesn't claim the new duration" not_stdout_has "expires in 5m" "$LIBEXEC/lan-ssh" for 5m 10.2.0.0/24
  "$LIBEXEC/lan-ssh" on 10.3.0.0/24 >/dev/null
  check "lan-ssh for: permanent rule reported" stdout_has "already allowed permanently" "$LIBEXEC/lan-ssh" for 5m 10.3.0.0/24
  check "lan-ssh for: no ALREADY_ENABLED noise" not_stderr_has ALREADY_ENABLED "$LIBEXEC/lan-ssh" for 5m 10.2.0.0/24
}

test_lan_ssh_refresh_writes_legacy_status_file() {
  lan_setup
  "$LIBEXEC/lan-ssh" refresh
  check "refresh: no file when not legacy" test ! -e "$JUNIPER_RUN_DIR/lan-ssh-legacy"
  echo ssh >"$T/fw/run_svc"
  "$LIBEXEC/lan-ssh" refresh
  check "refresh: file with the warning when legacy" grep -q "open to every network" "$JUNIPER_RUN_DIR/lan-ssh-legacy"
  "$LIBEXEC/lan-ssh" on 10.0.0.0/24 >/dev/null
  check "on: clears the status file" test ! -e "$JUNIPER_RUN_DIR/lan-ssh-legacy"
  echo ssh >"$T/fw/perm_svc"
  "$LIBEXEC/lan-ssh" refresh
  check "refresh: permanent legacy counts" test -e "$JUNIPER_RUN_DIR/lan-ssh-legacy"
  "$LIBEXEC/lan-ssh" off >/dev/null
  check "off: clears the status file" test ! -e "$JUNIPER_RUN_DIR/lan-ssh-legacy"
}

# The login user reads this file (the banner): a root caller's umask must not hide it.
test_lan_ssh_refresh_pins_modes_whatever_the_umask() {
  lan_setup
  echo ssh >"$T/fw/run_svc"
  (
    umask 077
    "$LIBEXEC/lan-ssh" refresh
  )
  check "refresh: run dir 0755 under umask 077" test "$(stat -c %a "$JUNIPER_RUN_DIR")" = 755
  check "refresh: status file 0644 under umask 077" test "$(stat -c %a "$JUNIPER_RUN_DIR/lan-ssh-legacy")" = 644
  chmod 700 "$JUNIPER_RUN_DIR"
  chmod 600 "$JUNIPER_RUN_DIR/lan-ssh-legacy"
  "$LIBEXEC/lan-ssh" refresh
  check "refresh: existing run dir fixed to 0755" test "$(stat -c %a "$JUNIPER_RUN_DIR")" = 755
  check "refresh: existing status file fixed to 0644" test "$(stat -c %a "$JUNIPER_RUN_DIR/lan-ssh-legacy")" = 644
}

test_lan_ssh_off_removes_everything() {
  lan_setup
  "$LIBEXEC/lan-ssh" on 10.1.0.0/24 fd00::/64 >/dev/null
  "$LIBEXEC/lan-ssh" for 1h 10.2.0.0/24 >/dev/null
  echo ssh >"$T/fw/perm_svc"
  echo ssh >"$T/fw/run_svc"
  check "lan-ssh off: runs" "$LIBEXEC/lan-ssh" off
  check "lan-ssh off: no permanent rules" test ! -s "$T/fw/perm_rich"
  check "lan-ssh off: no runtime rules" test ! -s "$T/fw/run_rich"
  check "lan-ssh off: legacy permanent service gone" test ! -s "$T/fw/perm_svc"
  check "lan-ssh off: legacy runtime service gone" test ! -s "$T/fw/run_svc"
  check "lan-ssh off: tailscale0 untouched" not_called "tailscale0"
  check "lan-ssh off: default zone untouched" not_called "default-zone"
}

test_lan_ssh_status_states() {
  lan_setup
  touch "$JUNIPER_STATE_DIR/locked"
  check "lan-ssh status: off" stdout_has "LAN SSH is off" "$LIBEXEC/lan-ssh" status
  check "lan-ssh bare: same as status" stdout_has "LAN SSH is off" "$LIBEXEC/lan-ssh"
  check "lan-ssh status: off has no legacy warning" not_stdout_has "every network" "$LIBEXEC/lan-ssh" status
  check "lan-ssh legacy: exit 1 when off" fails "$LIBEXEC/lan-ssh" legacy
  "$LIBEXEC/lan-ssh" on 10.1.0.0/24 fd00::/64 >/dev/null
  "$LIBEXEC/lan-ssh" for 1h 10.2.0.0/24 >/dev/null
  check "lan-ssh status: scoped lists v4" stdout_has "10.1.0.0/24" "$LIBEXEC/lan-ssh" status
  check "lan-ssh status: scoped lists v6" stdout_has "fd00::/64" "$LIBEXEC/lan-ssh" status
  check "lan-ssh status: runtime marked temporary" stdout_has "10.2.0.0/24 (temporary" "$LIBEXEC/lan-ssh" status
  check "lan-ssh status: permanent not marked temporary" not_stdout_has "10.1.0.0/24 (temporary" "$LIBEXEC/lan-ssh" status
  check "lan-ssh status: scoped is not legacy" fails "$LIBEXEC/lan-ssh" legacy
  echo ssh >"$T/fw/perm_svc"
  check "lan-ssh status: legacy warns" stdout_has "open to every network; run .ujust lan-ssh on. to scope it" "$LIBEXEC/lan-ssh" status
  check "lan-ssh legacy: exit 0 with warning" stdout_has "open to every network" "$LIBEXEC/lan-ssh" legacy
  rm "$JUNIPER_STATE_DIR/locked"
  check "lan-ssh status: not locked note" stdout_has "not locked down" "$LIBEXEC/lan-ssh" status
}

test_lan_ssh_unknown_subcommand() {
  lan_setup
  check "lan-ssh: unknown subcommand refused" fails "$LIBEXEC/lan-ssh" sideways
  check "lan-ssh: usage on stderr" stderr_has usage "$LIBEXEC/lan-ssh" sideways
}

test_motd_warns_on_legacy_lan_ssh() {
  lan_setup
  stub tailscale 'echo 100.64.0.1'
  touch "$JUNIPER_STATE_DIR/locked"
  check "motd: no status file, no warning" not_stdout_has "every network" "$LIBEXEC/motd"
  echo ssh >"$T/fw/run_svc"
  check "motd: never asks firewalld" not_called "firewall-cmd"
  "$LIBEXEC/lan-ssh" refresh
  check "motd: legacy warning shown" stdout_has "ujust lan-ssh on" "$LIBEXEC/motd"
  rm "$JUNIPER_STATE_DIR/locked"
  check "motd: no warning before lockdown" not_stdout_has "ujust lan-ssh on" "$LIBEXEC/motd"
}

test_pi_status_warns_on_legacy_lan_ssh() {
  check "pi-status: calls lan-ssh legacy" grep -q 'libexec/juniper/lan-ssh legacy' "$ROOT/system_files/usr/share/juniper/just/pi.just"
}

test_just_recipe_wraps_script() {
  check "recipe: thin wrapper" grep -q 'sudo /usr/libexec/juniper/lan-ssh' "$ROOT/system_files/usr/share/juniper/just/network.just"
  check "recipe: not echoed by just" grep -q '^    @sudo /usr/libexec/juniper/lan-ssh' "$ROOT/system_files/usr/share/juniper/just/network.just"
  check "recipe: no inline firewall-cmd" not_grep_dir 'firewall-cmd' "$ROOT/system_files/usr/share/juniper/just/network.just"
}

test_motd_shows_gave_up_and_held_together() {
  stub fastfetch ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl '[[ $* != *is-failed* ]]'
  stub tailscale 'exit 1'
  echo "key rejected on 2033-05-18" >"$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  echo "update $BAD failed its health check twice; waiting for a newer image" >"$JUNIPER_STATE_DIR/update-held"
  export JUNIPER_RUN_DIR=$T/run
  mkdir -p "$JUNIPER_RUN_DIR"
  touch "$JUNIPER_STATE_DIR/locked"
  echo "SSH is open to every network (old lan-ssh rule)" >"$JUNIPER_RUN_DIR/lan-ssh-legacy"
  check "motd: all warnings -> gave-up in the Tailscale row" stdout_has "not joined: key rejected on 2033-05-18" "$LIBEXEC/motd"
  check "motd: all warnings -> held in the Update row" stdout_has "update $BAD failed its health check twice" "$LIBEXEC/motd"
  check "motd: all warnings -> lan-ssh legacy warning" stdout_has "SSH is open to every network (old lan-ssh rule)" "$LIBEXEC/motd"
  unset JUNIPER_RUN_DIR
}

test_pi_status_shows_gave_up_legacy_and_held() {
  local j=$ROOT/system_files/usr/share/juniper/just/pi.just
  check "pi-status: gave-up line kept" grep -q 'tailscale-join-gave-up' "$j"
  check "pi-status: lan-ssh legacy line kept" grep -q 'lan-ssh legacy' "$j"
  check "pi-status: held line kept" grep -q 'update-held' "$j"
}

test_ujust_completion() {
  # shellcheck disable=SC2016 # expands inside the stub
  stub just 'case $3 in
  --summary) echo "lan-ssh pi-eeprom switch update update-schedule tailscale-ssh" ;;
  --show) [[ $4 == pi-eeprom ]] && printf "pi-eeprom action=\"status\":\n    case x in\n      status) a ;;\n      apply|force) b ;;\n      *) c ;;\n    esac\n" ;;
esac'
  comp() { # words... (last = word being completed); prints COMPREPLY
    # shellcheck disable=SC1091
    source "$ROOT/system_files/usr/share/bash-completion/completions/ujust"
    COMP_WORDS=("$@") COMP_CWORD=$(($# - 1))
    _ujust
    echo "${COMPREPLY[*]}"
  }
  check "completion: registered for ujust" bash -c "source '$ROOT/system_files/usr/share/bash-completion/completions/ujust'; complete -p ujust | grep -q '_ujust'"
  check "completion: first word by prefix" test "$(comp ujust up)" = "update update-schedule"
  check "completion: lan-ssh args" test "$(comp ujust lan-ssh '')" = "on off for status"
  check "completion: lan-ssh prefix" test "$(comp ujust lan-ssh f)" = "for"
  check "completion: case patterns from recipe" test "$(comp ujust pi-eeprom '')" = "status apply force"
  check "completion: recipe without fixed args" test -z "$(comp ujust update '')"
  check "completion: just failure is silent" bash -c "PATH=/nonexistent; source '$ROOT/system_files/usr/share/bash-completion/completions/ujust'; COMP_WORDS=(ujust x); COMP_CWORD=1; _ujust 2>&1; test -z \"\${COMPREPLY[*]}\""
}

# --- tests/repo-audit.sh (the image smoke test's repo-key check) ---
repo_dir() { # NAME CONTENT: a one-file repo dir under $T/repos-NAME
  mkdir -p "$T/repos-$1"
  printf '%b' "$2" >"$T/repos-$1/x.repo"
}
audit() { "$ROOT/tests/repo-audit.sh" "$@"; }
test_repo_audit() {
  local k=file:///etc/pki/rpm-gpg/K good
  good="[a]\nname=a\nenabled=1\ngpgcheck=1\ngpgkey=$k\n"
  repo_dir good "$good"
  check "repo-audit: a clean repo passes" audit "$T/repos-good"
  repo_dir truthy "[a]\ngpgcheck=Yes\ngpgkey=$k\n[b]\ngpgcheck=TRUE\ngpgkey=$k\n[c]\ngpgcheck=on\ngpgkey=$k\n"
  check "repo-audit: dnf truthy forms pass" audit "$T/repos-truthy"
  repo_dir cont "[a]\ngpgcheck=1\ngpgkey=$k\n    $k.2\n"
  check "repo-audit: local continuation line passes" audit "$T/repos-cont"
  repo_dir off "[a]\nenabled=0\ngpgcheck=0\ngpgkey=https://x/y\n"
  check "repo-audit: a disabled repo is ignored" audit "$T/repos-off"
  local name body
  while IFS='|' read -r name body; do
    repo_dir "$name" "$body"
    check "repo-audit: refuses $name" not_ok audit "$T/repos-$name"
  done <<EOF
no-check|[a]\ngpgcheck=0\ngpgkey=$k\n
false|[a]\ngpgcheck=False\ngpgkey=$k\n
spaced-zero|[a]\ngpgcheck = 0\ngpgkey=$k\n
unset|[a]\nname=a\ngpgkey=$k\n
garbage|[a]\ngpgcheck=maybe\ngpgkey=$k\n
https-key|[a]\ngpgcheck=1\ngpgkey=https://evil/key\n
second-key|[a]\ngpgcheck=1\ngpgkey=$k https://evil/key\n
comma-key|[a]\ngpgcheck=1\ngpgkey=$k,https://evil/key\n
cont-key|[a]\ngpgcheck=1\ngpgkey=$k\n    https://evil/key\n
other-dir|[a]\ngpgcheck=1\ngpgkey=file:///tmp/key\n
no-key|[a]\ngpgcheck=1\n
upper-key-name|[a]\nGPGCHECK=0\ngpgkey=$k\n
dup-check|[a]\ngpgcheck=0\ngpgcheck=1\ngpgkey=$k\n
second-repo|[a]\ngpgcheck=1\ngpgkey=$k\n[b]\nbaseurl=http://x\n
enabled-garbage|[a]\nenabled=maybe\ngpgcheck=0\ngpgkey=$k\n
EOF
  repo_dir main "[main]\ngpgcheck=0\n[a]\ngpgcheck=1\ngpgkey=$k\n"
  check "repo-audit: a [main] section is skipped" audit "$T/repos-main"
  repo_dir dotdot "[a]\ngpgcheck=1\ngpgkey=$k/../../../tmp/k\n"
  check "repo-audit: refuses a gpgkey path that climbs out" not_ok audit "$T/repos-dotdot"
  repo_dir dotok "[a]\ngpgcheck=1\ngpgkey=file:///etc/pki/./rpm-gpg/x/../K\n"
  check "repo-audit: a normalised in-tree path passes" audit "$T/repos-dotok"
  repo_dir bom "\xef\xbb\xbf[a]\ngpgcheck=0\ngpgkey=https://x\n"
  check "repo-audit: refuses a BOM before the first section" not_ok audit "$T/repos-bom"
  repo_dir preamble "gpgcheck=0\n[a]\ngpgcheck=1\ngpgkey=$k\n"
  check "repo-audit: refuses content before the first section" not_ok audit "$T/repos-preamble"
  repo_dir upper "[a]\nGPGCHECK=1\ngpgkey=$k\n"
  check "repo-audit: an upper-case GPGCHECK counts as unset" not_ok audit "$T/repos-upper"
  repo_dir sameid-1 "[a]\ngpgcheck=1\ngpgkey=$k\n"
  mkdir -p "$T/repos-sameid-2"
  cp "$T/repos-sameid-1/x.repo" "$T/repos-sameid-2/x.repo"
  check "repo-audit: the same id in two dirs is not a duplicate" audit "$T/repos-sameid-1" "$T/repos-sameid-2"
  repo_dir sameid-bad "[a]\ngpgcheck=0\ngpgkey=$k\n"
  check "repo-audit: a shadowed bad repo in another dir is still refused" not_ok audit "$T/repos-sameid-1" "$T/repos-sameid-bad"
  cp "$T/repos-good/x.repo" "$T/repos-good/y.repo"
  check "repo-audit: the same id twice in one dir is refused" not_ok audit "$T/repos-good"
  rm "$T/repos-good/y.repo"
  check "repo-audit: -r wants the repo present" not_ok audit -r missing "$T/repos-good"
  check "repo-audit: -r finds it" audit -r a "$T/repos-good"
  check "repo-audit: -r wants it enabled" not_ok audit -r a "$T/repos-off"
  mkdir "$T/empty"
  check "repo-audit: no repo files is an error" not_ok audit "$T/empty"
}
not_ok() { ! "$@" 2>/dev/null; }

# --- storage budgets (#54) ---
# stub df: prints the next "total avail" (MiB) pair from $T/df-queue (the last one repeats).
stage_env() {
  export JUNIPER_UPDATE_CONF=$T/update.conf
  # shellcheck disable=SC2016 # expands inside the stub
  stub df 'q=$T/df-queue; read -r total avail <"$q"; [[ $(wc -l <"$q") -le 1 ]] || sed -i 1d "$q"
printf "Filesystem 1048576-blocks Used Available Capacity Mounted on\n/dev/x %s 0 %s 0%% /\n" "$total" "$avail"'
  stub podman ''
}
df_queue() { printf '%s\n' "$@" >"$T/df-queue"; }

test_update_stage_enough_space() {
  stage_env
  df_queue "30000 5000"
  "$LIBEXEC/update-stage"
  check "update-stage: enough space -> upgrade" called "bootc upgrade --quiet"
  check "update-stage: enough space -> no prune" not_called "podman"
  check "update-stage: checks the ostree filesystem" called "df"
  check "update-stage: no marker" test ! -e "$JUNIPER_STATE_DIR/update-skipped-space"
}

test_update_stage_prunes_then_upgrades() {
  stage_env
  df_queue "30000 500" "30000 3000"
  "$LIBEXEC/update-stage"
  check "update-stage: short -> prunes dangling images only" called "podman image prune -f"
  check "update-stage: never prunes volumes or containers" not_called "volume"
  check "update-stage: recovered after prune -> upgrade" called "bootc upgrade --quiet"
  check "update-stage: recovered -> no marker" test ! -e "$JUNIPER_STATE_DIR/update-skipped-space"
}

test_update_stage_still_short_skips() {
  stage_env
  df_queue "30000 500"
  check "update-stage: still short -> exit 0" "$LIBEXEC/update-stage"
  check "update-stage: still short -> no upgrade" not_called "bootc upgrade"
  check "update-stage: marker has free, threshold, date" grep -Eq \
    '[0-9]{4}-[0-9]{2}-[0-9]{2}: 500 MiB free, 2048 MiB needed' "$JUNIPER_STATE_DIR/update-skipped-space"
  check "update-stage: says why in the journal" stderr_has "Not enough free space" "$LIBEXEC/update-stage"
}

test_update_stage_clears_marker_on_success() {
  stage_env
  echo "old" >"$JUNIPER_STATE_DIR/update-skipped-space"
  df_queue "30000 5000"
  "$LIBEXEC/update-stage"
  check "update-stage: success clears the marker" test ! -e "$JUNIPER_STATE_DIR/update-skipped-space"
}

test_update_stage_failed_upgrade_keeps_marker_and_fails() {
  stage_env
  stub bootc 'exit 1'
  echo "old" >"$JUNIPER_STATE_DIR/update-skipped-space"
  df_queue "30000 5000"
  check "update-stage: bootc failure fails the unit" fails "$LIBEXEC/update-stage"
  check "update-stage: bootc failure keeps the marker" test -e "$JUNIPER_STATE_DIR/update-skipped-space"
}

test_update_stage_threshold_from_conf() {
  stage_env
  df_queue "30000 3000"
  echo "MIN_FREE_MB=4096" >"$JUNIPER_UPDATE_CONF"
  "$LIBEXEC/update-stage"
  check "update-stage: conf raises the threshold" not_called "bootc upgrade"
  echo "MIN_FREE_MB=1000" >"$JUNIPER_UPDATE_CONF"
  "$LIBEXEC/update-stage"
  check "update-stage: conf lowers the threshold" called "bootc upgrade --quiet"
}

test_update_stage_conf_is_not_sourced() {
  stage_env
  df_queue "30000 3000"
  # shellcheck disable=SC2016 # the $( ) must stay literal in the conf file
  printf 'touch %s/pwned\nMIN_FREE_MB="$(touch %s/pwned2)"\n' "$T" "$T" >"$JUNIPER_UPDATE_CONF"
  "$LIBEXEC/update-stage"
  check "update-stage: conf is parsed, not executed" test ! -e "$T/pwned" -a ! -e "$T/pwned2"
  check "update-stage: junk value -> default threshold" called "bootc upgrade"
}

test_update_stage_df_failure_fails_open() {
  stage_env
  stub df 'exit 1'
  check "update-stage: df fails -> exit 0" "$LIBEXEC/update-stage"
  check "update-stage: df fails -> still upgrades" called "bootc upgrade --quiet"
  check "update-stage: df fails -> warns" stderr_has "Could not determine free space" "$LIBEXEC/update-stage"
  check "update-stage: df fails -> no marker" test ! -e "$JUNIPER_STATE_DIR/update-skipped-space"
  stub df ''
  check "update-stage: df prints nothing -> upgrades" "$LIBEXEC/update-stage"
}

test_update_stage_conf_tolerates_spaces_and_cr() {
  stage_env
  df_queue "30000 3000"
  printf 'MIN_FREE_MB = 4096\r\n' >"$JUNIPER_UPDATE_CONF"
  "$LIBEXEC/update-stage"
  check "update-stage: spaces around = and CR parsed" not_called "bootc upgrade"
  printf 'MIN_FREE_MB="1000"\r\n' >"$JUNIPER_UPDATE_CONF"
  "$LIBEXEC/update-stage"
  check "update-stage: quoted value with CR parsed" called "bootc upgrade --quiet"
}

test_motd_low_space_checks_sysroot() {
  motd_env
  df_queue "30000 20000"
  mkdir "$T/sysroot"
  JUNIPER_OSTREE_PATH=$T/sysroot "$LIBEXEC/motd" >/dev/null 2>&1
  check "motd: df on the ostree path" called "df -Pm $T/sysroot"
  : >"$CALLS"
  JUNIPER_OSTREE_PATH=$T/missing "$LIBEXEC/motd" >/dev/null 2>&1
  check "motd: missing ostree path falls back to /" called "df -Pm /"
  check "motd: missing ostree path not queried" not_called "df -Pm $T/missing"
}

test_update_stage_env_overrides_conf() {
  stage_env
  df_queue "30000 3000"
  echo "MIN_FREE_MB=1000" >"$JUNIPER_UPDATE_CONF"
  JUNIPER_MIN_FREE_MB=4096 "$LIBEXEC/update-stage"
  check "update-stage: JUNIPER_MIN_FREE_MB wins" not_called "bootc upgrade"
}

test_update_service_runs_update_stage() {
  local u=$ROOT/system_files/usr/lib/systemd/system/juniper-update.service
  check "juniper-update: runs update-stage" grep -qx 'ExecStart=/usr/libexec/juniper/update-stage' "$u"
  check "juniper-update: no direct bootc upgrade" not_grep_dir 'bootc upgrade' "$u"
}

test_image_prune_timer() {
  local d=$ROOT/system_files/usr/lib/systemd/system
  check "prune timer: weekly" grep -qx 'OnCalendar=weekly' "$d/juniper-image-prune.timer"
  check "prune timer: randomized" grep -q '^RandomizedDelaySec=' "$d/juniper-image-prune.timer"
  check "prune timer: persistent" grep -qx 'Persistent=true' "$d/juniper-image-prune.timer"
  check "prune service: dangling images only" grep -qx 'ExecStart=/usr/bin/podman image prune -f' "$d/juniper-image-prune.service"
  check "prune service: never volumes or containers" not_grep_dir 'volume\|container\|--all' "$d/juniper-image-prune.service"
  check "prune timer enabled in build.sh" grep -q 'juniper-image-prune.timer' "$ROOT/build_files/build.sh"
}

test_journal_keeps_free_space() {
  local j=$ROOT/system_files/usr/lib/systemd/journald.conf.d/50-juniper.conf
  check "journald: keeps 1G free" grep -qx 'SystemKeepFree=1G' "$j"
  check "journald: 200M cap kept" grep -qx 'SystemMaxUse=200M' "$j"
}

motd_env() {
  stub fastfetch ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl '[[ $* != *is-failed* ]]'
  stub tailscale 'exit 1'
  stage_env
}

test_motd_shows_update_skipped_for_space() {
  motd_env
  df_queue "30000 20000"
  echo "update skipped on 2033-05-18: 500 MiB free, 2048 MiB needed" >"$JUNIPER_STATE_DIR/update-skipped-space"
  check "motd: skipped-for-space shown" stdout_has "update skipped on 2033-05-18: 500 MiB free" "$LIBEXEC/motd"
  rm "$JUNIPER_STATE_DIR/update-skipped-space"
  check "motd: no marker, no line" not_stdout_has "update skipped" "$LIBEXEC/motd"
}

test_motd_warns_on_low_root_space() {
  motd_env
  df_queue "30000 20000"
  check "motd: plenty free -> no warning" not_stdout_has "Low disk space" "$LIBEXEC/motd"
  df_queue "30000 2500"
  check "motd: under 10% free -> warning" stdout_has "Low disk space" "$LIBEXEC/motd"
  df_queue "8000 900"
  check "motd: under 1 GiB free -> warning" stdout_has "900 MiB free" "$LIBEXEC/motd"
  df_queue "100000 5000"
  check "motd: 5% but >1 GiB free -> still warns (under 10%)" stdout_has "Low disk space" "$LIBEXEC/motd"
  df_queue "8000 1100"
  check "motd: 13% and over 1 GiB -> no warning" not_stdout_has "Low disk space" "$LIBEXEC/motd"
}

test_motd_runs_clean() {
  motd_env
  df_queue "30000 20000"
  check "motd: no shell errors" not_stderr_has "unbound\|syntax\|not found" "$LIBEXEC/motd"
  check "motd: exits 0" "$LIBEXEC/motd"
}

test_pi_status_shows_storage_warnings() {
  local j=$ROOT/system_files/usr/share/juniper/just/pi.just
  check "pi-status: skipped-for-space line" grep -q 'update-skipped-space' "$j"
  check "pi-status: low-space line" grep -q 'df ' "$j"
}

test_pi_status_kernel_age() {
  local j=$ROOT/system_files/usr/share/juniper/just/pi.just
  # Run the recipe's kernel line itself, with uname and rpm stubbed.
  # shellcheck disable=SC2016 # literal text of the recipe line
  grep -F '@k=$(uname -r)' "$j" | sed 's/^    @//' >"$T/kline.sh"
  check "pi-status: kernel line present" test -s "$T/kline.sh"
  stub uname 'echo 6.12.0-55.el10.aarch64'
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpm 'echo $(( $(date +%s) - 41 * 86400 - 3600 ))'
  check "pi-status: kernel and age" stdout_has "Kernel 6.12.0-55.el10.aarch64 (built 41 days ago)" bash "$T/kline.sh"
  stub rpm 'exit 1'
  check "pi-status: unknown build date" stdout_has "Kernel 6.12.0-55.el10.aarch64 (build date unknown)" bash "$T/kline.sh"
}

test_kernel_age_script() {
  local k=$ROOT/.github/scripts/kernel-age.sh now=1760000000 day=86400
  printf 'have=6.12.0-55\nhave_ts=%s\nchecked=1\nwant=6.12.0-55\nwant_ts=\n' $((now - 41 * day)) >"$T/same.env"
  printf 'have=6.12.0-55\nhave_ts=%s\nchecked=1\nwant=6.12.1-60\nwant_ts=%s\n' $((now - 41 * day)) $((now - 3 * day)) >"$T/new.env"
  printf 'have=6.12.0-55\nhave_ts=%s\nchecked=1\nwant=6.12.1-60\nwant_ts=%s\n' $((now - 41 * day)) $((now - 20 * day)) >"$T/old.env"
  printf 'have=6.12.0-55\nhave_ts=%s\n' $((now - 41 * day)) >"$T/failed.env"
  printf 'have=package raspberrypi2-kernel4 is not installed\nhave_ts=1\nchecked=1\n' >"$T/notinst.env"
  printf 'have=6.12.0-55\nhave_ts=1\nchecked=1\nwant=1 ::error::x\nwant_ts=1\n' >"$T/evil.env"
  export NOW=$now
  check "kernel-age: repo check failed summary" stdout_has "repo check failed" "$k" report "$T/failed.env"
  check "kernel-age: repo check failed is not 'nothing newer'" not_stdout_has "nothing newer" "$k" report "$T/failed.env"
  check "kernel-age: repo check failed note" stdout_has "repo check failed" "$k" note "$T/failed.env"
  check "kernel-age: not installed -> unknown" stdout_has "Pi kernel: unknown" "$k" report "$T/notinst.env"
  check "kernel-age: bad EVR never printed" not_stdout_has "error::x" "$k" report "$T/evil.env"
  check "kernel-age: up to date summary" stdout_has "Pi kernel: 6.12.0-55 (built 2025-" "$k" report "$T/same.env"
  check "kernel-age: up to date, no warning" not_stdout_has "::warning::" "$k" report "$T/same.env"
  check "kernel-age: newer repo warns" stdout_has "::warning::AlmaLinux's Pi repo has kernel 6.12.1-60" "$k" report "$T/new.env"
  check "kernel-age: recent kernel not escalated" not_stdout_has "days behind" "$k" report "$T/new.env"
  check "kernel-age: old newer kernel escalates" stdout_has "::warning::Pi kernel 20 days behind" "$k" report "$T/old.env"
  check "kernel-age: unknown summary" stdout_has "Pi kernel: unknown" "$k" report "$T/missing.env"
  check "kernel-age: unknown note" stdout_has "Pi kernel: unknown\\." "$k" note "$T/missing.env"
  check "kernel-age: unknown exits 0" "$k" note "$T/missing.env"
  check "kernel-age: note without newer kernel" stdout_has "^Pi kernel: 6.12.0-55 (built 2025-[0-9-]*)\\.$" "$k" note "$T/same.env"
  check "kernel-age: note with newer kernel" stdout_has "A newer kernel 6.12.1-60 has been in AlmaLinux's Pi repo since .*; it arrives with the next base rebuild\\." "$k" note "$T/new.env"
  unset NOW
}

metrics_env() {
  export JUNIPER_METRICS_DIR=$T/metrics JUNIPER_RUN_DIR=$T/run JUNIPER_OS_RELEASE=$T/os-release
  mkdir -p "$JUNIPER_RUN_DIR"
  echo 'IMAGE_VERSION=10.1.20330518' >"$T/os-release"
  stub bootc 'cat <<JSON
{"status":{"booted":{"image":{"image":{"image":"ghcr.io/gnathoi/juniper-minimal:latest"},"imageDigest":"sha256:aaa","timestamp":"2033-05-18T03:00:00Z"}},
"staged":{"image":{"image":{"image":"x"},"imageDigest":"sha256:bbb"}}}}
JSON'
  stub timedatectl 'echo yes'
  stub rpm 'echo 1900000000'
  prom=$JUNIPER_METRICS_DIR/juniper.prom
  health_stub 0
}

# health_stub CODE: fake healthcheck for the metrics script.
health_stub() {
  # shellcheck disable=SC2016 # expands inside the stub
  printf '#!/usr/bin/env bash\n[[ $1 == --check ]] || exit 9\nexit %s\n' "$1" >"$T/healthcheck"
  chmod +x "$T/healthcheck"
  export JUNIPER_HEALTHCHECK=$T/healthcheck
}

test_metrics_writes_image_and_staged() {
  metrics_env
  "$LIBEXEC/metrics"
  check "metrics: image info" grep -qx 'juniper_image_info{image="ghcr.io/gnathoi/juniper-minimal:latest",digest="sha256:aaa",version="10.1.20330518"} 1' "$prom"
  check "metrics: staged info" grep -qx 'juniper_staged_image_info{digest="sha256:bbb"} 1' "$prom"
  check "metrics: image timestamp" grep -qx "juniper_image_timestamp_seconds $(date -d 2033-05-18T03:00:00Z +%s)" "$prom"
  check "metrics: kernel build time" grep -qx 'juniper_kernel_build_timestamp_seconds 1900000000' "$prom"
  check "metrics: time synced" grep -qx 'juniper_time_synced 1' "$prom"
  check "metrics: gauges default 0" grep -qx 'juniper_update_held 0' "$prom"
  check "metrics: locked 0" grep -qx 'juniper_locked 0' "$prom"
  check "metrics: file mode 0644" test "$(stat -c %a "$prom")" = 644
  check "metrics: no temp files left" test "$(find "$JUNIPER_METRICS_DIR" -name '.juniper.prom.*' | wc -l)" = 0
}

test_metrics_no_staged_image() {
  metrics_env
  stub bootc 'echo "{\"status\":{\"booted\":{\"image\":{\"image\":{\"image\":\"i\"},\"imageDigest\":\"sha256:aaa\"}}}}"'
  "$LIBEXEC/metrics"
  check "metrics: no staged -> metric absent" not_grep_dir juniper_staged_image_info "$JUNIPER_METRICS_DIR"
  check "metrics: no image timestamp -> metric absent" not_grep_dir juniper_image_timestamp_seconds "$JUNIPER_METRICS_DIR"
  check "metrics: image info still there" grep -q '^juniper_image_info' "$prom"
}

test_metrics_flags_from_markers() {
  metrics_env
  touch "$JUNIPER_STATE_DIR/locked" "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  echo "held" >"$JUNIPER_STATE_DIR/update-held"
  echo "skipped" >"$JUNIPER_STATE_DIR/update-skipped-space"
  echo "open" >"$JUNIPER_RUN_DIR/lan-ssh-legacy"
  "$LIBEXEC/metrics"
  local m
  for m in update_held update_skipped_space tailscale_join_gave_up lan_ssh_legacy locked; do
    check "metrics: $m is 1" grep -qx "juniper_$m 1" "$prom"
  done
  rm "$JUNIPER_STATE_DIR/locked"
  "$LIBEXEC/metrics"
  check "metrics: legacy lan-ssh needs lockdown" grep -qx 'juniper_lan_ssh_legacy 0' "$prom"
  : >"$JUNIPER_STATE_DIR/update-held"
  "$LIBEXEC/metrics"
  check "metrics: empty held marker is 0" grep -qx 'juniper_update_held 0' "$prom"
}

test_metrics_health_last_ok_from_mtime() {
  metrics_env
  "$LIBEXEC/metrics"
  check "metrics: no health-last-ok -> metric absent" not_grep_dir juniper_health_last_ok "$JUNIPER_METRICS_DIR"
  touch -d @1900000123 "$JUNIPER_STATE_DIR/health-last-ok"
  "$LIBEXEC/metrics"
  check "metrics: health-last-ok mtime" grep -qx 'juniper_health_last_ok_timestamp_seconds 1900000123' "$prom"
}

test_metrics_missing_inputs_leave_metrics_out() {
  metrics_env
  stub bootc 'exit 1'
  stub timedatectl 'exit 1'
  stub rpm 'exit 1'
  check "metrics: still succeeds" "$LIBEXEC/metrics"
  check "metrics: no image info" not_grep_dir juniper_image_info "$JUNIPER_METRICS_DIR"
  check "metrics: no time metric" not_grep_dir juniper_time_synced "$JUNIPER_METRICS_DIR"
  check "metrics: no kernel metric" not_grep_dir juniper_kernel_build "$JUNIPER_METRICS_DIR"
  check "metrics: marker gauges still written" grep -qx 'juniper_update_held 0' "$prom"
  stub timedatectl 'echo no'
  stub rpm 'echo notanumber'
  "$LIBEXEC/metrics"
  check "metrics: unsynced is 0" grep -qx 'juniper_time_synced 0' "$prom"
  check "metrics: garbage build time dropped" not_grep_dir juniper_kernel_build "$JUNIPER_METRICS_DIR"
}

test_metrics_escapes_label_values() {
  metrics_env
  cat >"$T/evil.json" <<'JSON'
{"status":{"booted":{"image":{"image":{"image":"a\\b\"c\nd"},"imageDigest":"sha256:aaa"}}}}
JSON
  stub bootc "cat $T/evil.json"
  "$LIBEXEC/metrics"
  check "metrics: backslash, quote and newline escaped" grep -qF 'image="a\\b\"c\nd"' "$prom"
  check "metrics: one line per sample" test "$(grep -c '^juniper_image_info' "$prom")" = 1
}

test_metrics_failed_write_keeps_old_file() {
  metrics_env
  "$LIBEXEC/metrics"
  cp "$prom" "$T/old.prom"
  chmod 0555 "$JUNIPER_METRICS_DIR"
  if [[ $(id -u) != 0 ]]; then
    check "metrics: unwritable dir fails" fails "$LIBEXEC/metrics"
    check "metrics: old file untouched" cmp -s "$prom" "$T/old.prom"
  fi
  chmod 0755 "$JUNIPER_METRICS_DIR"
}

test_healthcheck_touches_last_ok() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "healthcheck: success touches health-last-ok" test -e "$JUNIPER_STATE_DIR/health-last-ok"
  rm -f "$JUNIPER_STATE_DIR/health-last-ok"
  stub ip ''
  "$LIBEXEC/healthcheck" || true
  check "healthcheck: failure does not touch it" test ! -e "$JUNIPER_STATE_DIR/health-last-ok"
}

test_metrics_healthy_gauge() {
  metrics_env
  "$LIBEXEC/metrics"
  check "metrics: healthy 1" grep -qx 'juniper_healthy 1' "$prom"
  health_stub 1
  "$LIBEXEC/metrics"
  check "metrics: unhealthy 0" grep -qx 'juniper_healthy 0' "$prom"
  health_stub 124
  "$LIBEXEC/metrics"
  check "metrics: probe crash/timeout code reports unhealthy" grep -qx 'juniper_healthy 0' "$prom"
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$T/healthcheck"
  JUNIPER_METRICS_HEALTH_TIMEOUT=1 "$LIBEXEC/metrics"
  check "metrics: hung check reports unhealthy" grep -qx 'juniper_healthy 0' "$prom"
  check "metrics: last-ok help text" "$LIBEXEC/metrics"
  touch "$JUNIPER_STATE_DIR/health-last-ok"
  "$LIBEXEC/metrics"
  check "metrics: last-ok describes confirmed boot" grep -q 'Last boot whose health check confirmed the deployment' "$prom"
}

test_healthcheck_check_mode_is_side_effect_free() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  check "healthcheck --check: healthy exits 0" "$LIBEXEC/healthcheck" --check
  check "healthcheck --check: no bootloader sync" not_called "bootloader"
  check "healthcheck --check: no last-ok marker" test ! -e "$JUNIPER_STATE_DIR/health-last-ok"
  stub ip ''
  printf '\x00\x00\x00\x01' >"$T/tryboot"
  check "healthcheck --check: unhealthy exits 1" fails "$LIBEXEC/healthcheck" --check
  check "healthcheck --check: no reboot even under tryboot" not_called "systemctl reboot"
  check "healthcheck --check: no strike" test ! -e "$JUNIPER_STATE_DIR/bad-digests"
  check "healthcheck --check: no bootc call" not_called "bootc"
}

test_motd_warns_when_clock_unsynced() {
  motd_env
  df_queue "30000 20000"
  stub timedatectl 'echo no'
  check "motd: unsynced clock warned" stdout_has "Clock not synchronised (NTP)" "$LIBEXEC/motd"
  stub timedatectl 'echo yes'
  check "motd: synced clock, no warning" not_stdout_has "Clock not synchronised" "$LIBEXEC/motd"
  stub timedatectl 'exit 1'
  check "motd: unknown clock state, no warning" not_stdout_has "Clock not synchronised" "$LIBEXEC/motd"
}

test_enable_metrics_reads_textfile_dir() {
  local j=$ROOT/system_files/usr/share/juniper/just/services.just
  check "enable-metrics: textfile collector on the host dir" grep -q '^    Exec=.*--collector.textfile.directory=/host/var/lib/juniper/metrics$' "$j"
  check "enable-metrics: re-run restarts the exporter" grep -q 'systemctl restart node-exporter.service' "$j"
}

test_metrics_timer_defaults() {
  local d=$ROOT/system_files/usr/lib/systemd/system
  check "metrics timer: every 5 minutes" grep -qx 'OnUnitActiveSec=5min' "$d/juniper-metrics.timer"
  check "metrics timer: first run 2 min after boot" grep -qx 'OnBootSec=2min' "$d/juniper-metrics.timer"
  check "metrics service: runs the script" grep -qx 'ExecStart=/usr/libexec/juniper/metrics' "$d/juniper-metrics.service"
  check "metrics: enabled in build.sh" grep -q 'juniper-metrics.timer' "$ROOT/build_files/build.sh"
}

# --- fwkey: the OTP device key through the firmware (issue #50) ---
# Stub rpi-fw-crypto driven by $T/fw.mode (ok|not-set|locked|gen-fails|nolock|otp-error|invalid).
# pubkey answers the key presence; hmac copies stdin to $T/hmac.in and prints an HMAC of it
# under a test key. The device tree says Pi 5 with a fixed bootloader (fw_build to change it).
fw_build() { # fw_build N: the bootloader build-timestamp, a big-endian u32
  local n=$1
  mkdir -p "$JUNIPER_DT/chosen/bootloader"
  # shellcheck disable=SC2059 # the format is the bytes
  printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $((n >> 24 & 255)) $((n >> 16 & 255)) $((n >> 8 & 255)) $((n & 255)))" \
    >"$JUNIPER_DT/chosen/bootloader/build-timestamp"
}
fwkey_env() {
  export T JUNIPER_SYSFS=$T/sys JUNIPER_VCIO=$T/vcio TMPDIR=$T/tmp JUNIPER_DT=$T/dt \
    JUNIPER_FWKEY_WEDGED=$T/run/fwkey-wedged
  mkdir -p "$TMPDIR" "$T/sys/block/mmcblk0/device" "$JUNIPER_DT"
  : >"$JUNIPER_VCIO"
  printf 'raspberrypi,5-model-b\0brcm,bcm2712\0' >"$JUNIPER_DT/compatible"
  fw_build 1790000000 # after 2026-06-17 (fine-grained locks)
  echo 0353445344333247803a1b2c3d014e00 >"$T/sys/block/mmcblk0/device/cid"
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'mode=$(cat "$T/fw.mode" 2>/dev/null || echo ok)
case $1 in
  pubkey)
        case $mode in
          ok|nolock) ;;
          not-set|gen-fails) echo "Failed to get public key: x" >&2; echo "Last crypto error: 6 (Key not set (all zeros))" >&2; exit 250 ;;
          invalid) echo "Last crypto error: 7 (Invalid key)" >&2; exit 249 ;;
          locked) echo "Last crypto error: 4 (locked)" >&2; exit 252 ;;
          otp-error) echo "Last crypto error: 5 (OTP error)" >&2; exit 251 ;;
        esac ;;
  hmac) cat >"$T/hmac.in"
        case $mode in
          ok|nolock) openssl dgst -sha256 -mac HMAC -macopt key:juniper-test -r "$T/hmac.in" | cut -c1-64 | tr -d "\n" ;;
          not-set|gen-fails) echo "Last crypto error: 6 (Key is all zeros)" >&2; exit 250 ;;
          invalid) echo "Last crypto error: 7 (Invalid key)" >&2; exit 249 ;;
          locked) echo "Last crypto error: 4 (locked)" >&2; exit 252 ;;
          otp-error) echo "Last crypto error: 5 (OTP error)" >&2; exit 251 ;;
        esac ;;
  genkey) [[ $mode == gen-fails ]] && { echo "Last crypto error: 10 (not blank)" >&2; exit 246; }
          echo ok >"$T/fw.mode"; echo "Successfully generated ECDSA key in slot 1" ;;
  set-key-status) [[ $mode == nolock ]] && { echo "Last crypto error: 2 (EINVAL)" >&2; exit 254; }; echo "Set key 1 status" ;;
  get-key-status) [[ $mode == nolock ]] && echo "Key 1 status: 0x00000101 (x)" || echo "Key 1 status: 0x00001b01 (x)" ;;
esac'
}
fw_calls() { grep -c '^rpi-fw-crypto' "$CALLS" || true; }

test_fwkey_derive_exact_bytes() {
  fwkey_env
  "$LIBEXEC/fwkey" derive mmcblk0 >"$T/out"
  check "fwkey: exactly 64 hex bytes, no newline" test "$(wc -c <"$T/out")" = 64
  check "fwkey: hex only" grep -Eqx '[0-9a-f]{64}' "$T/out"
  check "fwkey: exact HMAC input" cmp -s "$T/hmac.in" <(printf 'juniper.luks.root.v1\0mmc:0353445344333247803a1b2c3d014e00')
  check "fwkey: HMAC over key id 1, hex" called "rpi-fw-crypto hmac --in /dev/stdin --key-id 1 --outform hex"
}

test_fwkey_derive_is_stable() {
  fwkey_env
  check "fwkey: same card, same passphrase" test "$("$LIBEXEC/fwkey" derive mmcblk0)" = "$("$LIBEXEC/fwkey" derive mmcblk0)"
  local a
  a=$("$LIBEXEC/fwkey" derive mmcblk0)
  echo 0353445344333247803a1b2c3d014e01 >"$T/sys/block/mmcblk0/device/cid"
  check "fwkey: other card, other passphrase" test "$("$LIBEXEC/fwkey" derive mmcblk0)" != "$a"
}

test_fwkey_mmc_card_id() {
  fwkey_env
  check "fwkey: mmc id" test "$("$LIBEXEC/fwkey" card-id mmcblk0)" = "mmc:0353445344333247803a1b2c3d014e00"
}

test_fwkey_usb_without_serial_is_board_only() { # ruling 1 (I2)
  fwkey_env
  mkdir -p "$T/sys/devices/usb1/1-1/1-1:1.0/host0/target0/0:0:0:0" "$T/sys/block/sda"
  echo 0781 >"$T/sys/devices/usb1/1-1/idVendor"
  echo 5583 >"$T/sys/devices/usb1/1-1/idProduct"
  ln -s "$T/sys/devices/usb1/1-1/1-1:1.0/host0/target0/0:0:0:0" "$T/sys/block/sda/device"
  check "fwkey: board-only id" test "$("$LIBEXEC/fwkey" card-id sda)" = "board:"
  echo 4C530001 >"$T/sys/devices/usb1/1-1/serial"
  check "fwkey: usb id with serial" test "$("$LIBEXEC/fwkey" card-id sda)" = "usb:0781:5583:4C530001"
  : >"$T/sys/devices/usb1/1-1/serial"
  check "fwkey: empty usb serial is board-only" test "$("$LIBEXEC/fwkey" card-id sda)" = "board:"
  "$LIBEXEC/fwkey" derive sda >/dev/null
  check "fwkey: board-only HMAC input" cmp -s "$T/hmac.in" <(printf 'juniper.luks.root.v1\0board:')
}

test_fwkey_usb_walk_stays_in_sysfs() {
  fwkey_env
  mkdir -p "$T/outside/dev" "$T/sys/block/sdb"
  echo 1234 >"$T/outside/idVendor"
  echo 5678 >"$T/outside/idProduct"
  echo LEAK >"$T/outside/serial"
  ln -s "$T/outside/dev" "$T/sys/block/sdb/device"
  check "fwkey: no ids outside sysfs" test "$("$LIBEXEC/fwkey" card-id sdb)" = "board:"
}

test_fwkey_nvme_serial_trimmed() {
  fwkey_env
  mkdir -p "$T/sys/block/nvme0n1/device"
  echo "  S6X1NJ0R123456  " >"$T/sys/block/nvme0n1/device/serial"
  check "fwkey: nvme id, whitespace removed" test "$("$LIBEXEC/fwkey" card-id nvme0n1)" = "nvme:S6X1NJ0R123456"
}

test_fwkey_card_id_missing_disk() {
  fwkey_env
  check "fwkey: unknown disk fails" fails "$LIBEXEC/fwkey" card-id sdz
  check "fwkey: derive on unknown disk fails" fails "$LIBEXEC/fwkey" derive sdz
  check "fwkey: derive on unknown disk prints nothing" test -z "$("$LIBEXEC/fwkey" derive sdz 2>/dev/null || true)"
  check "fwkey: no HMAC for unknown disk" not_called "rpi-fw-crypto hmac"
}

test_fwkey_probe_states() {
  fwkey_env
  check "fwkey: probe ok" test "$("$LIBEXEC/fwkey" probe)" = ok
  check "fwkey: probe asks for the public key" called "rpi-fw-crypto pubkey --key-id 1 --out /dev/null"
  check "fwkey: probe never runs hmac" not_called "rpi-fw-crypto hmac"
  check "fwkey: probe never trusts get-key-status" not_called "rpi-fw-crypto get-key-status"
  echo not-set >"$T/fw.mode"
  check "fwkey: probe not-set (250)" test "$("$LIBEXEC/fwkey" probe)" = not-set
  echo invalid >"$T/fw.mode"
  check "fwkey: probe invalid key (249)" test "$("$LIBEXEC/fwkey" probe)" = unavailable:invalid-key
  echo locked >"$T/fw.mode"
  check "fwkey: probe locked is unavailable" test "$("$LIBEXEC/fwkey" probe)" = "unavailable:firmware error 4 (exit 252)"
  echo otp-error >"$T/fw.mode"
  check "fwkey: probe other error" test "$("$LIBEXEC/fwkey" probe)" = "unavailable:firmware error 5 (exit 251)"
  rm -f "$JUNIPER_VCIO"
  check "fwkey: probe no vcio" test "$("$LIBEXEC/fwkey" probe)" = "unavailable:no $JUNIPER_VCIO"
  check "fwkey: probe never writes" not_called "rpi-fw-crypto genkey"
}

test_fwkey_probe_without_cli() {
  fwkey_env
  check "fwkey: probe without the CLI" test "$(RPI_FW_CRYPTO=$T/missing "$LIBEXEC/fwkey" probe)" = "unavailable:firmware error none (exit 127)"
}

# Hardware finding: pre-2026-01-21 Pi 5 firmware wedges the mailbox on hmac. No call at all.
test_fwkey_firmware_too_old_makes_no_calls() {
  local n
  # 2025-11-05 (the board), one below the fix, and files that aren't exactly 4 bytes (GNU od
  # zero-pads a short word: \xff\xff would read as 4294901760)
  for n in 1762364238 1769002726 missing short short2 short3 long; do
    fwkey_env
    echo not-set >"$T/fw.mode"
    case $n in
      missing) rm -f "$JUNIPER_DT/chosen/bootloader/build-timestamp" ;;
      short) printf '\001\002' >"$JUNIPER_DT/chosen/bootloader/build-timestamp" ;;
      short2) printf '\377\377' >"$JUNIPER_DT/chosen/bootloader/build-timestamp" ;;
      short3) printf '\377\377\377' >"$JUNIPER_DT/chosen/bootloader/build-timestamp" ;;
      long) printf '\377\377\377\377\000' >"$JUNIPER_DT/chosen/bootloader/build-timestamp" ;;
      *) fw_build "$n" ;;
    esac
    check "fwkey ($n): probe too old" test "$("$LIBEXEC/fwkey" probe)" = unavailable:firmware-too-old
    check "fwkey ($n): ensure too old" test "$("$LIBEXEC/fwkey" ensure || true)" = unavailable:firmware-too-old
    check "fwkey ($n): ensure fails" fails "$LIBEXEC/fwkey" ensure
    check "fwkey ($n): derive fails" fails "$LIBEXEC/fwkey" derive mmcblk0
    check "fwkey ($n): lock unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
    check "fwkey ($n): no rpi-fw-crypto call" test "$(fw_calls)" = 0
  done
  fwkey_env
  rm -f "$T/fw.mode"
  fw_build 1769002727 # pieeprom-2026-01-21: the HMAC lock-up fix
  check "fwkey: 2026-01-21 passes the gate" test "$("$LIBEXEC/fwkey" probe)" = ok
}

test_fwkey_pi4_unverified() {
  fwkey_env
  printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' >"$JUNIPER_DT/compatible"
  check "fwkey: pi4 probe" test "$("$LIBEXEC/fwkey" probe)" = unavailable:pi4-unverified
  check "fwkey: pi4 ensure fails" fails "$LIBEXEC/fwkey" ensure
  check "fwkey: pi4 derive fails" fails "$LIBEXEC/fwkey" derive mmcblk0
  check "fwkey: pi4 lock unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  check "fwkey: pi4 no rpi-fw-crypto call" test "$(fw_calls)" = 0
  printf 'brcm,bcm2837\0' >"$JUNIPER_DT/compatible"
  check "fwkey: other board" test "$("$LIBEXEC/fwkey" probe)" = unavailable:unsupported-board
  rm -f "$JUNIPER_DT/compatible"
  check "fwkey: no compatible" test "$("$LIBEXEC/fwkey" probe)" = unavailable:unsupported-board
  check "fwkey: still no call" test "$(fw_calls)" = 0
}

# A call that never returns (D state) is left behind; the marker stops every later call.
test_fwkey_hung_firmware_is_wedged() {
  local start
  fwkey_env
  export JUNIPER_FWKEY_DEADLINE=1
  stub rpi-fw-crypto 'sleep 4'
  start=$SECONDS
  "$LIBEXEC/fwkey" probe >"$T/out" 2>"$T/err"
  check "fwkey: returns at the deadline" test $((SECONDS - start)) -le 3
  check "fwkey: hung pubkey is wedged" test "$(cat "$T/out")" = unavailable:firmware-wedged
  check "fwkey: wedged marker written" test -e "$JUNIPER_FWKEY_WEDGED"
  check "fwkey: says why on stderr" grep -q "wedged until reboot" "$T/err"
  start=$SECONDS
  check "fwkey: ensure after wedge" test "$("$LIBEXEC/fwkey" ensure || true)" = unavailable:firmware-wedged
  check "fwkey: derive after wedge fails" fails "$LIBEXEC/fwkey" derive mmcblk0
  check "fwkey: lock after wedge" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  check "fwkey: after wedge, instant" test $((SECONDS - start)) -le 1
  check "fwkey: no call after the wedge" test "$(fw_calls)" = 1
  check "fwkey: no genkey" not_called "rpi-fw-crypto genkey"
}

# A NUL in the output ends `read -d ''` early: never wait on a child that may still run.
test_fwkey_nul_output_is_not_waited_on() {
  local start
  fwkey_env
  export JUNIPER_FWKEY_DEADLINE=2
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'printf "x\0y"; sleep 4'
  start=$SECONDS
  "$LIBEXEC/fwkey" probe >"$T/out" 2>/dev/null
  check "fwkey: NUL output returns at once" test $((SECONDS - start)) -le 1
  check "fwkey: NUL output is unavailable" grep -q '^unavailable:' "$T/out"
  check "fwkey: NUL output is not a wedge" test ! -e "$JUNIPER_FWKEY_WEDGED"
  check "fwkey: NUL output never generates" fails "$LIBEXEC/fwkey" ensure
  check "fwkey: NUL output, no genkey" not_called "rpi-fw-crypto genkey"
}

test_fwkey_hung_genkey_and_hmac_are_wedged() {
  fwkey_env
  export JUNIPER_FWKEY_DEADLINE=1
  echo not-set >"$T/fw.mode"
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'case $1 in pubkey) echo "Last crypto error: 6 (x)" >&2; exit 250 ;; *) sleep 4 ;; esac'
  check "fwkey: hung genkey" test "$("$LIBEXEC/fwkey" ensure 2>/dev/null || true)" = unavailable:firmware-wedged
  check "fwkey: genkey marker" test -e "$JUNIPER_FWKEY_WEDGED"
  fwkey_env
  export JUNIPER_FWKEY_DEADLINE=1
  stub rpi-fw-crypto 'cat >/dev/null; sleep 4'
  check "fwkey: hung hmac fails derive" test -z "$("$LIBEXEC/fwkey" derive mmcblk0 2>/dev/null || true)"
  check "fwkey: hmac marker" test -e "$JUNIPER_FWKEY_WEDGED"
}

test_fwkey_genkey_only_when_not_set() {
  fwkey_env
  echo not-set >"$T/fw.mode"
  check "fwkey: generated" test "$("$LIBEXEC/fwkey" ensure)" = generated
  check "fwkey: genkey once" test "$(grep -c '^rpi-fw-crypto genkey --key-id 1 --alg ec$' "$CALLS")" = 1
  check "fwkey: then ok, no second genkey" test "$("$LIBEXEC/fwkey" ensure)" = ok
  check "fwkey: still genkey once" test "$(grep -c '^rpi-fw-crypto genkey' "$CALLS")" = 1
}

test_fwkey_never_writes_when_locked_or_no_vcio() {
  for mode in locked novcio otp-error invalid; do
    fwkey_env
    echo "$mode" >"$T/fw.mode"
    [[ $mode == novcio ]] && rm -f "$JUNIPER_VCIO"
    check "fwkey ($mode): ensure fails" fails "$LIBEXEC/fwkey" ensure
    check "fwkey ($mode): reports unavailable" stdout_has '^unavailable:' "$LIBEXEC/fwkey" ensure
    check "fwkey ($mode): no genkey" not_called "rpi-fw-crypto genkey"
  done
}

test_fwkey_ensure_fails_when_genkey_fails() {
  fwkey_env
  echo gen-fails >"$T/fw.mode"
  check "fwkey: failed genkey fails ensure" fails "$LIBEXEC/fwkey" ensure
  check "fwkey: failed genkey reported" stdout_has '^unavailable:' "$LIBEXEC/fwkey" ensure
}

test_fwkey_never_reads_raw_key() {
  fwkey_env
  echo not-set >"$T/fw.mode"
  "$LIBEXEC/fwkey" ensure >/dev/null
  "$LIBEXEC/fwkey" derive mmcblk0 >/dev/null
  "$LIBEXEC/fwkey" lock >/dev/null
  check "fwkey: no privkey" not_called "privkey"
  check "fwkey: no key-usage write" not_called "set-key-usage"
  check "fwkey: no vcmailbox" not_called "vcmailbox"
  check "fwkey: no temp files" test -z "$(ls -A "$TMPDIR")"
  check "fwkey: script never names privkey" not_grep_dir 'privkey\|rpi-otp-private-key\|vcmailbox\|set-key-usage' "$LIBEXEC/fwkey"
}

test_fwkey_lock_is_best_effort() { # ruling 4 (I3)
  fwkey_env
  check "fwkey: locked" test "$("$LIBEXEC/fwkey" lock)" = locked
  check "fwkey: one call, four flags" called "rpi-fw-crypto set-key-status 1 READ_LOCKED GEN_LOCKED HMAC_LOCKED USAGE_LOCKED"
  check "fwkey: SIGN stays unlocked" not_called "SIGN_LOCKED"
  echo nolock >"$T/fw.mode"
  check "fwkey: unavailable, exit 0" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  rm -f "$JUNIPER_VCIO"
  check "fwkey: no vcio, unavailable, exit 0" test "$("$LIBEXEC/fwkey" lock)" = unavailable
}

# Before 2026-06-17 bit 8 was a global LOCKED bit and bits 9-12 don't exist: don't ask.
test_fwkey_lock_skipped_before_fine_grained_locks() {
  fwkey_env
  fw_build 1778498402 # pieeprom-2026-05-11: HMAC fixed, no per-operation locks
  check "fwkey: 2026-05-11 lock unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  check "fwkey: 2026-05-11 no set-key-status" not_called "set-key-status"
  check "fwkey: 2026-05-11 still derives" stdout_has '^[0-9a-f]\{64\}$' "$LIBEXEC/fwkey" derive mmcblk0
  fw_build 1781654813 # pieeprom-2026-06-17
  check "fwkey: 2026-06-17 locks" test "$("$LIBEXEC/fwkey" lock)" = locked
}

test_fwkey_lock_checks_hmac_bit() {
  fwkey_env
  # set-key-status succeeds but the firmware ignores HMAC_LOCKED (bit 11 clear)
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'case $1 in get-key-status) echo "Key 1 status: 0x00000301 (x)" ;; esac'
  check "fwkey: bit 11 clear is unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'case $1 in get-key-status) echo "Key 1 status: unknown" ;; esac'
  check "fwkey: unparsable status is unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'case $1 in get-key-status) echo "Key 1 status: 0x00000801 (x)"; exit 1 ;; esac'
  check "fwkey: failed get-key-status is unavailable" test "$("$LIBEXEC/fwkey" lock)" = unavailable
}

test_fwkey_derive_fails_closed() {
  fwkey_env
  echo locked >"$T/fw.mode"
  check "fwkey: derive fails when locked" fails "$LIBEXEC/fwkey" derive mmcblk0
  check "fwkey: derive prints nothing when locked" test -z "$("$LIBEXEC/fwkey" derive mmcblk0 2>/dev/null || true)"
  echo not-set >"$T/fw.mode"
  check "fwkey: derive fails when not set" fails "$LIBEXEC/fwkey" derive mmcblk0
  check "fwkey: derive never generates" not_called "rpi-fw-crypto genkey"
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'cat >/dev/null; printf "%s" ABCDEF'
  check "fwkey: derive rejects non-hex output" test -z "$("$LIBEXEC/fwkey" derive mmcblk0 2>/dev/null || true)"
}

# M1: many matching lines must not kill the parser with SIGPIPE under pipefail.
test_fwkey_long_error_output() {
  fwkey_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub rpi-fw-crypto 'case $1 in
  pubkey) for ((i = 0; i < 20000; i++)); do echo "Last crypto error: 6 (Key is all zeros)"; done >&2; exit 250 ;;
  get-key-status) for ((i = 0; i < 20000; i++)); do echo "Key 1 status: 0x00001b01 (x)"; done ;;
esac'
  check "fwkey: long error output still parsed" test "$("$LIBEXEC/fwkey" probe)" = not-set
  check "fwkey: long status output still parsed" test "$("$LIBEXEC/fwkey" lock)" = locked
}

# M3: only an exact KEY_NOT_SET may reach genkey; garbage or a missing CLI never does.
test_fwkey_ensure_garbage_never_generates() {
  local out
  for out in 'Last crypto error: 66 (x)' 'Last crypto error:  6' 'Last crypto error: (x)' 'error 6' \
    '0123456789abcdef' '' 'bash: rpi-fw-crypto: command not found'; do
    fwkey_env
    # shellcheck disable=SC2016 # expands inside the stub
    stub rpi-fw-crypto "case \$1 in pubkey) printf '%s\n' '$out' >&2; exit 127 ;; esac"
    check "fwkey ($out): ensure fails" fails "$LIBEXEC/fwkey" ensure
    check "fwkey ($out): unavailable" stdout_has '^unavailable:' "$LIBEXEC/fwkey" ensure
    check "fwkey ($out): no genkey" not_called "rpi-fw-crypto genkey"
  done
  fwkey_env
  check "fwkey (no CLI): ensure unavailable" test "$(RPI_FW_CRYPTO=$T/missing "$LIBEXEC/fwkey" ensure || true)" = "unavailable:firmware error none (exit 127)"
  check "fwkey (no CLI): no genkey" not_called "rpi-fw-crypto genkey"
}

# M2: setup() drops the overrides fwkey_env exports.
test_fwkey_overrides_not_inherited_a() { fwkey_env; }
test_fwkey_overrides_not_inherited_b() {
  check "setup: JUNIPER_SYSFS unset" test -z "${JUNIPER_SYSFS+x}"
  check "setup: JUNIPER_VCIO unset" test -z "${JUNIPER_VCIO+x}"
}

test_fwkey_usage() {
  fwkey_env
  check "fwkey: unknown command fails" fails "$LIBEXEC/fwkey" bogus
  check "fwkey: no command fails" fails "$LIBEXEC/fwkey"
  check "fwkey: bad deadline falls back" test "$(JUNIPER_FWKEY_DEADLINE=abc "$LIBEXEC/fwkey" probe)" = ok
  check "fwkey: zero deadline falls back" test "$(JUNIPER_FWKEY_DEADLINE=0 "$LIBEXEC/fwkey" probe)" = ok
}

# --- cryptroot: first-boot encryption and unlock (issue #50) ---
# The board passphrase lives only in the environment: never in a file under $T.
fake_pass() { printf '%s' 5e1f0c2a9b3d4e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7; }
order() { [[ $(grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1) -lt $(grep -nF -- "$2" "$CALLS" | head -1 | cut -d: -f1) ]]; }
order_last() { [[ $(grep -nF -- "$1" "$CALLS" | tail -1 | cut -d: -f1) -lt $(grep -nF -- "$2" "$CALLS" | tail -1 | cut -d: -f1) ]]; }
not_grep_v() { ! grep -qv -- "$1" "$2"; }
count_calls() { grep -cF -- "$1" "$CALLS" || true; }
# stub_file NAME: like stub, with the body on stdin.
stub_file() {
  # shellcheck disable=SC2016 # $* and $CALLS expand when the stub runs
  { printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$1" && cat; } >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
# crt ARGS: run cryptroot; its exit status goes to RC (a failure must not end the runner).
crt() {
  RC=0
  "$LIBEXEC/cryptroot" "$@" || RC=$?
}
runf() { sed -n "s/^$1=//p" "$T/run/cryptroot"; }
tok() { cat "$T/luks/$1/token$2" 2>/dev/null || true; }

# bsys_part DISK N START SIZE: a partition in the fake block sysfs (I14 layout).
bsys_part() {
  local d=$T/bsys/devices/$1 p
  p=$1$2
  [[ $1 == *[0-9] ]] && p=$1p$2
  mkdir -p "$d/$p" "$T/bsys/class/block"
  echo "$2" >"$d/$p/partition"
  echo "$3" >"$d/$p/start"
  echo "$4" >"$d/$p/size"
  ln -sfn "../../devices/$1/$p" "$T/bsys/class/block/$p"
  ln -sfn "../../devices/$1" "$T/bsys/class/block/$1"
}

# luks_card NAME RECOVERY SLOTS [reencrypt]: an existing juniper header on /dev/NAME.
luks_card() {
  local d=$T/luks/$1
  mkdir -p "$d"
  : >"$d/header"
  echo aes-xts-plain64 >"$d/cipher"
  echo "$3" >"$d/slots"
  if [[ -n $2 ]]; then
    printf '{"type":"juniper","keyslots":[],"root_uuid":"U1","binding":"juniper.luks.root.v1","id_type":"mmc","recovery":"%s","recipients":"2"}' "$2" >"$d/token0"
  fi
  if [[ ${4:-} == reencrypt ]]; then
    : >"$d/reencrypt"
    : >"$d/repair-needed"
  fi
}

# cryptroot_env STATE MARKER
#   STATE:  plain | luks-notoken (header marked for reencryption, so no token: C1) |
#           luks-done-notoken (conversion finished, cut before the token) |
#           luks-pending | luks-sealed
#   MARKER: on | off | converting | encrypted | missing | anything else
cryptroot_env() {
  local state=$1 marker=$2
  if [[ -d ${T:?}/cidata ]]; then chmod -R u+w "$T/cidata"; fi
  rm -rf "${T:?}/luks" "${T:?}/bsys" "${T:?}/run" "${T:?}/cidata" "${T:?}"/sfdisk.* \
    "${T:?}"/fw.* "${T:?}/age.fail" "${T:?}"/cs.* "${T:?}/console" "${T:?}/tryboot"
  : >"$CALLS"
  export T FAKE_PASS
  FAKE_PASS=$(fake_pass)
  export JUNIPER_CMDLINE=$T/cmdline JUNIPER_BLOCK_SYSFS=$T/bsys JUNIPER_SYSFS=$T/sys \
    JUNIPER_CIDATA_MNT=$T/cidata JUNIPER_RUN_DIR=$T/run JUNIPER_CPUINFO=$T/cpuinfo \
    JUNIPER_TRYBOOT_FLAG=$T/no-tryboot JUNIPER_ROOT_WAIT=2 JUNIPER_UNLOCK_FAIL_DELAY=0 \
    JUNIPER_FWKEY=$T/bin/fwkey JUNIPER_CONSOLE=$T/console JUNIPER_CRYPTSETUP_LOCKDIR=$T/run-cryptsetup
  echo "BOOT_IMAGE=(hd0,gpt2)/vmlinuz root=UUID=U1 rw boot=UUID=B1 rootflags=noatime panic=10 rd.shell=0 rd.emergency=reboot ostree=/ostree/boot.1/default/x/0" >"$T/cmdline"
  printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics\n' >"$T/cpuinfo"
  bsys_part mmcblk0 1 2048 2097152
  bsys_part mmcblk0 2 2099200 2097152
  bsys_part mmcblk0 3 4192256 12584927
  echo 62521344 >"$T/bsys/devices/mmcblk0/size"
  cat >"$T/blkid.db" <<'EOF'
/dev/mmcblk0p1 TYPE=vfat LABEL=CIDATA UUID=C1 PART_ENTRY_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
/dev/mmcblk0p2 TYPE=xfs LABEL=boot UUID=B1 PART_ENTRY_TYPE=0fc63daf-8483-4772-8e79-3d69d8477de4
/dev/mmcblk0p3 TYPE=xfs LABEL=root UUID=U1 PART_ENTRY_TYPE=b921b045-1df0-41c3-af44-4c6f280d3fae
EOF
  mkdir -p "$T/cidata"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA owner@laptop\n# comment\n\nssh-rsa AAAAB3NzaC1yc2E owner@desk\n' >"$T/cidata/juniper-recovery.txt"
  [[ $marker == missing ]] || echo "$marker" >"$T/cidata/juniper-encrypt"
  case $state in
    luks-notoken) luks_card mmcblk0p3 '' 0 reencrypt ;;
    luks-done-notoken) luks_card mmcblk0p3 '' 0 ;;
    luks-pending) luks_card mmcblk0p3 pending 0 ;;
    luks-sealed)
      luks_card mmcblk0p3 sealed "0 1"
      echo $((62521344 - 33 - 4192256)) >"$T/bsys/devices/mmcblk0/mmcblk0p3/size"
      ;;
  esac
  # blkid answers from blkid.db; a device with a fake header is crypto_LUKS, label juniper-root.
  # shellcheck disable=SC2016 # expands inside the stub
  stub_file blkid <<'EOF'
db() {
  local dev rest
  while read -r dev rest; do
    if [[ -e $T/luks/${dev##*/}/header ]]; then
      rest=$(printf ' %s' "$rest" | sed -E 's/ (TYPE|LABEL|UUID)=[^ ]*//g')
      rest="$rest TYPE=crypto_LUKS LABEL=juniper-root UUID=luks-${dev##*/}"
    fi
    echo "$dev $rest"
  done <"$T/blkid.db"
}
tok= tag= dev=
while (($#)); do
  case $1 in -c | -o) shift ;; -p) ;; -t) tok=$2; shift ;; -s) tag=$2; shift ;; *) dev=$1 ;; esac
  shift
done
if [[ -n $tok ]]; then
  out=$(db | grep -E " $tok( |\$)" | cut -d' ' -f1)
else
  out=$(db | grep "^$dev " | grep -oE " $tag=[^ ]*" | cut -d= -f2-)
fi
[[ -n $out ]] || exit 2
echo "$out"
EOF
  # cryptsetup keeps fake header state in $T/luks/<dev>/: header, slots, token<N>, cipher,
  # reencrypt (online-reencrypt requirement), repair-needed, wrongboard (key doesn't open it).
  # shellcheck disable=SC2016 # expands inside the stub
  stub_file cryptsetup <<'EOF'
cmd=$1
shift
n=
for a in "$@"; do
  case $a in /dev/fd/*) ;; /dev/*) n=${a##*/}; break ;; esac
done
d=$T/luks/$n
has() { local a; for a in "${@:2}"; do [[ $a == "$1" ]] && return 0; done; return 1; }
val() { local p=; for a in "${@:2}"; do [[ $p == "$1" ]] && { echo "$a"; return; }; p=$a; done; }
# Like cryptsetup 2.8: no header metadata changes while the header is marked for reencryption.
case $cmd:${1:-} in
  token:import | luksAddKey:* | luksKillSlot:*)
    if [[ -e $d/reencrypt ]]; then
      echo "Operation incompatible with device marked for LUKS2 reencryption. Aborting." >&2
      exit 1
    fi ;;
esac
if has --key-file "$@"; then
  k=$(cat)
  if [[ $k != "$FAKE_PASS" ]]; then echo "cryptsetup-key bad" >>"$CALLS"; exit 2; fi
  if [[ -e $d/wrongboard ]]; then echo "No key available with this passphrase." >&2; exit 2; fi
fi
case $cmd in
  reencrypt)
    if has --init-only "$@"; then
      [[ -e $T/cs.init.fail ]] && exit 1
      mkdir -p "$d"; : >"$d/header"; : >"$d/reencrypt"; echo 0 >"$d/slots"
      val --cipher "$@" >"$d/cipher"
      if [[ -e $T/cs.init.fail-after-header ]]; then : >"$d/repair-needed"; exit 1; fi
    else
      [[ -e $d/repair-needed ]] && { echo "needs repair" >&2; exit 1; }
      [[ -e $T/cs.resume.fail ]] && exit 1
      rm -f "$d/reencrypt"
    fi ;;
  repair) rm -f "$d/repair-needed" ;;
  token)
    id=$(val --token-id "$@")
    if [[ $1 == import ]]; then
      [[ -e $d/token$id ]] && ! has --token-replace "$@" && { echo "Token $id in use." >&2; exit 1; }
      [[ -e $T/cs.token.fail ]] && exit 1
      cat >"$d/token$id"
    else
      cat "$d/token$id" 2>/dev/null || exit 1
    fi ;;
  luksDump)
    [[ -e $d/header ]] || exit 1
    printf 'LUKS header information\nVersion:       \t2\nLabel:          \tjuniper-root\n'
    if [[ -e $d/reencrypt ]]; then printf 'Requirements:\tonline-reencrypt-v2\n'; fi
    printf '\nKeyslots:\n'
    for s in $(cat "$d/slots"); do printf '  %s: luks2\n\tKey:        512 bits\n' "$s"; done
    if [[ -e $d/reencrypt ]]; then printf '  1: reencrypt (unbound)\n'; fi
    printf 'Tokens:\n'
    for t in "$d"/token*; do if [[ -e $t ]]; then printf '  %s: juniper\n' "${t##*token}"; fi; done ;;
  luksKillSlot)
    s=" $(cat "$d/slots") "; s=${s/ ${!#} / }; echo $s >"$d/slots" ;;
  luksAddKey)
    s=$(val --key-slot "$@")
    if [[ " $(cat "$d/slots") " == *" $s "* ]]; then echo "Key slot $s is full." >&2; exit 1; fi
    r=$(cat /dev/fd/3)
    [[ $r =~ ^[0-9a-f]{64}$ ]] || exit 1
    echo "newkey fd3=$(readlink /proc/$$/fd/3) sha=$(printf %s "$r" | sha256sum | cut -c1-64)" >>"$CALLS"
    echo "$(cat "$d/slots") $s" >"$d/slots" ;;
  open) [[ -e $d/header ]] || exit 1; echo "$n" >"$T/luks/active" ;;
  status)
    [[ -e $T/luks/active ]] || exit 4
    printf '/dev/mapper/juniper-root is active.\n  type:    LUKS2\n  cipher:  %s\n  keysize: 512 bits\n' "$(cat "$T/luks/$(cat "$T/luks/active")/cipher")" ;;
  isLuks) [[ -e $d/header ]] ;;
  *) exit 1 ;;
esac
EOF
  # sfdisk -N records its stdin in $T/sfdisk.K and updates the partition size in sysfs.
  # shellcheck disable=SC2016 # expands inside the stub
  stub_file sfdisk <<'EOF'
num=
dev=
while (($#)); do
  case $1 in -N) num=$2; shift ;; /dev/*) dev=${1##*/} ;; esac
  shift
done
[[ -n $num ]] || exit 0
k=$(($(cat "$T/sfdisk.count" 2>/dev/null || echo 0) + 1))
echo "$k" >"$T/sfdisk.count"
cat >"$T/sfdisk.$k"
p=$dev$num
[[ $dev == *[0-9] ]] && p=${dev}p$num
s=$(sed -n 's/^size=//p' "$T/sfdisk.$k")
if [[ $s == + ]]; then
  s=$(($(cat "$T/bsys/devices/$dev/size") - 33 - $(cat "$T/bsys/devices/$dev/$p/start")))
fi
echo "$s" >"$T/bsys/devices/$dev/$p/size"
EOF
  stub partx ''
  stub sleep ''
  # CIDATA is $T/cidata: writable only between remount,rw and remount,ro.
  # shellcheck disable=SC2016 # expands inside the stub
  stub mount '[[ -e $T/mount.fail ]] && exit 32
case "$*" in *remount,rw*) chmod u+w "$T/cidata" ;; *) chmod a-w "$T/cidata" ;; esac'
  # shellcheck disable=SC2016 # expands inside the stub
  stub umount 'chmod u+w "$T/cidata"'
  # age honours -o; the fake ciphertext holds a hash of the input, never the input.
  # shellcheck disable=SC2016 # expands inside the stub
  stub_file age <<'EOF'
rec= out=
while (($#)); do
  case $1 in -R) rec=$2; shift ;; -o) out=$2; shift ;; esac
  shift
done
[[ -e $T/age.fail ]] && { echo "age: error: no recipients" >&2; exit 1; }
[[ -s $rec ]] || exit 1
in=$(cat)
[[ $out == /dev/null ]] && exit 0
s=$(printf %s "$in" | sha256sum | cut -c1-64)
echo "age-in sha=$s" >>"$CALLS"
printf -- '-----BEGIN AGE ENCRYPTED FILE-----\n%s\nq"uote\\back\n-----END AGE ENCRYPTED FILE-----\n' "$s" >"$out"
EOF
  # shellcheck disable=SC2016 # expands inside the stub
  stub fwkey 'case $1 in
  derive) [[ -e $T/fw.derive-fail ]] && exit 1; printf %s "$FAKE_PASS" ;;
  ensure) m=$(cat "$T/fw.mode" 2>/dev/null || echo ok); echo "$m"; [[ $m == ok || $m == generated ]] ;;
  card-id) [[ -e $T/fw.cardid-fail ]] && exit 1; cat "$T/fw.id" 2>/dev/null || echo mmc:abc ;;
  probe) cat "$T/fw.probe" 2>/dev/null || echo ok ;;
  lock) echo unavailable ;;
esac'
}

test_cryptroot_first_boot_sequence() {
  cryptroot_env plain on
  crt prepare >"$T/out" 2>&1
  check "prep: exit 0" test "$RC" = 0
  check "prep: marker converting before relocate" order "mount -o remount,rw" "sfdisk --relocate gpt-bak-std /dev/mmcblk0"
  check "prep: relocate before grow" order "sfdisk --relocate" "sfdisk -N 3"
  check "prep: +64 MiB absolute" grep -qx "size=$((12584927 + 131072))" "$T/sfdisk.1"
  check "prep: partx after grow" called "partx -u -n 3 /dev/mmcblk0"
  check "prep: init-only slot 0" called "--init-only --type luks2 --key-slot 0 --reduce-device-size 32M"
  check "prep: label, pbkdf2" called "--pbkdf pbkdf2 --pbkdf-force-iterations 1000 --label juniper-root --key-file - /dev/mmcblk0p3"
  check "prep: resume before token" order "--resume-only" "cryptsetup token import --token-id 0"
  check "prep: no repair within one boot" not_called "cryptsetup repair"
  check "prep: resume with progress" called "cryptsetup reencrypt --batch-mode --resume-only --progress-frequency 10 --key-file - /dev/mmcblk0p3"
  check "prep: sector 512, aes" called "--cipher aes-xts-plain64 --key-size 512 --sector-size 512"
  check "prep: age before slot 1" order "age -R" "cryptsetup luksAddKey --batch-mode --key-slot 1"
  check "prep: max grow is last sfdisk" grep -qx 'size=+' "$T/sfdisk.2"
  check "prep: max grow after sealing" order_last "cryptsetup luksAddKey" "sfdisk -N 3" # I13
  check "prep: recovery file" test -s "$T/cidata/juniper-recovery.age"
  check "prep: no .new left" test ! -e "$T/cidata/juniper-recovery.age.new"
  check "prep: recorded" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: slots 0 and 1" test "$(cat "$T/luks/mmcblk0p3/slots")" = "0 1"
  check "prep: token sealed" grep -q '"recovery":"sealed"' "$T/luks/mmcblk0p3/token0"
  check "prep: run state" test "$(runf state)" = encrypted
  check "prep: genkey path ran" called "fwkey ensure"
  check "prep: lock dir" test -d "$T/run-cryptsetup"
  check "prep: every message prefixed" not_grep_v '^juniper-cryptroot: ' "$T/out"
  check "prep: CIDATA unmounted" called "umount $T/cidata"
  check "prep: no passphrase anywhere" not_grep_dir "$(fake_pass)" "$T"
  local writes='^cryptsetup (reencrypt|luksAddKey|luksKillSlot|token import|repair)|^sfdisk|remount,rw'
  local before
  before=$(grep -cE "$writes" "$CALLS" || true)
  crt prepare 2>/dev/null
  check "prep: second boot changes nothing" test "$(grep -cE "$writes" "$CALLS")" = "$before"
}

test_cryptroot_off_or_missing_does_nothing() { # I1, ruling 2
  local m
  for m in off missing garbage; do
    cryptroot_env plain "$m"
    crt prepare
    check "prep ($m): no sfdisk" not_called sfdisk
    check "prep ($m): no fwkey" not_called fwkey
    check "prep ($m): no cryptsetup" not_called cryptsetup
    check "prep ($m): no CIDATA write" not_called "remount,rw"
    check "prep ($m): plain" test "$(runf state)" = not-encrypted
    check "prep ($m): no wait" not_called sleep
  done
  cryptroot_env plain off
  crt prepare
  check "prep (off): reason" test "$(runf reason)" = "encrypt: false"
  cryptroot_env plain missing
  crt prepare
  check "prep (missing): reason" test "$(runf reason)" = "not requested at flash time"
}

test_cryptroot_failure_before_header_is_final() { # C2
  cryptroot_env plain on
  stub sfdisk 'exit 1'
  crt prepare 2>/dev/null
  check "prep: recorded fail-open" grep -qx 'not-encrypted:relocate failed' "$T/cidata/juniper-encrypt"
  check "prep: run file says why" test "$(runf reason)" = "relocate failed"
  check "prep: no header" not_called "cryptsetup reencrypt"
  : >"$CALLS"
  stub sfdisk ''
  crt prepare
  check "prep: second boot doesn't encrypt" not_called "cryptsetup reencrypt"
  check "prep: second boot no fwkey" not_called fwkey
}

test_cryptroot_unreadable_sysfs_is_final() {
  cryptroot_env plain on
  rm "$T/bsys/devices/mmcblk0/mmcblk0p3/size"
  ln -s /nonexistent "$T/bsys/devices/mmcblk0/mmcblk0p3/size"
  crt prepare 2>/dev/null
  check "prep: exit 0 after fail-open" test "$RC" = 0
  check "prep: recorded" grep -q '^not-encrypted:' "$T/cidata/juniper-encrypt"
  check "prep: no sfdisk" not_called sfdisk
}

test_cryptroot_killed_before_header_is_final() { # C2: the trap, not the explicit checks
  cryptroot_env plain on
  # shellcheck disable=SC2016 # expands inside the stub
  stub sfdisk 'kill -TERM $PPID'
  crt prepare 2>"$T/err"
  check "prep: SIGTERM ran the trap" grep -q 'relocate failed; continuing unencrypted' "$T/err"
  check "prep: SIGTERM before the header records fail-open" grep -qx 'not-encrypted:relocate failed' "$T/cidata/juniper-encrypt"
  check "prep: SIGTERM, no header" not_called "cryptsetup reencrypt"
  check "prep: SIGTERM, CIDATA unmounted" called "umount"
}

test_cryptroot_error_trap_before_header() { # C2: an unchecked failure trips the ERR trap
  cryptroot_env plain on
  # sysfs size readable by the precheck, gone by the time the grow reads it
  # shellcheck disable=SC2016 # expands inside the stub
  stub sfdisk 'if [[ $* == *relocate* ]]; then rm "$T/bsys/devices/mmcblk0/mmcblk0p3/size"; fi'
  crt prepare 2>"$T/err"
  check "prep: it was the trap" grep -q 'grow failed; continuing unencrypted' "$T/err"
  check "prep: ERR trap exit 0" test "$RC" = 0
  check "prep: ERR trap records the step" grep -qx 'not-encrypted:grow failed' "$T/cidata/juniper-encrypt"
  check "prep: ERR trap, no grow" not_called "sfdisk -N"
}

test_cryptroot_kernel_size_must_grow() { # --reduce-device-size needs the 64 MiB
  cryptroot_env plain on
  # shellcheck disable=SC2016 # expands inside the stub
  stub sfdisk 'if [[ $* == *-N* ]]; then cat >/dev/null; fi'
  crt prepare 2>/dev/null
  check "prep: grow not seen -> fail open" grep -qx 'not-encrypted:grow failed' "$T/cidata/juniper-encrypt"
  check "prep: grow not seen -> no header" not_called "cryptsetup reencrypt"
}

test_cryptroot_karg_is_final() { # I8
  cryptroot_env plain on
  sed -i 's/$/ juniper.encrypt=0/' "$T/cmdline"
  crt prepare 2>/dev/null
  check "prep: karg recorded" grep -qx 'not-encrypted:juniper.encrypt=0' "$T/cidata/juniper-encrypt"
  check "prep: karg no fwkey" not_called fwkey
  check "prep: karg no sfdisk" not_called sfdisk
  sed -i 's/ juniper.encrypt=0//' "$T/cmdline"
  : >"$CALLS"
  crt prepare
  check "prep: karg removed, still no cryptsetup" not_called cryptsetup
  check "prep: karg removed, reason kept" test "$(runf reason)" = juniper.encrypt=0
}

# setup_case CASE: break one first-boot precondition.
setup_case() {
  case $1 in
    norecipient) touch "$T/age.fail" ;;
    norecipientfile) rm "$T/cidata/juniper-recovery.txt" ;;
    twocands)
      echo "/dev/sda3 TYPE=xfs LABEL=root UUID=U1 PART_ENTRY_TYPE=b921b045-1df0-41c3-af44-4c6f280d3fae" >>"$T/blkid.db"
      bsys_part sda 3 4192256 12584927
      echo 62521344 >"$T/bsys/devices/sda/size"
      ;;
    wrongtype) sed -i '/mmcblk0p3/s/PART_ENTRY_TYPE=[^ ]*/PART_ENTRY_TYPE=0fc63daf-8483-4772-8e79-3d69d8477de4/' "$T/blkid.db" ;;
    nospace) echo $((4192256 + 12584927 + 34 + 131071)) >"$T/bsys/devices/mmcblk0/size" ;;
    nocardid) touch "$T/fw.cardid-fail" ;;
  esac
}

test_cryptroot_genkey_only_last() { # I7
  local c
  declare -A why=([norecipient]="no usable recovery recipient" [norecipientfile]="no usable recovery recipient"
    [twocands]="two disks carry this root filesystem" [wrongtype]="root partition not on the boot disk"
    [nospace]="no free space after the root partition" [nocardid]="disk not found in sysfs")
  for c in norecipient norecipientfile twocands wrongtype nospace nocardid; do
    cryptroot_env plain on
    setup_case "$c"
    crt prepare 2>/dev/null
    check "prep ($c): fwkey ensure not called" not_called "fwkey ensure"
    check "prep ($c): no sfdisk" not_called sfdisk
    check "prep ($c): no cryptsetup" not_called cryptsetup
    check "prep ($c): reason" grep -qxF "not-encrypted:${why[$c]}" "$T/cidata/juniper-encrypt"
  done
}

test_cryptroot_firmware_unavailable_fails_open() {
  cryptroot_env plain on
  echo "unavailable:no /dev/vcio" >"$T/fw.mode"
  crt prepare 2>/dev/null
  check "prep: ensure detail recorded" grep -qxF "not-encrypted:firmware key interface unavailable: no /dev/vcio" "$T/cidata/juniper-encrypt"
  check "prep: ensure failure, no sfdisk" not_called sfdisk
  cryptroot_env plain on
  echo "garbage" >"$T/fw.mode"
  crt prepare 2>/dev/null
  check "prep: unknown ensure output fails open" grep -qxF "not-encrypted:firmware key interface unavailable: garbage" "$T/cidata/juniper-encrypt"
  cryptroot_env plain on
  touch "$T/fw.derive-fail"
  echo locked >"$T/fw.probe"
  crt prepare 2>/dev/null
  check "prep: derive failure uses the probe" grep -qxF "not-encrypted:firmware key interface unavailable: derive failed (locked)" "$T/cidata/juniper-encrypt"
  check "prep: derive failure, no sfdisk" not_called sfdisk
  check "prep: derive failure, no cryptsetup" not_called cryptsetup
}

# Task 3b: fwkey's firmware gate reasons all fail open, recorded with the reason.
test_cryptroot_firmware_gate_reasons_fail_open() {
  local r
  for r in firmware-too-old pi4-unverified unsupported-board firmware-wedged invalid-key; do
    cryptroot_env plain on
    echo "unavailable:$r" >"$T/fw.mode"
    crt prepare 2>/dev/null
    check "prep ($r): exit 0" test "$RC" = 0
    check "prep ($r): recorded on CIDATA" grep -qxF "not-encrypted:firmware key interface unavailable: $r" "$T/cidata/juniper-encrypt"
    check "prep ($r): recorded in /run" test "$(runf reason)" = "firmware key interface unavailable: $r"
    check "prep ($r): no sfdisk" not_called sfdisk
    check "prep ($r): no cryptsetup" not_called cryptsetup
  done
  cryptroot_env plain on
  touch "$T/fw.derive-fail"
  echo unavailable:firmware-wedged >"$T/fw.probe"
  crt prepare 2>/dev/null
  check "prep: wedged during derive fails open" grep -qxF "not-encrypted:firmware key interface unavailable: derive failed (firmware-wedged)" "$T/cidata/juniper-encrypt"
  check "prep: wedged during derive, no cryptsetup" not_called cryptsetup
}

test_cryptroot_recipients_validated_by_age() { # C3
  cryptroot_env plain on
  touch "$T/age.fail"
  crt prepare 2>/dev/null
  check "prep: age validates" called "age -R $T/cidata/juniper-recovery.txt -o /dev/null"
  check "prep: no recipient reason" grep -qx 'not-encrypted:no usable recovery recipient' "$T/cidata/juniper-encrypt"
  check "prep: no recipient, no cryptsetup" not_called cryptsetup
}

test_cryptroot_init_failure_fails_open() {
  cryptroot_env plain on
  touch "$T/cs.init.fail"
  crt prepare 2>/dev/null
  check "prep: init-only failed, no header -> fail open" grep -qx 'not-encrypted:encrypt failed' "$T/cidata/juniper-encrypt"
}

test_cryptroot_init_failure_with_header_resumes() { # never fail open over a header
  cryptroot_env plain on
  touch "$T/cs.init.fail-after-header"
  crt prepare 2>/dev/null
  check "prep: header kept converting, then finished" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: repair after a failed init" order "cryptsetup repair" "--resume-only"
  check "prep: sealed" grep -q '"recovery":"sealed"' "$T/luks/mmcblk0p3/token0"
}

test_cryptroot_token_failure_keeps_converting() {
  cryptroot_env plain on
  touch "$T/cs.token.fail"
  crt prepare 2>/dev/null
  check "prep: token failure keeps converting" grep -qx converting "$T/cidata/juniper-encrypt"
  rm "$T/cs.token.fail"
  : >"$CALLS"
  crt prepare 2>/dev/null
  check "prep: next boot imports the token (C1)" called "cryptsetup token import --token-id 0"
  check "prep: next boot does not resume again" not_called "cryptsetup reencrypt"
  check "prep: next boot finishes" grep -qx encrypted "$T/cidata/juniper-encrypt"
}

test_cryptroot_plain_converting_retries() { # header never written: retry from preconditions
  cryptroot_env plain converting
  crt prepare 2>/dev/null
  check "prep: converting plain retries" called "--init-only"
  check "prep: converting plain finishes" grep -qx encrypted "$T/cidata/juniper-encrypt"
}

test_cryptroot_resume_after_header_without_token() { # C1
  cryptroot_env luks-notoken converting
  crt prepare 2>/dev/null
  check "prep: token imported" called "cryptsetup token import --token-id 0"
  check "prep: token has root uuid" grep -q '"root_uuid":"U1"' "$T/luks/mmcblk0p3/token0"
  check "prep: repair then resume" order "cryptsetup repair" "--resume-only"
  check "prep: resume then token" order "--resume-only" "cryptsetup token import --token-id 0"
  check "prep: token then seal" order "cryptsetup token import --token-id 0" "cryptsetup luksAddKey"
  check "prep: C1 finishes" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: C1 sealed" grep -q '"recovery":"sealed"' "$T/luks/mmcblk0p3/token0"
  check "prep: no second header" not_called "--init-only"
}

# Kill point: the conversion finished, power was cut before the token import.
test_cryptroot_cut_after_resume_before_token() {
  cryptroot_env luks-done-notoken converting
  crt prepare 2>/dev/null
  check "prep: no repair" not_called "cryptsetup repair"
  check "prep: no resume" not_called "cryptsetup reencrypt"
  check "prep: token imported" grep -q '"root_uuid":"U1"' "$T/luks/mmcblk0p3/token0"
  check "prep: sealed" grep -q '"recovery":"sealed"' "$T/luks/mmcblk0p3/token0"
  check "prep: grown" grep -qx 'size=+' "$T/sfdisk.1"
  check "prep: recorded" grep -qx encrypted "$T/cidata/juniper-encrypt"
}

test_cryptroot_unlock_adopts_finished_tokenless_header() {
  cryptroot_env luks-done-notoken converting
  crt unlock 2>/dev/null
  check "unlock adopt: exit 0" test "$RC" = 0
  check "unlock adopt: token then open" order "cryptsetup token import --token-id 0" "cryptsetup open"
  check "unlock adopt: token root uuid" grep -q '"root_uuid":"U1"' "$T/luks/mmcblk0p3/token0"
  check "unlock adopt: opened" test "$(cat "$T/luks/active")" = mmcblk0p3
  check "unlock adopt: recovery pending" test "$(runf recovery)" = pending
  check "unlock adopt: CIDATA unmounted" called "umount"
  cryptroot_env luks-done-notoken encrypted
  crt unlock 2>/dev/null
  check "unlock adopt: needs the converting marker" not_called "cryptsetup token import"
  cryptroot_env luks-done-notoken converting
  printf '\0\0\0\1' >"$T/tryboot"
  export JUNIPER_TRYBOOT_FLAG=$T/tryboot
  crt unlock 2>/dev/null
  check "unlock adopt: no header write under tryboot" not_called "cryptsetup token import"
}

test_cryptroot_unlock_unfinished_conversion_hint() {
  cryptroot_env luks-notoken converting
  crt unlock 2>/dev/null
  check "unlock unfinished: exit 1" test "$RC" = 1
  check "unlock unfinished: not opened" not_called "cryptsetup open"
  check "unlock unfinished: says it could not resume" grep -q "could not resume" "$T/console"
  check "unlock unfinished: not 'another Pi'" not_grep_dir "another Raspberry Pi" "$T/console"
}

test_cryptroot_first_boot_resume_failure_exits_0() { # prepare exits 0 (brief)
  cryptroot_env plain on
  touch "$T/cs.resume.fail"
  crt prepare 2>/dev/null
  check "prep: resume failure on first boot exits 0" test "$RC" = 0
  check "prep: first-boot resume failure keeps converting" grep -qx converting "$T/cidata/juniper-encrypt"
  check "prep: first-boot resume failure, no token yet" not_called "cryptsetup token import"
  check "prep: first-boot resume failure, run reason" test "$(runf reason)" = "encryption unfinished; the next boot retries"
}

test_cryptroot_c1_needs_converting_marker() {
  local m
  for m in encrypted on; do
    cryptroot_env luks-notoken "$m"
    crt prepare 2>/dev/null
    check "prep ($m): tokenless LUKS untouched" not_called "cryptsetup token import"
    check "prep ($m): no resume" not_called "cryptsetup reencrypt"
  done
  cryptroot_env luks-notoken converting
  setup_case wrongtype
  crt prepare 2>/dev/null
  check "prep: tokenless LUKS of another type untouched" not_called "cryptsetup token import"
}

test_cryptroot_resume_mid_reencrypt() {
  cryptroot_env luks-notoken converting
  crt prepare 2>/dev/null
  check "prep: repair" called "cryptsetup repair --batch-mode --key-file - /dev/mmcblk0p3"
  check "prep: repair then resume" order "cryptsetup repair" "--resume-only"
  check "prep: resume then seal" order "--resume-only" "cryptsetup luksAddKey"
  check "prep: seal then grow" order_last "cryptsetup luksAddKey" "sfdisk -N 3"
  check "prep: grow to max" grep -qx 'size=+' "$T/sfdisk.1"
  check "prep: no relocate on resume" not_called "sfdisk --relocate"
  check "prep: recorded" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: no genkey on resume" not_called "fwkey ensure"
}

test_cryptroot_resume_failure_keeps_converting() {
  cryptroot_env luks-notoken converting
  touch "$T/cs.resume.fail"
  crt prepare 2>/dev/null
  check "prep: resume failure exits 0" test "$RC" = 0
  check "prep: resume failure keeps converting" grep -qx converting "$T/cidata/juniper-encrypt"
  check "prep: resume failure, no seal" not_called "cryptsetup luksAddKey"
  check "prep: resume failure, no grow" not_called "sfdisk"
  rm "$T/cs.resume.fail"
  : >"$CALLS"
  crt prepare 2>/dev/null
  check "prep: next boot finishes" grep -qx encrypted "$T/cidata/juniper-encrypt"
}

test_cryptroot_cut_after_grow_records() { # kill point: after the grow, before the record
  cryptroot_env luks-sealed converting
  crt prepare 2>/dev/null
  check "prep: records encrypted" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "prep: no second grow" not_called sfdisk
  check "prep: no header writes" not_called "cryptsetup luksAddKey"
}

test_cryptroot_encrypted_card_is_quiet() {
  cryptroot_env luks-sealed encrypted
  crt prepare 2>/dev/null
  check "prep: no header writes" test "$(grep -cE '^cryptsetup (reencrypt|luksAddKey|luksKillSlot|token import|repair)' "$CALLS")" = 0
  check "prep: no sfdisk" not_called sfdisk
  check "prep: no CIDATA write" not_called "remount,rw"
  check "prep: no fwkey" not_called fwkey
}

test_cryptroot_no_grow_unless_converting() { # I1: grow only on the encrypting path
  cryptroot_env luks-pending encrypted
  crt prepare 2>/dev/null
  check "prep: encrypted marker, no grow" not_called sfdisk
}

test_cryptroot_seal_retry_kills_slot1_first() { # I5
  cryptroot_env luks-pending converting
  echo "0 1" >"$T/luks/mmcblk0p3/slots"
  crt prepare 2>/dev/null
  check "seal: kill slot 1" called "cryptsetup luksKillSlot --batch-mode --key-file - /dev/mmcblk0p3 1"
  check "seal: kill before add" order "cryptsetup luksKillSlot" "cryptsetup luksAddKey --batch-mode --key-slot 1"
  check "seal: exactly slots 0 and 1" test "$(cat "$T/luks/mmcblk0p3/slots")" = "0 1"
  check "seal: never kills slot 0" not_called "luksKillSlot --batch-mode --key-file - /dev/mmcblk0p3 0"
  check "seal: sealed" grep -q '"recovery":"sealed"' "$T/luks/mmcblk0p3/token0"
}

test_cryptroot_seal_age_failure_leaves_pending() { # C3
  cryptroot_env luks-pending encrypted
  touch "$T/age.fail"
  crt prepare 2>/dev/null
  check "seal: age failure, no luksAddKey" not_called "cryptsetup luksAddKey"
  check "seal: age failure, still pending" grep -q '"recovery":"pending"' "$T/luks/mmcblk0p3/token0"
  check "seal: age failure, no token 1" test ! -e "$T/luks/mmcblk0p3/token1"
  crt unlock 2>/dev/null
  check "seal: unlock reports pending" test "$(runf recovery)" = pending
}

test_cryptroot_seal_cut_after_token1_redoes() { # kill point: after the slot, before `sealed`
  cryptroot_env luks-pending converting
  echo "0 1" >"$T/luks/mmcblk0p3/slots"
  echo '{"type":"juniper-recovery","keyslots":[],"age":"old"}' >"$T/luks/mmcblk0p3/token1"
  echo old >"$T/cidata/juniper-recovery.age"
  crt prepare 2>/dev/null
  check "seal: token 1 replaced" not_grep_dir '"age":"old"' "$T/luks"
  check "seal: file replaced" not_grep_dir '^old$' "$T/cidata/juniper-recovery.age"
  check "seal: slots 0 1" test "$(cat "$T/luks/mmcblk0p3/slots")" = "0 1"
}

test_cryptroot_recovery_via_pipe() {
  cryptroot_env luks-pending encrypted
  crt prepare 2>/dev/null
  check "seal: new key through a pipe" grep -q '^newkey fd3=pipe:' "$CALLS"
  local a b
  a=$(sed -n 's/^age-in sha=//p' "$CALLS")
  b=$(sed -n 's/^newkey .* sha=//p' "$CALLS")
  check "seal: the sealed key is the added key" test -n "$a" -a "$a" = "$b"
  check "seal: no passphrase in argv" not_called "$(fake_pass)"
}

test_cryptroot_token_json_shape() {
  cryptroot_env plain on
  crt prepare 2>/dev/null
  local t0 t1
  t0=$(tok mmcblk0p3 0)
  t1=$(tok mmcblk0p3 1)
  check "token0: exact" test "$t0" = '{"type":"juniper","keyslots":[],"root_uuid":"U1","binding":"juniper.luks.root.v1","id_type":"mmc","recovery":"sealed","recipients":"2"}'
  check "token1: type" grep -q '^{"type":"juniper-recovery","keyslots":\[\],"age":"' "$T/luks/mmcblk0p3/token1"
  check "token1: escaped" grep -qF 'q\"uote\\back\n-----END AGE ENCRYPTED FILE-----\n"}' "$T/luks/mmcblk0p3/token1"
  check "token1: one line" test "$(grep -c '' "$T/luks/mmcblk0p3/token1")" = 1
  check "token1: begins armored" test "${t1%%'\n'*}" = '{"type":"juniper-recovery","keyslots":[],"age":"-----BEGIN AGE ENCRYPTED FILE-----'
}

test_cryptroot_no_header_writes_under_tryboot() { # I9
  local c
  cryptroot_env luks-pending converting
  printf '\0\0\0\1' >"$T/tryboot"
  export JUNIPER_TRYBOOT_FLAG=$T/tryboot
  crt prepare 2>"$T/err"
  for c in "luksAddKey" "luksKillSlot" "token import" "reencrypt" "repair" "sfdisk" "remount,rw"; do
    check "tryboot: no $c" not_called "$c"
  done
  check "tryboot: logged" grep -q 'under tryboot; header changes deferred until a confirmed boot' "$T/err"
  check "tryboot: run file" test -s "$T/run/cryptroot"
  printf '\0\0\0\0' >"$T/tryboot"
  crt prepare 2>/dev/null
  check "tryboot flag 0: sealing runs" called "luksAddKey"
}

test_cryptroot_usb_board_only_encrypts() { # I2
  cryptroot_env plain on
  echo board: >"$T/fw.id"
  crt prepare 2>/dev/null
  check "board: encrypted" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "board: id_type" grep -q '"id_type":"board"' "$T/luks/mmcblk0p3/token0"
  crt unlock 2>/dev/null
  check "board: binding" test "$(runf binding)" = board
}

test_cryptroot_cidata_ro_except_writes() {
  cryptroot_env plain on
  crt prepare 2>/dev/null
  check "cidata: mounted read-only" called "mount -o ro -t vfat /dev/mmcblk0p1 $T/cidata"
  check "cidata: as many ro as rw" test "$(count_calls "remount,rw")" = "$(count_calls "remount,ro")"
  check "cidata: writes happened" test "$(count_calls "remount,rw")" -ge 3
  # a write outside a window would have failed: the stubbed mount makes the dir read-only
  check "cidata: marker written" grep -qx encrypted "$T/cidata/juniper-encrypt"
  check "cidata: blob written" test -s "$T/cidata/juniper-recovery.age"
  check "cidata: unmounted" called "umount"
}

test_cryptroot_adiantum_without_aes() {
  cryptroot_env plain on
  printf 'Features\t: fp asimd evtstrm crc32 cpuid\n' >"$T/cpuinfo"
  crt prepare 2>/dev/null
  check "pi4: adiantum" called "--cipher xchacha12,aes-adiantum-plain64 --key-size 256 --sector-size 512"
}

test_cryptroot_unlock_plain_is_noop() {
  cryptroot_env plain off
  crt prepare
  crt unlock
  check "unlock plain: exit 0" test "$RC" = 0
  check "unlock plain: no open" not_called "cryptsetup open"
  check "unlock plain: no fwkey" not_called fwkey
  check "unlock plain: state" test "$(runf state)" = not-encrypted
  check "unlock plain: one state line" test "$(grep -c '^state=' "$T/run/cryptroot")" = 1
  check "unlock plain: keeps prepare's reason" test "$(runf reason)" = "encrypt: false"
  check "plain boot: prepare and unlock never sleep" not_called sleep
}

test_cryptroot_unlock_tries_each_candidate() {
  cryptroot_env luks-sealed encrypted
  sed -i '1i /dev/sda3 TYPE=xfs LABEL=root UUID=U2 PART_ENTRY_TYPE=b921b045-1df0-41c3-af44-4c6f280d3fae' "$T/blkid.db"
  bsys_part sda 3 4192256 12584927
  luks_card sda3 sealed "0 1"
  touch "$T/luks/sda3/wrongboard"
  crt unlock 2>/dev/null
  check "unlock: exit 0" test "$RC" = 0
  check "unlock: tried sda3" called "cryptsetup open --allow-discards --key-file - /dev/sda3 juniper-root"
  check "unlock: then mmcblk0p3" order "/dev/sda3 juniper-root" "/dev/mmcblk0p3 juniper-root"
  check "unlock: derive per disk" called "fwkey derive mmcblk0"
  check "unlock: opened" test "$(cat "$T/luks/active")" = mmcblk0p3
  check "unlock: fwkey lock once" test "$(count_calls "fwkey lock")" = 1
  check "unlock: lock after open" order "/dev/mmcblk0p3 juniper-root" "fwkey lock"
  check "unlock: state" test "$(runf state)" = encrypted
  check "unlock: cipher" test "$(runf cipher)" = aes-xts-plain64
  check "unlock: binding" test "$(runf binding)" = board+mmc
  check "unlock: key_lock" test "$(runf key_lock)" = unavailable
  check "unlock: recovery" test "$(runf recovery)" = sealed:2
  check "unlock: no sleep" not_called sleep
  check "unlock: no header writes" not_called "token import"
}

test_cryptroot_unlock_ignores_other_root_uuid() {
  cryptroot_env luks-sealed encrypted
  sed -i 's/"root_uuid":"U1"/"root_uuid":"U9"/' "$T/luks/mmcblk0p3/token0"
  crt unlock 2>/dev/null
  check "unlock: another release's root not opened" not_called "cryptsetup open"
}

test_cryptroot_unlock_ignores_unknown_token_fields() {
  cryptroot_env luks-sealed encrypted
  sed -i 's/}$/,"future":"x","n":"7"}/' "$T/luks/mmcblk0p3/token0"
  crt unlock 2>/dev/null
  check "unlock: unknown fields ignored" test "$(runf recovery)" = sealed:2
}

test_cryptroot_unlock_skips_unfinished_conversion() {
  cryptroot_env luks-notoken converting
  crt unlock 2>/dev/null
  check "unlock: half-encrypted root not opened" not_called "cryptsetup open"
}

test_cryptroot_unlock_failure_under_tryboot_exits_fast() {
  cryptroot_env luks-sealed encrypted
  touch "$T/luks/mmcblk0p3/wrongboard"
  printf '\0\0\0\1' >"$T/tryboot"
  export JUNIPER_TRYBOOT_FLAG=$T/tryboot JUNIPER_UNLOCK_FAIL_DELAY=120
  check "unlock tryboot: exit 1" fails "$LIBEXEC/cryptroot" unlock
  check "unlock tryboot: no sleep" not_called sleep
  check "unlock tryboot: one try" test "$(count_calls "cryptsetup open")" = 1
  check "unlock tryboot: no console hint" test ! -e "$T/console"
}

test_cryptroot_unlock_failure_normal_boot_hint() {
  cryptroot_env luks-sealed encrypted
  touch "$T/luks/mmcblk0p3/wrongboard"
  check "unlock: exit 1" fails "$LIBEXEC/cryptroot" unlock
  check "unlock: three tries" test "$(count_calls "cryptsetup open")" = 3
  check "unlock: 10 s apart" test "$(count_calls "sleep 10")" = 2
  check "unlock: then the delay" called "sleep 0"
  check "unlock: console hint" grep -q "just unlock-card" "$T/console"
  check "unlock: no rebind promise" not_grep_dir rebind "$T/console"
  check "unlock: no lock on failure" not_called "fwkey lock"
}

test_cryptroot_unlock_no_device_leaves_it_to_dracut() {
  cryptroot_env plain on
  : >"$T/blkid.db"
  crt unlock 2>/dev/null
  check "unlock: nothing found exits 0" test "$RC" = 0
  check "unlock: nothing found, no hint" test ! -e "$T/console"
}

test_cryptroot_usage() {
  cryptroot_env plain off
  local rc
  rc=0
  "$LIBEXEC/cryptroot" bogus 2>/dev/null || rc=$?
  check "cryptroot: unknown command exits 2" test "$rc" = 2
  rc=0
  "$LIBEXEC/cryptroot" 2>/dev/null || rc=$?
  check "cryptroot: no command exits 2" test "$rc" = 2
  rc=0
  "$LIBEXEC/cryptroot" prepare extra 2>/dev/null || rc=$?
  check "cryptroot: extra argument exits 2" test "$rc" = 2
  check "cryptroot: no set -x" not_grep_dir '^[[:space:]]*set -[a-zA-Z]*x' "$LIBEXEC/cryptroot"
}

# --- #81: hardware-run follow-ups ---
test_second_strike_writes_update_held_at_once() {
  strike_env
  fail_boot boot-1
  check "held at fallback: one strike -> no update-held" test ! -e "$JUNIPER_STATE_DIR/update-held"
  fail_boot boot-2
  check "held at fallback: second strike writes update-held" \
    test "$(cat "$JUNIPER_STATE_DIR/update-held")" = "update $BAD failed its health check twice; waiting for a newer image"
  stub fastfetch ''
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl '[[ $* != *is-failed* ]]'
  check "held at fallback: motd shows it" stdout_has "failed its health check twice" "$LIBEXEC/motd"
}

test_update_unhold() {
  check "update-unhold: nothing held" stdout_has "nothing held" "$LIBEXEC/update-unhold"
  printf '%s 2 boot-2\n%s 1 boot-3\n' "$BAD" "$NEW" >"$JUNIPER_STATE_DIR/bad-digests"
  echo "update $BAD failed its health check twice; waiting for a newer image" >"$JUNIPER_STATE_DIR/update-held"
  check "update-unhold: names the first digest" stdout_has "$BAD" "$LIBEXEC/update-unhold"
  printf '%s 2 boot-2\n%s 1 boot-3\n' "$BAD" "$NEW" >"$JUNIPER_STATE_DIR/bad-digests"
  echo held >"$JUNIPER_STATE_DIR/update-held"
  check "update-unhold: names the second digest" stdout_has "$NEW" "$LIBEXEC/update-unhold"
  check "update-unhold: bad-digests removed" test ! -e "$JUNIPER_STATE_DIR/bad-digests"
  check "update-unhold: update-held removed" test ! -e "$JUNIPER_STATE_DIR/update-held"
  check "update-unhold: second run says nothing held" stdout_has "nothing held" "$LIBEXEC/update-unhold"
  echo held >"$JUNIPER_STATE_DIR/update-held"
  check "update-unhold: only a note -> cleared" stdout_has "Cleared" "$LIBEXEC/update-unhold"
  check "update-unhold: note removed" test ! -e "$JUNIPER_STATE_DIR/update-held"
  # End to end: after unhold a previously held digest is tried again.
  strike_env
  fail_boot boot-1
  fail_boot boot-2
  "$LIBEXEC/update-unhold" >/dev/null
  staged_digest "$BAD"
  "$LIBEXEC/apply-update" >/dev/null
  check "update-unhold: the held digest goes ahead again" called "bootloader tryreboot"
  local j=$ROOT/system_files/usr/share/juniper/just/update.just
  check "update-unhold: recipe runs it with sudo" grep -qx '    sudo /usr/libexec/juniper/update-unhold' "$j"
}

test_pi_status_does_not_echo_recipe_lines() {
  local j=$ROOT/system_files/usr/share/juniper/just/pi.just
  check "pi-status: every recipe line is @-prefixed" \
    test -z "$(sed -n '/^pi-status:/,/^$/p' "$j" | sed 1d | sed '/^$/d' | grep -v '^    @')"
}

test_lan_ssh_default_sources_skip_host_routes_and_covered_prefixes() {
  fw_fake
  stub ip 'case "$*" in
  "-j route show scope link") echo "[{\"dst\":\"192.168.1.0/24\",\"dev\":\"eth0\"},{\"dst\":\"192.168.1.7\",\"dev\":\"eth0\"},{\"dst\":\"10.0.0.5/32\",\"dev\":\"eth0\"},{\"dst\":\"10.0.0.0/24\",\"dev\":\"eth0\"},{\"dst\":\"10.0.0.0/25\",\"dev\":\"eth0\"}]" ;;
  "-j -6 route show") echo "[{\"dst\":\"fe80::/64\",\"dev\":\"eth0\"},{\"dst\":\"fe80::1/128\",\"dev\":\"eth0\"},{\"dst\":\"2001:db8:1::5/128\",\"dev\":\"eth0\"},{\"dst\":\"2001:db8:1::/64\",\"dev\":\"eth0\"}]" ;;
esac'
  "$LIBEXEC/lan-ssh" on >/dev/null 2>&1
  check "lan-ssh default: network kept" perm_has ipv4 192.168.1.0/24
  check "lan-ssh default: v6 network kept" perm_has ipv6 2001:db8:1::/64
  check "lan-ssh default: fe80::/10 kept" perm_has ipv6 fe80::/10
  check "lan-ssh default: v4 host route (bare) dropped" not_grep_dir 192.168.1.7 "$T/fw"
  check "lan-ssh default: v4 /32 dropped" not_grep_dir 10.0.0.5 "$T/fw"
  check "lan-ssh default: v6 /128 dropped" not_grep_dir 2001:db8:1::5 "$T/fw"
  check "lan-ssh default: fe80::1/128 dropped" not_grep_dir 'fe80::1/' "$T/fw"
  check "lan-ssh default: fe80::/64 covered by fe80::/10" not_grep_dir 'fe80::/64' "$T/fw"
  check "lan-ssh default: /25 covered by /24" not_grep_dir '10.0.0.0/25' "$T/fw"
  check "lan-ssh default: covering /24 kept" perm_has ipv4 10.0.0.0/24
  # Explicit CIDRs are the user's choice: a host stays.
  : >"$T/fw/perm_rich"
  "$LIBEXEC/lan-ssh" on 192.168.5.7 >/dev/null
  check "lan-ssh explicit: host kept as /32" perm_has ipv4 192.168.5.7/32
}

test_version_label_and_first_boot_reboot_guard() {
  # shellcheck disable=SC2016 # literal $IMAGE_VERSION
  check "Containerfile: image version label" \
    grep -qx 'LABEL org.opencontainers.image.version=$IMAGE_VERSION' "$ROOT/Containerfile"
  check "build.yml: version label checked" grep -q 'org.opencontainers.image.version' "$ROOT/.github/workflows/build.yml"
  local f cond
  for f in "$ROOT/system_files/usr/lib/systemd/system/juniper-reboot.service" \
    "$ROOT/system_files_desktop/usr/lib/systemd/system/juniper-reboot-retry.service"; do
    cond=$(grep -m1 "^ExecCondition=/usr/bin/awk" "$f" || true)
    check "${f##*/}: skips the first 10 minutes after boot" test -n "$cond"
    # Run the condition against a fake /proc/uptime ($$ is systemd's escape for $).
    cond=${cond#ExecCondition=/usr/bin/awk }
    cond=${cond//\$\$/\$}
    cond=${cond//\/proc\/uptime/$T/uptime}
    echo "120.5 400.1" >"$T/uptime"
    check "${f##*/}: 2 minutes up -> skipped" fails eval "awk ${cond}"
    echo "601.0 400.1" >"$T/uptime"
    check "${f##*/}: 10+ minutes up -> runs" eval "awk ${cond}"
  done
}

# --- runner ---
# UNIT_FILTER=REGEX runs only the matching tests (e.g. UNIT_FILTER=cryptroot tests/unit.sh).
# --- initramfs completeness (issue #50): the dracut module installs every command ---
MODSETUP=$ROOT/system_files/usr/lib/dracut/modules.d/90juniper-cryptroot/module-setup.sh
modsetup_cmds() { # the words of module-setup.sh's inst_multiple call (with its continuations)
  sed -n '/^[[:space:]]*inst_multiple/,/[^\\]$/p' "$MODSETUP" | tr -d '\134' | tr -s ' \t' '\n' |
    grep -v -e '^$' -e '^inst_multiple$' -e '^-o$'
}

refuses() { ! python3 "$ROOT/tests/script-commands.py" "$1" >/dev/null 2>&1; }
test_script_commands_parser() { # the extractor itself, on the constructs the scripts use
  local f=$T/s out
  # shellcheck disable=SC2016 # a script under test, not expanded here
  printf '%s\n' '#!/usr/bin/env bash' 'set -e' 'x=${FOO_BIN:-/usr/bin/foo}' 'f() { printf "%s" "$1" | a1; }' \
    'v=$(b1 -x "$(b2 <"$f")" 2>/dev/null || true)' 'case $v in' '  one | two) c1 ;;' \
    '  *" q,r"*)' '    c2 | c3' '    ;;' 'esac' 'if [[ $v =~ ^(a|b)[[:space:]]*$ && $(d1) == 4 ]]; then ((n++)); fi' \
    'exec {fd}< <(exec </dev/null 2>&1; "$x" | e1)' 'while read -r l; do :; done < <(e2 a)' \
    'with_key() { "$@"; }' 'with_key d g1 --opt' 'timeout -s KILL 5 g2' 'arr=("$(h1)" b)' \
    'trap cleanup EXIT' 'cleanup() { i1; }' 'f "$(j1)" &&' '  k1' 'f x # l1 in a comment' \
    "echo 'm1 in quotes' \"\$((1 + 2))\"" >"$f"
  out=$(python3 "$ROOT/tests/script-commands.py" "$f" | tr '\n' ' ')
  check "script-commands: every construct" test "$out" = \
    '$@ /usr/bin/foo a1 b1 b2 bash c1 c2 c3 d1 e1 e2 env g1 g2 h1 i1 j1 k1 timeout '
  printf '%s\n' 'cat <<EOF' 'x' 'EOF' >"$f"
  check "script-commands: refuses a here-document" refuses "$f"
  # shellcheck disable=SC2016
  printf '%s\n' 'x=`date`' >"$f"
  check "script-commands: refuses backticks" refuses "$f"
}

test_initramfs_installs_every_script_command() {
  local c cmds have
  cmds=$(python3 "$ROOT/tests/script-commands.py" "$LIBEXEC/cryptroot" "$LIBEXEC/fwkey")
  have=$(modsetup_cmds)
  check "initramfs: the extractor found cryptsetup and wc" test -n "$(grep -x cryptsetup <<<"$cmds")" -a -n "$(grep -x wc <<<"$cmds")"
  for c in $cmds; do
    # shellcheck disable=SC2016 # '$@' etc. are literal names, not expansions
    case $c in
      # with_key's "$@" (its commands are listed by name), fwkey's dispatch to its own functions
      '$@' | '$cmd' | '$input') ;;
      /*) check "initramfs: module-setup.sh installs $c" grep -Eq "inst_simple $c( |\$)" "$MODSETUP" ;;
      '$'*) check "initramfs: unresolved command $c (resolve it or allowlist it here)" false ;;
      *) check "initramfs: inst_multiple has $c" grep -qx -- "$c" <<<"$have" ;;
    esac
  done
}

for t in $(declare -F | awk -v f="${UNIT_FILTER:-.}" '$3 ~ /^test_/ && $3 ~ f {print $3}'); do
  setup
  "$t"
  rm -rf "$T"
done
if ((fails)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
