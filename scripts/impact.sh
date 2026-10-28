#!/usr/bin/env bash
set -euo pipefail
# feat: blast-radius impact tracing - local importers/callers of changed files (Greptile-inspired, beyond the diff)
# impact.sh [--files path[,path...]] [target_dir]  (one path per line on stdin when --files omitted)
# Deterministic, no network, no API tokens. Always exits 0.
# Output lines: IMPACT <changed-file> <- <importer-file>:<line> <kind>   (kind: import|require|include|reference)
# Caps: 50 lines per changed file, 200 total, then one "... N more" line. Empty result -> "IMPACT none".

export LC_ALL=C

target_dir="."
files_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --files)
      if [ $# -ge 2 ]; then files_arg="$2"; shift 2; else files_arg=""; shift; fi
      ;;
    --help|-h)
      echo "Usage: impact.sh [--files path[,path...]] [target_dir]   # or one path per line on stdin"
      exit 0
      ;;
    -*)
      shift
      ;;
    *)
      target_dir="$1"
      shift
      ;;
  esac
done

if ! cd "$target_dir" >/dev/null 2>&1; then
  echo "IMPACT none"
  exit 0
fi

tmp_files=$(mktemp)
tmp_raw=$(mktemp)
tmp_kinds=$(mktemp)
tmp_out=$(mktemp)
trap 'rm -f "$tmp_files" "$tmp_raw" "$tmp_kinds" "$tmp_out"' EXIT

if [ -n "$files_arg" ]; then
  printf '%s\n' "$files_arg" | tr ',' '\n' > "$tmp_files"
elif [ ! -t 0 ]; then
  cat > "$tmp_files"
else
  : > "$tmp_files"
fi
# trim whitespace, drop empties, dedupe -> deterministic iteration order
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$tmp_files" | sort -u > "$tmp_files.2"
mv "$tmp_files.2" "$tmp_files"

in_git=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then in_git=1; fi

excluded_path() {
  case "$1" in
    .git/*|*/.git/*|node_modules/*|*/node_modules/*|.forge-standard-review/*|*/.forge-standard-review/*|dist/*|*/dist/*|build/*|*/build/*|__pycache__/*|*/__pycache__/*|.venv/*|*/.venv/*|vendor/*|*/vendor/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

esc_re() {
  printf '%s' "$1" | sed 's/[^[:alnum:]_]/\\&/g'
}

# grep -rn is primary; git grep results merged when inside a git repo (dedup via sort -u later)
collect_matches() {
  grep -rnI -e "$1" . \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.forge-standard-review \
    --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ \
    --exclude-dir=.venv --exclude-dir=vendor 2>/dev/null | sed 's#^\./##' || true
  if [ "$in_git" -eq 1 ]; then
    git grep -nI -e "$1" -- . 2>/dev/null | sed 's#^\./##' || true
  fi
}

# classify a matched line content into a kind; $1 = escaped stem, $2 = line content
classify_line() {
  sre="$1"
  content="$2"
  if printf '%s' "$content" | grep -qE "require[[:space:]]*\([[:space:]]*['\"][^'\"]*/?${sre}(\.[[:alnum:]]+)?['\"]"; then
    echo "require"
  elif printf '%s' "$content" | grep -qE "#[[:space:]]*include[[:space:]]*[\"<][^\">]*${sre}"; then
    echo "include"
  elif printf '%s' "$content" | grep -qE "^[[:space:]]*use[[:space:]]+${sre}([:;[:space:]]|$)"; then
    echo "import"
  elif printf '%s' "$content" | grep -qE "(^[[:space:]]*(import[[:space:]]+${sre}([^[:alnum:]_]|$)|import[^#;]*[[:space:]]from[[:space:]]+['\"]?\.{0,2}/{0,2}${sre}([^[:alnum:]_]|$)|export[^#;]*[[:space:]]from[[:space:]]+['\"]?\.{0,2}/{0,2}${sre}([^[:alnum:]_]|$)|from[[:space:]]+['\"]?\.{0,2}/{0,2}${sre}([^[:alnum:]_]|$)|from[[:space:]]+\.{1,2}[[:space:]]+import[[:space:]]+${sre}([^[:alnum:]_]|$)))"; then
    echo "import"
  else
    echo "reference"
  fi
}

emitted_total=0
more_total=0
cwd="$(pwd)"

while IFS= read -r changed_raw || [ -n "$changed_raw" ]; do
  changed="$changed_raw"
  [ -z "$changed" ] && continue
  changed="${changed#./}"
  case "$changed" in "$cwd"/*) changed="${changed#"$cwd"/}" ;; esac
  base="${changed##*/}"
  stem="${base%.*}"
  [ -z "$stem" ] && continue
  sre="$(esc_re "$stem")"
  file_emitted=0
  : > "$tmp_raw"
  : > "$tmp_kinds"
  collect_matches "\\b${sre}\\b" > "$tmp_raw"
  while IFS= read -r m || [ -n "$m" ]; do
    [ -z "$m" ] && continue
    mpath="${m%%:*}"
    mrest="${m#*:}"
    mline="${mrest%%:*}"
    mcontent="${mrest#*:}"
    if [ -z "$mpath" ] || [ -z "$mline" ]; then continue; fi
    case "$mline" in ''|*[!0-9]*) continue ;; esac
    if [ "$mpath" = "$changed" ]; then continue; fi
    if excluded_path "$mpath"; then continue; fi
    kind="$(classify_line "$sre" "$mcontent")"
    printf '%s:%s|%s\n' "$mpath" "$mline" "$kind" >> "$tmp_kinds"
  done < "$tmp_raw"
  if [ -s "$tmp_kinds" ]; then
    sort -u "$tmp_kinds" -o "$tmp_kinds"
    while IFS= read -r mc || [ -n "$mc" ]; do
      [ -z "$mc" ] && continue
      if [ "$emitted_total" -ge 200 ] || [ "$file_emitted" -ge 50 ]; then
        more_total=$((more_total + 1))
        continue
      fi
      mc_path="${mc%%|*}"
      mc_kind="${mc#*|}"
      printf 'IMPACT %s <- %s %s\n' "$changed" "$mc_path" "$mc_kind" >> "$tmp_out"
      emitted_total=$((emitted_total + 1))
      file_emitted=$((file_emitted + 1))
    done < "$tmp_kinds"
  fi
done < "$tmp_files"

if [ -s "$tmp_out" ]; then
  cat "$tmp_out"
  if [ "$more_total" -gt 0 ]; then printf '... %d more\n' "$more_total"; fi
else
  echo "IMPACT none"
fi
exit 0
