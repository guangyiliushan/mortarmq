#!/usr/bin/env bash
# Fail when the installed moonc is older than the competition compliance line.
#
# The MoonBit toolchain has no native `>=` assertion, so `moon version --all`
# alone only records evidence for a human to read. This turns hackathon
# acceptance criterion 1 (moonc >= 0.10.14) into a build failure instead.
#
# Usage: assert-moonc.sh            # floor from $MOONC_VERSION_FLOOR
#        assert-moonc.sh 0.11.0     # explicit floor (for ad-hoc runs)
set -euo pipefail

floor="${1:-${MOONC_VERSION_FLOOR:-0.10.14}}"

line="$(moon version --all | awk '$1 == "moonc" { print $2; exit }')"
if [ -z "$line" ]; then
  echo "::error::could not parse a moonc version out of 'moon version --all'"
  exit 1
fi

# Strip a leading v and any +build metadata: v0.10.14+7d59c7ec9 -> 0.10.14
got="${line#v}"
got="${got%%+*}"

echo "installed moonc: $got"
echo "required floor : $floor"

# Numeric per-segment compare, so 0.9.0 < 0.10.14 < 0.11.0 (string sort lies).
awk -v a="$got" -v b="$floor" 'BEGIN {
  n = split(a, A, "."); m = split(b, B, ".")
  for (i = 1; i <= (n > m ? n : m); i++) {
    x = (i <= n) ? A[i] + 0 : 0
    y = (i <= m) ? B[i] + 0 : 0
    if (x > y) { printf "moonc %s satisfies the %s floor\n", a, b; exit 0 }
    if (x < y) { printf "moonc %s is below the required %s floor\n", a, b; exit 1 }
  }
  printf "moonc %s matches the required %s floor\n", a, b
  exit 0
}'
