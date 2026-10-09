#!/usr/bin/env bash
# CHANGELOG.md helpers for the release job. Changes go under "## Unreleased"; a release moves
# them under "## TAG (DATE)".
#   changelog.sh unreleased FILE           print the Unreleased entries
#   changelog.sh section FILE TAG          print the entries released as TAG
#   changelog.sh stamp FILE TAG DATE NOTES move the entries in NOTES (the "unreleased" output
#                                          of the built commit) from Unreleased to TAG, in place
# Only entries still under Unreleased move: ones merged after the built commit stay, and a
# rerun of an already-stamped release changes nothing. A second release with the same TAG
# (same day) adds its entries to the existing TAG section.
set -euo pipefail

usage() {
  sed -n '4,7p' "$0" >&2
  exit 2
}

# Strip leading and trailing blank lines.
trim() { sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac; }

# body FILE HEADING: the lines under the "## " heading whose title is HEADING (exact, or followed
# by " (date)"), up to the next "## " heading.
body() {
  awk -v h="$2" '
    /^## / { if (on) exit; t = substr($0, 4); on = (t == h || index(t, h " (") == 1); next }
    on' "$1" | trim
}

stamp() {
  local file=$1 tag=$2 date=$3 notes=$4 tmp
  grep -qx '## Unreleased' "$file" || {
    echo "changelog: no '## Unreleased' heading in $file" >&2
    exit 1
  }
  tmp=$(mktemp)
  awk -v tag="$tag" -v date="$date" -v notesfile="$notes" '
    BEGIN { while ((getline l <notesfile) > 0) { n[++nn] = l; if (entry(l)) want[l]++ } }
    function entry(l) { return l != "" && l !~ /^### / }
    function is_tag(l, t) { t = substr(l, 4); return t == tag || index(t, tag " (") == 1 }
    # Print a[1..k] without "### " headings that have no entries left, squeezing blank lines.
    function emit(a, k, i, j, has, last, out) {
      for (i = 1; i <= k; i++) {
        if (a[i] ~ /^### /) {
          has = 0
          for (j = i + 1; j <= k && a[j] !~ /^### /; j++) if (entry(a[j])) has = 1
          if (!has) continue
        }
        if (a[i] == "" && (!out || last == "")) continue
        print a[i]
        last = a[i]
        out++
      }
      if (out && last != "") print ""
    }
    { line[++nl] = $0 }
    END {
      for (ur = 1; line[ur] != "## Unreleased"; ur++) ;
      for (end = ur + 1; end <= nl && line[end] !~ /^## /; end++) ;
      # Move only entries still under Unreleased, so a rerun of an older commit is a no-op.
      for (i = ur + 1; i < end; i++) {
        l = line[i]
        if (entry(l) && want[l] > 0) { want[l]--; moved[l]++; any = 1 } else u[++nu] = l
      }
      if (!any) { for (i = 1; i <= nl; i++) print line[i]; exit }
      for (i = 1; i <= nn; i++) if (!entry(n[i]) || moved[n[i]]-- > 0) m[++nm] = n[i]

      for (i = 1; i <= ur; i++) print line[i]
      print ""
      emit(u, nu)
      for (t = end; t <= nl && !(line[t] ~ /^## / && is_tag(line[t])); t++) ;
      if (t > nl) {
        print "## " tag " (" date ")"
        print ""
        emit(m, nm)
        t = end - 1
      } else {
        for (i = end; i <= t; i++) print line[i]
        print ""
        emit(m, nm)
        if (line[t + 1] == "") t++
      }
      for (i = t + 1; i <= nl; i++) print line[i]
    }
  ' "$file" >"$tmp"
  trim <"$tmp" >"$file"
  rm -f "$tmp"
}

case ${1:-} in
  unreleased) (($# == 2)) || usage && body "$2" Unreleased ;;
  section) (($# == 3)) || usage && body "$2" "$3" ;;
  stamp) (($# == 5)) || usage && stamp "$2" "$3" "$4" "$5" ;;
  *) usage ;;
esac
