#!/usr/bin/env bash
set -euo pipefail
# fix: merge-preservation - 2nd invocation never overwrites: state.json jq merge preserves reviews[], checklist CUSTOM blocks, history always overwrites, learning.md append-only

target_dir="${1:-.forge-standard-review}"
mkdir -p "$target_dir"

script_dir="$(cd "$(dirname "$0")" && pwd)"
# Resolve reference paths (script-relative, portable to any install location)
resolve_ref() {
  local rel="$1"
  if [ -f "$rel" ]; then echo "$rel"
  elif [ -f "$script_dir/../$rel" ]; then echo "$script_dir/../$rel"
  else echo ""; fi
}

state_template="$(resolve_ref "references/state.json.template")"
checklist_ref="$(resolve_ref "references/checklist.md")"
# state.json merge: preserve reviews[] array, jq fallback to cp -n
if [ -f "$target_dir/state.json" ]; then
  if command -v jq >/dev/null 2>&1 && [ -n "$state_template" ] && [ -f "$state_template" ]; then
    tmp_merged="$(mktemp)"
    jq -s '.[0] * {reviews: .[1].reviews} * (if .[1].lastReviewAt != null then {lastReviewAt: .[1].lastReviewAt} else {} end) | .reviews //= []' "$state_template" "$target_dir/state.json" > "$tmp_merged" 2>/dev/null || cp -n "$state_template" "$tmp_merged" 2>/dev/null || true
    if [ -s "$tmp_merged" ] && jq empty "$tmp_merged" 2>/dev/null; then
      mv "$tmp_merged" "$target_dir/state.json"
    else
      rm -f "$tmp_merged"
    fi
  else
    : # jq missing or template missing - cp -n semantics: preserve existing file
  fi
else
  if [ -n "$state_template" ] && [ -f "$state_template" ]; then
    cp "$state_template" "$target_dir/state.json"
  else
    echo '{"initialized":true,"reviews":[],"version":1,"lastReviewAt":null}' > "$target_dir/state.json"
  fi
fi

# checklist.md merge: preserve CUSTOM blocks or lines containing CUSTOM
if [ -f "$target_dir/checklist.md" ]; then
  tmp_custom="$(mktemp)"
  if grep -q "USER CUSTOM START" "$target_dir/checklist.md" 2>/dev/null; then
    sed -n '/USER CUSTOM START/,/USER CUSTOM END/p' "$target_dir/checklist.md" > "$tmp_custom" 2>/dev/null || true
  else
    grep "CUSTOM" "$target_dir/checklist.md" > "$tmp_custom" 2>/dev/null || true
    # diff -u fallback: preserve user lines not in template that contain CUSTOM
    if command -v diff >/dev/null 2>&1 && [ -n "$checklist_ref" ] && [ -f "$checklist_ref" ]; then
      diff -u "$checklist_ref" "$target_dir/checklist.md" 2>/dev/null | grep "^+.*CUSTOM" | sed 's/^+//' >> "$tmp_custom" 2>/dev/null || true
    fi
    sort -u "$tmp_custom" -o "$tmp_custom" 2>/dev/null || true
  fi
  if [ -s "$tmp_custom" ]; then
    # file exists - never cp blindly; ensure CUSTOM preserved
    if ! grep -q "CUSTOM" "$target_dir/checklist.md" 2>/dev/null; then
      cat "$tmp_custom" >> "$target_dir/checklist.md"
    fi
  fi
  rm -f "$tmp_custom"
else
  if [ -n "$checklist_ref" ] && [ -f "$checklist_ref" ]; then
    cp -n "$checklist_ref" "$target_dir/checklist.md" 2>/dev/null || cp "$checklist_ref" "$target_dir/checklist.md"
  fi
fi

# history.md: always overwrite/sync via history.sh
if [ -f "$script_dir/history.sh" ]; then
  bash "$script_dir/history.sh" "$target_dir" 2>/dev/null || echo "no-vcs" > "$target_dir/history.md"
elif [ -f "./scripts/history.sh" ]; then
  bash "./scripts/history.sh" "$target_dir" 2>/dev/null || echo "no-vcs" > "$target_dir/history.md"
else
  echo "no-vcs" > "$target_dir/history.md"
fi

# learning.md: never truncated - append only, create if missing
if [ ! -f "$target_dir/learning.md" ]; then
  touch "$target_dir/learning.md"
fi

# feedback.jsonl: append-only JSONL memory - never truncate. When merging an existing
# instance, optional $2 (file or dir holding feedback.jsonl) supplies foreign/new JSON
# lines: append only lines not already present, exact-line dedupe via grep -Fxq,
# preserving existing order (learning.md append-only semantics).
if [ ! -f "$target_dir/feedback.jsonl" ]; then
  touch "$target_dir/feedback.jsonl"
fi
if [ "$#" -ge 2 ] && [ -n "$2" ]; then
  foreign_fb="$2"
  if [ -d "$foreign_fb" ]; then
    foreign_fb="$foreign_fb/feedback.jsonl"
  fi
  if [ -f "$foreign_fb" ]; then
    while IFS= read -r fb_line || [ -n "$fb_line" ]; do
      if [ -n "$fb_line" ] && ! grep -Fxq -- "$fb_line" "$target_dir/feedback.jsonl" 2>/dev/null; then
        printf '%s\n' "$fb_line" >> "$target_dir/feedback.jsonl"
      fi
    done < "$foreign_fb"
  fi
fi

# rules.md: plain-English team rules - never lose user rules. Create with header template
# if missing; optional $2 (file or dir holding rules.md) supplies foreign rules: union of
# lines, exact-line dedupe via grep -Fxq, preserving existing order.
if [ ! -f "$target_dir/rules.md" ]; then
  cat > "$target_dir/rules.md" <<'EOF'
# Team review rules - plain-English rules enforced on every review
# One rule per line as "- <rule text>". Lines starting with '#' and blank lines are ignored.
# Example (uncomment to activate):
# - No console.log in shipped code; use the structured logger.
EOF
fi
if [ "$#" -ge 2 ] && [ -n "$2" ]; then
  foreign_rules="$2"
  if [ -d "$foreign_rules" ]; then
    foreign_rules="$foreign_rules/rules.md"
  fi
  if [ -f "$foreign_rules" ]; then
    while IFS= read -r rule_line || [ -n "$rule_line" ]; do
      if [ -n "$rule_line" ] && ! grep -Fxq -- "$rule_line" "$target_dir/rules.md" 2>/dev/null; then
        printf '%s\n' "$rule_line" >> "$target_dir/rules.md"
      fi
    done < "$foreign_rules"
  fi
fi
echo "merge done"
