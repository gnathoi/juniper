#!/usr/bin/env bash
# Pi kernel age for the release train. The kernel only arrives with AlmaLinux base rebuilds
# (build.sh can't upgrade it), so the age is made visible, never a reason to fail a release.
#
#   kernel-age.sh report FILE   CI step summary line, plus a ::warning:: when the repo is ahead
#   kernel-age.sh note FILE     the release-notes line
#
# FILE holds have=EVR, have_ts=EPOCH, checked=1, want=EVR, want_ts=EPOCH. checked=1 is
# written only when the repo query worked (want is then the repo's newest, maybe == have);
# without it the repo check failed. EVRs must match a conservative charset, else unknown. A missing, empty or unparsable FILE means "unknown". NOW (epoch
# seconds) overrides the clock for tests. Always exits 0 on a known command.
set -uo pipefail

ESCALATE_DAYS=14

day() { date -u -d "@$1" +%Y-%m-%d; }
evr() { [[ ${1:-} =~ ^[A-Za-z0-9._+~^:-]+$ ]]; }
num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

load() {
  have='' have_ts='' want='' want_ts='' checked=''
  [ -r "${1:-}" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      have) have=$v ;;
      have_ts) have_ts=$v ;;
      want) want=$v ;;
      want_ts) want_ts=$v ;;
      checked) checked=$v ;;
    esac
  done <"$1"
  evr "$have" || have=''
  evr "$want" || want=''
  [ "$checked" = 1 ] && [ -n "$want" ] || {
    checked=''
    want=''
    want_ts=''
  }
  num "$have_ts" || have_ts=''
  num "$want_ts" || want_ts=''
}

built() { if num "$1"; then echo "built $(day "$1")"; else echo "build date unknown"; fi; }

cmd=${1:-}
now=${NOW:-$(date +%s)}
load "${2:-}"

case $cmd in
  report)
    if [ -z "$have" ]; then
      echo "Pi kernel: unknown (the check could not run)"
      exit 0
    fi
    if [ -z "$checked" ]; then
      echo "Pi kernel: $have ($(built "$have_ts")); repo check failed, so a newer kernel can't be ruled out"
      exit 0
    fi
    if [ -z "$want" ] || [ "$want" = "$have" ]; then
      echo "Pi kernel: $have ($(built "$have_ts")); AlmaLinux's Pi repo has nothing newer"
      exit 0
    fi
    msg="Pi kernel: $have ($(built "$have_ts")); AlmaLinux's Pi repo has $want"
    days=0
    if num "$want_ts"; then
      days=$(((now - want_ts) / 86400))
      msg+=" since $(day "$want_ts")"
    fi
    echo "$msg"
    if [ "$days" -gt "$ESCALATE_DAYS" ]; then
      echo "::warning::Pi kernel $days days behind: the repo's $want has been out since $(day "$want_ts"); the image ships $have until the base is rebuilt"
    else
      echo "::warning::AlmaLinux's Pi repo has kernel $want; the base image ships $have"
    fi
    ;;
  note)
    if [ -z "$have" ]; then
      echo "Pi kernel: unknown."
      exit 0
    fi
    line="Pi kernel: $have ($(built "$have_ts"))."
    if [ -z "$checked" ]; then
      echo "$line AlmaLinux's Pi repo check failed, so a newer kernel can't be ruled out."
      exit 0
    fi
    if [ -n "$want" ] && [ "$want" != "$have" ]; then
      line+=" A newer kernel $want has been in AlmaLinux's Pi repo"
      num "$want_ts" && line+=" since $(day "$want_ts")"
      line+="; it arrives with the next base rebuild."
    fi
    echo "$line"
    ;;
  *)
    echo "usage: kernel-age.sh report|note FILE" >&2
    exit 2
    ;;
esac
