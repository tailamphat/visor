---
name: visor-dev
description: Build or change a Visor feature end to end, from request to a proven local commit on main. Use for `/visor-dev <request>` or any request to add, fix or change behaviour in the Visor notch app: plans it, gets the plan approved by an approver agent, builds test first, gates it with review and perf agents, proves it in the debug app, has visor-qa test it independently and reports. Never pushes.
---

# visor-dev

Take `{request}` to a proven local commit on `main`, mostly hands-off. You, the main session, are the builder. Read `CLAUDE.md` and `docs/architecture.md` before planning. Agent prompts are in `briefs.md`; the plan template is `plan-template.md`.

## Size first

| Size | When | Steps | Agents |
|---|---|---|---|
| S | Copy fix, one-line bug | 1 (short plan, 1-3 criteria), 3, 4, 7 and 7b if visible, 8 | QA if visible |
| M | Most changes | all | approver; gate Review + Perf (+ Security if triggered); QA |
| L | New provider, tab, agent CLI | all | approver; full gate; perf before vs after; QA |

Security is triggered when the diff touches hooks, sockets, plugins, network, keychain or the clipboard. When unsure between two sizes, pick the larger.

## Stop list

Never auto-approve these. Stop and ask the user:

- releases, version bumps, `appcast.xml`
- deleting or migrating user data
- changes to approval or hook behaviour, or to plugin security
- editing CLAUDE.md rules
- new dependencies
- anything outside this repo

## Pipeline

### 1. Plan

Write `plans/<slug>.md` in the session scratchpad (not the repo) from `plan-template.md`. Sections in order: Request (verbatim), Goal, Size, Done when, Auto criteria, Out of scope, Files in order, Tests first, Proof script, Risks and assumptions.

- Every Done-when row traces to a phrase of the request and names its verifier: a test, a check.sh rule, a proof step with a screenshot, or a perf limit. Never "looks good".
- Always add the auto criteria: idle CPU <= baseline + 0.2%; check.sh 0 hits and all tests pass; for UI, balanced around the camera; for hooks, debug socket only.
- Files follow the matching `docs/architecture.md` recipe, VisorCore first.
- Resolve open questions to the narrower, safer reading and list them.
- Record the baseline now: `scripts/perf.sh -n 10` against the running release build.

### 1b. Visible changes

If the user will see anything different, publish the options side by side, at real notch size, with a recommendation, to the single mockup page (republish the same artifact, never a new one). The approver picks the recommended option unless it fails the rubric. The run continues. Put the mockup link and the final screenshot in the Done report so the user can ask to switch.

### 2. Approval (M and L)

Spawn `visor-approver` with the approver brief. Give it only the request, the plan path, CLAUDE.md and docs/architecture.md: never the chat or your reasoning. Append its verdict to the plan.

- APPROVED: continue.
- REJECTED: apply the exact fixes once and resubmit.
- STOP LIST yes, or a second rejection: stop. Show the user both plan versions and the reasons.

### 3. Build test first

Write the failing tests from the plan in `Tests/VisorCoreTests`, run `scripts/test.sh` and see them fail for the right reason. Then write the code until `scripts/test.sh` is green. Never plain `swift test`.

### 4. Self review

Run `scripts/check.sh` and fix every hit. Then read your own diff (`git diff`) once, top to bottom.

### 5. Gate (M and L)

Send all gate agents in ONE message so they run in parallel. Each gets only the diff, the file list and the relevant CLAUDE.md section (see `briefs.md`):

- `visor-reviewer`: bugs and refactor suggestions.
- `visor-perf`: `scripts/perf.sh` before and after, `--sample` on hot paths if needed. Give it the baseline and the pid of the debug build with the change.
- Security (only if triggered): a general agent with the security brief, which applies the built-in security-review approach scoped to the diff.

Each returns at most 8 findings with `file:line` and a concrete failure scenario.

### 6. Fix

Check each finding against the code before acting; a finding is a claim, not a fact. Fix real bugs, apply worthwhile refactors, skip the rest with a reason. Rerun `scripts/check.sh`. Run a second gate pass only after a large fix. Never loop.

### 7. Prove in the real app

