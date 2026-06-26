# HCF Hooks

This is the authoritative reference for HCF's hook system. HCF uses
**convention over configuration**: instead of a central registry, each agent
declares its own pipeline membership in its frontmatter. The work skills
(`plan-create`, `plan-orchestrate`) point here rather than duplicating this
logic.

The previous central registry (`pipeline.md`) is now **legacy**. See
[Legacy `pipeline.md`](#legacy-pipelinemd) below for how it is detected and
superseded.

## Hook Points

There are exactly **8** hook points. A hook point is a named moment in the
plan/implementation flow at which enrolled agents run.

| Hook                  | Fires                                                                  |
|-----------------------|------------------------------------------------------------------------|
| `pre-plan`            | Before `plan-create` Phase 1 (Discovery) begins                        |
| `post-plan`           | `plan-create` Phase 6, after dependency validation                     |
| `pre-implementation`  | `plan-orchestrate` after Step 2, before the first batch                |
| `pre-batch`           | Each loop iteration, before Step 5 (spawn workers)                     |
| `post-batch`          | Each loop iteration, after Step 6 (collect results)                    |
| `post-implementation` | `plan-orchestrate` Step 4a, when all tasks are complete                |
| `pre-commit`          | Step 4a, after the full test suite passes, before the commit          |
| `post-commit`         | Step 4a, after the commit, before the push/PR prompt                   |

### Why there is no `execution` hook

There is deliberately **no** `execution` hook. In HCF, executing a plan **is**
the implementation loop — the Step 3 → 5 → 6 → 8 batch cycle in
`plan-orchestrate`. An `execution` hook would fire over that same span already
covered by the `*-implementation` and `*-batch` hooks (`pre-implementation`,
`pre-batch`, `post-batch`, `post-implementation`), so it would only duplicate
what those hooks express. Use those instead.

## Frontmatter Schema

An agent enrolls itself in a hook by adding these keys to its YAML frontmatter,
alongside the existing `name` / `description` / `model` / `tools` keys.

```yaml
---
name: devils-advocate
description: "..."
model: opus
tools: Read, Write, Edit, Glob, Grep
# --- hook enrollment ---
phase: post-plan   # enrolls this agent at the named hook point
order: 100         # integer; lower runs first; default 100
mode: single       # "single" | "batch"; default "single"
---
```

| Key     | Type    | Default    | Meaning                                                                                  |
|---------|---------|------------|------------------------------------------------------------------------------------------|
| `phase` | string  | (none)     | The hook point that enrolls this agent. Must be one of the 8 hooks above.                |
| `order` | integer | `100`      | Run order within a hook. Lower runs first. Equal values tie-break by `name`.            |
| `mode`  | enum    | `single`   | How the agent is spawned: `single` (one subagent for the whole plan) or `batch` (files are split into batches of ~10 and spawned as parallel subagents). |

### The enrollment rule

**If an agent declares a `phase`, it runs.** There is no conditional
evaluation. HCF intentionally has **no** `requires:` or `condition:` mechanism —
a declared `phase` is an unconditional enrollment. To stop an agent from
running at a hook, remove its `phase` key (or delete/override the agent); do not
look for a condition to toggle.

An agent with **no** `phase` key is simply not enrolled in any hook (e.g.
`tdd-worker`, which the orchestrator spawns directly, never via a hook).

## Discovery Routine

This is the deterministic, stepwise routine a skill follows to resolve which
agents run at a given hook. Follow it literally; do not improvise.

Let `HOOK` be the hook point being run (one of the 8 above).

1. **Glob local agents.** List `.claude/agents/*.md` in the current project.
2. **Glob plugin agents.** List `*.md` in the plugin's `agents/` directory
   (see [Resolving the plugin `agents/` directory](#resolving-the-plugin-agents-directory)).
3. **Merge with local override.** Build one set of agents keyed by their
   frontmatter `name`. A local `.claude/agents` file **OVERRIDES** a plugin
   agent with the same `name` — the local file wins entirely; the plugin
   version of that name is discarded (no field-level merge). Plugin agents whose
   `name` is not shadowed locally are kept.
4. **Validate phases.** For each merged agent that declares a `phase`: if its
   `phase` value is **not** one of the 8 known hooks, **ignore** that agent
   (it never runs) and **print a warning** naming the agent and its unknown
   phase. Do not let an unknown phase match any hook.
5. **Filter to this hook.** Keep only agents whose validated frontmatter
   `phase` equals `HOOK`.
6. **Empty check.** If the filtered set is empty, this is an **empty hook** —
   return immediately. See [Empty-hook fast path](#empty-hook-fast-path).
7. **Sort.** Sort the filtered agents by `order` ascending (a missing `order`
   is treated as `100`), then by `name` for ties. See
   [Sort and tie-break](#sort-and-tie-break).
8. **Print the resolved order.** Before running anything, **PRINT** the
   resolved, sorted list of agents (name, order, mode) for this hook so the run
   is auditable.
9. **Spawn.** Spawn each agent in the sorted order according to its `mode`:
   - `single` → one subagent for the whole plan.
   - `batch` → split the relevant file list into batches of ~10 and spawn
     parallel subagents (one Task call per batch, all in a single message).

### Resolving the plugin `agents/` directory

Resolve the plugin's `agents/` directory **concretely** from the running
skill's own file path. A skill lives at `skills/{name}/SKILL.md` inside the
plugin, so the plugin root is **two levels up** from the skill file, and the
agents directory is `{plugin-root}/agents/`. (This matches the convention used
by `project-update`, which resolves the plugin dir as "two levels up from this
skill file.")

If the plugin `agents/` directory **cannot be resolved** from the skill path,
fall back to using `.claude/agents` **only** (skip the plugin agents in steps 2
and 3, and proceed with whatever local agents exist).

### Empty-hook fast path

A hook is **empty** when, after the local-overrides-plugin merge and the
filter-to-this-hook step, **zero** agents have a `phase` equal to this hook.

When a hook is empty:
- **Return immediately.**
- Perform **no logging and no narration.** This means more than suppressing the
  resolved-order line: do **not** explain the empty result either. Do not state
  which agents declared no `phase`, do not name the hook, do not say it is empty
  or being skipped, and do not describe the enrollment analysis you just did.
  The entire discovery routine for an empty hook is **silent and internal** —
  nothing about it reaches the user-visible output.
- Do **no work** — no staging, no diffing, no subagent spawns.

This keeps unused hooks free of overhead and noise. The common failure mode is
"thinking out loud" — narrating *why* a hook is empty (e.g. "standards-enforcer
and tdd-worker declare no phase, so this hook is a no-op"). That narration is
exactly what the fast path forbids: an empty hook is invisible, full stop. Only
a **non-empty** hook produces visible output (its printed resolved order).

### Sort and tie-break

Order is fully deterministic:

1. Sort by `order`, ascending (integer). A **missing** `order` is treated as
   `100`.
2. For agents with **equal** `order`, tie-break by `name`, **case-insensitive,
   ascending** (A before B). For example, `Apple` and `banana` with the same
   `order` sort as `Apple`, `banana`.

## Legacy `pipeline.md`

HCF no longer reads `pipeline.md` as configuration; frontmatter enrollment is
always authoritative. A leftover `.claude/pipeline.md` is flagged by the
`SessionStart` hook (`hooks/detect-legacy-pipeline.sh`) and, more importantly,
**blocks the planning workflow**: `PreToolUse` (`gate-skill.sh`) and
`UserPromptExpansion` (`gate-command.sh`) deny `plan-create`/`plan-orchestrate`
while the file exists, regardless of how they are invoked. `/project-update` is
left runnable — it is the only component that migrates or deletes the file, and
once it does, the gates open automatically.
