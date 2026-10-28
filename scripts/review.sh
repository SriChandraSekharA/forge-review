#!/usr/bin/env bash
set -euo pipefail
# feat: hunk-aware findings + severity-cap score - real file:line from diff hunk headers;
# score is a pure function of findings (critical 3 / high 5 / medium 7 / low-nitpick 8-10);
# loop stops when the finding set converges instead of counting up to a cap.
# feat: worker->critic loop gate 8 max4 - monotonic learning.md append

# review.sh - Worker->Critic loop gate 8 max 4, local only
# Usage:
#   ./scripts/review.sh --staged [--preview]
#   ./scripts/review.sh --range BASE..HEAD [--preview]
#   ./scripts/review.sh --file path/to/file [--preview]
#   ./scripts/review.sh [--preview]  (defaults to BASE_SHA...HEAD_SHA diff)
# Options:
#   --max-iterations N   max loop iterations (default 8)
#   --max-fixes N        max total hint re-injections across the loop (default 4)
#   --tests CMD          run CMD (bash -c) once per iteration after critic scoring;
#                        non-zero exit injects a synthetic [test/high] finding
# Feedback memory: .forge-standard-review/feedback.jsonl (see scripts/learn.sh)
# Team rules: .forge-standard-review/rules.md (one "- <plain-English rule>" per line,
# '#' comments/blank lines ignored) is loaded once and injected into every iteration
# as "# review-rule:" markers; a missing or empty file is never an error.

script_dir="$(cd "$(dirname "$0")" && pwd)"

mode="auto"
range_val=""
file_path=""
preview=0
MAX_ITERATIONS=8
MAX_FIXES=4
tests_cmd=""

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --staged)
      mode="staged"
      shift
      ;;
    --range)
      mode="range"
      if [ $# -lt 2 ]; then echo "error: --range requires BASE..HEAD" >&2; exit 2; fi
      range_val="$2"
      shift 2
      ;;
    --file)
      mode="file"
      if [ $# -lt 2 ]; then echo "error: --file requires path" >&2; exit 2; fi
      file_path="$2"
      shift 2
      ;;
    --preview)
      preview=1
      shift
      ;;
    --max-iterations)
      if [ $# -lt 2 ]; then echo "error: --max-iterations requires N" >&2; exit 2; fi
      case "$2" in
        ''|*[!0-9]*|0) echo "error: --max-iterations requires a positive integer" >&2; exit 2 ;;
      esac
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --max-fixes)
      if [ $# -lt 2 ]; then echo "error: --max-fixes requires N" >&2; exit 2; fi
      case "$2" in
        ''|*[!0-9]*) echo "error: --max-fixes requires a non-negative integer" >&2; exit 2 ;;
      esac
      MAX_FIXES="$2"
      shift 2
      ;;
    --tests)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "error: --tests requires a command" >&2; exit 2; fi
      tests_cmd="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--staged|--range BASE..HEAD|--file path] [--preview] [--max-iterations N] [--max-fixes N] [--tests CMD]"
      exit 0
      ;;
    *)
      # bare range like HEAD~1..HEAD or main...feature
      if echo "$1" | grep -qE "\.\."; then
        mode="range"
        range_val="$1"
        shift
      else
        echo "unknown arg: $1" >&2
        exit 2
      fi
      ;;
  esac
done

# Resolve BASE_SHA and HEAD_SHA as spec requires (triple-dot pin)
BASE_SHA=""
HEAD_SHA=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BASE_SHA="$(git rev-parse --verify origin/main 2>/dev/null | head -n1 || true)"
  if [ -z "$BASE_SHA" ]; then BASE_SHA="$(git rev-parse --verify HEAD~1 2>/dev/null | head -n1 || true)"; fi
  if [ -z "$BASE_SHA" ]; then BASE_SHA="HEAD"; fi
  HEAD_SHA="$(git rev-parse --verify HEAD 2>/dev/null | head -n1 || true)"
  if [ -z "$HEAD_SHA" ]; then HEAD_SHA="HEAD"; fi
else
  BASE_SHA="HEAD"
  HEAD_SHA="HEAD"
fi

# Resolve diff target file
diff_file=$(mktemp)
trap 'rm -f "$diff_file"' EXIT

