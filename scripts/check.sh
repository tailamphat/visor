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

# 4. The website's design tokens: the generated blocks in docs/index.html and the design system
#    document (docs/design-system.html) match DesignTokens.swift, DesignComponents.swift and
#    index.html's component classes (scripts/site-tokens.sh --check); the document must carry all
#    three blocks. Added lines on both pages use var(--v-*) instead of a raw hex equal to a palette
#    token (6 digits, or 3 doubled: #fff is #FFFFFF).
#    Exempt: the generated blocks, a hex shown as text (right after ">"), and index.html's hidden
#    SVG defs (agent brand marks and .art scenes keep their own palettes; presentation attributes
#    can't take var()). rgba() is not checked here; the notch mocks use var(--v-fill-*) or color-mix().
scripts/site-tokens.sh 2>/dev/null | sed -n 's/^ *--v-\([a-z0-9-]*\): \(#[0-9A-F]\{6\}\);$/\2 \1/p' > "$TMP/palette"
for SITE in docs/index.html docs/design-system.html; do
  [[ -f "$SITE" ]] || continue
  line() { grep -n "$1" "$SITE" | head -1 | cut -d: -f1; }
  TB="$(line 'tokens:begin \*/')"; TE="$(line 'tokens:end \*/')"
  CB=0; CE=0  # index.html's component classes are hand-written there, so they are checked
  [[ "$SITE" == docs/index.html ]] || { CB="$(line 'components:begin \*/')"; CE="$(line 'components:end \*/')"; }
  MB="$(line 'measures:begin \*/')"; ME="$(line 'measures:end \*/')"
  DB="$(line '^<svg width="0" height="0"')"
  DE="$(awk -v b="${DB:-0}" 'b && NR > b && /^<\/svg>/ { print NR; exit }' "$SITE")"
  if ! scripts/site-tokens.sh --check "$SITE" > "$TMP/tokens.log" 2>&1; then
    grep -v '^[<>0-9-]' "$TMP/tokens.log" | while IFS= read -r msg; do hit "$SITE" "${TB:-1}" "site-tokens: $msg"; done
  fi
  if [[ "$SITE" == docs/design-system.html ]]; then
    for NAME in tokens components measures; do
      grep -q "$NAME:begin \*/" "$SITE" && grep -q "$NAME:end \*/" "$SITE" ||
        hit "$SITE" 1 "needs the generated $NAME block (/* $NAME:begin */ ... /* $NAME:end */, then scripts/site-tokens.sh --write $SITE)"
    done
  fi
  awk -F'\t' -v site="$SITE" -v pal="$TMP/palette" \
      -v r="${TB:-0} ${TE:-0} ${CB:-0} ${CE:-0} ${MB:-0} ${ME:-0} ${DB:-0} ${DE:-0}" '
    BEGIN { while ((getline line < pal) > 0) { split(line, p, " "); name[p[1]] = p[2] } n = split(r, b, " ") }
    function exempt(l,   k) { for (k = 1; k < n; k += 2) if (b[k] && l >= b[k] && l <= b[k + 1]) return 1; return 0 }
    $1 == site && !exempt($2) {
      s = substr($0, length($1) + length($2) + 3)
      # A run of hex digits after "#": 6 as written, 3 doubled (#fff is #FFFFFF), any other length skipped.
      while (match(s, /#[0-9A-Fa-f]+/)) {
        run = toupper(substr(s, RSTART + 1, RLENGTH - 1))
        before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        h = ""
        if (length(run) == 6) h = "#" run
        else if (length(run) == 3) h = "#" substr(run, 1, 1) substr(run, 1, 1) substr(run, 2, 1) substr(run, 2, 1) substr(run, 3, 1) substr(run, 3, 1)
        if (h != "" && (h in name) && before != ">")
          printf "%s:%s: raw %s equals token %s (use var(--v-%s))\n", $1, $2, (length(run) == 3 ? "#" run " (" h ")" : h), name[h], name[h]
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$TMP/added" >> "$HITS"
done

# 5. The design system: no literal colour, type size, radius or fill in any app view. Unlike
#    the rules above this scans the whole of Sources/Visor (Plugins included), not only added
#    lines, so it passes only while the tree is clean. Patterns and skipped paths come from
#    scripts/design-literals.txt, which DesignAdoptionTests reads too; there is no allowlist of
#    lines. Skipped by path there: the design system itself (Sources/Visor/DesignSystem/; the
#    token values in Sources/VisorCore/Design*.swift are outside Sources/Visor), Theme.swift
#    (token entry point), and, out of scope by the epic, agent brand marks and Office pixel art.
LITERALS=scripts/design-literals.txt
if [[ -f "$LITERALS" ]]; then
  find Sources/Visor -name '*.swift' | sort | perl -e '
    my $list = shift; my (@literals, @skips);
    open(my $fh, "<", $list) or die "check: $list: $!\n";
    while (<$fh>) {
      chomp; next if /^#/;
      my @f = split /\t/;
      next if @f < 3;
      push @literals, [$f[1], qr/$f[2]/] if $f[0] eq "literal";
      push @skips, $f[1] if $f[0] eq "skip";
    }
    FILE: while (my $file = <STDIN>) {
      chomp $file;
      for my $s (@skips) { next FILE if ($s =~ m{/$} ? index($file, $s) == 0 : $file eq $s) }
      open(my $in, "<", $file) or next;
      while (my $line = <$in>) {
        next if $line =~ m{^\s*//};
        for my $l (@literals) {
          print "$file:$.: literal $l->[0] (use DS, Theme or a shared component; see $list)\n" if $line =~ $l->[1];
        }
      }
      close $in;
    }
  ' "$LITERALS" >> "$HITS"
else
  hit "$LITERALS" 1 "missing (the design-system literal rule reads it)"
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
