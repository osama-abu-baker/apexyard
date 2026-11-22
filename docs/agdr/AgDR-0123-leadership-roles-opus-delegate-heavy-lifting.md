# AgDR-0123 — Leadership and review roles on Opus, heavy lifting delegated to Haiku and Sonnet

**Status**: Accepted · **Category**: agents / cost · **Amends**: AgDR-0050 (model matrix, four Heads) · **Related**: AgDR-0074, AgDR-0056

> In the context of the per-agent model matrix (AgDR-0050) and the observed cost of Opus doing bulk reading and writing (AgDR-0074), facing a CEO directive that execution must run on cheaper tiers while judgement stays on Opus, I decided to **put every leadership and review role on Opus but forbid it from doing heavy reading or writing itself — the orchestrator runs Haiku to read, Sonnet to build, and the Opus role reviews the Sonnet output against its own bar** — to achieve Opus-quality decisions at Sonnet/Haiku execution cost, accepting that the pipeline must be driven by the orchestrator because a sub-agent cannot spawn sub-agents.

## Context

- AgDR-0050's matrix put Tech Lead, SRE, Head of Engineering and the reviewers on Opus, but the other Heads (Product, Design, Security, Data) on Sonnet.
- AgDR-0074 found the main thread dominates spend because Opus does the bulk work in-thread.
- CEO directive (2026-11-22, ITH-611): subagents doing execution run on Sonnet or Haiku; Opus is for planning, reviewing and orchestrating. All Heads, the Tech Lead and SRE stay on Opus but must not do heavy lifting.
- Platform constraint: a sub-agent has no Agent tool, so an Opus role spawned as a sub-agent cannot itself dispatch Haiku/Sonnet workers.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Keep AgDR-0050 matrix as is | No change | Four Heads plan on Sonnet; Opus roles still read and write in bulk |
| B. Everything on Sonnet except the main session | Cheapest | Loses Opus judgement in reviews and strategic calls |
| C. Leadership/review roles on Opus + a delegation rule; orchestrator runs Haiku → Sonnet → Opus review (chosen) | Opus where judgement matters, cheap tiers for volume; works within the no-nesting constraint | Relies on the orchestrator to run the pipeline; the rule in the agent file is self-discipline |

## Decision

Chosen: **C**.

- `model: opus` on Head of Product, Design, Security, Data (Engineering, Tech Lead, SRE already Opus). Review agents (Rex, Hakim, Tariq, Contrarian, Pen Tester) unchanged on Opus.
- Each leadership agent carries a "Delegation" section: plan and review only; small targeted reads to verify a claim are fine; bulk reading and writing go through the orchestrator's Haiku → Sonnet pipeline, and the Opus role reviews the result ("is it at the level I would have produced?").
- Agents with no `model:` default to Sonnet via `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in the operator's user settings (operator-level, outside this repo).

## Consequences

- Execution volume moves to Haiku and Sonnet; Opus is spent on plans and verdicts.
- The orchestrator (main session or a Workflow) owns the pipeline; an Opus role's output is a plan or a verdict, not a large artifact.
- The delegation rule is self-discipline inside the agent prompt; there is no hook at the spawn boundary (same limit as AgDR-0056 / agent-role-selection).
- Supersedes AgDR-0050's Sonnet assignment for the four Heads only.

## Artifacts

- ITH-611
- `.claude/agents/head-of-{product,design,security,data,engineering}.md`, `tech-lead.md`, `sre.md`
