# Visor workflow

How a request becomes a pushed commit. You decide; agents do the work. `CLAUDE.md` has the hard rules.

## Skills

| Skill | Use for |
|---|---|
| `/visor-dev <request>` | One change, end to end. |
| `/visor-pm <request>` | Anything bigger: splits it into items and runs each one like `/visor-dev`, with agents. |
| `/visor-release <version>` | Shipping a version. Stops twice for you: review, then ship. |

## The flow

```mermaid
flowchart TD
  subgraph START["1. Start"]
    R["Your request"] --> A["Analyst: scope, risks, suggested items"]
    A --> BL["PM: backlog with items, done-when, budget"]
    BL --> QR{"You: questions, only if they change the result"}
  end

  subgraph ITEM["2. Each item, in its own git worktree"]
    WT["PM: new worktree and branch"] --> PL["Builder: plan and done-when"]
    PL --> MK["Builder: mockup on the mockup page, if you will see it"]
    MK --> AP{"Approver: plan OK?"}
    AP -- "no, first time" --> RV["Builder: apply the fixes"] --> AP
    AP -- "no, second time" --> SP["PM: split the item, or park it"]
    AP -- "stop-list item" --> SL{"You: decide"}
    AP -- "yes" --> BT["Builder: failing tests first, then code until green"]
    BT --> CK["Builder: check.sh, reads its own diff"]
    CK --> GT["Gate, in parallel: reviewer, perf, security if hooks, sockets or secrets"]
    GT --> FX["Builder: checks each finding, fixes"]
    FX --> PV["Builder: proves it in the debug app, screenshots"]
    PV --> QA{"QA: own test cases, tries to break it"}
    QA -- "fail, first time" --> QF["Builder: fix, add unit tests, prove again"] --> QA
    QA -- "fail, second time" --> QY{"You: fix, accept or park"}
    QA -- "pass" --> CM["Builder: commit on the item branch"]
  end

  subgraph FINISH["3. Finish"]
    MG["PM: rebase and merge into main, check.sh, all tests"] --> EQ{"Epic QA: whole feature on main"}
    EQ -- "fail" --> NI["PM: new fix item"]
    EQ -- "pass" --> RP["PM: report page with evidence"]
    RP --> PU{"You: push?"}
    PU -- "yes" --> DN["Pushed to GitHub"]
  end

  QR --> WT
  SP -. "still stuck" .-> ST{"You: decide"}
  CM --> MG
  NI --> WT

  classDef you fill:#fde68a,stroke:#b45309,color:#1f1300
  class QR,SL,QY,ST,PU you
```

Yellow boxes are the only places you are asked. A plan gets two tries with the approver and a build gets two tries with QA; after that the item is split, parked or brought to you. Items that only change logic (nothing to see) skip their own QA; the epic QA covers them. Small items skip the approver and the gate.

## Who does what

| Agent | Job | Sees |
|---|---|---|
| visor-analyst | Breaks a request into items | The request |
| visor-builder | Plans, codes and proves one item in its own git worktree | The item and its plan |
| visor-approver | Accepts or rejects a plan | The request and the plan |
| visor-reviewer | Finds bugs in the diff | The diff and the rules |
| visor-perf | Checks CPU and memory | The diff and the running debug app |
| visor-qa | Tests the app like you would and tries to break it | Only the request and what "done" means, never the code |

All agents except the builder are read-only. Only the main session starts agents, merges and pushes.

## When you are asked

- Anything on the stop list: releases, deleting or migrating your data, approval or hook behaviour, plugin security, CLAUDE.md rules, new dependencies, anything outside the repo.
- An item still stuck after two tries and a split.
- The final report: push or not.

Nothing is pushed without your OK.

## Ground rules

- Tests first; logic lives in VisorCore.
- Idle CPU stays near 0%.
- Anything beside the notch is balanced around the camera.
- Testing uses the debug app and its own socket only, never the real one.
- Agents that use the screen (proof and QA) take turns.
- Commits use the author set in the repo's git config.
- Epic state lives in `.pm/` on one laptop (not in git).

## Files

- Skills: `.claude/skills/visor-dev`, `visor-pm`, `visor-release`
- Agents: `.claude/agents/visor-*.md`
- Epic state: `.pm/<epic>/` (backlog, plans, evidence, report)
