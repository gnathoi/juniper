#!/usr/bin/env bash
# First-boot root encryption against loop devices (issue #50): the real cryptroot, cryptsetup,
# sfdisk, partx, blkid and age on a GPT disk laid out like bib's. Only the firmware is
# stubbed: `fwkey` (JUNIPER_FWKEY) derives a fixed key. Needs root, loop devices and dm-crypt:
#   sudo just image=juniper-minimal test-cryptroot     (privileged container, as CI runs it)
#   sudo tests/cryptroot-loop.sh                       (on a Pi, from a checkout)
# Knobs: CRYPTROOT=path (script under test; default: the checkout's, else the image's),
# ADD_REBIND_SLOT=path (default: the checkout's disk/add-rebind-slot, else /disk/add-rebind-slot),
# ONLY=REGEX (scenario names), WORKDIR=dir (default /var/tmp), GPT_SIZE=8G, DISK_SIZE=10G,
# DATA_MIB=1024 (smaller values spare an SD card), KILL_DELAY=2 (seconds into the resume).
# Each kill point SIGKILLs cryptroot's process group, emulates a reboot (unmount, detach,
# reattach, empty /run) and runs prepare again; every encrypted end state gets the same checks.
set -Eeuo pipefail
trap 'echo "cryptroot-loop.sh:$LINENO: failed: $BASH_COMMAND" >&2' ERR

here=$(cd "$(dirname "$0")" && pwd)
U=${ROOT_UUID:-66f85224-e922-4b9c-8854-731adda9f5c3}
KEY=7f1c0de5a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829304152 # the stub's board key
GPT_SIZE=${GPT_SIZE:-8G}
DISK_SIZE=${DISK_SIZE:-10G}
DATA_MIB=${DATA_MIB:-1024}
KILL_DELAY=${KILL_DELAY:-2}
ROOT_TYPE=b921b045-1df0-41c3-af44-4c6f280d3fae

die() {
  echo "cryptroot-loop: $*" >&2
  exit 1
}
((EUID == 0)) || die "needs root (loop devices, dm-crypt, mount)"

if [[ -n ${CRYPTROOT:-} ]]; then
  :
elif [[ -x $here/../system_files/usr/libexec/juniper/cryptroot ]]; then
  CRYPTROOT=$(cd "$here/.." && pwd)/system_files/usr/libexec/juniper/cryptroot
else
  CRYPTROOT=/usr/libexec/juniper/cryptroot
fi
[[ -x $CRYPTROOT ]] || die "no cryptroot at $CRYPTROOT"
# The laptop half of `just rebind-card` (disk/ in a checkout; /disk in `just test-cryptroot`).
ADD_REBIND_SLOT=${ADD_REBIND_SLOT:-}
for f in "$here/../disk/add-rebind-slot" /disk/add-rebind-slot; do
  [[ -n $ADD_REBIND_SLOT || ! -r $f ]] || ADD_REBIND_SLOT=$f
done
[[ -n $ADD_REBIND_SLOT ]] || die "no disk/add-rebind-slot (mount the checkout's disk/ at /disk)"

if ! command -v mkfs.vfat >/dev/null && [[ -e /run/.containerenv ]]; then
  echo "mkfs.vfat missing; installing dosfstools in this throwaway container"
  dnf -y -q install dosfstools >/dev/null || die "could not install dosfstools"
fi
for c in cryptsetup sfdisk partx blkid blockdev losetup mount umount mountpoint setsid \
  mkfs.vfat mkfs.xfs openssl ssh-keygen age sha256sum od dmsetup; do
  command -v "$c" >/dev/null || die "missing command: $c"
done
[[ -e /dev/mapper/control ]] || die "no /dev/mapper/control (device-mapper)"
[[ ! -e /dev/mapper/juniper-root ]] || die "/dev/mapper/juniper-root already exists here"
# Never share a root UUID with a disk this machine already has (cryptroot would see two).
if [[ -n $(blkid -c /dev/null -t "UUID=$U" -o device 2>/dev/null || true) ]]; then
  U=$(cat /proc/sys/kernel/random/uuid)
  echo "the default root UUID exists on this machine; using $U"
fi

W=$(mktemp -d -p "${WORKDIR:-/var/tmp}" cryptroot-loop.XXXXXX)
REAL_PATH=$PATH
LOOP=
P3=
fails=0
passes=0
scenario=

cleanup() {
  set +e
  trap - ERR
  # detach can die (exit), which would end this trap before the work dir goes: a subshell.
  (detach) || echo "cleanup: could not detach cleanly" >&2
  for m in "$W/m" "$W/c" "$W/cidata-mnt"; do
    while mountpoint -q "$m" 2>/dev/null; do umount -l "$m"; done
  done
  if [[ -z ${KEEP:-} ]]; then rm -rf "$W"; else echo "kept $W"; fi
}
trap cleanup EXIT

# --- results ---
check() {
  local name=$1
  shift
  if "$@"; then
    passes=$((passes + 1))
    echo "ok   $scenario: $name"
  else
    fails=$((fails + 1))
    echo "FAIL $scenario: $name"
  fi
}
eq() {
  [[ $1 == "$2" ]] && return 0
  echo "     got '$1', want '$2'"
  return 1
}
# Same JSON matching as cryptroot (all values are strings; export may pretty-print).
jfield() {
  local v
  v=$(printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
  printf '%s' "${v%%$'\n'*}"
}

# --- the firmware stub and the kill hooks ---
mkdir -p "$W/hook" "$W/m" "$W/c"
cat >"$W/fwkey" <<EOF
#!/usr/bin/env bash
# fwkey stub: the CLI contract of system_files/usr/libexec/juniper/fwkey. FWKEY_MODE picks
# ok | unavailable (KEY_LOCKED: ensure fails) | derive-fail (derive prints nothing).
echo "fwkey \$*" >>"\$FWKEY_LOG"
mode=\${FWKEY_MODE:-ok}
case \$1 in
  probe) if [[ \$mode == unavailable ]]; then echo locked; else echo ok; fi ;;
  ensure) if [[ \$mode == unavailable ]]; then echo "unavailable:key locked"; exit 1; fi; echo ok ;;
  card-id) echo "mmc:0123456789abcdef0123456789abcdef" ;;
  derive) if [[ \$mode == derive-fail ]]; then exit 1; fi; if [[ -r $W/board.key ]]; then cat $W/board.key; else printf '%s' $KEY; fi ;;
  lock) echo unavailable ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$W/fwkey"

