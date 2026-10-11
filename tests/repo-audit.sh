#!/usr/bin/env bash
# Strict audit of dnf repo files: every enabled repo must check package signatures and
# trust only local key files. Usage: repo-audit.sh [-r REPOID]... DIR...
# Exits 1 and prints each problem on stderr; -r also requires REPOID to be present and enabled.
#
# Why not `dnf repoinfo`: it wants the repo metadata to be reachable. This parses the files
# itself, the way an ini reader does: a line starting with whitespace continues the previous
# value (a gpgkey= with a remote key on the next line must not slip past), key names are
# case-insensitive, and gpgcheck must be a clear "on" (1/yes/true/on, dnf's truthy forms;
# unset means off). Repeated enabled/gpgcheck/gpgkey keys in one section are refused:
# which one wins is the reader's business, not something to rely on.
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

awk -v keyprefix=file:///etc/pki/rpm-gpg/ -v want="${want[*]:-}" '
function truthy(v) { v = tolower(v); return v == "1" || v == "yes" || v == "true" || v == "on" }
function falsy(v) { v = tolower(v); return v == "0" || v == "no" || v == "false" || v == "off" }
function bad(msg) { print "repo-audit: " fname ": [" id "] " msg > "/dev/stderr"; rc = 1 }
function finish(   n, keys, i) {
  if (id == "") return
  if (falsy(val["enabled"])) return
  enabled[id] = 1
  if (!truthy(val["gpgcheck"])) bad("gpgcheck is not on (" (("gpgcheck" in val) ? val["gpgcheck"] : "unset") ")")
  if (!("gpgkey" in val) || val["gpgkey"] ~ /^[ \t,]*$/) bad("no gpgkey")
  n = split(val["gpgkey"], keys, /[ \t,]+/)
  for (i = 1; i <= n; i++)
    if (keys[i] != "" && index(keys[i], keyprefix) != 1) bad("gpgkey not a local key file: " keys[i])
}
FNR == 1 { finish(); id = ""; delete val; last = ""; fname = FILENAME }
/^[ \t]*[#;]/ || /^[ \t]*$/ { next }
/^[ \t]/ { if (last != "") val[last] = val[last] " " $0; next }
/^\[/ {
  finish(); delete val; last = ""
  id = $0; sub(/^\[/, "", id); sub(/\].*$/, "", id)
  if (id in seen) bad("section defined twice")
  seen[id] = 1
  next
}
{
  eq = index($0, "=")
  if (eq == 0) next
  k = tolower(substr($0, 1, eq - 1)); gsub(/[ \t]+$/, "", k)
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
