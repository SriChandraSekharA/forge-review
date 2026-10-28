#!/usr/bin/env bash
set -euo pipefail
# learn.sh - feedback memory CLI (Greptile-inspired learning for forge-standard-review)
# Appends learned feedback to <target>/.forge-standard-review/feedback.jsonl (JSONL,
# append-only - never deletes or rewrites existing entries).
#
# Usage:
#   ./scripts/learn.sh --dismiss --file <glob-or-path> --rule <regex> --reason <text> [TARGET_DIR]
#   ./scripts/learn.sh --floor --severity <high|medium|low|nitpick> --reason <text> [TARGET_DIR]
#   ./scripts/learn.sh --rule "<plain-english text>" [TARGET_DIR]
#   ./scripts/learn.sh --rules [TARGET_DIR]
#   ./scripts/learn.sh --list [TARGET_DIR]
#
# TARGET_DIR (optional, last positional arg) defaults to the script-relative repo root.
# review.sh consumes feedback.jsonl: dismiss rules suppress matching findings;
# the (strictest learned) severity floor drops findings below it.
# rules.md holds plain-English team rules (one "- <rule>" per line); --rule appends
# (exact-line dedupe), --rules prints the active (non-comment, non-blank) lines.

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
target_root="$(cd -- "$script_dir/.." && pwd)"

mode=""
f_glob=""
f_rule=""
f_reason=""
f_sev=""

usage() {
  echo "Usage: $0 --dismiss --file <glob-or-path> --rule <regex> --reason <text> [TARGET_DIR]"
  echo "       $0 --floor --severity <high|medium|low|nitpick> --reason <text> [TARGET_DIR]"
  echo "       $0 --rule \"<plain-english text>\" [TARGET_DIR]"
  echo "       $0 --rules [TARGET_DIR]"
  echo "       $0 --list [TARGET_DIR]"
}

die() {
  echo "error: $1" >&2
  usage >&2
  exit 2
}

# Parse args (mode flag, options, optional trailing positional TARGET_DIR)
while [ $# -gt 0 ]; do
  case "$1" in
    --dismiss|--floor|--list|--rules)
      if [ -n "$mode" ]; then die "only one of --dismiss/--floor/--list/--rules allowed"; fi
      mode="${1#--}"
      shift
      ;;
    --file)
      [ $# -ge 2 ] || die "--file requires a value"
      f_glob="$2"
      shift 2
      ;;
    --rule)
      [ $# -ge 2 ] || die "--rule requires a value"
      # dual-purpose: standalone action (learn a plain-English team rule) when no
      # action flag seen yet; otherwise the <regex> option of --dismiss
      if [ -z "$mode" ]; then
        mode="rule"
      fi
      f_rule="$2"
      shift 2
      ;;
    --severity)
      [ $# -ge 2 ] || die "--severity requires a value"
      f_sev="$2"
      shift 2
      ;;
    --reason)
      [ $# -ge 2 ] || die "--reason requires a value"
      f_reason="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "unknown arg: $1"
      ;;
    *)
      # optional target dir as last positional arg (like other scripts)
      target_root="$1"
      shift
      ;;
  esac
done

if [ -z "$mode" ]; then
  die "one of --dismiss/--floor/--list/--rules/--rule is required"
fi

fb_dir="$target_root/.forge-standard-review"
fb_file="$fb_dir/feedback.jsonl"

json_validate() {
  # $1 = candidate JSON string; echoes nothing, returns 0 iff valid JSON document
  printf '%s' "$1" | jq -e . >/dev/null 2>&1
}