# hook: logs its argv (never a secret: those go through stdin), runs the real command, and at
# the kill point (KILL_WHEN before|after|during, KILL_MATCH regex on "name args", KILL_NTH-th
# match) SIGKILLs cryptroot's whole process group, itself included.
cat >"$W/hook/hook" <<'EOF'
#!/usr/bin/env bash
name=${0##*/}
real=$(PATH=$REAL_PATH command -v "$name") || exit 127
printf '%s\n' "$name $*" >>"$HOOK_LOG"
when=
if [[ -n ${KILL_MATCH:-} && ! -e $KILL_DONE && "$name $*" =~ $KILL_MATCH ]]; then
  n=$(($(cat "$KILL_COUNT" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$KILL_COUNT"
  if ((n == ${KILL_NTH:-1})); then when=$KILL_WHEN; fi
fi
[[ -n $when ]] || exec "$real" "$@"
read -r st </proc/$$/stat
read -r _ _ pg _ <<<"${st##*) }"
[[ $pg != "$TEST_PGID" ]] || { echo "hook: refusing to kill the test's own group" >&2; exit 1; }
killgroup() {
  echo "$pg" >"$KILL_DONE.pg"
  printf '%s %s\n' "$1" "$name $2" >"$KILL_DONE"
  kill -9 -- "-$pg"
  sleep 10
  exit 99
}
case $when in
  before) killgroup before "$*" ;;
  after)
    "$real" "$@"
    killgroup "after(rc=$?)" "$*"
    ;;
  during)
    exec 3<&0
    "$real" "$@" <&3 3<&- &
    cpid=$!
    sleep "$KILL_DELAY"
    if kill -0 "$cpid" 2>/dev/null; then killgroup during "$*"; fi
    echo "finished before the kill (raise DISK/GPT size or lower KILL_DELAY)" >"$KILL_MISSED"
    wait "$cpid"
    ;;
esac
EOF
chmod +x "$W/hook/hook"
for c in cryptsetup sfdisk partx age; do ln -s hook "$W/hook/$c"; done
read -r st </proc/$$/stat
read -r _ _ TEST_PGID _ <<<"${st##*) }"
export REAL_PATH TEST_PGID KILL_DELAY HOOK_LOG=$W/hook.log FWKEY_LOG=$W/fwkey.log \
  KILL_DONE=$W/kill.done KILL_COUNT=$W/kill.count KILL_MISSED=$W/kill.missed

# --- recovery recipients ---
ssh-keygen -q -t ed25519 -N '' -C juniper-test -f "$W/id_ed25519"
ssh-keygen -q -t ecdsa -b 256 -N '' -C juniper-test -f "$W/id_ecdsa"
ssh-keygen -q -t ed25519 -N '' -C juniper-test-new -f "$W/id_new"
printf 'Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$W/cpuinfo-aes"
printf 'Features\t: fp asimd evtstrm crc32 cpuid\n' >"$W/cpuinfo-noaes"
printf '\0\0\0\1' >"$W/tryboot-1"
echo "root=UUID=$U rw" >"$W/cmdline"

# --- the disk ---
# attach: LOOP and P3 for $W/disk.img, partitions visible.
attach() {
  local i
  LOOP=$(losetup -fP --show "$W/disk.img")
  P3=${LOOP}p3
  for ((i = 0; i < 100; i++)); do
    node_ready "${LOOP}p1" && node_ready "$P3" && return 0
    sleep 0.1
  done
  die "no partitions on $LOOP"
}
# node_ready DEV: the kernel has the partition and the /dev node is its current one (after a
# detach the old node can linger a moment, and a mount through it fails "Can't lookup blockdev").
node_ready() {
  local sys=/sys/class/block/${1##*/}/dev want maj min
  [[ -r $sys && -b $1 ]] || return 1
  read -r want <"$sys" 2>/dev/null || return 1
  read -r maj min < <(stat -c '%t %T' "$1") || return 1
  [[ $want == "$((16#$maj)):$((16#$min))" ]]
}
# detach: close and unmount whatever uses the disk, then drop the loop device.
detach() {
  local m d
  [[ -n $LOOP ]] || return 0
  for m in "$W/m" "$W/c" "$W/cidata-mnt"; do
    while mountpoint -q "$m" 2>/dev/null; do umount "$m" || umount -l "$m"; done
  done
  [[ -e /dev/mapper/juniper-root ]] && cryptsetup close juniper-root
  for d in $(dmsetup ls 2>/dev/null | awk '{print $1}'); do
    if dmsetup deps -o devname "$d" 2>/dev/null | grep -q "(${LOOP##*/}p"; then
      echo "     leftover dm device $d on $LOOP; removing" >&2
      dmsetup remove --force "$d" || true
    fi
  done
  losetup -d "$LOOP"
  for ((i = 0; i < 50; i++)); do
    [[ -z $(losetup -j "$W/disk.img") ]] && break
    sleep 0.1
  done
  [[ -z $(losetup -j "$W/disk.img") ]] || die "$LOOP is still attached (held by: $(ls /sys/block/"${LOOP##*/}"/holders 2>/dev/null))"
  for ((i = 0; i < 50; i++)); do
    compgen -G "/sys/class/block/${LOOP##*/}p*" >/dev/null || compgen -G "${LOOP}p*" >/dev/null || break
    sleep 0.1
  done
  LOOP=
  P3=
}
# reboot: a power cycle as far as cryptroot can tell (the disk's writes all survive, though).
reboot() {
  group_gone
  detach
  rm -rf "$W/run"
  attach
}

# group_alive PGID: a member of the process group is still running (zombies hold nothing).
group_alive() {
  local f st state g
  for f in /proc/[0-9]*/stat; do
    st=$(cat "$f" 2>/dev/null) || continue
    read -r state _ g _ <<<"${st##*) }"
    [[ $g == "$1" && $state != Z ]] && return 0
  done
  return 1
}
# group_gone: wait until the SIGKILLed process group has fully exited.
group_gone() {
  local pg i
  [[ -r $KILL_DONE.pg ]] || return 0
  read -r pg <"$KILL_DONE.pg" || [[ -n ${pg:-} ]] || return 0
  for ((i = 0; i < 100; i++)); do
    group_alive "$pg" || return 0
    sleep 0.1
  done
  echo "     process group $pg still running 10 s after the kill" >&2
}

# The plaintext disk, made once: GPT written on GPT_SIZE then the file grown to DISK_SIZE
# (bib's backup GPT is not at the end of the card), p3 XFS root with DATA_MIB of random files.
CANARY="juniper-plaintext-canary-$U"
make_template() {
  truncate -s "$GPT_SIZE" "$W/disk.img"
  sfdisk -q "$W/disk.img" <<EOF
label: gpt
size=1GiB, type=uefi
size=1GiB, type=linux
type=$ROOT_TYPE
EOF
  truncate -s "$DISK_SIZE" "$W/disk.img"
  attach
  mkfs.vfat -n CIDATA "${LOOP}p1" >/dev/null
  mkfs.xfs -q -f "${LOOP}p2"
  mkfs.xfs -q -f -m uuid="$U" -L root "$P3"
  mount "$P3" "$W/m"
  local i n=$(((DATA_MIB + 63) / 64))
  for ((i = 0; i < n; i++)); do
    head -c 64M /dev/urandom >"$W/m/data$i"
  done
  # Recognisable plaintext: after encryption it must be nowhere on the raw disk.
  head -c 4M < <(yes "$CANARY") >"$W/m/data-canary" # not a pipe: yes dies of SIGPIPE
  (cd "$W/m" && sha256sum data* >SHA256SUMS)
  cp "$W/m/SHA256SUMS" "$W/SHA256SUMS"
  umount "$W/m"
  detach
  mv "$W/disk.img" "$W/template.img"
}

# fresh MARKER RECIPIENTS: a copy of the template; MARKER (juniper-encrypt, - for none),
# RECIPIENTS ed25519 | ecdsa | none.
fresh() {
  rm -f "$W/disk.img" "$W/hook.log" "$W/fwkey.log" "$W/kill."* "$W/board.key"
  RECOVERY_ID=$W/id_ed25519
  rm -rf "$W/run"
  cp --sparse=always "$W/template.img" "$W/disk.img"
  attach
  c_mount
  [[ $1 == - ]] || echo "$1" >"$W/c/juniper-encrypt"
  case $2 in
    ed25519) cp "$W/id_ed25519.pub" "$W/c/juniper-recovery.txt" ;;
    ecdsa) cp "$W/id_ecdsa.pub" "$W/c/juniper-recovery.txt" ;;
    none) ;;
  esac
  c_umount
  : >"$W/hook.log"
  : >"$W/fwkey.log"
  P3_SIZE0=$(blockdev --getsz "$P3")
  DUMP0=$(sfdisk --dump "$LOOP")
}

