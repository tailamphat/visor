#!/bin/bash
# Checks that a release can start: scripts/release-preflight.sh <version>
#
#   scripts/release-preflight.sh 0.9.0
#   scripts/release-preflight.sh 0.9.0 --no-check   # skip scripts/check.sh
#
# Read-only: it changes nothing. Prints one pass/FAIL line per check and
# exits 1 if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
RUN_CHECK=1
[[ "${2:-}" == --no-check ]] && RUN_CHECK=0
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release-preflight.sh <version> [--no-check]" >&2
  exit 2
fi

TAP="${VISOR_TAP:-$HOME/workspace/homebrew-tap}"
NOREPLY="tailamphat@users.noreply.github.com"
IDENTITY="Notchboard Local Signing"
FAILED=0

pass() { echo "pass  $1"; }
fail() { echo "FAIL  $1"; FAILED=1; }

# Version: well formed and newer than the last tag.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
LAST="${LAST_TAG#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "version $VERSION is not x.y.z"
elif [[ -n "$LAST" && "$(printf '%s\n%s\n' "$LAST" "$VERSION" | sort -V | tail -1)" != "$VERSION" || "$VERSION" == "$LAST" ]]; then
  fail "version $VERSION is not newer than $LAST_TAG"
else
  pass "version $VERSION (last tag ${LAST_TAG:-none})"
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  fail "tag v$VERSION already exists"
fi

# Git: on main, clean, at or after the last tag.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == main ]] && pass "on main" || fail "on $BRANCH, not main"
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
  pass "clean tree"
else
  fail "uncommitted or untracked files"
fi
if [[ -z "$LAST_TAG" ]] || git merge-base --is-ancestor "$LAST_TAG" HEAD; then
  pass "HEAD is at or after ${LAST_TAG:-the first commit}"
else
  fail "HEAD is behind $LAST_TAG"
fi

# Unpushed commits: all with the noreply email.
git fetch -q origin main 2>/dev/null || true
BAD_EMAILS="$(git log --format=%ae origin/main..HEAD 2>/dev/null | grep -vxF "$NOREPLY" | sort -u || true)"
AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
if [[ -z "$BAD_EMAILS" ]]; then
  pass "unpushed commits ($AHEAD) all use $NOREPLY"
else
  fail "unpushed commits with other emails: $(echo "$BAD_EMAILS" | tr '\n' ' ')"
fi

# GitHub: signed in as tailamphat, CI green for HEAD.
if gh auth status 2>&1 | grep -q "account tailamphat"; then
  pass "gh signed in as tailamphat"
else
  fail "gh is not signed in as tailamphat (gh auth switch -u tailamphat)"
fi
HEAD_SHA="$(git rev-parse HEAD)"
CI="$(gh run list --commit "$HEAD_SHA" --workflow CI --json status,conclusion \
  --jq 'if length == 0 then "" else (.[0] | "\(.status) \(.conclusion)") end' 2>/dev/null || true)"
case "$CI" in
  "completed success") pass "CI green for HEAD" ;;
  "") fail "no CI run for HEAD (push first, or wait for it)" ;;
  *) fail "CI for HEAD: $CI" ;;
esac

# Signing: the local certificate (bundle.sh) and Sparkle's EdDSA key.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  pass "signing certificate \"$IDENTITY\""
else
  fail "no \"$IDENTITY\" certificate (scripts/make-signing-identity.sh)"
fi
# Looks up the item's attributes only, so the Keychain never asks for access.
if security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1; then
  pass "Sparkle EdDSA key in the login Keychain"
else
  fail "no Sparkle EdDSA key in the Keychain (see CLAUDE.md, Updates and releases)"
fi
[[ -x .build/artifacts/sparkle/Sparkle/bin/generate_appcast ]] &&
  pass "Sparkle generate_appcast present" ||
  fail "no .build/artifacts/sparkle/Sparkle/bin/generate_appcast (swift build first)"

# Tap clone: present and clean.
if [[ -f "$TAP/Casks/visor.rb" ]]; then
  if [[ -z "$(git -C "$TAP" status --porcelain)" ]]; then
    pass "tap clone clean ($TAP)"
  else
    fail "tap clone has changes ($TAP)"
  fi
else
  fail "no tap clone at $TAP (set VISOR_TAP)"
fi

# Tests, build and rule checks on everything since the last tag.
if [[ $RUN_CHECK == 1 ]]; then
  LOG="$(mktemp)"
  if scripts/check.sh "${LAST_TAG:-HEAD}" > "$LOG" 2>&1; then
    pass "scripts/check.sh ${LAST_TAG:-HEAD}"
  else
    fail "scripts/check.sh ${LAST_TAG:-HEAD} (last lines below)"
    tail -15 "$LOG" | sed 's/^/      /'
  fi
  rm -f "$LOG"
else
  echo "skip  scripts/check.sh (--no-check)"
fi

if [[ $FAILED == 1 ]]; then
  echo "preflight: FAIL"
  exit 1
fi
echo "preflight: pass"
