# PR Session Ref — Name the Conversation That Produced the PR

Every PR **must** carry a `## Ref` section naming the agent session that produced it.

```markdown
## Ref
Ithbat IAM v0.2 | Orchestrator
```

## Why

This portfolio runs many concurrent Claude Code sessions — Orchestrator, QA, Security, SSO, Branding, SDK, Marketing, Head of Engineering — often on the same repos, sometimes on adjacent files, occasionally on the same subsystem without knowing it. A merged PR currently records *what* changed and *which ticket*, but not *who was driving*. When something needs following up, there is no way back to the reasoning.

That gap has a measurable cost. On 2026-07-30 two sessions independently claimed migration version `000078`, landing a duplicate on `main` that stopped golang-migrate running in every environment until it was renumbered (ITH-347). Neither PR named its session, so working out who to talk to meant reading commit authorship — which is identical for all of them, because every session commits as the same git identity.

The `Ref` line makes that one line of the PR body instead of an investigation.

## What to write

The session name as it appears in the session list — the same string a peer would use to message you. Examples:

```
## Ref
Ithbat IAM v0.2 | Security
```

```
## Ref
Ithbat IAM v0.2 | Head of Engineering
```

Add a short qualifier when the session name alone is ambiguous — a long-running session that has moved through several distinct pieces of work, or a re-launched session with the same name as an earlier one:

```
## Ref
Ithbat IAM v0.2 | Orchestrator — promo/discount cluster (ITH-336/337)
```

If a human authored the PR rather than an agent, say so plainly:

```
## Ref
Human (CEO) — direct commit, no agent session
```

## Enforcement

`validate-pr-create.sh` blocks `gh pr create` when a required section is missing, exactly as it already does for `## Testing` and `## Glossary`. `Ref` is added to `.pr.required_sections` in `.claude/project-config.json`.

**The hook checks presence, not content.** No environment variable exposes a session's human-readable name — `CLAUDE_CODE_SESSION_ID` is a UUID and nothing maps it back to "Ithbat IAM v0.2 | Orchestrator". So the value is supplied by the agent from what it knows about itself, and the hook can only confirm the section exists. An agent that writes a wrong or vague `Ref` passes the gate. That is a real limit, and it is why this is a rule rather than only a check.

The existing `<!-- pr-sections: skip -->` marker bypasses all required sections including this one, with a visible warning. Use it for genuine exceptions, not convenience.

## Fork-local, and why

This is a **fork override**, not upstream apexyard behaviour. It lives in `.claude/project-config.json` — a file upstream does not ship — so it costs nothing on an upstream sync. That is deliberate: this fork's last sync resolved 179 conflicts, 49 of them real fork customizations, and the aim is to add capability without adding to that number.

It is worth proposing upstream via `/request-apexyard-feature`. Multi-session portfolios are the framework's own model, and the traceability gap is not specific to Ithbat.

---

*Fork-local rule for the Ithbat IAM ops fork. Not part of upstream [ApexYard](https://github.com/me2resh/apexyard).*
