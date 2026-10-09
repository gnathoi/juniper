#!/usr/bin/env bash
# Unit tests for system_files/usr/libexec/juniper/*. Real commands (bootc, tailscale,
# firewall-cmd, systemctl, ...) are replaced by stubs on PATH that append their argv to
# $CALLS. Run: tests/unit.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC2034 # used by the tests added in later tasks
LIBEXEC=$ROOT/system_files/usr/libexec/juniper
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
  stub shred 'if [[ $1 == -u ]]; then rm -f "$2"; fi'
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
    JUNIPER_CLOUD_DISABLED=$T/cloud-init.disabled
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

test_firstboot_rerun_after_power_loss() {
  firstboot_env
  "$LIBEXEC/firstboot"
  "$LIBEXEC/firstboot"
  check "firstboot rerun: still scrubbed" not_grep_dir secret "$JUNIPER_CIDATA_DIR"
  check "firstboot rerun: marked done" test -e "$JUNIPER_STATE_DIR/firstboot.done"
}

test_firstboot_mounts_cidata_by_label() {
  firstboot_env
  unset JUNIPER_CIDATA_DIR
  stub blkid 'echo /dev/mmcblk0p1'
  # mount is stubbed, so the trap's rmdir fails on the non-empty dir; keep it under $T
  TMPDIR=$T "$LIBEXEC/firstboot" || true
  check "firstboot: looks up CIDATA label" called "blkid -L CIDATA"
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
