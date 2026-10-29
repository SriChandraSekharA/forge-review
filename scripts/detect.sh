#!/usr/bin/env bash
set -euo pipefail
# detect.sh - detection engine: hunk-aware diff flattening + local heuristic rules.
# Usage: ./scripts/detect.sh <diff-file> <findings-out>
# Findings format: "L: <path>:<line> [axis/severity] <reason> -> fix hint: <fix>"
# Env: TESTS_PRESENT=1 enables the test-quality axis (axis 6).
#
# This script is deliberately the ONLY place that knows how to find things.
# Real linters run first when they are installed (ruff, eslint, gitleaks, and
# semgrep behind an explicit opt-in); the regex rules below are the offline
# fallback for whatever no linter covered. A missing tool never blocks a review.
#
# Ruleset selection: `.forge-standard-review/knowledge.md` (written by
# knowledge.sh from the repo own standards doc) may carry directives such as
#   ruff-select: E,F,B,S
#   eslint-config: configs/eslint.review.cjs
# They are used instead of the defaults, so the review follows repo policy
# rather than a hardcoded rule list.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
normalizer="$script_dir/lint-normalize.py"

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

# --- Real linters -----------------------------------------------------------
# Selection is per language, so a missing tool degrades that language to the
# regex fallback instead of failing the run:
#   ruff      -> Python        (offline once installed)
#   eslint    -> JS/TS         (offline; honours eslint-config directive)
#   gitleaks  -> secrets, all  (offline once installed)
#   semgrep   -> all           (OPT-IN: FORGE_SEMGREP=1, --config auto fetches rules)
#
# COVERED_LANGS records only languages a linter actually ran for: if ruff is
# absent, Python is not covered and the regex rules keep working. The regexes
# additionally yield to a linter only where that linter detects the same class
# of problem (see the YIELD argument of scan_flat).

knowledge_doc=".forge-standard-review/knowledge.md"

# Read a directive value out of the knowledge doc, falling back to $2.
knowledge_directive() {
  local key="$1" fallback="$2" value=""
  if [ -f "$knowledge_doc" ]; then
    value=$(grep -iE "^[[:space:]]*${key}[[:space:]]*:" "$knowledge_doc" 2>/dev/null \
      | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r' || true)
  fi
  [ -n "$value" ] || value="$fallback"
  printf '%s' "$value"
}

record_detectors() {
  if [ -n "${FORGE_DETECT_LOG:-}" ]; then
    printf 'detectors: %s\n' "${DETECTORS:-none}" >> "$FORGE_DETECT_LOG" 2>/dev/null || true
  fi
}

# emit_tool_findings <tool> <json>
emit_tool_findings() {
  local tool="$1" json="$2"
  [ -s "$json" ] || return 0
  [ -f "$normalizer" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 "$normalizer" "$tool" "$json" "$flat_records" >> "$findings_out" 2>/dev/null || true
}

# A linter that ran and reported (exit 0 or 1) owns its language; exit 2+ is a
# tool error and must not silently disable the regex fallback.
linter_ran() {
  local rc="$1"
  [ "$rc" -le 1 ]
}

# Normalize an extension list into the space-padded form (" py js ") used by the
# coverage/yield comparisons, so " py" and "py js" both compare correctly.
pad_exts() {
  local padded
  padded="$(printf '%s' "${1:-}" | tr -s ' ')"
  case "$padded" in
    " "*) ;;
    *) padded=" $padded" ;;
  esac
  case "$padded" in
    *" ") ;;
    *) padded="$padded " ;;
  esac
  printf '%s' "$padded"
}

# Keep only paths that exist in this working tree (see run_linters for why).
filter_existing() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done
  return 0
}

