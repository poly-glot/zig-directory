---
name: review
description: Review the current branch's diff against the base for this repo (Zig backend + Deno/Fresh web). Runs the scoped gate, then delegates to the read-only code-reviewer agent (rules sweep + rewrite parity check + five-axis lens). Invoke with /review.
---

# Code Review orchestrator

`/review` is a **thin dispatcher**: do the cheap setup, then hand the expensive read-everything work to the `code-reviewer` agent so the diff and rules sweep don't flood this session. Don't do review work here.

## Step 1: Determine subject

- `git rev-parse --abbrev-ref HEAD` gives the current branch.
- The base is `git merge-base HEAD main`, falling back to `master`. If the working tree has uncommitted changes, note that the review covers committed branch work, and offer to include the working tree.

## Step 2: Run the gate first

Run the scoped checks so the reviewer isn't reviewing broken code:

- if any `src/**/*.zig` or `build.zig` changed in range: `zig build test`
- if any `web/**` source changed: `cd web && deno task check`

Report failures up front; a red gate is itself a Request-changes.

## Step 3: Spawn the agent

```
Agent({ subagent_type: "code-reviewer", description: "<branch> review",
  prompt: "Review the current branch <branch> against <base> (read-only). Apply the .claude/rules sweep, the rewrite parity check, and the five-axis lens per your agent definition." })
```

Run it in the foreground; the user is waiting on the verdict.

## Step 4: Relay

The agent's report is the source of truth. Lead with the verdict, then the findings by severity. Don't invent findings here. If the agent missed something obvious, update `.claude/rules/` so the next run catches it, rather than patch it inline.

## Why a skill and an agent

- **Skill = trigger.** `/review` is the entry point, and slash commands must be skills.
- **Agent = isolated worker.** Reading the whole diff and every rule dumps tens of thousands of tokens; the agent keeps that out of the main context and stays read-only.
