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

Hook resolution is performed by **`hooks/discover-hooks.sh`**, which ships with
the plugin. Callers run it and read its output. **Never enumerate agent files by
hand, and never write a glob loop to do it** — that is exactly the failure this
script exists to eliminate ([#4](https://github.com/markshust/hcf/issues/4)):
the routine used to be prose, every session improvised its own bash, one of
those scripts had a syntax error, and the partial output was consumed as a
complete enumeration. Every hook silently resolved empty.

Let `HOOK` be the hook point being run (one of the 8 above).

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --hook=<HOOK>
```

`{skill-base-dir}` is the **`Base directory for this skill`** value stated when
the skill loads. It is given verbatim, so no path inference is involved.
`${CLAUDE_PLUGIN_ROOT}` is **not** available here — it resolves only for
`hooks.json` entries, not for a skill's own Bash calls.

Then, based on the result:

| Exit | stdout | Meaning | What the caller does |
|------|--------|---------|----------------------|
| `0` | non-empty | Agents are enrolled | **Print the output verbatim** (this is the auditable resolved order), then spawn each agent in the listed order per its `mode` |
| `0` | **empty** | Empty hook | [Empty-hook fast path](#empty-hook-fast-path) — return silently |
| `1` | — | Runtime error; the plugin `agents/` dir is unresolvable | **Stop.** Surface stderr verbatim |
| `2` | — | Bad arguments, including a malformed `--expect` value | **Stop.** Surface stderr verbatim |
| `3` | — | An agent file declares an invalid `phase` or `mode` | **Stop.** Surface stderr verbatim |
| `4` | — | Enrollment changed mid-run ([drift](#drift-detection)) | **Stop.** Surface stderr verbatim |

**Only exit 0 with empty stdout is an empty hook.** Any non-zero exit is an
error to report loudly, never a hook to skip silently. Conflating the two is
what made the original bug invisible for so long.

**If the script is missing or not executable, that is a hard failure.** Say so
and stop. There is no prose fallback — falling back to hand-enumeration would
reintroduce improvised bash at exactly the moment the script is unavailable.

Spawn modes: `single` → one subagent for the whole plan. `batch` → split the
relevant file list into batches of ~10 and spawn parallel subagents (one Task
call per batch, all in a single message). The mode comes from the agent's
`mode` field, never from reading its body.

### What the script does (specification)

This is the contract `hooks/discover-hooks.sh` implements. It is here so the
behavior is reviewable — not as steps for anyone to perform by hand.

1. **Enumerate plugin agents.** Top-level `*.md` in the plugin's `agents/`
   directory, which the script resolves from its own location
   (`$(dirname "$0")/../agents`). Not recursive.
2. **Enumerate local agents.** Top-level `*.md` in
   `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/agents`. A missing directory is normal,
   not an error — most projects have none.
3. **Parse frontmatter.** `name`, `phase`, `order`, `mode` from the **first**
   `---` block only, anchored at start-of-line. A commented `# phase:` key is
   **not** enrollment (this is what keeps `standards-enforcer` dormant). Quoted
   values are unquoted; a trailing ` # …` comment is stripped from unquoted
   values, so the [example above](#frontmatter-schema) parses as written; CRLF
   files are handled. A file with no `phase` is simply not enrolled.
4. **Merge with local override,** keyed on the frontmatter `name` — *not* the
   filename. A local file **overrides** a plugin agent of the same `name`
   entirely; there is no field-level merge. Duplicate names within one directory
   warn and resolve last-wins.
5. **Validate — fatally.** A `phase` outside the 8 hooks, or a `mode` other than
   `single`/`batch`, **aborts with exit 3**, naming every offending file and the
   fix. Validation is **global**: a bad value in a `post-commit` agent aborts a
   `pre-plan` query, so the problem surfaces at the earliest moment rather than
   hours later. A non-numeric `order` is milder — it warns and falls back to
   `100`.
6. **Filter** to `HOOK` when `--hook` is given.
7. **Sort** by `order` ascending (missing = `100`), then `name`
   case-insensitively. See [Sort and tie-break](#sort-and-tie-break).

Other flags: `--json` for machine-readable output, `--fingerprint` /
`--expect=` for [drift detection](#drift-detection), `--help` for usage. Run it
with no `--hook` for a by-hand debugging view of all 8 hooks — that is the
fastest answer to "why didn't my agent fire?".

### Drift detection

Enrollment must not change partway through a run, or the back half of an
orchestration executes a different pipeline than the plan was built against.

`--fingerprint` prints a stable digest of the fully-resolved enrollment across
**all 8 hooks**:

```
discover-hooks-fingerprint-v1 <64-hex>
```

`plan-create` writes this to `.claude/plans/{plan-name}/.hook-fingerprint`, and
`plan-orchestrate` passes it back as `--expect=<value>` on every hook call. If
enrollment changed, the script exits **4** and names what changed; HCF halts.

The hash covers each agent's origin (`plugin` or `local`), `name`, `phase`,
`order`, and `mode` — never paths, mtimes, or sizes, so it is stable across
machines and reinstalls. Including origin matters: without it, shadowing a
plugin agent with a local file carrying identical enrollment keys but entirely
different instructions would be a silent agent swap.

**Agent body content is deliberately not hashed.** Editing an agent's prose,
description, or `tools` list is *not* drift. Hashing bodies would fire on every
typo fix and on any plugin upgrade touching prose, which would make the
mechanism unusable. Drift detection answers "did the pipeline change?", not
"did this agent change?".

**Self-inflicted drift.** A plan whose own subject matter is agent files will
legitimately change enrollment mid-run and halt itself. That is correct, but
surprising — the escape hatch is to delete `.hook-fingerprint` and re-run to
re-baseline, which the exit-4 message says. Nothing else HCF does mid-run
touches `agents/` or `.claude/agents/`.

### Resolving the plugin `agents/` directory

The script self-locates: its `agents/` directory is always
`$(dirname "$0")/../agents`, so it must stay in the plugin's `hooks/` directory
alongside `agents/`. If that directory cannot be found the script **exits 1**
rather than proceeding with local agents only — silently dropping the plugin's
own bundled agents is precisely the failure mode being fixed.

(`project-update` separately resolves the plugin directory as "two levels up
from this skill file" for its legacy-migration path. That convention still
applies there and is unrelated to discovery.)

### Empty-hook fast path

A hook is **empty** when `discover-hooks.sh --hook=<HOOK>` exits **0** with
**empty stdout**. A non-zero exit is *not* an empty hook — see the table above.

When a hook is empty:
- **Return immediately.**
- Perform **no logging and no narration.** This means more than suppressing the
  resolved-order line: do **not** explain the empty result either. Do not state
  which agents declared no `phase`, do not name the hook, do not say it is empty
  or being skipped, and do not describe the enrollment analysis you just did.
  The entire discovery routine for an empty hook is **silent and internal** —
  nothing about it reaches the user-visible output.
- Do **no work** — no staging, no diffing, no subagent spawns.
- Do **not narrate the script call either.** A filtered query on an empty hook
  prints zero bytes precisely so there is nothing to echo. Do not say "the
  discovery script returned no agents" — that is the same narration wearing a
  different hat.

This keeps unused hooks free of overhead and noise. The common failure mode is
"thinking out loud" — narrating *why* a hook is empty (e.g. "standards-enforcer
and tdd-worker declare no phase, so this hook is a no-op"). That narration is
exactly what the fast path forbids: an empty hook is invisible, full stop. Only
a **non-empty** hook produces visible output (its printed resolved order).

The script itself is louder than its callers on purpose: run with **no**
`--hook`, it prints an explicit `(empty — …)` marker for every unenrolled hook,
because that mode exists for a human debugging by hand. The silence rule governs
what *skills* emit, not what the script can tell you when you ask it directly.

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