get_diff() {
  local out="$1"
  case "$mode" in
    staged)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git diff --staged > "$out" 2>/dev/null || git diff --cached > "$out" 2>/dev/null || true
      else
        : > "$out"
      fi
      ;;
    range)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # range_val may contain .. or ... ; use as-is for git diff
        # shellcheck disable=SC2086
        git diff $range_val > "$out" 2>/dev/null || git diff "$BASE_SHA...$HEAD_SHA" > "$out" 2>/dev/null || true
      else
        : > "$out"
      fi
      ;;
    file)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git diff HEAD -- "$file_path" > "$out" 2>/dev/null || true
        if [ ! -s "$out" ] && [ -f "$file_path" ]; then
          # untracked or staged file: show staged or file content as added diff
          git diff --staged -- "$file_path" > "$out" 2>/dev/null || true
          if [ ! -s "$out" ]; then
            # Synthesize a REAL unified-diff header (with hunk range) so added lines
            # map to their true 1-based line numbers instead of collapsing to 1.
            _file_lines=$(grep -c '' "$file_path" 2>/dev/null || echo 0)
            case "$_file_lines" in ''|*[!0-9]*) _file_lines=0 ;; esac
            {
              echo "diff --git a/$file_path b/$file_path"
              echo "new file mode 100644"
              echo "--- /dev/null"
              echo "+++ b/$file_path"
              echo "@@ -0,0 +1,$_file_lines @@"
              cat "$file_path" 2>/dev/null || true
            } > "$out"
          fi
        fi
      else
        if [ -f "$file_path" ]; then cat "$file_path" > "$out"; else : > "$out"; fi
      fi
      ;;
    auto)
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Prefer staged if staged changes exist, else BASE...HEAD
        staged_tmp=$(mktemp)
        git diff --staged > "$staged_tmp" 2>/dev/null || true
        if [ -s "$staged_tmp" ]; then
          cat "$staged_tmp" > "$out"
        else
          git diff "$BASE_SHA...$HEAD_SHA" > "$out" 2>/dev/null || git diff HEAD~1...HEAD > "$out" 2>/dev/null || git diff HEAD > "$out" 2>/dev/null || true
        fi
        rm -f "$staged_tmp"
      else
        : > "$out"
      fi
      ;;
  esac
}

get_diff "$diff_file"

# TEST_AWARE detection - non-failing, timeout 30s, guards for missing tests
TESTS_PRESENT=0
TEST_FILES_LIST=""
TEST_DISCOVERY=""
TEST_CONTEXT=""
# directory guards
if [ -d tests ] || [ -d testsuite ] || [ -d __tests__ ] || [ -d spec ]; then
  TESTS_PRESENT=1
fi
# glob pattern guards - find *.test.* and *.spec.* (prune heavy dirs, non-failing)
if [ "$TESTS_PRESENT" -eq 0 ]; then
  if find . -maxdepth 4 -type f -name "*.test.*" -print 2>/dev/null | grep -q . 2>/dev/null; then
    TESTS_PRESENT=1
  elif find . -maxdepth 4 -type f -name "*.spec.*" -print 2>/dev/null | grep -q . 2>/dev/null; then
    TESTS_PRESENT=1
  fi
fi
# config file guards
for _cfg in pytest.ini vitest.config.js vitest.config.ts vitest.config.mjs vitest.config.cjs jest.config.js jest.config.ts jest.config.cjs jest.config.mjs; do
  if [ -f "$_cfg" ]; then TESTS_PRESENT=1; break; fi
done
if [ "$TESTS_PRESENT" -eq 0 ]; then
  if ls vitest.config.* >/dev/null 2>&1; then TESTS_PRESENT=1; fi
fi
if [ "$TESTS_PRESENT" -eq 0 ]; then
  if ls jest.config.* >/dev/null 2>&1; then TESTS_PRESENT=1; fi
fi
if [ "$TESTS_PRESENT" -eq 0 ] && [ -f package.json ]; then
  if grep -q '"test"' package.json 2>/dev/null; then TESTS_PRESENT=1; fi
fi
if [ "$TESTS_PRESENT" -eq 0 ] && [ -f Makefile ]; then
  if grep -qE "^test[[:space:]]*:" Makefile 2>/dev/null; then TESTS_PRESENT=1; fi