# cr ACTION [VAR=value...]: run cryptroot as the initramfs would, in its own process group.
cr() {
  local action=$1
  shift
  # A SIGKILLed or refusing run is an expected result here, not a test error.
  set +e
  trap - ERR
  env PATH="$W/hook:$REAL_PATH" JUNIPER_CMDLINE="$W/cmdline" JUNIPER_CIDATA_MNT="$W/cidata-mnt" \
    JUNIPER_RUN_DIR="$W/run" JUNIPER_CPUINFO="$W/cpuinfo-aes" \
    JUNIPER_TRYBOOT_FLAG="$W/no-tryboot" JUNIPER_ROOT_WAIT=5 JUNIPER_UNLOCK_FAIL_DELAY=0 \
    JUNIPER_FWKEY="$W/fwkey" JUNIPER_CONSOLE=/dev/null "$@" \
    setsid -w "$CRYPTROOT" "$action" >"$W/out" 2>&1
  rc=$?
  set -e
  trap 'echo "cryptroot-loop.sh:$LINENO: failed: $BASH_COMMAND" >&2' ERR
  grep -v '^Progress' "$W/out" | sed "s/^/     | /" || true
  if [[ ! -e $KILL_DONE ]] && mountpoint -q "$W/cidata-mnt"; then
    check "cryptroot $action left CIDATA unmounted" false
  fi
}

