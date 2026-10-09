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
  for cmd in bootc tailscale firewall-cmd systemctl shred ip rpi-bootc-bootloader \
    mount umount blkid chown timedatectl; do
    stub "$cmd" ''
  done
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

test_update_schedule_sets_time() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  stub timedatectl 'echo Europe/London'
  out=$("$LIBEXEC/update-schedule" 03:30)
  check "schedule: drop-in written" grep -qx 'OnCalendar=\*-\*-\* 03:30:00' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: resets OnCalendar first" grep -qx 'OnCalendar=' "$JUNIPER_DROPIN_DIR/schedule.conf"
  check "schedule: timer re-enabled" called "systemctl enable --now juniper-reboot.timer"
  check "schedule: names the timezone" grep -q 'Europe/London' <<<"$out"
}

test_update_schedule_rejects_bad_input() {
  export JUNIPER_DROPIN_DIR=$T/dropin
  for bad in 24:00 3:30 03:3 '03:30;reboot' 'now'; do
    # shellcheck disable=SC2016 # $0/$1 expand in the inner bash
    check "schedule: rejects '$bad'" bash -c '! "$0" "$1" 2>/dev/null' "$LIBEXEC/update-schedule" "$bad"
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