fi
if [ "$TESTS_PRESENT" -eq 0 ] && [ -f pyproject.toml ]; then
  if grep -q "pytest" pyproject.toml 2>/dev/null; then TESTS_PRESENT=1; fi
fi
# normalize to 0/1
if [ "$TESTS_PRESENT" != "0" ] && [ "$TESTS_PRESENT" != "1" ]; then TESTS_PRESENT=1; fi
# if tests detected, collect (a) list test files, (b) discovery with 30s timeout, non-failing
if [ "$TESTS_PRESENT" -eq 1 ]; then
  # (a) list test files capped at 20, non-failing
  _tf1=$(find . -type f \( -name "*.test.*" -o -name "*.spec.*" \) 2>/dev/null | head -20 || true)
  _tf2=""
  for _d in tests testsuite __tests__ spec; do
    if [ -d "$_d" ]; then
      _tf2="$_tf2
$(find "$_d" -type f 2>/dev/null | head -20 || true)"
    fi
  done
  TEST_FILES_LIST="$_tf1$_tf2"
  TEST_FILES_LIST=$(echo "$TEST_FILES_LIST" | grep -v "^[[:space:]]*$" | head -30 || true)
  # (b) quick test discovery, timeout 30s, failure gracefully
  _disc=""
  if command -v pytest >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      _disc=$(timeout 30 pytest --collect-only 2>&1 | head -30 || true)
    elif command -v gtimeout >/dev/null 2>&1; then
      _disc=$(gtimeout 30 pytest --collect-only 2>&1 | head -30 || true)
    else
      _disc=$(pytest --collect-only 2>&1 | head -30 || true)
    fi
  fi
  if [ -z "$_disc" ] && [ -f package.json ]; then
    if command -v npm >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        _try=$(timeout 30 npm test -- --listTests 2>&1 | head -20 || true)
      elif command -v gtimeout >/dev/null 2>&1; then
        _try=$(gtimeout 30 npm test -- --listTests 2>&1 | head -20 || true)
      else
        _try=$(npm test -- --listTests 2>&1 | head -20 || true)
      fi
      if echo "$_try" | grep -qE "test|spec|PASS|FAIL" 2>/dev/null; then _disc="$_try"; fi
      if [ -z "$_disc" ]; then
        if command -v npx >/dev/null 2>&1; then
          if command -v timeout >/dev/null 2>&1; then
            _try2=$(timeout 30 npx jest --listTests 2>&1 | head -20 || true)
          elif command -v gtimeout >/dev/null 2>&1; then
            _try2=$(gtimeout 30 npx jest --listTests 2>&1 | head -20 || true)
          else
            _try2=$(npx jest --listTests 2>&1 | head -20 || true)
          fi
          if echo "$_try2" | grep -qE "\.test|\.spec" 2>/dev/null; then _disc="$_try2"; fi
        fi
      fi
    fi
  fi
  if [ -z "$_disc" ]; then
    if command -v npx >/dev/null 2>&1 && ls vitest.config.* >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        _disc=$(timeout 30 npx vitest list 2>&1 | head -20 || true)
      elif command -v gtimeout >/dev/null 2>&1; then
        _disc=$(gtimeout 30 npx vitest list 2>&1 | head -20 || true)
      else
        _disc=$(npx vitest list 2>&1 | head -20 || true)
      fi
    fi
  fi
  TEST_DISCOVERY="$_disc"
  TEST_CONTEXT="Tests detected: yes
Test files:
${TEST_FILES_LIST:-none}
Discovery:
${TEST_DISCOVERY:-no discovery output}"
else
  TEST_CONTEXT="Tests detected: no"
fi
export TESTS_PRESENT
export TEST_CONTEXT
export TEST_FILES_LIST
export TEST_DISCOVERY
# persist for report/critic visibility (isolated under .forge-standard-review/, non-failing)
mkdir -p .forge-standard-review 2>/dev/null || true
printf "%s\n" "$TEST_CONTEXT" > .forge-standard-review/test_context.md 2>/dev/null || true

# --preview: print diff and exit
if [ "$preview" -eq 1 ]; then
  cat "$diff_file"
  exit 0
fi

# Prepare output dir - never overwrite learning.md, only append
out_dir=".forge-standard-review"
mkdir -p "$out_dir"
# Ensure learning.md exists (monotonic append only)
if [ ! -f "$out_dir/learning.md" ]; then
  : > "$out_dir/learning.md"
