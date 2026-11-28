# Epic: {title}

Saved as `.pm/{epic}/backlog.md` in the repo (gitignored). The PM updates it on every status change and re-reads it instead of keeping history.

## Request

> {request, verbatim}

## Done when (epic)

| # | Criterion | User's words | Proven by (item evidence) | Status |
|---|---|---|---|---|
| E1 | {observable result} | "{phrase from the request}" | {item id + test name / screenshot / perf number} | open \| proven |

Every phrase of the request has a criterion. An unproven criterion at the end becomes a new item.

## Out of scope

- {what this epic will not do, and why}

## Assumptions

- {open question} resolved to {narrower, safer reading}.
- Mockup picks: {item id}: option {X} ({link}).

## Budget

Units: S 1, M 4, L 8 (1 unit is about 50k subagent tokens).
Estimate: {n} units ({tokens}). Pause and ask before {estimate x 1.25}.
Used: {tokens} so far (sum of the Tokens column plus the PM's analyst and gate agents).

## Locks

screen: {free | item id}

## Items

Status: todo, planning, approved, building, gating, proving, qa, done, parked, blocked.

| Id | Title | Size | Depends on | Files (expected) | Status | Branch / worktree | Evidence | Tokens |
|---|---|---|---|---|---|---|---|---|
| I1 | {title} | S\|M\|L | - | `Sources/VisorCore/X.swift`, `Tests/VisorCoreTests/XTests.swift` | todo | {branch} `{worktree path}` | `.pm/{epic}/evidence/I1/` | 0 |

## Log

One line per event that changes a decision (rejection, re-split, park, user answer). No progress chatter.

- {date} I1: {event}
