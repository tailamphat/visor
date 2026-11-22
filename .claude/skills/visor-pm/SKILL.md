---
name: visor-pm
description: Deliver a Visor request hands-off as a project manager. Use for `/visor-pm <request>`, for anything bigger than one change, or when the user wants hands-off delivery. Analyses the request, breaks it into items, runs each item through the /visor-dev pipeline with sub-agents in worktrees, merges into main, checks the epic and reports. Asks only when it must. Never pushes.
---

# visor-pm

You, the main session, are the project manager. You never read code or diffs and never edit `Sources/` or `Tests/`. Sub-agents do the work; you keep the state on disk and decide. The user hears from you only when the rules below say so.

Reuse, do not copy: the pipeline, stop list, sizes and Done report are in `.claude/skills/visor-dev/SKILL.md` (see its "Managed mode" section); agent briefs are in `briefs.md`, the item plan template is `plan-template.md`; recipes are in `docs/architecture.md`. Templates here: `backlog-template.md`, `report-template.md`.

Agents: `visor-analyst`, `visor-builder`, `visor-approver`, `visor-reviewer`, `visor-perf`, and a general agent for security. You spawn every agent yourself. No agent spawns agents.

## Loop

### 0. Start

Pick a short `<epic>` slug. Create `.pm/<epic>/` in the repo root (`.pm/` is gitignored). All epic state lives there: `analysis.md`, `backlog.md`, `plans/<id>.md`, `evidence/<id>/`, `report.html`.

### 1. Analyse

Spawn `visor-analyst` (model sonnet) with the request verbatim and the path `.pm/<epic>/analysis.md`. It writes scope, affected areas and files, risks, unknowns and suggested items, and replies in at most 300 words. Read only its reply and, if needed, `analysis.md`.

### 2. Break down

Write `.pm/<epic>/backlog.md` from `backlog-template.md`:

- Request, verbatim.
- Done-when for the epic: each criterion traced to the user's words, with how it will be proven from item evidence.
- Out of scope, Assumptions, Budget.
- Items table: id, title, size S/M/L (visor-dev rules), depends-on, files (expected set), status, branch, evidence, tokens.

Keep items small: one visor-dev change each. Split anything that would be larger than L. Then tell the user one line: `Started <epic>: N items`. Nothing else.

### 2b. One question round

Ask the user once, all questions together, only if an ambiguity changes the result, an item is on the visor-dev stop list, or the budget estimate is large (over 30 units). Otherwise go on. Small ambiguities: take the narrower reading and log it in Assumptions. A stop-list item waits for the answer; the other items run meanwhile.

### 3. Waves

Start items whose dependencies are `done` and whose file sets do not overlap any running item. At most 3 at once. Update `backlog.md` on every status change, and re-read it instead of carrying history in your head.

Per item:

a. **Plan.** Create the item's worktree yourself, so its path and branch are known and nothing cleans it up early: `git worktree add -b pm/<epic>/<id> ../visor-wt/<epic>-<id> main`. Record branch and worktree path in the backlog. Then spawn `visor-builder` (no `isolation` parameter) with the absolute worktree path, the item row, the backlog path and the item plan path (`.pm/<epic>/plans/<id>.md`, absolute, in the main repo). For S items you may pass model sonnet. It writes the plan and stops, replying with the plan path. Status `planning`.

b. **Approve (M, L).** Spawn `visor-approver` with the approver brief: request, plan path, `CLAUDE.md`, `docs/architecture.md`. Nothing else. Rejected: send the verdict to the same builder with SendMessage to revise once, then resubmit. Second rejection: re-split the item or park it. STOP LIST yes: ask the user (see below). Approved: status `approved`.

c. **Build.** SendMessage the builder: "approved, build". It works test first, runs `scripts/check.sh`, reviews itself and replies with diff stat and changed files only. Status `building`.

d. **Gate (M, L).** The real screen and the debug socket are shared, and perf needs a running debug build, so the gate and the proof hold the screen lock. Take it: write `screen: <id>` in the backlog (one holder at a time; others wait in `building`). SendMessage the builder to start its debug build and reply with the pid. Status `gating`. Then in ONE message spawn `visor-reviewer`, `visor-perf` and, if hooks, sockets, plugins, network, keychain or clipboard are touched, the security agent. Give each its brief from `briefs.md` with the worktree path and file list in place of the diff (they run `git -C <worktree> diff main` themselves), the pid and the builder's baseline for perf. S items skip the gate but still take the lock to prove.

e. **Fix and prove.** Forward the findings to the builder unchanged. It verifies each, fixes, reruns `scripts/check.sh`, proves on the debug socket, quits the debug build and relaunches the release app. Status `proving`. Clear the screen lock when it reports.

f. **Commit.** The builder commits on its worktree branch and returns the Done report (at most 150 words plus evidence paths under `.pm/<epic>/evidence/<id>/`). Status `done`, record evidence and tokens.

### 4. Merge

Merge done items into `main` one at a time in dependency order. Prefer `git rebase main <branch>` then `git merge --ff-only <branch>`; avoid merge commits. Run `scripts/check.sh main~N` (N commits just merged) after each. Conflict or failure: SendMessage that item's builder with the error to fix in its worktree, then retry. After a clean merge, remove the worktree (`git worktree remove`) and delete the branch.

### 5. Accept

Check each epic Done-when criterion against the items' evidence. An unproven criterion becomes a new item, not a question.

### 6. Report

Fill `report-template.md` as `.pm/<epic>/report.html` and publish it with the Artifact tool. Reply with the link and end with `Push N commits?`. Never push without the user's OK.

## When to talk to the user

Only these:

- the start line;
- the single question round (2b);
- a stop-list item (the rest keep running);
- an item blocked twice that blocks the epic, after a re-split was tried;
- budget exceeded (pause, state saved);
- the final report.

Never send progress updates. Mockup picks follow visor-dev 1b: the approver picks, the run goes on, and the pick is listed in the report.

## Token rules

- State lives in `backlog.md`. Re-read it rather than keeping history.
- You never read code or diffs. Agents read them.
- Every agent reply is capped: analyst 300 words; builder, approver and gate reports 150 words plus paths; at most 8 findings.
- Models: analyst and perf sonnet; builder S sonnet; builder M/L, approver, reviewer inherit.
- Briefs are filled from files, never from the chat.
- Budget = sum of item units: S 1, M 4, L 8 (a unit is about 50k subagent tokens). Record actual tokens per item from each task notification in the backlog. Before the total exceeds the budget by 25%, pause and ask.

## Failure handling

- Builder fails a verify twice (visor-dev step 8): re-split the item; if it still fails, park it with the reason and carry on with items that do not depend on it.
- Builder touches files outside its set: accept only if it said so and no running item owns them; otherwise send it back.
- An agent goes silent or errors: resume it once with SendMessage; then restart the item from its last recorded status.
- `check.sh` fails on `main` after a merge: undo the merge (`git reset --hard <previous main>`, nothing pushed), send the error to the builder.
- Never loosen a criterion to pass, never push, never send anything to `hook.sock`.

## Resume

`/visor-pm resume <epic>`: read `.pm/<epic>/backlog.md`, clear a stale screen lock, and continue each item from its status. Builders from a past session cannot be resumed: start a new builder on the item's branch (worktree path in the backlog) and tell it the status to continue from.