# c_mount [OPT]: CIDATA at $W/c, retried with a short backoff; c_umount likewise.
c_mount() {
  local i
  for ((i = 1; i <= 10; i++)); do
    mount ${1:+-o "$1"} -t vfat "${LOOP}p1" "$W/c" 2>"$W/mount.err" && return 0
    sleep "0.$i"
  done
  echo "     could not mount CIDATA ${LOOP}p1: $(cat "$W/mount.err")" >&2
  return 1
}
c_umount() {
  local i
  for ((i = 1; i <= 10; i++)); do
    umount "$W/c" 2>/dev/null && return 0
    sleep "0.$i"
  done
  echo "     CIDATA busy; detaching it lazily" >&2
  umount -l "$W/c"
}
# cidata FILE: a file from CIDATA. Says so, loudly, when it can't be read.
cidata() {
  if ! c_mount ro; then
    echo "<CIDATA unreadable: mount failed>"
    return 0
  fi
  if [[ -e $W/c/$1 ]]; then
    cat "$W/c/$1" || echo "<CIDATA unreadable: $1>"
  else
    echo "<no $1 on CIDATA>"
  fi
  c_umount
}
cidata_has() {
  local r=1
  c_mount ro || die "cannot read CIDATA"
  [[ -e $W/c/$1 ]] && r=0
  c_umount
  return "$r"
}
header_sum() { head -c 16M "$P3" | sha256sum; }
content_ok() { # DEV: mounts read-only and checks every file
  local r=0
  mount -o ro "$1" "$W/m" || return 1
  (cd "$W/m" && sha256sum -c --quiet SHA256SUMS) || r=1
  cmp -s "$W/m/SHA256SUMS" "$W/SHA256SUMS" || r=1
  umount "$W/m"
  return "$r"
}
unlock_left_plain() { [[ $rc == 0 && ! -e /dev/mapper/juniper-root ]]; }
unlock_refused() { [[ $rc != 0 && ! -e /dev/mapper/juniper-root ]]; }
is_hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
not_called() { ! grep -qE -- "$1" "$2"; }
# no_leak STRING PATH...: STRING is in no file under PATH. A missing or unreadable file fails
# (grep's exit 2 used to pass); inside a directory, entries that vanish mid-scan are tolerated.
no_leak() {
  local s=$1 p rc
  shift
  for p; do
    [[ -e $p ]] || {
      echo "     no_leak: $p does not exist"
      return 1
    }
    rc=0
    if [[ -d $p ]]; then
      grep -rqaF -D skip -s -- "$s" "$p" || rc=$?
      ((rc != 2)) || rc=1
    else
      grep -qaF -- "$s" "$p" || rc=$?
    fi
    case $rc in
      0)
        echo "     no_leak: found in $p"
        return 1
        ;;
      1) ;;
      *)
        echo "     no_leak: could not read $p"
        return 1
        ;;
    esac
  done
}
recovery_from_cidata() {
  local r=0
  c_mount ro || return 1
  age -d -i "${RECOVERY_ID:-$W/id_ed25519}" "$W/c/juniper-recovery.age" |
    cryptsetup open --test-passphrase --key-file - "$P3" || r=1
  c_umount
  return "$r"
}
recovery_from_token() {
  cryptsetup token export --token-id 1 "$P3" |
    sed -n 's/.*"age"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's|\\/|/|g; s/\\n/\n/g' |
    age -d -i "${RECOVERY_ID:-$W/id_ed25519}" | cryptsetup open --test-passphrase --key-file - "$P3"
}
# The board's key: $KEY, or another Pi's after new_board.
board_key() { if [[ -r $W/board.key ]]; then cat "$W/board.key"; else printf '%s' "$KEY"; fi; }
board_key_opens() { board_key | cryptsetup open --test-passphrase --key-file - "$P3"; }
key_opens() { printf '%s' "$1" | cryptsetup open --test-passphrase --key-file - "$P3" 2>/dev/null; }
key_fails() { ! key_opens "$1"; }
key_opens_either() { key_opens "$1" || key_opens "$2"; }

# encrypted_checks CIPHER: the end state of every encrypting path, unlock included.
encrypted_checks() {
  local cipher=$1 dump t0 t1 slots last start size off
  dump=$(cryptsetup luksDump "$P3" 2>/dev/null || true)
  check "p3 is crypto_LUKS" eq "$(blkid -c /dev/null -s TYPE -o value "$P3")" crypto_LUKS
  check "LUKS label juniper-root" eq "$(blkid -c /dev/null -s LABEL -o value "$P3")" juniper-root
  check "no reencryption left" not_called 'online-reencrypt' <(printf '%s\n' "$dump")
  t0=$(cryptsetup token export --token-id 0 "$P3" 2>/dev/null || true)
  t1=$(cryptsetup token export --token-id 1 "$P3" 2>/dev/null || true)
  check "token 0 type juniper" eq "$(jfield "$t0" type)" juniper
  check "token 0 root_uuid" eq "$(jfield "$t0" root_uuid)" "$U"
  check "token 0 recovery sealed" eq "$(jfield "$t0" recovery)" sealed
  check "token 0 recipients 1" eq "$(jfield "$t0" recipients)" 1
  check "token 0 id_type mmc" eq "$(jfield "$t0" id_type)" mmc
  check "token 1 type juniper-recovery" eq "$(jfield "$t1" type)" juniper-recovery
  slots=$(printf '%s\n' "$dump" | sed -n '/^Keyslots:/,/^Tokens:/p' | sed -n 's/^  \([0-9]\+\): .*/\1/p' | tr '\n' ' ')
  check "keyslots exactly 0 and 1" eq "$slots" "0 1 "
  check "tokens exactly 0 and 1" eq "$(printf '%s\n' "$dump" | sed -n '/^Tokens:/,/^Digests:/p' | sed -n 's/^  \([0-9]\+\): .*/\1/p' | tr '\n' ' ')" "0 1 "
  check "cipher $cipher" eq "$(printf '%s\n' "$dump" | sed -n '/^Data segments:/,/^Keyslots:/s/^[[:space:]]*cipher:[[:space:]]*//p')" "$cipher"
  check "sector size 512" eq "$(printf '%s\n' "$dump" | sed -n '/^Data segments:/,/^Keyslots:/s/^[[:space:]]*sector:[[:space:]]*\([0-9]*\).*/\1/p')" 512
  off=$(printf '%s\n' "$dump" | sed -n '/^Data segments:/,/^Keyslots:/s/^[[:space:]]*offset:[[:space:]]*\([0-9]*\).*/\1/p')
  check "data offset 16 MiB" eq "$off" 16777216
  off=${off:-0}
  check "CIDATA marker encrypted" eq "$(cidata juniper-encrypt)" encrypted
  check "no juniper-recovery.age.new left" eval '! cidata_has juniper-recovery.age.new'
  last=$(sfdisk --dump "$LOOP" | sed -n 's/^last-lba: *//p')
  read -r start size < <(sfdisk --dump "$LOOP" | sed -n "s|^$P3 : start= *\([0-9]*\), size= *\([0-9]*\),.*|\1 \2|p")
  check "p3 grown to the last usable LBA" eq "$((start + size - 1))" "$last"
  check "kernel sees the grown p3" eq "$(blockdev --getsz "$P3")" "$size"
  check "board key opens" board_key_opens
  check "recovery key (CIDATA juniper-recovery.age) opens" recovery_from_cidata
  check "recovery key (token 1 ciphertext) opens" recovery_from_token

  rm -rf "$W/run" # a later boot
  cr unlock
  check "unlock exits 0" eq "$rc" 0
  check "unlock opened /dev/mapper/juniper-root" test -b /dev/mapper/juniper-root
  if [[ -b /dev/mapper/juniper-root ]]; then
    check "run record state=encrypted" grep -qx state=encrypted "$W/run/cryptroot"
    check "mapping is XFS with the root UUID" eq "$(blkid -c /dev/null -s UUID -o value /dev/mapper/juniper-root)" "$U"
    check "mapping is p3 minus the data offset" eq "$(blockdev --getsz /dev/mapper/juniper-root)" "$((size - off / 512))"
    check "root content intact (sha256sum -c)" content_ok /dev/mapper/juniper-root
    cryptsetup close juniper-root
  fi
}