run_linters() {
  local flat="$1"
  flat_records="$flat"
  COVERED_LANGS=" "
  RUFF_BANDIT=0
  DETECTORS=""

  local changed
  changed=$(cut -f1 "$flat" 2>/dev/null | sort -u || true)
  if [ -z "$changed" ]; then
    DETECTORS="none"
    record_detectors
    return 0
  fi

  local py_files js_files
  py_files=$(printf '%s\n' "$changed" | grep -E '\.py$' || true)
  js_files=$(printf '%s\n' "$changed" | grep -E '\.(js|jsx|mjs|cjs|ts|tsx)$' || true)

  # A linter can only judge a file that exists in this working tree. In --diff-file
  # mode the patch is never applied, so the file is usually absent; running a tool
  # on a missing path reports an I/O error, and claiming coverage from that would
  # silence the regex fallback for a file no tool ever read.
  py_files=$(printf '%s\n' "$py_files" | filter_existing || true)
  js_files=$(printf '%s\n' "$js_files" | filter_existing || true)

  local tmp rc select
  tmp=$(mktemp)

  # --- Python ---
  if [ -n "$py_files" ] && command -v ruff >/dev/null 2>&1; then
    select=$(knowledge_directive 'ruff-select' 'E9,F,B,S')
    rc=0
    # shellcheck disable=SC2086
    ruff check --select "$select" --output-format=json --no-cache --quiet $py_files > "$tmp" 2>/dev/null || rc=$?
    if linter_ran "$rc"; then
      emit_tool_findings ruff "$tmp"
      COVERED_LANGS="${COVERED_LANGS}py "
      DETECTORS="${DETECTORS}ruff "
      # Bandit families (S) are what cover the string-built query and swallowed
      # exception classes; without them ruff says nothing about those, so the
      # regex rules must not stand down.
      case ",${select}," in
        *,S,*|*,S[0-9]*) RUFF_BANDIT=1 ;;
        *) RUFF_BANDIT=0 ;;
      esac
    fi
  fi

  # --- JS/TS ---
  local eslint_bin=""
  if [ -x node_modules/.bin/eslint ]; then
    eslint_bin="node_modules/.bin/eslint"
  elif command -v eslint >/dev/null 2>&1; then
    eslint_bin="eslint"
  fi
  if [ -n "$js_files" ] && [ -n "$eslint_bin" ]; then
    local eslint_config
    eslint_config=$(knowledge_directive 'eslint-config' '')
    rc=0
    # shellcheck disable=SC2086
    if [ -n "$eslint_config" ]; then
      "$eslint_bin" --config "$eslint_config" --format json --no-error-on-unmatched-pattern $js_files > "$tmp" 2>/dev/null || rc=$?
    else
      "$eslint_bin" --format json --no-error-on-unmatched-pattern $js_files > "$tmp" 2>/dev/null || rc=$?
    fi
    if linter_ran "$rc"; then
      emit_tool_findings eslint "$tmp"
      COVERED_LANGS="${COVERED_LANGS}js ts "
      DETECTORS="${DETECTORS}eslint "
    fi
  fi

  # --- Secrets, every language ---
  if command -v gitleaks >/dev/null 2>&1; then
    rc=0
    gitleaks detect --no-git --source . --no-banner --exit-code 0 \
      --report-format json --report-path "$tmp" >/dev/null 2>&1 || rc=$?
    if linter_ran "$rc"; then
      emit_tool_findings gitleaks "$tmp"
      DETECTORS="${DETECTORS}gitleaks "
    fi
  fi

  # --- Opt-in only: --config auto fetches rules from the network ---
  if [ "${FORGE_SEMGREP:-0}" = "1" ] && command -v semgrep >/dev/null 2>&1; then
    rc=0
    # shellcheck disable=SC2086
    semgrep scan --config auto --json --quiet $changed > "$tmp" 2>/dev/null || rc=$?
    if linter_ran "$rc"; then
      emit_tool_findings semgrep "$tmp"
      COVERED_LANGS="${COVERED_LANGS}py js ts "
      DETECTORS="${DETECTORS}semgrep "
    fi
  fi

  rm -f "$tmp"
  if [ -z "$DETECTORS" ]; then
    DETECTORS="none"
  else
    DETECTORS="${DETECTORS% }"
  fi
  record_detectors
  return 0
}

# True when a linter already ran for this path's language.
lang_covered() {
  local path="$1" ext
  ext="${path##*.}"
  case "$ext" in
    tsx) ext="ts" ;;
    jsx|mjs|cjs) ext="js" ;;
  esac
  case "$COVERED_LANGS" in
    *" $ext "*) return 0 ;;
  esac
  return 1
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

  # Real linters first (each one only where it is installed and relevant).
  run_linters "$flat"

  # scan_flat <regex> <axis/severity> <reason> <fix> [yield-langs]
  # The pattern travels through the environment (ENVIRON) so awk never strips
  # backslashes from it: `-v` assignments process escape sequences and turn an
  # escaped plus into an invalid quantifier on BSD awk.
  # "yield-langs" is a space-padded extension list (" py "). Files of such a
  # language are left to the real linter when it demonstrably detects the same
  # problem class and actually ran; when it is absent, this rule still applies.
  scan_flat() {
    local pat="$1" axis_sev="$2" reason="$3" fix="$4" yield_langs
    yield_langs="$(pad_exts "${5:-}")"
    SCAN_PAT="$pat" YIELD_LANGS="$yield_langs" awk -F'\t' -v as="$axis_sev" -v rsn="$reason" -v fx="$fix" -v cv="${COVERED_LANGS:- }" '
      function ext_of(p,  e) {
        e = p
        sub(/.*\./, "", e)
        if (e == "tsx") return "ts"
        if (e == "jsx" || e == "mjs" || e == "cjs") return "js"
        return e
      }
      BEGIN { c = 0; pat = tolower(ENVIRON["SCAN_PAT"]) }
      # never report the detector own rule table: skip scan_flat / SCAN_PAT lines
      $3 ~ /scan_flat|SCAN_PAT/ { next }
      index(ENVIRON["YIELD_LANGS"], " " ext_of($1) " ") > 0 && index(cv, " " ext_of($1) " ") > 0 { next }
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
  # 3) string-built SQL - yields to ruff only when its bandit families are selected
  local py_bandit=""
  [ "${RUFF_BANDIT:-0}" = "1" ] && py_bandit=" py"
  scan_flat 'sql injection|select.*\+|query\(.*\+|sql = "' 'security/critical' 'possible SQL injection (CWE-89)' 'use parameterized query' "$py_bandit"
  # 4) swallowed exceptions
  scan_flat 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}|except:[[:space:]]*pass' 'correctness/high' 'empty catch swallows error' 'handle typed error or rethrow' "$py_bandit"

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
