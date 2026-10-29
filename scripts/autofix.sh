#!/usr/bin/env bash
set -euo pipefail
# autofix.sh - apply the mechanically fixable part of a review, using real linters.
# Usage: ./scripts/autofix.sh <diff-file>
#
# Prints exactly one line:
#   autofix: applied ruff eslint
#   autofix: nothing to fix
#
# Only tools installed locally are used, and only the files this diff touches.
# Code is rewritten IN THE WORKING TREE, so the caller must recompute the diff
# afterwards. Everything a linter cannot fix (design, tests, architecture) stays
# with the reviewer - this script never invents a change.
#
# Ruleset selection follows the same knowledge-doc directive that detect.sh
# honours, so a repo that narrowed `ruff-select` gets the same ruleset here.

diff_file="${1:?usage: autofix.sh <diff-file>}"

paths=$(grep -E '^\+\+\+ b/' "$diff_file" 2>/dev/null \
  | sed -E 's|^\+\+\+ b/||; s|\t.*$||' \
  | grep -v '^/dev/null' | grep -v '^$' | sort -u || true)
if [ -z "$paths" ]; then
  echo "autofix: nothing to fix"
  exit 0
fi

py_files=$(printf '%s\n' "$paths" | grep -E '\.py$' || true)
js_files=$(printf '%s\n' "$paths" | grep -E '\.(js|jsx|mjs|cjs|ts|tsx)$' || true)

knowledge_doc=".forge-standard-review/knowledge.md"
ruff_select=""
if [ -f "$knowledge_doc" ]; then
  ruff_select=$(grep -iE '^[[:space:]]*ruff-select[[:space:]]*:' "$knowledge_doc" 2>/dev/null \
    | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r' || true)
fi
[ -n "$ruff_select" ] || ruff_select="E9,F,B,S"

eslint_config=""
if [ -f "$knowledge_doc" ]; then
  eslint_config=$(grep -iE '^[[:space:]]*eslint-config[[:space:]]*:' "$knowledge_doc" 2>/dev/null \
    | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r' || true)
fi

# Cheap content fingerprint: a fixer that reports success but changed nothing
# must not consume a fix budget slot.
fingerprint() {
  local list="$1" out=""
  while IFS= read -r file; do
    if [ -z "$file" ] || [ ! -f "$file" ]; then continue; fi
    out="$out$(cksum < "$file")"
  done <<< "$list"
  printf '%s' "$out"
}

applied=""

if [ -n "$py_files" ] && command -v ruff >/dev/null 2>&1; then
  before=$(fingerprint "$py_files")
  # shellcheck disable=SC2086
  ruff check --select "$ruff_select" --fix --no-cache --quiet $py_files >/dev/null 2>&1 || true
  after=$(fingerprint "$py_files")
  [ "$before" = "$after" ] || applied="${applied}ruff "
fi

eslint_bin=""
if [ -x node_modules/.bin/eslint ]; then
  eslint_bin="node_modules/.bin/eslint"
elif command -v eslint >/dev/null 2>&1; then
  eslint_bin="eslint"
fi
if [ -n "$js_files" ] && [ -n "$eslint_bin" ]; then
  before=$(fingerprint "$js_files")
  # shellcheck disable=SC2086
  if [ -n "$eslint_config" ]; then
    "$eslint_bin" --config "$eslint_config" --fix --no-error-on-unmatched-pattern $js_files >/dev/null 2>&1 || true
  else
    "$eslint_bin" --fix --no-error-on-unmatched-pattern $js_files >/dev/null 2>&1 || true
  fi
  after=$(fingerprint "$js_files")
  [ "$before" = "$after" ] || applied="${applied}eslint "
fi

if [ -z "$applied" ]; then
  echo "autofix: nothing to fix"
else
  echo "autofix: applied ${applied% }"
fi