- Quit Notchy first if it runs (`pgrep -x Notchy`).
- `swift build --product Visor`, then `VISOR_NO_MUSIC=1 .build/debug/Visor` in the background.
- Run the plan's proof script against `hook-debug.sock` only. Never send anything to `hook.sock`.
- Take each screenshot with `screencapture -x -R x,y,w,h` into the scratchpad and look at it.
- Quit the debug build and relaunch the release build afterwards (`open /Applications/Visor.app` or `./scripts/bundle.sh --open`).

### 7b. QA (whenever the user can see or use the change)

Skipped only for a change with nothing to see or use (VisorCore logic with no app wiring yet); under /visor-pm, the epic QA covers it.

Your proof checks your own plan with your own script. QA checks the request with its own cases. Spawn `visor-qa` with the QA brief (`briefs.md`): the request verbatim, the plan's Done-when table only (criterion and request phrase, never the Verify-by column or the proof script), the code path, the evidence folder (`<scratchpad>/qa/`), the mockup link, the debug messages the change adds and the touched areas. Never give it the diff or your reasoning. It builds and drives the debug build itself, so nothing else may use the screen or the debug socket while it runs.

- PASS: go on to step 8.
- FAIL: treat each finding as a claim, reproduce it, fix it (step 6), add the cases it marked "unit test" to `Tests/VisorCoreTests`, rerun `scripts/test.sh` and `scripts/check.sh`, prove again (step 7), then run QA once more.
- A second FAIL: stop and ask the user, with both QA reports. Never loosen a criterion or drop a case to pass.

### 8. Verify, commit, report

Run every Verify-by from the plan. A failure goes back to step 3: at most 2 attempts, then stop and ask the user. Never loosen a criterion to make it pass.

Commit on `main`:

- Conventional Commits: `type(scope): plain description`.
- Email: `git log -5 --format=%ae` must show the noreply address; commit with `git -c user.email=<that address> commit`.
- End the message with the session's attribution lines.

Then present the Done report. Push only when the user says so.

## Managed mode (under /visor-pm)

When `/visor-pm` runs an item, the pipeline is split between the PM (main session) and a `visor-builder` agent in its own worktree. Everything else in this file still holds.

| Step | Builder | PM |
|---|---|---|
| 1 Plan, 1b mockup | writes the plan to `.pm/<epic>/plans/<id>.md`, records the baseline, publishes the mockup, then stops | records it in the backlog |
| 2 Approval | revises once if sent a rejection | spawns `visor-approver`, forwards the verdict |
| 3 Build, 4 Self review | on "approved, build" | waits |
| 5 Gate | starts the debug build when it holds the screen lock, replies with the pid | spawns reviewer, perf, security in one message |
| 6 Fix, 7 Prove | fixes, proves, relaunches release | holds the screen lock for one builder at a time |
| 7b QA | waits; on FAIL gets the findings, fixes, adds the "unit test" cases, proves again | spawns `visor-qa` (still holding the screen lock) with the item's Done-when, the worktree path and `.pm/<epic>/evidence/<id>/qa/`; forwards FAIL findings unchanged |
| 8 Verify, commit | commits on its worktree branch, not `main`; Done report max 150 words | merges into `main`, runs `scripts/check.sh` |

The builder never spawns agents, never merges and never pushes. Stop-list hits go to the PM, which asks the user.

## Done report

```
## Done: {title}  ({size}, commit {hash})

| # | Criterion | Evidence | Pass |
|---|---|---|---|
| D1 | ... | test `Suite/name` green / screenshot path / perf number | yes |
| A1 | Idle CPU <= baseline + 0.2% | 0.3% -> 0.4% | yes |

Gate findings
| Agent | Finding | Outcome |
|---|---|---|
| reviewer | file:line ... | fixed / skipped: reason |

QA: {PASS | FAIL then PASS} ({N} cases, {M} pass, {K} not run), evidence {path}
| QA finding | Outcome |
|---|---|
| 1. ... | fixed, unit test `Suite/name` added / skipped: reason |

Perf: CPU avg {before}% -> {after}%, max {before}% -> {after}%, memory {before} -> {after} MB
Mockup: {link} (picked: {option}; ask to switch)
Screenshot: {path}
Assumptions: {list}
Not pushed. Say "push" to push.
```

## Rules that always hold

- No em dashes anywhere. Fixtures use `acme.ghe.com`, `octocat`, `/Users/me`.
- Event-driven, off the main thread, idle CPU ~0%. Shared helpers over new copies.
- Balanced around the camera in every state.
- Debug socket only. Never `_decide` on the real socket.
