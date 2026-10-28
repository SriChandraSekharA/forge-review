#!/usr/bin/env bash
set -euo pipefail
# critic.sh - severity-cap score: a PURE FUNCTION of the findings, never of the iteration.
# Usage: ./scripts/critic.sh <findings-file> [iteration]
#
# The second argument is accepted for CLI compatibility and deliberately ignored:
# a review score that rises just because the loop ran again is a countdown timer,
# not a signal. The score can only change when the findings change.
#
# Scoring (review.sh gates at >= 8):
#   no findings              -> 10
#   any critical             -> 3
#   else any high            -> 5
#   else any medium          -> 7
#   else only low/nitpick    -> 10 - min(count, 2)   => 10 / 9 / 8
#
# An explicit `score:` line in the findings file still wins (clamped 1-10); that is
# how a real detector may assert a score it derived from its own rule metadata.
# Also emits `feedback:` and `hints:` lines.

findings_file="${1:-/dev/stdin}"

# Explicit score wins (clamped 1-10)
if [ -f "$findings_file" ] && grep -qE "^score:[[:space:]]*[0-9]+" "$findings_file" 2>/dev/null; then
  explicit=$(grep -E "^score:[[:space:]]*[0-9]+" "$findings_file" | head -1 | grep -oE "[0-9]+" | head -1)
  if [ -n "$explicit" ]; then
    if [ "$explicit" -lt 1 ]; then explicit=1; fi
    if [ "$explicit" -gt 10 ]; then explicit=10; fi
    echo "score: $explicit"
    echo "feedback: explicit score honored from findings"
    if [ "$explicit" -ge 8 ]; then
      echo "hints: none"
    else
      echo "hints: address flagged patterns, add boundary coverage, use parameterized statements"
    fi
    exit 0
  fi
fi

# Single pass over the findings file: count every finding line once and bucket it
# by severity. Severity lives in a "[axis/severity]" or "[severity]" bracket group.
read -r total critical high medium low rest < <(
  awk '
    /^score:|^feedback:|^hints:|^[[:space:]]*$/ { next }
    {
      total++
      line = $0
      if (line ~ /\[[^]]*\/[[:space:]]*critical[[:space:]]*\]/ || line ~ /\[[[:space:]]*critical[[:space:]]*\]/) { critical++; next }
      if (line ~ /\[[^]]*\/[[:space:]]*high[[:space:]]*\]/     || line ~ /\[[[:space:]]*high[[:space:]]*\]/)     { high++; next }
      if (line ~ /\[[^]]*\/[[:space:]]*medium[[:space:]]*\]/   || line ~ /\[[[:space:]]*medium[[:space:]]*\]/)   { medium++; next }
      if (line ~ /\[[^]]*\/[[:space:]]*low[[:space:]]*\]/      || line ~ /\[[[:space:]]*low[[:space:]]*\]/)      { low++; next }
      rest++
    }
    END { printf "%d %d %d %d %d %d\n", total, critical, high, medium, low, rest }
  ' "$findings_file" 2>/dev/null || printf '0 0 0 0 0 0\n'
)

# Normalize (awk may print nothing for an unreadable file)
case "$total" in ''|*[!0-9]*) total=0 ;; esac
case "$critical" in ''|*[!0-9]*) critical=0 ;; esac
case "$high" in ''|*[!0-9]*) high=0 ;; esac
case "$medium" in ''|*[!0-9]*) medium=0 ;; esac
case "$low" in ''|*[!0-9]*) low=0 ;; esac
case "$rest" in ''|*[!0-9]*) rest=0 ;; esac

if [ "$total" -eq 0 ]; then
  echo "score: 10"
  echo "feedback: meets gate (10/10) - no findings"
  echo "hints: none"
  exit 0
fi

low_ish=$((low + rest))
if [ "$critical" -gt 0 ]; then
  score=3
  feedback="below gate (3/10) - $critical critical finding(s) of $total cap the score at 3"
  hints="resolve critical findings first: parameterize queries, validate untrusted input, remove committed secrets"
elif [ "$high" -gt 0 ]; then
  score=5
  feedback="below gate (5/10) - $high high finding(s) of $total cap the score at 5"
  hints="fix high-severity findings: handle errors explicitly, add boundary checks, stop swallowing exceptions"
elif [ "$medium" -gt 0 ]; then
  score=7
  feedback="below gate (7/10) - $medium medium finding(s) of $total cap the score at 7"
  hints="address medium findings: close outstanding markers, reduce method length, add edge-case coverage"
else
  penalty=$low_ish
  if [ "$penalty" -gt 2 ]; then penalty=2; fi
  score=$((10 - penalty))
  feedback="meets gate ($score/10) - $low_ish low/nitpick finding(s), nothing medium or worse"
  hints="none"
fi

if [ "$score" -lt 1 ]; then score=1; fi
if [ "$score" -gt 10 ]; then score=10; fi

echo "score: $score"
echo "feedback: $feedback"
echo "hints: $hints"