# plain_checks REASON: fail-open end state: plain, intact, not grown, final marker.
plain_checks() {
  check "p3 still XFS with the root UUID" eq "$(blkid -c /dev/null -s UUID -o value "$P3")" "$U"
  check "p3 not grown" eq "$(blockdev --getsz "$P3")" "$P3_SIZE0"
  check "partition table untouched" eq "$(sfdisk --dump "$LOOP")" "$DUMP0"
  check "root content intact" content_ok "$P3"
  check "CIDATA marker" eq "$(cidata juniper-encrypt)" "not-encrypted:$1"
  check "run record reason" grep -qxF "reason=$1" "$W/run/cryptroot"
}

# --- scenarios ---
want() { [[ $1 =~ ${ONLY:-.} ]]; }

s_plain_untouched() {
  fresh - ed25519
  local h
  h=$(header_sum)
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "p3 header bytes unchanged" eq "$(header_sum)" "$h"
  check "partition table untouched" eq "$(sfdisk --dump "$LOOP")" "$DUMP0"
  check "no marker written" eval '! cidata_has juniper-encrypt'
  check "fwkey never called" test ! -s "$W/fwkey.log"
  check "no cryptsetup writes" not_called '^cryptsetup (reencrypt|luksFormat|token import|luksAddKey)' "$W/hook.log"
  check "run record: not requested" grep -qxF 'reason=not requested at flash time' "$W/run/cryptroot"
  cr unlock
  check "unlock exits 0, nothing opened" unlock_left_plain
  check "root content intact" content_ok "$P3"
}

s_happy() {
  fresh on ed25519
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "order: init-only, resume, token 0, slot 1, token 1, sealed" eq \
    "$(grep -oE '^cryptsetup (reencrypt.*(--init-only|--resume-only)|token import --token-id [01]( --token-replace)?|luksAddKey)' "$W/hook.log" |
      sed -E 's/reencrypt.*(--init-only|--resume-only)/\1/; s/^cryptsetup //' | tr '\n' ,)" \
    "--init-only,--resume-only,token import --token-id 0,luksAddKey,token import --token-id 1 --token-replace,token import --token-id 0 --token-replace,"
  encrypted_checks aes-xts-plain64

  local r h
  r=$(
    c_mount ro && age -d -i "$W/id_ed25519" "$W/c/juniper-recovery.age"
    c_umount
  )
  check "recovery key is 64 hex" is_hex64 "$r"
  check "no plaintext (canary file) left on the raw disk" no_leak "$CANARY" "$W/disk.img"
  check "board key not on the disk image" no_leak "$KEY" "$W/disk.img"
  check "recovery key not on the disk image" no_leak "$r" "$W/disk.img"
  check "board key not in /run or /tmp" no_leak "$KEY" /run /tmp "$W/run" "$W/hook.log" "$W/out"
  check "recovery key not in /run or /tmp" no_leak "$r" /run /tmp "$W/run" "$W/hook.log" "$W/out"
  r=

  # Idempotence: the next boot's prepare writes nothing.
  h=$(header_sum)
  local age0 t
  age0=$(cidata juniper-recovery.age | sha256sum)
  : >"$W/fwkey.log"
  : >"$W/hook.log"
  cr prepare
  check "second prepare exits 0" eq "$rc" 0
  check "second prepare: LUKS header bytes unchanged" eq "$(header_sum)" "$h"
  check "second prepare: recovery file unchanged" eq "$(cidata juniper-recovery.age | sha256sum)" "$age0"
  check "second prepare: marker still encrypted" eq "$(cidata juniper-encrypt)" encrypted
  check "second prepare: no fwkey ensure" not_called 'ensure' "$W/fwkey.log"
  check "second prepare: no header writes" not_called '^cryptsetup (reencrypt|token import|luksAddKey|luksKillSlot|repair)' "$W/hook.log"
  t=$(sfdisk --dump "$LOOP")
  cr prepare
  check "third prepare: partition table unchanged" eq "$(sfdisk --dump "$LOOP")" "$t"
}

