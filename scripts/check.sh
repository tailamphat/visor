#!/bin/bash
# Checks a change before review: scripts/check.sh [--no-test] [base-ref]
#
#   scripts/check.sh            # uncommitted changes (and new files) vs HEAD
#   scripts/check.sh main~3     # everything from main~3 to the working tree
#   scripts/check.sh --no-test  # skip scripts/test.sh for a quick rerun
#
# Runs the tests and a debug build, then looks at the ADDED lines of the diff
# for things CLAUDE.md rules out. Private words come from an optional file
# outside the repo: ${VISOR_PRIVATE_WORDS:-$HOME/.config/visor/private-words.txt},
# one per line. Never put real words in the repo.
# Prints "file:line: rule" per hit and exits 1 on any hit or failure.
set -uo pipefail
cd "$(dirname "$0")/.."

TEST=1
BASE=HEAD
for arg in "$@"; do
  case "$arg" in
    --no-test) TEST=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) BASE="$arg" ;;
  esac
done
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "check: unknown ref $BASE" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HITS="$TMP/hits"
: > "$HITS"
FAILED=0

# Added lines as "file<TAB>line<TAB>text". New untracked files count in full.
git diff -U0 --no-color --no-ext-diff "$BASE" -- . | awk '
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
  /^@@ / { split($3, a, ","); n = substr(a[1], 2) + 0; next }
  /^\+/ { if (f != "/dev/null") print f "\t" n "\t" substr($0, 2); n++ }
' > "$TMP/added"
git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
  [[ -f "$f" ]] && grep -Iq . "$f" 2>/dev/null || continue
  awk -v f="$f" '{ print f "\t" NR "\t" $0 }' "$f" >> "$TMP/added"
done
{ git diff --name-only "$BASE" -- .; git ls-files --others --exclude-standard; } | sort -u > "$TMP/files"
echo "check: $(wc -l < "$TMP/files" | tr -d ' ') changed files, $(wc -l < "$TMP/added" | tr -d ' ') added lines (vs $BASE)"

# 1. Tests and build.
if [[ $TEST == 1 ]]; then
  if scripts/test.sh > "$TMP/test.log" 2>&1; then
    echo "tests: pass"
  else
    echo "tests: FAIL (last lines below)"; tail -25 "$TMP/test.log"; FAILED=1
  fi
else
  echo "tests: skipped (--no-test)"
fi
if swift build --product Visor > "$TMP/build.log" 2>&1; then
  echo "build: pass"
else
  echo "build: FAIL"; grep -E 'error:' "$TMP/build.log" | sort -u | head -20; FAILED=1
fi

# 2. Compiler warnings in changed files.
ROOT="$(pwd)"
while IFS= read -r f; do
  [[ "$f" == *.swift ]] || continue
  grep -F "$ROOT/$f:" "$TMP/build.log" | grep -E ': warning: ' | sort -u | while IFS= read -r w; do
    loc="${w#"$ROOT/"}"; loc="${loc%%: warning: *}"; loc="${loc%:*}"
    echo "$loc: compiler warning: ${w##*: warning: }" >> "$HITS"
  done
done < "$TMP/files"

# 3. Rules on added lines.
EMDASH="$(printf '\342\200\224')"
WORDS="${VISOR_PRIVATE_WORDS:-$HOME/.config/visor/private-words.txt}"
LITERAL='[0-9]+(\.[0-9]+)?'
CHAIN="(^|[^A-Za-z0-9_.])($LITERAL[[:space:]]*[-+*][[:space:]]*){4}$LITERAL"

hit() { echo "$1:$2: $3" >> "$HITS"; }

