# Report: {epic title}

Publish as `.pm/{epic}/report.html` with the Artifact tool (follow its page rules: a short title, light and dark tokens, phone width). One page. Fill every section; write "none" rather than dropping one.

## What was built

{Two or three sentences from the user's point of view.}

## Epic criteria

| # | Criterion | Evidence | Pass |
|---|---|---|---|
| E1 | ... | item I2, test `Suite/name` green; screenshot `.pm/{epic}/evidence/I2/proof-1.png` | yes |

## Items

| Id | Title | Size | Commit | Summary (one line) | Gate findings fixed / skipped |
|---|---|---|---|---|---|
| I1 | ... | M | `{hash}` | ... | 2 / 1 |

## Screenshots

- `{absolute path}`: {what it shows}

## Decisions made for you

- Assumptions: {from the backlog}
- Mockup picks: {item}: option {X}, {mockup link}. Ask to switch.

## Parked

- {item}: {why}, {what would unblock it} | none

## Tokens

Used {tokens} of a {budget} budget ({percent}%). Per item in the backlog.

## Commits on main (not pushed)

```
{git log --oneline main ^origin/main}
```

**Push {N} commits?**