s_adiantum() {
  fresh on ed25519
  cr prepare JUNIPER_CPUINFO="$W/cpuinfo-noaes"
  check "prepare exits 0" eq "$rc" 0
  encrypted_checks xchacha12,aes-adiantum-plain64
}

# kill_point NAME WHEN MATCH [NTH]: SIGKILL prepare there, check the interrupted state, reboot,
# prepare again, and require the same end state as the happy path.
kill_point() {
  local when=$1 match=$2 nth=${3:-1}
  fresh on ed25519
  cr prepare KILL_WHEN="$when" KILL_MATCH="$match" KILL_NTH="$nth"
  if [[ -e $KILL_MISSED ]]; then
    check "kill landed mid-resume" false
    echo "     $(cat "$KILL_MISSED")"
  fi
  check "prepare was SIGKILLed ($(cat "$KILL_DONE" 2>/dev/null || echo no kill))" test -e "$KILL_DONE"
  reboot
}
rerun() {
  rm -f "$W/kill."*
  cr prepare
  check "rerun: prepare exits 0" eq "$rc" 0
  encrypted_checks aes-xts-plain64
}
dump_has() { cryptsetup luksDump "$P3" | grep -q -- "$1"; }
token0() { jfield "$(cryptsetup token export --token-id 0 "$P3" 2>/dev/null || true)" "$1"; }

s_kill_after_init_only() {
  kill_point after 'reencrypt .*--init-only'
  check "interrupted: header marked for reencryption" dump_has online-reencrypt
  check "interrupted: no token 0 yet (C1)" eq "$(token0 type)" ""
  check "interrupted: marker converting" eq "$(cidata juniper-encrypt)" converting
  rm -rf "$W/run"
  : >"$W/hook.log"
  cr unlock
  check "unlock refuses a half-encrypted root" unlock_refused
  check "unlock wrote nothing to the header" not_called '^cryptsetup (token import|repair|reencrypt)' "$W/hook.log"
  reboot
  rerun
}

s_kill_mid_resume() {
  kill_point during 'reencrypt .*--resume-only'
  check "interrupted: header marked for reencryption" dump_has online-reencrypt
  rerun
  check "rerun repaired before resuming" grep -qE '^cryptsetup repair' "$W/hook.log"
}

s_kill_after_resume() {
  kill_point after 'reencrypt .*--resume-only'
  check "interrupted: conversion finished" eval '! dump_has online-reencrypt'
  check "interrupted: no token 0 yet" eq "$(token0 type)" ""
  rerun
}

s_kill_after_token0() {
  kill_point after '^cryptsetup token import --token-id 0 /'
  check "interrupted: token 0 pending" eq "$(token0 recovery)" pending
  # Under tryboot the header is never touched.
  local h
  h=$(header_sum)
  rm -rf "$W/run"
  cr prepare JUNIPER_TRYBOOT_FLAG="$W/tryboot-1"
  check "tryboot prepare exits 0" eq "$rc" 0
  check "tryboot prepare: header bytes unchanged" eq "$(header_sum)" "$h"
  rerun
}

s_kill_after_age() {
  kill_point after '^age .*juniper-recovery\.age\.new'
  check "interrupted: only keyslot 0" eq "$(cryptsetup luksDump "$P3" | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -cE '^  [0-9]+: ' || true)" 1
  rerun
}

s_kill_after_addkey() {
  kill_point after '^cryptsetup luksAddKey'
  check "interrupted: token 0 still pending" eq "$(token0 recovery)" pending
  rerun
  check "rerun replaced the stale slot 1" grep -qE '^cryptsetup luksKillSlot .* 1$' "$W/hook.log"
}

s_kill_after_token1() {
  kill_point after '^cryptsetup token import --token-id 1'
  check "interrupted: token 0 still pending" eq "$(token0 recovery)" pending
  rerun
}

s_kill_after_grow() {
  # partx -u: 1st after the +64 MiB grow, 2nd after the grow to the end of the disk.
  kill_point after '^partx -u' 2
  check "interrupted: marker converting" eq "$(cidata juniper-encrypt)" converting
  check "interrupted: token 0 sealed" eq "$(token0 recovery)" sealed
  rerun
}

s_failopen_no_recipients() {
  fresh on none
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  plain_checks "no usable recovery recipient"
  check "fwkey ensure never called (I7)" not_called 'ensure' "$W/fwkey.log"
  failopen_again
}
s_failopen_ecdsa_only() {
  fresh on ecdsa
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  plain_checks "no usable recovery recipient"
  check "fwkey ensure never called (I7)" not_called 'ensure' "$W/fwkey.log"
  failopen_again
}
s_failopen_key_locked() {
  fresh on ed25519
  cr prepare FWKEY_MODE=unavailable
  check "prepare exits 0" eq "$rc" 0
  plain_checks "firmware key interface unavailable: key locked"
  check "fwkey derive never called" not_called 'derive' "$W/fwkey.log"
  failopen_again FWKEY_MODE=unavailable
}
s_failopen_derive_fails() {
  fresh on ed25519
  cr prepare FWKEY_MODE=derive-fail
  check "prepare exits 0" eq "$rc" 0
  plain_checks "firmware key interface unavailable: derive failed (ok)"
  failopen_again FWKEY_MODE=derive-fail
}
# The fail-open decision is final: the next boot changes nothing and asks no firmware.
failopen_again() {
  local h m
  h=$(header_sum)
  m=$(cidata juniper-encrypt)
  reboot
  : >"$W/fwkey.log"
  cr prepare "$@"
  check "second prepare: p3 unchanged" eq "$(header_sum)" "$h"
  check "second prepare: marker unchanged" eq "$(cidata juniper-encrypt)" "$m"
  check "second prepare: fwkey never called" test ! -s "$W/fwkey.log"
  check "second prepare: still not grown" eq "$(blockdev --getsz "$P3")" "$P3_SIZE0"
}

