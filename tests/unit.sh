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
fails=0

setup() {
  T=$(mktemp -d)
  export CALLS=$T/calls JUNIPER_STATE_DIR=$T/state
  mkdir -p "$T/bin" "$JUNIPER_STATE_DIR"
  : >"$CALLS"
  for cmd in bootc tailscale firewall-cmd systemctl ip rpi-bootc-bootloader \
    mount umount blkid chown timedatectl; do
    stub "$cmd" ''
  done
  # shellcheck disable=SC2016 # expands inside the stub
  stub shred 'for a; do [[ $a == -* || $a == "$T"/* ]] || { echo "shred outside test dir: $a" >&2; exit 1; }; done
if [[ $1 == -u ]]; then rm -f "$2"; fi'
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
  check "apply-update: no staged -> no reboot" not_called rpi-bootc-bootloader
}

test_apply_update_with_staged() {
  stub bootc 'echo "{\"status\":{\"staged\":{\"image\":{}}}}"'
  "$LIBEXEC/apply-update"
  check "apply-update: staged -> tryreboot" called "rpi-bootc-bootloader tryreboot"
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

health_env() {
  export JUNIPER_HEALTH_TRIES=1 JUNIPER_HEALTH_INTERVAL=0 JUNIPER_TRYBOOT_FLAG=$T/tryboot
}

test_healthcheck_healthy_confirms() {
  health_env
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  "$LIBEXEC/healthcheck"
  check "health: healthy -> make booted the firmware default" called "rpi-bootc-bootloader sync"
}

test_healthcheck_unhealthy_tryboot_falls_back() {
  health_env
  printf '\x00\x00\x00\x01' >"$JUNIPER_TRYBOOT_FLAG"
  "$LIBEXEC/healthcheck" || true
  check "health: unhealthy tryboot -> reboot" called "systemctl reboot"
  check "health: unhealthy -> no sync" not_called "rpi-bootc-bootloader sync"
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
  check "health: healthy tryboot -> sync" called "rpi-bootc-bootloader sync"
  check "health: healthy tryboot -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_ipv6_only_route_is_healthy() {
  health_env
  # shellcheck disable=SC2016 # expands inside the stub
  stub ip 'if [[ $* == *-6* ]]; then echo "default via fe80::1 dev end0 proto ra"; fi'
  "$LIBEXEC/healthcheck"
  check "health: IPv6-only default route -> healthy" called "rpi-bootc-bootloader sync"
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
  stub tailscale 'case $1 in status) echo "{\"BackendState\":\"Running\"}" ;; debug) echo "{\"RunSSH\":true}" ;; esac'
  "$LIBEXEC/healthcheck"
  check "health: locked + Tailscale SSH -> healthy" called "rpi-bootc-bootloader sync"
  check "health: locked + Tailscale SSH -> no reboot" not_called "systemctl reboot"
}

test_healthcheck_locked_sshd_is_healthy() {
  health_env
  touch "$JUNIPER_STATE_DIR/locked"
  stub ip 'echo "default via 192.168.1.1 dev wlan0"'
  # shellcheck disable=SC2016 # expands inside the stub
  stub tailscale 'case $1 in status) echo "{\"BackendState\":\"Running\"}" ;; debug) echo "{\"RunSSH\":false}" ;; esac'
  # shellcheck disable=SC2016 # expands inside the stub
  stub systemctl 'if [[ $1 == is-active ]]; then echo active; fi'
  "$LIBEXEC/healthcheck"
  check "health: locked + sshd (ujust tailscale-ssh off) -> healthy" called "rpi-bootc-bootloader sync"
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
  check "health: no hook dir -> healthy" called "rpi-bootc-bootloader sync"
  mkdir -p "$JUNIPER_HEALTH_D"
  printf '#!/bin/sh\nexit 0\n' >"$JUNIPER_HEALTH_D/10-ok" && chmod +x "$JUNIPER_HEALTH_D/10-ok"
  : >"$CALLS"
  "$LIBEXEC/healthcheck"
  check "health: passing hook -> healthy" called "rpi-bootc-bootloader sync"
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
stderr_has() { { "${@:2}" 2>&1 >/dev/null || true; } | grep -q -- "$1"; }

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
  for c in '"GB\ninstall cfg80211 /bin/sh"' '"G\x01"' '"G\tB"' GBR '"G"' '"12"' 44; do
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
  export JUNIPER_NOW=2000000000
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

ts_join_env() {
  export JUNIPER_TAILSCALE_KEY=$T/authkey JUNIPER_NOW=2000000000
  echo "tskey-auth-secret" >"$JUNIPER_TAILSCALE_KEY"
  touch -d @$((2000000000 - 86400)) "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_success_shreds_key() {
  ts_join_env
  check "ts join: success exits 0" "$LIBEXEC/tailscale-join"
  check "ts join: joins with ssh and the key file" called "tailscale up --ssh --auth-key=file:$JUNIPER_TAILSCALE_KEY --timeout=120s"
  check "ts join: success shreds the key" test ! -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: success leaves no marker" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
}

test_tailscale_join_network_failure_keeps_key() {
  ts_join_env
  stub tailscale 'echo "timeout waiting for the backend" >&2; exit 1'
  check "ts join: network failure exits non-zero (systemd retries)" fails "$LIBEXEC/tailscale-join"
  check "ts join: network failure keeps the key" test -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: network failure writes no marker" test ! -e "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
}

test_tailscale_join_rejected_key_gives_up() {
  ts_join_env
  stub tailscale 'echo "backend error: invalid key: unable to validate API key" >&2; exit 1'
  check "ts join: rejected key exits 0 (no retry)" "$LIBEXEC/tailscale-join"
  check "ts join: rejected key shredded" test ! -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: rejected key writes marker with reason" grep -q rejected "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
}

test_tailscale_join_old_key_gives_up() {
  ts_join_env
  touch -d @$((2000000000 - 15 * 86400)) "$JUNIPER_TAILSCALE_KEY"
  check "ts join: 15-day-old key exits 0" "$LIBEXEC/tailscale-join"
  check "ts join: old key shredded" test ! -e "$JUNIPER_TAILSCALE_KEY"
  check "ts join: old key writes marker with reason" grep -q "older than 14 days" "$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  check "ts join: old key never tries to join" not_called "tailscale up"
}

test_tailscale_join_fresh_key_network_failure_keeps_key() {
  ts_join_env
  touch -d @$((2000000000 - 13 * 86400)) "$JUNIPER_TAILSCALE_KEY"
  stub tailscale 'echo "dial tcp: lookup controlplane.tailscale.com: no such host" >&2; exit 1'
  check "ts join: 13-day-old key + network failure fails" fails "$LIBEXEC/tailscale-join"
  check "ts join: 13-day-old key kept" test -e "$JUNIPER_TAILSCALE_KEY"
}

test_tailscale_join_max_days_override() {
  ts_join_env
  check "ts join: max days override gives up" env JUNIPER_TAILSCALE_KEY_MAX_DAYS=0 "$LIBEXEC/tailscale-join"
  check "ts join: override shreds" test ! -e "$JUNIPER_TAILSCALE_KEY"
}

test_motd_shows_tailscale_gave_up() {
  echo "key rejected by Tailscale on 2033-05-18" >"$JUNIPER_STATE_DIR/tailscale-join-gave-up"
  stub tailscale 'exit 1'
  check "motd: gave-up shown with recovery" stdout_has "ujust tailscale-up" "$LIBEXEC/motd"
}

# --- runner ---
for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  setup
  "$t"
  rm -rf "$T"
done
if ((fails)); then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
