# Plan: {title}

Saved as `plans/{slug}.md` in the session scratchpad, never in the repo.

## Request

> {request, verbatim}

## Goal

{One sentence, from the user's point of view.}

## Size

{S | M | L} - {why}. Gate: {none | Review + Perf | Review + Perf + Security}. Security gate: {on | off} because {hooks, sockets, plugins, network, keychain or clipboard touched or not}.

## Done when

| # | Criterion | Request phrase | Verify by |
|---|---|---|---|
| D1 | {observable result} | "{phrase from the request}" | {named test `Suite/testName` \| check.sh rule \| proof step N + screenshot \| perf limit} |
| D2 | ... | ... | ... |

Never "looks good". Every criterion traces to a request phrase, every request phrase has a criterion.

## Auto criteria (always added)

| # | Criterion | Verify by |
|---|---|---|
| A1 | Idle CPU <= baseline + 0.2% (baseline {x}%) | `scripts/perf.sh -n 10` before and after |
| A2 | No check hits, all tests pass | `scripts/check.sh` exit 0 |
| A3 | {UI only} Balanced around the camera: same inset both sides, header slots equal per CLAUDE.md | proof screenshot, measured left vs right |
| A4 | {hooks only} Proof uses `hook-debug.sock` only, never `hook.sock` | proof script review + check.sh rule |

## Out of scope

- {what this change will not do, and why}

## Files in order

From the `docs/architecture.md` recipe "{recipe name}". VisorCore first.

1. `Tests/VisorCoreTests/{X}Tests.swift` - {new tests}
2. `Sources/VisorCore/{X}.swift` - {logic}
3. `Sources/Visor/{Folder}/{File}.swift` - {wiring}
4. `CLAUDE.md` / `docs/architecture.md` - {only if a flow or debug message changed}

## Tests first

| Test | Asserts |
|---|---|
| `{Suite}/{sentenceName}` | {exact expectation} |

## Proof script

Debug build, `VISOR_NO_MUSIC=1 .build/debug/Visor`, socket `~/Library/Application Support/Visor/hook-debug.sock`.

1. `printf '%s\n' '{json}' | nc -U "$HOME/Library/Application Support/Visor/hook-debug.sock"`
2. `screencapture -x -R {x,y,w,h} {scratchpad}/proof-{n}.png` - shows {what}
3. ...

## Risks and assumptions

- Assumption: {open question} resolved to {narrower, safer reading}.
- Risk: {what could break} - {how the plan covers it}.

## Approval

{Approver verdict appended here.}