s_tryboot_plain() {
  fresh on ed25519
  cr prepare JUNIPER_TRYBOOT_FLAG="$W/tryboot-1"
  check "prepare exits 0" eq "$rc" 0
  check "p3 still XFS with the root UUID" eq "$(blkid -c /dev/null -s UUID -o value "$P3")" "$U"
  check "partition table untouched" eq "$(sfdisk --dump "$LOOP")" "$DUMP0"
  check "marker still on" eq "$(cidata juniper-encrypt)" on
  check "fwkey never called" test ! -s "$W/fwkey.log"
}

# --- re-bind (#76): `just rebind-card` on a laptop, then a boot in another Pi ---
KEY2=0d15ea5e0ddba11c0ffee000feedfacecafebabe1234567890abcdef00112233 # the other Pi's key
# encrypted_card: the happy path's end state, as the owner's card is before it moves.
encrypted_card() {
  fresh on ed25519
  cr prepare
  check "setup: encrypted" eq "$(token0 recovery)" sealed
  : >"$W/hook.log"
}
# laptop_rebind: what `just rebind-card` does as root, through the same script.
laptop_rebind() {
  local ct
  c_mount || die "cannot mount CIDATA"
  ct=$(cat "$W/c/juniper-recovery.age")
  bash "$ADD_REBIND_SLOT" "$P3" "$W/c" age "$W/id_ed25519" "$ct"
  RB_KEY=$(cat "$W/c/juniper-rebind.key")
  c_umount
}
new_board() { printf '%s' "$KEY2" >"$W/board.key"; }
rebind_checks() {
  check "new board's key opens" key_opens "$KEY2"
  check "old board's key no longer opens" key_fails "$KEY"
  check "re-bind key no longer opens" key_fails "$RB_KEY"
  check "re-bind file removed" eval '! cidata_has juniper-rebind.key'
  check "re-bind key not on the header or in logs" no_leak "$RB_KEY" "$W/hook.log" "$W/out" "$W/run"
  encrypted_checks aes-xts-plain64
}

s_rebind_new_board() {
  encrypted_card
  laptop_rebind
  check "laptop: slot 2 added" eq "$(cryptsetup luksDump "$P3" | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -cE '^  2: ')" 1
  check "laptop: re-bind key opens" key_opens "$RB_KEY"
  check "laptop: file is the key" eq "$(cidata juniper-rebind.key)" "$RB_KEY"
  new_board
  rm -rf "$W/run"
  # The other Pi's first boot under tryboot changes nothing.
  local h
  h=$(header_sum)
  cr prepare JUNIPER_TRYBOOT_FLAG="$W/tryboot-1"
  check "tryboot: header unchanged" eq "$(header_sum)" "$h"
  rm -rf "$W/run"
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "order: kill slot 0, add slot 0, kill slot 2" eq \
    "$(grep -oE '^cryptsetup (luksKillSlot --batch-mode --key-file - \S+ [0-9]|luksAddKey --batch-mode --key-slot 0)' "$W/hook.log" |
      sed -E 's|^cryptsetup ||; s|--batch-mode ||; s|--key-file - \S+ ||' | tr '\n' ,)" \
    "luksKillSlot 0,luksAddKey --key-slot 0,luksKillSlot 2,"
  rebind_checks
}

# A power cut after each step: the next boot in the new Pi finishes.
rebind_kill() { # MATCH
  encrypted_card
  laptop_rebind
  new_board
  rm -rf "$W/run"
  cr prepare KILL_WHEN=after KILL_MATCH="$1" KILL_NTH=1
  check "prepare was SIGKILLed ($(cat "$KILL_DONE" 2>/dev/null || echo no kill))" test -e "$KILL_DONE"
  check "a key still opens (re-bind or new board)" key_opens_either "$RB_KEY" "$KEY2"
  check "recovery still opens" recovery_from_cidata
  reboot
  rm -f "$W/kill."*
  cr prepare
  check "rerun: prepare exits 0" eq "$rc" 0
  rebind_checks
}
s_rebind_kill_after_killslot0() { rebind_kill '^cryptsetup luksKillSlot .* 0$'; }
s_rebind_kill_after_addkey0() { rebind_kill '^cryptsetup luksAddKey --batch-mode --key-slot 0 '; }
s_rebind_kill_after_killslot2() { rebind_kill '^cryptsetup luksKillSlot .* 2$'; }

# Same Pi: nothing to move. The key file and slot 2 just go.
s_rebind_same_board() {
  encrypted_card
  laptop_rebind
  rm -rf "$W/run"
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "slot 0 untouched" not_called '^cryptsetup (luksAddKey|luksKillSlot .* 0$)' "$W/hook.log"
  check "old (same) board's key opens" key_opens "$KEY"
  check "re-bind key no longer opens" key_fails "$RB_KEY"
  check "re-bind file removed" eval '! cidata_has juniper-rebind.key'
  encrypted_checks aes-xts-plain64
}