fi

# --- Team rules (Greptile custom rules & standards analog) ---
# Loads $out_dir/rules.md: one plain-English rule per line as "- <text>";
# '#' comment lines and blank lines are ignored. A missing or empty file is
# not an error - the review simply runs with zero team rules active.
RULES_CONTEXT=""
RULES_COUNT=0
rules_file="$out_dir/rules.md"
if [ -f "$rules_file" ]; then
  rules_body="$(grep -vE '^[[:space:]]*(#|$)' "$rules_file" 2>/dev/null || true)"
  if [ -n "$rules_body" ]; then
    while IFS= read -r rule_text; do
      [ -z "$rule_text" ] && continue
      RULES_CONTEXT="${RULES_CONTEXT}# review-rule: ${rule_text}"$'\n'
      RULES_COUNT=$((RULES_COUNT + 1))
    done <<< "$rules_body"
  fi
fi
# Timestamp for run log
ts=$(date +%s 2>/dev/null || echo $$)
run_log="$out_dir/run-${ts}-$$.log"
: > "$run_log"
# Capture active team rules in the run log (one '# review-rule:' marker per rule;
# nothing appended when no rules are active)
printf '%s' "$RULES_CONTEXT" >> "$run_log"

# --- Detection engine ---
# Detection lives in scripts/detect.sh (hunk-aware flattening + local rules).
# review.sh only orchestrates and must never re-implement detection.
detect_script="$script_dir/detect.sh"
if [ ! -f "$detect_script" ]; then
  echo "error: detect.sh not found next to review.sh ($detect_script)" >&2
  exit 2
fi
run_worker() {
  TESTS_PRESENT="${TESTS_PRESENT:-0}" bash "$detect_script" "$1" "$2"
}

# --- Feedback memory (Greptile-inspired learned feedback) ---
# Sources .forge-standard-review/feedback.jsonl (append-only, written by learn.sh):
#   {"ts":"<epoch>","action":"dismiss","path":"<glob>","rule":"<regex>","reason":"..."}
#   {"ts":"<epoch>","action":"floor","min_severity":"high|medium|low|nitpick","reason":"..."}
# Invalid/missing lines are skipped gracefully - feedback never fails the review.

# Severity rank: critical=4 high=3 medium=2 low=1 nitpick=0 (unknown treated as 0)
sev_rank() {
  case "$1" in
    critical) echo 4 ;;
    high) echo 3 ;;
    medium) echo 2 ;;
    low) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Load feedback.jsonl once: sets FLOOR_RANK (-1 = none) and DISMISS_LIST (path<TAB>rule lines)
load_feedback_memory() {
  local fb="$1"
  FLOOR_RANK=-1
  DISMISS_LIST=""
  [ -f "$fb" ] || return 0
  local line action dpath drule sev srank
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then continue; fi
    action="$(printf '%s' "$line" | jq -r '.action // ""' 2>/dev/null || true)"
    case "$action" in
      dismiss)
        dpath="$(printf '%s' "$line" | jq -r '.path // ""' 2>/dev/null || true)"
        drule="$(printf '%s' "$line" | jq -r '.rule // ""' 2>/dev/null || true)"
        if [ -n "$dpath" ] && [ -n "$drule" ]; then
          DISMISS_LIST="${DISMISS_LIST}${dpath}"$'\t'"${drule}"$'\n'
        fi
        ;;
      floor)
        sev="$(printf '%s' "$line" | jq -r '.min_severity // ""' 2>/dev/null || true)"
        case "$sev" in
          critical|high|medium|low|nitpick)
            srank=$(sev_rank "$sev")
            if [ "$srank" -gt "$FLOOR_RANK" ]; then FLOOR_RANK="$srank"; fi
            ;;
        esac
        ;;
    esac
  done < "$fb"
}

