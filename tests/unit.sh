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

# fails CMD...: CMD exits non-zero (stderr hidden). stderr_has PATTERN CMD...: CMD's stderr matches.
fails() { ! "$@" 2>/dev/null; }
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