# The new Pi's firmware can't give a key (old EEPROM, locked): change nothing, keep T; once it
# can, the next boot re-binds.
s_rebind_firmware_unavailable() {
  encrypted_card
  laptop_rebind
  new_board
  local h
  h=$(header_sum)
  rm -rf "$W/run"
  cr prepare FWKEY_MODE=unavailable
  check "prepare exits 0" eq "$rc" 0
  check "header unchanged" eq "$(header_sum)" "$h"
  check "says why" grep -q "firmware key is unavailable" "$W/out"
  check "re-bind key still opens" key_opens "$RB_KEY"
  check "file kept" cidata_has juniper-rebind.key
  rm -rf "$W/run"
  cr prepare
  check "then: prepare exits 0" eq "$rc" 0
  rebind_checks
}

# A key file that opens nothing (planted, or for another card): ignored, nothing changes.
s_rebind_bogus_key() {
  encrypted_card
  c_mount || die "cannot mount CIDATA"
  printf '%064d\n' 0 >"$W/c/juniper-rebind.key"
  c_umount
  new_board
  local h
  h=$(header_sum)
  rm -rf "$W/run"
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "header unchanged" eq "$(header_sum)" "$h"
  check "says why" grep -q "not re-binding" "$W/out"
  check "file left for the owner" cidata_has juniper-rebind.key
}

# --- re-seal (#83 Task 12): `ujust recovery-reseal` writes CIDATA/juniper-reseal.txt ---
reseal_request() { # CONTENT
  c_mount || die "cannot mount CIDATA"
  printf '%s\n' "$1" >"$W/c/juniper-reseal.txt"
  c_umount
}
old_recovery_fails() {
  local r=0
  c_mount ro || return 1
  if age -d -i "$W/id_ed25519" "$W/c/juniper-recovery.age" >/dev/null 2>&1; then r=1; fi
  c_umount
  return "$r"
}
reseal_checks() {
  RECOVERY_ID=$W/id_new
  check "request removed" eval '! cidata_has juniper-reseal.txt'
  check "recipients are the new key" eq "$(cidata juniper-recovery.txt)" "$(cat "$W/id_new.pub")"
  check "old SSH key can't decrypt the recovery file" old_recovery_fails
  encrypted_checks aes-xts-plain64
}

s_reseal_new_key() {
  encrypted_card
  reseal_request "$(cat "$W/id_new.pub")"
  local h
  h=$(header_sum)
  rm -rf "$W/run"
  cr prepare JUNIPER_TRYBOOT_FLAG="$W/tryboot-1"
  check "tryboot: header unchanged" eq "$(header_sum)" "$h"
  rm -rf "$W/run"
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "order: age, kill slot 1, add slot 1, token 1" eq \
    "$(grep -oE '^(age -R|cryptsetup (luksKillSlot --batch-mode --key-file - \S+ 1|luksAddKey --batch-mode --key-slot 1|token import --token-id 1))' "$W/hook.log" |
      sed -E 's|^cryptsetup ||; s|--batch-mode ||; s|--key-file - \S+ ||' | tr '\n' ,)" \
    "age -R,age -R,luksKillSlot 1,luksAddKey --key-slot 1,token import --token-id 1,"
  reseal_checks
}

reseal_kill() { # MATCH
  encrypted_card
  reseal_request "$(cat "$W/id_new.pub")"
  rm -rf "$W/run"
  cr prepare KILL_WHEN=after KILL_MATCH="$1" KILL_NTH=1
  check "prepare was SIGKILLed ($(cat "$KILL_DONE" 2>/dev/null || echo no kill))" test -e "$KILL_DONE"
  check "board key still opens" board_key_opens
  check "request still there" cidata_has juniper-reseal.txt
  reboot
  rm -f "$W/kill."*
  cr prepare
  check "rerun: prepare exits 0" eq "$rc" 0
  reseal_checks
}
s_reseal_kill_after_age() { reseal_kill '^age -R .*juniper-reseal\.txt -a '; }
s_reseal_kill_after_killslot1() { reseal_kill '^cryptsetup luksKillSlot .* 1$'; }
s_reseal_kill_after_addkey1() { reseal_kill '^cryptsetup luksAddKey --batch-mode --key-slot 1 '; }
s_reseal_kill_after_token1() { reseal_kill '^cryptsetup token import --token-id 1 '; }

# A request age can't use: ignored, nothing changes, the old recovery key still works.
s_reseal_bad_request() {
  encrypted_card
  reseal_request "not a key"
  local h
  h=$(header_sum)
  rm -rf "$W/run"
  cr prepare
  check "prepare exits 0" eq "$rc" 0
  check "header unchanged" eq "$(header_sum)" "$h"
  check "says why" grep -q "no usable recipient; not re-sealing" "$W/out"
  check "old recovery key still opens" recovery_from_cidata
}

scenarios=(plain_untouched happy adiantum kill_after_init_only kill_mid_resume kill_after_resume
  kill_after_token0 kill_after_age kill_after_addkey kill_after_token1 kill_after_grow
  failopen_no_recipients failopen_ecdsa_only failopen_key_locked failopen_derive_fails tryboot_plain
  rebind_new_board rebind_kill_after_killslot0 rebind_kill_after_addkey0 rebind_kill_after_killslot2
  rebind_same_board rebind_bogus_key rebind_firmware_unavailable
  reseal_new_key reseal_kill_after_age reseal_kill_after_killslot1 reseal_kill_after_addkey1
  reseal_kill_after_token1 reseal_bad_request)

echo "cryptroot under test: $CRYPTROOT"
cryptsetup --version
echo "disk: GPT on $GPT_SIZE, file $DISK_SIZE, $DATA_MIB MiB of data; work dir $W"
make_template
for s in "${scenarios[@]}"; do
  want "$s" || continue
  scenario=$s
  echo "=== $s"
  start=$SECONDS
  "s_$s"
  detach
  echo "    ($((SECONDS - start)) s)"
done
echo "$passes passed, $fails failed"
((fails == 0))