# Filter findings through learned dismiss rules + severity floor (in place).
# Sets SUPPRESSED_ITER / BELOW_FLOOR_ITER / DISMISSED_ITER for this iteration.
apply_learning_filters() {
  local src="$1"
  local filtered
  filtered=$(mktemp)
  : > "$filtered"
  SUPPRESSED_ITER=0
  BELOW_FLOOR_ITER=0
  DISMISSED_ITER=0
  local fline rest token fpath catsev fsev frank reason drop dpath drule
  while IFS= read -r fline; do
    [ -z "$fline" ] && continue
    drop=0
    rest="${fline#L: }"
    token="${rest%%[[:space:]]*}"
    fpath="${token%:*}"
    # reason: text after the [category/severity] group
    reason="$(printf '%s\n' "$rest" | sed -E 's/^[^]]*\][[:space:]]*//')"
    # severity from the [category/severity] bracket group
    catsev="$(printf '%s\n' "$rest" | grep -oE '\[[^]]*\]' | head -n1 || true)"
    catsev="${catsev#\[}"
    catsev="${catsev%\]}"
    fsev="${catsev#*/}"
    # 1) learned severity floor: drop findings strictly below floor
    if [ "$drop" -eq 0 ] && [ "$FLOOR_RANK" -ge 0 ]; then
      frank=$(sev_rank "$fsev")
      if [ "$frank" -lt "$FLOOR_RANK" ]; then
        BELOW_FLOOR_ITER=$((BELOW_FLOOR_ITER + 1))
        drop=1
      fi
    fi
    # 2) learned dismiss rules: path glob (or literal) AND reason regex (grep -E, case-sensitive)
    if [ "$drop" -eq 0 ] && [ -n "$DISMISS_LIST" ]; then
      while IFS=$'\t' read -r dpath drule; do
        if [ -z "$dpath" ] && [ -z "$drule" ]; then continue; fi
        # SC2053: unquoted RHS is intentional — dismiss rules are path GLOBS, not literals
        # shellcheck disable=SC2053
        if [[ "$fpath" == $dpath ]] && printf '%s\n' "$reason" | grep -Eq -- "$drule" 2>/dev/null; then
          DISMISSED_ITER=$((DISMISSED_ITER + 1))
          drop=1
          break
        fi
      done <<< "$DISMISS_LIST"
    fi
    if [ "$drop" -eq 0 ]; then
      printf '%s\n' "$fline" >> "$filtered"
    fi
  done < "$src"
  SUPPRESSED_ITER=$((DISMISSED_ITER + BELOW_FLOOR_ITER))
  TOTAL_SUPPRESSED=$((TOTAL_SUPPRESSED + SUPPRESSED_ITER))
  TOTAL_BELOW_FLOOR=$((TOTAL_BELOW_FLOOR + BELOW_FLOOR_ITER))
  cat "$filtered" > "$src"
  rm -f "$filtered"
}

# --- optional --tests hook (Greptile-TREX analog) ---
# Runs the exact user-supplied command once per iteration (bash -c, single
# execution, no retries). On failure, appends one synthetic [test/high] finding
# plus up to 10 output lines into the findings pool. Nothing is interpolated
# into the command beyond what the user passed.
run_tests_hook() {
  local findings_out="$1"
  [ -n "$tests_cmd" ] || return 0
  local raw_out tests_out tests_rc=0 tline
  raw_out=$(mktemp)
  tests_out=$(mktemp)
  # single execution - capture exit code and last 50 output lines
  bash -c "$tests_cmd" > "$raw_out" 2>&1 || tests_rc=$?
  if [ "$tests_rc" -ne 0 ]; then
    tail -n 50 "$raw_out" > "$tests_out" 2>/dev/null || : > "$tests_out"
    printf 'L: path:0 [test/high] test command failed (exit %s): %s\n' "$tests_rc" "$tests_cmd" >> "$findings_out"
    if [ -s "$tests_out" ]; then
      tail -n 10 "$tests_out" 2>/dev/null | while IFS= read -r tline; do
        [ -z "$tline" ] && continue
        printf 'L: path:0 [test/high] test-output: %s\n' "$tline" >> "$findings_out"
      done
    fi
    echo "tests hook: command failed (exit $tests_rc), synthetic finding appended" | tee -a "$run_log" >/dev/null
  else
    echo "tests hook: command passed (exit 0)" | tee -a "$run_log" >/dev/null
  fi
  rm -f "$raw_out" "$tests_out"
  return 0
}

# Loop gate 8 max 4
final_score=0
hint_accum=""
TOTAL_SUPPRESSED=0
TOTAL_BELOW_FLOOR=0
fixes_used=0
prev_sig=""
stop_loop=0

