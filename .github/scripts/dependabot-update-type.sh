#!/usr/bin/env bash
# Classify a Dependabot PR title ("Bump X from OLD to NEW"): prints major, minor-or-patch or
# other (digests, unparseable titles). Usage: dependabot-update-type.sh TITLE
set -euo pipefail

re='from v?([0-9]+)(\.[0-9A-Za-z.+-]*)? to v?([0-9]+)(\.[0-9A-Za-z.+-]*)?($|[^0-9A-Za-z.`])'
if [[ ${1:-} =~ $re ]]; then
  if [[ ${BASH_REMATCH[1]} == "${BASH_REMATCH[3]}" ]]; then echo minor-or-patch; else echo major; fi
else
  echo other
fi