case "$mode" in
  dismiss)
    [ -n "$f_glob" ] || die "--dismiss requires --file <glob-or-path>"
    [ -n "$f_rule" ] || die "--dismiss requires --rule <regex>"
    # duplicate detection: same (path, rule) pair already learned -> "already learned", exit 0.
    # File is JSONL (one JSON object per line); invalid lines are skipped gracefully.
    if [ -f "$fb_file" ]; then
      dup_found=0
      line=""
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        # single jq per line: invalid lines fail the jq call -> skipped, never fatal
        if printf '%s' "$line" | jq -e \
            --arg p "$f_glob" --arg r "$f_rule" \
            '.action == "dismiss" and .path == $p and .rule == $r' >/dev/null 2>&1; then
          dup_found=1
          break
        fi
      done < "$fb_file"
      if [ "$dup_found" -eq 1 ]; then
        echo "already learned (same path+rule), skipping"
        exit 0
      fi
    fi
    # -c: compact single-line JSON - the JSONL contract every consumer relies on
    json="$(jq -cn \
      --arg ts "$(date +%s 2>/dev/null || echo 0)" \
      --arg path "$f_glob" \
      --arg rule "$f_rule" \
      --arg reason "$f_reason" \
      '{ts: $ts, action: "dismiss", path: $path, rule: $rule, reason: $reason}')"
    ;;
  floor)
    [ -n "$f_sev" ] || die "--floor requires --severity <high|medium|low|nitpick>"
    case "$f_sev" in
      high|medium|low|nitpick) ;;
      *) die "--severity must be one of: high, medium, low, nitpick" ;;
    esac
    # -c: compact single-line JSON (JSONL contract)
    json="$(jq -cn \
      --arg ts "$(date +%s 2>/dev/null || echo 0)" \
      --arg sev "$f_sev" \
      --arg reason "$f_reason" \
      '{ts: $ts, action: "floor", min_severity: $sev, reason: $reason}')"
    ;;
  list)
    if [ ! -f "$fb_file" ] || [ ! -s "$fb_file" ]; then
      echo "(no feedback learned)"
      exit 0
    fi
    printed=0
    line=""
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      if ! json_validate "$line"; then continue; fi # skip invalid lines gracefully
      printf '%s\n' "$line" | jq .
      printed=1
    done < "$fb_file"
    if [ "$printed" -eq 0 ]; then
      echo "(no feedback learned)"
    fi
    exit 0
    ;;
  rule)
    [ -n "$f_rule" ] || die "--rule requires <plain-english text>"
    rules_file="$fb_dir/rules.md"
    rule_line="- $f_rule"
    mkdir -p "$fb_dir"
    # create with header template if missing - never overwrite existing content
    if [ ! -f "$rules_file" ]; then
      cat > "$rules_file" <<'EOF'
# Team review rules - plain-English rules enforced on every review
# One rule per line as "- <rule text>". Lines starting with '#' and blank lines are ignored.
# Example (uncomment to activate):
# - No console.log in shipped code; use the structured logger.
EOF
    fi
    # exact-line dedupe: identical rule text is a no-op, exit 0
    if grep -Fxq -- "$rule_line" "$rules_file" 2>/dev/null; then
      echo "rule already learned, skipping"
      exit 0
    fi
    # append-only: never rewrite or remove existing rules
    printf '%s\n' "$rule_line" >> "$rules_file"
    echo "rule learned: $rule_line"
    exit 0
    ;;
  rules)
    rules_file="$fb_dir/rules.md"
    if [ ! -f "$rules_file" ]; then
      echo "(no custom rules)"
      exit 0
    fi
    # active rules = file content minus comment lines and blank lines
    printed="$(grep -vE '^[[:space:]]*(#|$)' "$rules_file" 2>/dev/null || true)"
    if [ -z "$printed" ]; then
      echo "(no custom rules)"
    else
      printf '%s\n' "$printed"
    fi
    exit 0
    ;;
  *)
    die "unknown mode: $mode"
    ;;
esac

# jq-validate the JSON before writing (built by jq, but never trust silently)
if ! json_validate "$json"; then
  echo "error: generated JSON failed validation, not writing" >&2
  exit 1
fi

mkdir -p "$fb_dir"
# append-only: never truncate or rewrite existing feedback data
printf '%s\n' "$json" >> "$fb_file"
echo "learned: $json"
exit 0