load_feedback_memory "$out_dir/feedback.jsonl"

i=1
while [ "$i" -le "$MAX_ITERATIONS" ]; do
  findings_tmp=$(mktemp)
  critic_out=$(mktemp)

  # inject team rules + hint from previous iteration into diff context
  # marker lines use neutral prefixes to minimize triggering heuristic patterns
  aug_diff=$(mktemp)
  cat "$diff_file" > "$aug_diff"
  # team rules are re-injected every iteration (plain-English, one marker per rule)
  if [ -n "$RULES_CONTEXT" ]; then
    printf '%s' "$RULES_CONTEXT" >> "$aug_diff"
  fi
  if [ -n "$hint_accum" ]; then
    # neutral marker - intentionally avoids TODO/console.log/injection keywords
    echo "# review-hint iter $i: $hint_accum" >> "$aug_diff"
  fi
  run_worker "$aug_diff" "$findings_tmp" "$i"
  rm -f "$aug_diff"

  # Deduplicate findings
  if [ -s "$findings_tmp" ]; then
    sort -u "$findings_tmp" -o "$findings_tmp" 2>/dev/null || true
  fi

  # Feedback memory: learned dismiss rules + severity floor (after dedup)
  apply_learning_filters "$findings_tmp"
  if [ "$SUPPRESSED_ITER" -gt 0 ]; then
    echo "learning: $SUPPRESSED_ITER suppressed ($BELOW_FLOOR_ITER below floor)" >> "$run_log"
  fi

  set +o pipefail
  findings_count=$(grep -cvE "^[[:space:]]*$" "$findings_tmp" 2>/dev/null || true)
  set -o pipefail
  if ! echo "$findings_count" | grep -qE "^[0-9]+$"; then findings_count=0; fi

  # Run critic scoring. critic.sh is a required sibling script: it is the only
  # scorer (no inline duplicate that could drift or reintroduce a rising floor).
  critic_script="$script_dir/critic.sh"
  if [ ! -f "$critic_script" ]; then
    echo "error: critic.sh not found next to review.sh ($critic_script)" >&2
    rm -f "$findings_tmp" "$critic_out"
    exit 2
  fi
  bash "$critic_script" "$findings_tmp" "$i" > "$critic_out" 2>/dev/null || true

  score_line=$(grep -E "^score:[[:space:]]*[0-9]+" "$critic_out" | head -1 || echo "score: 6")
  score_val=$(echo "$score_line" | grep -oE "[0-9]+" | head -1)
  if [ -z "$score_val" ]; then score_val=6; fi
  feedback_line=$(grep -E "^feedback:" "$critic_out" | head -1 || echo "feedback: n/a")
  hints_line=$(grep -E "^hints:" "$critic_out" | head -1 || echo "hints: none")

  # --tests hook: once per iteration, after critic scoring
  run_tests_hook "$findings_tmp"
  # recompute count so logs reflect the pool incl. synthetic test findings
  if [ -n "$tests_cmd" ]; then
    findings_count=$(grep -cvE "^[[:space:]]*$" "$findings_tmp" 2>/dev/null || true)
    if ! echo "$findings_count" | grep -qE "^[0-9]+$"; then findings_count=0; fi
  fi

  # Append monotonically to learning.md (never overwrite)
  {
    echo "## $(date +"%Y-%m-%dT%H:%M:%S+05:30") Iteration $i score: $score_val"
    echo "$feedback_line"
    echo "$hints_line"
    echo "findings: $findings_count"
    if [ "${TESTS_PRESENT:-0}" -eq 1 ]; then
      echo "TEST_CONTEXT: $TEST_CONTEXT" | head -40
    fi
    if [ -s "$findings_tmp" ]; then
      cat "$findings_tmp"
    else
      echo "(no findings)"
    fi
    echo ""
  } >> "$out_dir/learning.md"

  # Log to run log
  {
    echo "=== Iteration $i ==="
    echo "$score_line"
    echo "$feedback_line"
    echo "$hints_line"
    echo "findings: $findings_count"
    if [ "${TESTS_PRESENT:-0}" -eq 1 ]; then
      echo "TEST_CONTEXT: $TEST_CONTEXT" | head -40
    fi
    if [ -s "$findings_tmp" ]; then cat "$findings_tmp"; fi
    echo ""
  } >> "$run_log"

  echo "Iteration $i: $score_line ($findings_count findings)" | tee -a "$run_log" >/dev/null
  # Also echo to stdout for user visibility
  echo "Iteration $i: $score_line ($findings_count findings)"

  final_score=$score_val
  cur_sig="$(cksum < "$findings_tmp" 2>/dev/null || echo none)"

  # Gate check
  if [ "$score_val" -ge 8 ]; then
    echo "Gate passed at iteration $i with score $score_val" | tee -a "$run_log"
    rm -f "$findings_tmp" "$critic_out"
    break
  else
    if [ "$fixes_used" -lt "$MAX_FIXES" ]; then
      hint_accum="${hints_line#hints:}"
      hint_accum="${hint_accum#"${hint_accum%%[![:space:]]*}"}"
      if [ -z "$hint_accum" ] || [ "$hint_accum" = "none" ]; then
        hint_accum="address findings, add boundary coverage, use parameterized statements"
      fi
      fixes_used=$((fixes_used + 1))
      echo "Gate not met (score $score_val <8), hint for next ($fixes_used/$MAX_FIXES): $hint_accum" | tee -a "$run_log"
    else
      # --max-fixes cap reached: stop re-injecting hints, keep iterating
      hint_accum=""
      echo "Gate not met (score $score_val <8), max fixes ($MAX_FIXES) reached - continuing without new hints" | tee -a "$run_log"
    fi
    # Converged: the finding set is byte-identical to the previous iteration.
    # Nothing in this loop mutates code, so an unchanged set can only repeat;
    # stop instead of spending iterations to reach a cap.
    if [ "$i" -gt 1 ] && [ -n "$prev_sig" ] && [ "$cur_sig" = "$prev_sig" ]; then
      echo "converged: findings unchanged since iteration $((i - 1)) - stopping" | tee -a "$run_log"
      stop_loop=1
    fi
    prev_sig="$cur_sig"
  fi

  rm -f "$findings_tmp" "$critic_out"

  if [ "$stop_loop" -eq 1 ]; then
    break
  fi

  # If last iteration, ensure log has final score
  if [ "$i" -eq "$MAX_ITERATIONS" ]; then
    echo "Max iterations ($MAX_ITERATIONS) reached with score $final_score" | tee -a "$run_log"
  fi
  i=$((i + 1))
