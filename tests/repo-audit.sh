#!/usr/bin/env bash
# Strict audit of dnf repo files: every enabled repo must check package signatures and
# trust only local key files. Usage: repo-audit.sh [-r REPOID]... DIR...
# Exits 1 and prints each problem on stderr; -r also requires REPOID to be present and enabled.
#
# Why not `dnf repoinfo`: it wants the repo metadata to be reachable. This parses the files
# itself, the way an ini reader does: a line starting with whitespace continues the previous
# value (a gpgkey= with a remote key on the next line must not slip past), and gpgcheck must
# be a clear "on" (1/yes/true/on, dnf's truthy forms). Key names are case-sensitive, as in
# libdnf5's ini parser and option lookup: "GPGCHECK=1" sets nothing there, so it counts as unset.
# Strict on purpose: dnf would inherit a [main] gpgcheck for a repo that omits it, but an
# image repo should say so itself, so unset means off here. Repeated enabled/gpgcheck/gpgkey
# keys in one section are refused: which one wins is the reader's business, not something to
# rely on. Any non-comment line outside a section (a UTF-8 BOM, stray text before the first
# [id]) is refused, since a reader may skip the lot and leave nothing audited. A [main] section
# is global config, not a repo, and is skipped. Duplicate ids are refused per directory only:
# across directories dnf keeps the first and ignores the rest, and every file is audited anyway.
# gpgkey paths are normalised (realpath -m) so /etc/pki/rpm-gpg/../../tmp/k does not pass.
# Pass every repo dir dnf reads: /etc/yum.repos.d, /etc/distro.repos.d, /usr/share/dnf5/repos.d.
set -euo pipefail

want=()
while getopts r: opt; do
  case $opt in
    r) want+=("$OPTARG") ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
shopt -s nullglob
files=()
for d; do files+=("$d"/*.repo); done
((${#files[@]})) || {
  echo "repo-audit: no .repo files in $*" >&2
  exit 1
}

awk -v keypath=/etc/pki/rpm-gpg/ -v want="${want[*]:-}" '
function norm(p,   cmd, out) {
  if (p ~ /'"'"'/) return p
  cmd = "realpath -m -- '"'"'" p "'"'"'"
  out = ""
  cmd | getline out
  close(cmd)
  return out
}
function truthy(v) { v = tolower(v); return v == "1" || v == "yes" || v == "true" || v == "on" }
function falsy(v) { v = tolower(v); return v == "0" || v == "no" || v == "false" || v == "off" }
function bad(msg) { print "repo-audit: " fname ": [" id "] " msg > "/dev/stderr"; rc = 1 }
function finish(   n, keys, i) {
  if (id == "" || id == "main") return
  if (falsy(val["enabled"])) return
  enabled[id] = 1
  if (!truthy(val["gpgcheck"])) bad("gpgcheck is not on (" (("gpgcheck" in val) ? val["gpgcheck"] : "unset") ")")
  if (!("gpgkey" in val) || val["gpgkey"] ~ /^[ \t,]*$/) bad("no gpgkey")
  n = split(val["gpgkey"], keys, /[ \t,]+/)
  for (i = 1; i <= n; i++)
    if (keys[i] != "" && (index(keys[i], "file://") != 1 || index(norm(substr(keys[i], 8)), keypath) != 1))
      bad("gpgkey not a local key file: " keys[i])
}
FNR == 1 { finish(); id = ""; delete val; last = ""; fname = FILENAME; dir = FILENAME; sub(/[^\/]*$/, "", dir) }
/^[ \t]*[#;]/ || /^[ \t]*$/ { next }
id == "" && !/^\[/ { bad("content outside a section: " $0); next }
/^[ \t]/ { if (last != "") val[last] = val[last] " " $0; next }
/^\[/ {
  finish(); delete val; last = ""
  id = $0; sub(/^\[/, "", id); sub(/\].*$/, "", id)
  if ((dir SUBSEP id) in seen) bad("section defined twice")
  seen[dir SUBSEP id] = 1
  next
}
{
  eq = index($0, "=")
  if (eq == 0) next
  k = substr($0, 1, eq - 1); gsub(/[ \t]+$/, "", k)
  v = substr($0, eq + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
  if ((k == "gpgcheck" || k == "gpgkey" || k == "enabled") && (k in val)) bad("duplicate " k)
  val[k] = v; last = k
}
END {
  finish()
  n = split(want, w, " ")
  for (i = 1; i <= n; i++)
    if (!(w[i] in enabled)) { print "repo-audit: required repo " w[i] " is missing or disabled" > "/dev/stderr"; rc = 1 }
  exit rc
}' "${files[@]}"
