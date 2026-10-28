#!/usr/bin/env bash
set -euo pipefail
# detect.sh - detection engine: hunk-aware diff flattening + local heuristic rules.
# Usage: ./scripts/detect.sh <diff-file> <findings-out>
# Findings format: "L: <path>:<line> [axis/severity] <reason> -> fix hint: <fix>"
# Env: TESTS_PRESENT=1 enables the test-quality axis (axis 6).
#
# This script is deliberately the ONLY place that knows how to find things.
# Phase 2 adds real linters (ruff / eslint / gitleaks / semgrep) beside these
# rules; the regex rules stay as the offline fallback.

# --- Hunk-aware line mapping ---
# Flatten a unified diff into "<file>\t<line>\t<text>" records for ADDED lines only,
# where <line> is the 1-based line number in the NEW file, tracked from the
# "@@ -a,b +c,d @@" header. This is what turns a diff-text offset into a real
# src/foo.py:87 coordinate, and it replaces the grep|head|while-read pipelines
# (and their pipefail fragility) with a single awk pass.
flatten_diff() {
  awk '
    {
      if (inhunk) {
        c = substr($0, 1, 1)
        if (c == "+") { printf "%s\t%d\t%s\n", file, n, substr($0, 2); n++; next }
        if (c == "-") { next }
        if (c == "\\") { next }
        if (c == " " || $0 == "") { n++; next }
        inhunk = 0
      }
      if ($0 ~ /^diff --git /) { file = ""; inhunk = 0; next }
      if ($0 ~ /^\+\+\+ /) {
        p = $0
        sub(/^\+\+\+[ \t]+/, "", p)
        sub(/\t.*$/, "", p)
        gsub(/^"|"$/, "", p)
        if (p == "/dev/null" || p == "b//dev/null") { file = ""; inhunk = 0 }
        else { sub(/^b\//, "", p); file = p; inhunk = 0 }
        next
      }
      if ($0 ~ /^--- /) { next }
      if ($0 ~ /^@@ /) {
        if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
          h = substr($0, RSTART + 1, RLENGTH - 1)
          split(h, a, ",")
          n = a[1] + 0
          inhunk = 1
        } else { inhunk = 0 }
        next
      }
    }
  ' "$1"
}

# Helper: worker heuristic scan (local, no API).
# Every finding carries the REAL file:line of the added line that triggered it.
run_worker() {
  local diff_in="$1"
  local findings_out="$2"
  # any further args (callers pass the iteration number) are intentionally ignored:
  # the scan is a pure function of the diff, so repeated iterations see the same findings.
  : > "$findings_out"

  local flat
  flat=$(mktemp)
  flatten_diff "$diff_in" > "$flat" 2>/dev/null || : > "$flat"

  # scan_flat <regex> <axis/severity> <reason> <fix> - one finding per matching added line (max 20)
  # The pattern travels through the environment (ENVIRON) so awk never strips
  # backslashes from it: `-v` assignments process escape sequences and turn an
  # escaped plus into an invalid quantifier on BSD awk.
  scan_flat() {
    local pat="$1" axis_sev="$2" reason="$3" fix="$4"
    SCAN_PAT="$pat" awk -F'\t' -v as="$axis_sev" -v rsn="$reason" -v fx="$fix" '
      BEGIN { c = 0; pat = tolower(ENVIRON["SCAN_PAT"]) }
      # never report the detector own rule table: skip scan_flat / SCAN_PAT lines
      $3 ~ /scan_flat|SCAN_PAT/ { next }
      tolower($3) ~ pat {
        printf "L: %s:%s [%s] %s -> fix hint: %s\n", $1, $2, as, rsn, fx
        c++
        if (c >= 20) exit
      }
    ' "$flat" >> "$findings_out" 2>/dev/null || true
  }

  # 1) leftover work markers
  scan_flat 'todo|fixme|hack' 'readability/medium' 'TODO/FIXME left - remove or ticket' 'resolve TODO'
  # 2) debug logging left in place
  scan_flat 'console\.log|console\.debug' 'readability/low' 'console.log leftover - use structured logger' 'remove console.log'
  # 3) string-built SQL
  scan_flat 'sql injection|select.*\+|query\(.*\+|sql = "' 'security/critical' 'possible SQL injection (CWE-89)' 'use parameterized query'
  # 4) swallowed exceptions
  scan_flat 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}|except:[[:space:]]*pass' 'correctness/high' 'empty catch swallows error' 'handle typed error or rethrow'

  # Coordinates for set-level (not per-line) heuristics: first changed file + its line
  local first_file first_line added_lines
  first_file=$(head -1 "$flat" 2>/dev/null | cut -f1 || true)
  first_line=$(head -1 "$flat" 2>/dev/null | cut -f2 || true)
  [ -n "$first_file" ] || first_file="unknown"
  [ -n "$first_line" ] || first_line=1
  added_lines=$(grep -c '' "$flat" 2>/dev/null || echo 0)
  case "$added_lines" in ''|*[!0-9]*) added_lines=0 ;; esac

  # 5) large single-file change (>250 added lines in ONE file) - split by intent.
  # 250 matches the repo convention for a module cap, so an ordinary new module passes.
  big_file=$(awk -F'\t' '
    { count[$1]++; if (!($1 in first)) first[$1] = $2 }
    END {
      best = ""; max = 0
      for (f in count) if (count[f] > max) { max = count[f]; best = f }
      if (best != "" && max > 250) printf "%s\t%s\t%d\n", best, first[best], max
    }
  ' "$flat" 2>/dev/null || true)
  if [ -n "$big_file" ]; then
    local big_path big_line big_count
    big_path=$(printf '%s' "$big_file" | cut -f1)
    big_line=$(printf '%s' "$big_file" | cut -f2)
    big_count=$(printf '%s' "$big_file" | cut -f3)
    echo "L: ${big_path}:${big_line} [architecture/medium] large change in one file ($big_count added lines) - split by intent (Fowler Long Method) -> fix hint: extract functions <50 lines" >> "$findings_out"
  fi

  # 6) test quality/coverage - axis 6, only when tests exist (TESTS_PRESENT)
  if [ "${TESTS_PRESENT:-0}" -eq 1 ]; then
    local changed_src changed_test
    changed_src=$(cut -f1 "$flat" 2>/dev/null | sort -u | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|py)$' || true)
    changed_test=$(printf '%s\n' "$changed_src" | grep -E '(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.' || true)
    if [ -n "$changed_src" ] && [ -z "$changed_test" ]; then
      echo "L: ${first_file}:${first_line} [correctness/high] missing test coverage for changed code - changed src without test update -> fix hint: add test for changed code: e.g. tests/test_foo.py covering boundary and failure cases" >> "$findings_out"
    fi
    if grep -qE '^deleted file mode' "$diff_in" 2>/dev/null && grep -qE '^--- a/.*(test|spec)' "$diff_in" 2>/dev/null; then
      local deleted_path
      deleted_path=$(grep -E '^--- a/.*(test|spec)' "$diff_in" 2>/dev/null | head -1 | sed -E 's/^--- a\///' || true)
      echo "L: ${deleted_path:-$first_file}:0 [correctness/high] test deletion detected - removing tests to fake green is forbidden -> fix hint: restore tests and fix code instead" >> "$findings_out"
    fi
    if grep -qiE 'mock' "$flat" 2>/dev/null; then
      if ! grep -qiE 'assert|expect|edge|boundary' "$flat" 2>/dev/null; then
        scan_flat 'mock' 'correctness/medium' 'brittle mocks without edge cases - mocks lack assertions for failure paths' 'add edge case test with realistic mock and assert failure branch'
      fi
    fi
    if [ "$added_lines" -gt 10 ]; then
      if ! grep -qiE 'edge|boundary|failure|error' "$flat" 2>/dev/null; then
        if [ -z "$changed_test" ]; then
          echo "L: ${first_file}:${first_line} [correctness/medium] test coverage gap - no edge case tests for changed code with $added_lines added lines -> fix hint: add test covering boundary, branch, and failure cases for changed logic" >> "$findings_out"
        fi
      fi
    fi
  fi

  rm -f "$flat"
  # No artificial finding for a clean diff: an empty findings file scores 10.
}

run_worker "${1:-/dev/stdin}" "${2:?findings output path required}"

exit 0