done

# Feedback memory totals: run log + final output (never deletes feedback data)
echo "learning: $TOTAL_SUPPRESSED suppressed ($TOTAL_BELOW_FLOOR below floor)" | tee -a "$run_log"

# Team rules totals: run log + final output (always printed; 'rules: 0 active' when none)
echo "rules: $RULES_COUNT active" | tee -a "$run_log"

# Ensure run log contains score: line for grep verification
if ! grep -qE "^score:" "$run_log" 2>/dev/null; then
  echo "score: $final_score" >> "$run_log"
fi

# Also ensure at least one score: line is at end for easy grep
echo "Final score: $final_score" >> "$run_log"
if command -v jq >/dev/null 2>&1 && [ -f "$out_dir/state.json" ]; then
  ts_now="$(date +"%Y-%m-%dT%H:%M:%S+05:30" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  if [ -n "$ts_now" ]; then
    tmp_ts="$(mktemp)"
    if jq --arg ts "$ts_now" '.lastReviewAt=$ts' "$out_dir/state.json" > "$tmp_ts" 2>/dev/null && [ -s "$tmp_ts" ] && jq empty "$tmp_ts" 2>/dev/null; then
      mv "$tmp_ts" "$out_dir/state.json"
    else
      rm -f "$tmp_ts"
    fi
  fi
elif [ -f "$out_dir/state.json" ] && command -v python3 >/dev/null 2>&1; then
  ts_now="$(date +"%Y-%m-%dT%H:%M:%S+05:30" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  if [ -n "$ts_now" ]; then
    python3 -c "import json,sys; p=sys.argv[1]; ts=sys.argv[2]; d=json.load(open(p)); d['lastReviewAt']=ts; json.dump(d, open(p,'w'), indent=2)" "$out_dir/state.json" "$ts_now" 2>/dev/null || true
  fi
fi
# Emit final score line in required format for verification
echo "score: $final_score"

exit 0
