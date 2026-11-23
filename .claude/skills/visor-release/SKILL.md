---
name: visor-release
description: Release a new Visor version end to end. Use for `/visor-release [version]` or when the user asks to release, ship or publish a new version of Visor: preflight, docs and website sync, release notes, a review stop, build and verify, a ship stop, then publish to GitHub, the appcast and the Homebrew tap.
---

# visor-release

Take Visor from `main` to a published `{version}`. Read the "Updates and releases" section of `CLAUDE.md` first, nothing else in full. Agent prompts are in `briefs.md`.

Two stops for the user: the review (STOP 1) and the ship (STOP 2). Nothing leaves this Mac before STOP 2. `{scratch}` is the session scratchpad, never the repo.

## Token rules

- Scripts do everything mechanical. Run them and read their output; don't redo their work by hand.
- At most two docs agents, model sonnet, run in parallel. Each sees only the changes output, its own files and the rules.
- No review or approver agents: every item in the release was already reviewed when it was built.
- Never read a whole file you don't change. Use the changes output, `git diff` and `grep`.
- The review shows diffs, not full files.

## Rules

- Commits use `tailamphat@users.noreply.github.com`. Conventional Commits.
- No pushes, tags, releases or tap changes before the user says ship at STOP 2.
- No em dashes, plain words, no employer or personal names; fixtures use `acme.ghe.com`, `octocat`, `/Users/me`.
- If a step fails, stop and say what failed. Don't fix the environment (keys, certificates, gh accounts) without asking.

## 1. Preflight

```
scripts/release-preflight.sh {version}
```

If no version was given, run step 2 first and use its suggested version. Any FAIL: show the list and stop. `--no-check` skips `scripts/check.sh` only on a rerun right after a pass.

## 2. Changes

```
scripts/release-changes.sh > {scratch}/changes.md
```

It groups commits since the last tag by type, flags surfaces (features, network or storage, hooks or plugins, UI, docs already changed) and suggests a version: any feat is a minor bump, else a patch. If the user's version disagrees with the suggestion, say so in the review; don't change it.

## 3. Docs sync

Spawn agents only for flagged surfaces, both in one message so they run in parallel:

| Agent | When | Files it owns |
|---|---|---|
| Docs (sonnet) | features, network or storage, hooks or plugins | README.md, docs/features.md, docs/how-it-works.md, SECURITY.md (docs/plugins.md if the plugin API changed) |
| Website (sonnet) | features | docs/index.html |

Fill the briefs in `briefs.md` with `{version}`, `{previous_minor}` and the path to `changes.md`. Skip an agent when none of its surfaces are flagged. When only fixes changed, skip both. Each agent edits in place and replies with a short summary; don't reread its files, read `git diff` instead.

### 3b. Screenshots

No new captures by default. When the UI surface is flagged, copy its "May be stale" images into the review as a list. Recapture only if the user asks; then follow the visuals approach in `CLAUDE.md` with fake data on the debug socket.

## 4. Release notes

Write `{scratch}/notes-{version}.md` yourself from `changes.md`:

```
## New
- One line per feature, what the user can now do.

## Fixes
- One line per fix the user would notice.
```

Plain words, user-facing, no commit types or scopes, no internal refactors, tests, docs or CI. Merge commits that make one feature. Leave out a heading with nothing under it. No `<` or `&` (the notes become HTML in the appcast). The same file is the GitHub release body and the appcast description.

## STOP 1: review

Show one short review: a single artifact if it is long, else a message. Include:

- version (and the suggestion if different)
- the notes
- `git diff --stat`
- `git diff` of the docs and website changes
- screenshots that may be stale
- preflight result

Ask: go, or what to change. Apply changes and show only the new diff. Wait for go.

## 5. Build and verify

After go, commit the docs (release.sh needs a clean tree, and the build number is the commit count):

```
git add README.md SECURITY.md docs
git -c user.email=tailamphat@users.noreply.github.com commit -m "docs(release): {version} docs and website"
scripts/release.sh {version}
scripts/release-verify.sh {version}
```

Skip the commit when nothing changed. Any FAIL in verify: stop and show it. The local update test in `CLAUDE.md` runs only if the user asks.

## STOP 2: ship

Run `scripts/release-publish.sh {version} {scratch}/notes-{version}.md --dry-run` and show its output under the question "Ship {version}?". The dry run lists the exact commands. Wait for a clear yes.

## 6. Publish

```
scripts/release-publish.sh {version} {scratch}/notes-{version}.md
```

It adds the notes to the appcast item, tags the build commit, commits the appcast, pushes main and the tag, creates the GitHub release with the zip, bumps the tap cask and pushes it, then prints the checks. Finished steps are skipped on a rerun, so after a failure fix the cause and run the same command again.

## Report

Under 150 words: version, release URL, the checks (appcast on main, `brew info`), docs and website changes in one line each, stale screenshots if any, and anything skipped or left for the user.