while IFS=$'\t' read -r f n text; do
  [[ "$f" == scripts/check.sh ]] && continue
  [[ "$text" == *"$EMDASH"* ]] && hit "$f" "$n" "em dash (use a hyphen or a colon)"
  if [[ "$f" == *.swift ]]; then
    code="${text#"${text%%[![:space:]]*}"}"
    [[ "$code" == //* ]] && continue
    [[ "$code" == *@State* ]] && hit "$f" "$n" "@State (keep view state on AppModel)"
    [[ "$code" == *repeatForever* ]] && hit "$f" "$n" "repeatForever (use LayerAnimations)"
    [[ "$code" == *symbolEffect* ]] && hit "$f" "$n" "symbolEffect (use LayerAnimations)"
    [[ "$code" == *"NSRegularExpression("* && "$code" != *"static let"* ]] &&
      hit "$f" "$n" "NSRegularExpression not on a static let (compile once)"
    [[ "$code" == *"Process()"* && "$f" != Sources/Visor/Support/Shell.swift ]] &&
      hit "$f" "$n" "Process() outside Shell.swift (use Shell.run)"
    [[ "$code" =~ (^|[^A-Za-z0-9_])(ISO8601)?DateFormatter\(\) && "$f" != Sources/VisorCore/Dates.swift ]] &&
      hit "$f" "$n" "DateFormatter() outside Dates.swift (use ISODate / DateTemplates)"
    [[ "$code" =~ $CHAIN ]] && hit "$f" "$n" "5+ numeric literals in one sum (older Swift on CI times out)"
  fi
  if [[ "$f" == scripts/* || "$f" == Tests/* ]]; then
    if [[ "$text" =~ (^|[^-a-z])hook\.sock && "$text" =~ (nc |socat|connect|write|send|\>) ]]; then
      hit "$f" "$n" "writes to the real hook.sock (use hook-debug.sock)"
    fi
  fi
done < "$TMP/added"

# 4. The website's design tokens: the block in docs/index.html matches DesignTokens.swift,
#    and added site lines use var(--v-*) instead of a raw 6-digit hex equal to a palette token.
#    Exempt: a hex shown as text (right after ">"), and the hidden SVG defs (agent brand
#    marks and .art scenes keep their own palettes; presentation attributes can't take var()).
#    #fff/#000 shorthands and rgba() are left to the design-system items that follow.
SITE=docs/index.html
if [[ -f "$SITE" ]]; then
  TB="$(grep -n 'tokens:begin \*/' "$SITE" | head -1 | cut -d: -f1)"
  TE="$(grep -n 'tokens:end \*/' "$SITE" | head -1 | cut -d: -f1)"
  DB="$(grep -n '^<svg width="0" height="0"' "$SITE" | head -1 | cut -d: -f1)"
  DE="$(awk -v b="${DB:-0}" 'b && NR > b && /^<\/svg>/ { print NR; exit }' "$SITE")"
  if ! scripts/site-tokens.sh --check "$SITE" > "$TMP/tokens.log" 2>&1; then
    hit "$SITE" "${TB:-1}" "tokens: $(head -1 "$TMP/tokens.log")"
  fi
  scripts/site-tokens.sh 2>/dev/null | sed -n 's/^ *--v-\([a-z0-9-]*\): \(#[0-9A-F]\{6\}\);$/\2 \1/p' > "$TMP/palette"
  awk -F'\t' -v site="$SITE" -v b="${TB:-0}" -v e="${TE:-0}" -v db="${DB:-0}" -v de="${DE:-0}" -v pal="$TMP/palette" '
    BEGIN { while ((getline line < pal) > 0) { split(line, p, " "); name[p[1]] = p[2] } }
    $1 == site && ($2 < b || $2 > e) && ($2 < db || $2 > de) {
      s = substr($0, length($1) + length($2) + 3)
      while (match(s, /#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
        h = toupper(substr(s, RSTART, 7))
        before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        after = substr(s, RSTART + 7, 1)
        if ((h in name) && after !~ /[0-9A-Fa-f]/ && before != ">")
          printf "%s:%s: raw %s equals token %s (use var(--v-%s))\n", $1, $2, h, name[h], name[h]
        s = substr(s, RSTART + 7)
      }
    }
  ' "$TMP/added" >> "$HITS"
fi

if [[ -f "$WORDS" ]]; then
  while IFS= read -r word || [[ -n "$word" ]]; do
    word="${word%%#*}"; word="$(echo "$word" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$word" ]] && continue
    grep -iF -- "$word" "$TMP/added" | while IFS=$'\t' read -r f n _; do
      hit "$f" "$n" "private word ($word)"
    done
  done < "$WORDS"
  echo "private words: checked ($WORDS)"
else
  echo "private words: no list at $WORDS (skipped)"
fi

# Summary.
COUNT="$(sort -u "$HITS" | grep -c . || true)"
if [[ "$COUNT" -gt 0 ]]; then
  echo "hits: $COUNT"
  sort -u "$HITS" | sort -t: -k1,1 -k2,2n
fi
if [[ $FAILED == 1 || "$COUNT" -gt 0 ]]; then
  echo "check: FAIL"; exit 1
fi
echo "check: pass"
