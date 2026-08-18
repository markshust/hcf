---
name: plan-orchestrate
description: Execute implementation plans with parallel TDD workers. Use when ready to run, execute, or start a plan. Triggers on "run the plan", "execute the plan", "implement the plan", "start the plan", "start implementation", "orchestrate", "begin autonomous execution". Requires a plan created by plan-create.
model: sonnet
argument-hint: "[plan-name]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Task
---

# Plan Orchestrate

Execute all tasks in a plan using parallel TDD workers. Fully autonomous after invocation.

## Usage

```
plan-orchestrate {plan-name}
```

Example: `plan-orchestrate user-auth`

## Prerequisites

**First, resolve the plans directory,** once, and reuse `$PLANS_DIR` for every path below. It is `.claude/plans` unless the project overrides it in `.claude/hcf.json` (see [Plans Directory](#plans-directory) in the README). The script answers with an absolute path resolved from the project root, so the result does not depend on the working directory:

```bash
PLANS_DIR="$("{skill-base-dir}/../../hooks/resolve-plans-dir.sh")" || exit 1
```

**Never substitute a hand-written `jq` line or a literal `.claude/plans`.** A non-zero exit means the project root or the configured value is unusable; surface the script's stderr verbatim and stop. Quote every path built from `$PLANS_DIR` — a configured directory may contain spaces.

Then:

1. Plan must exist at `$PLANS_DIR/{plan-name}/`
2. Project must be configured (`.claude/testing.md` exists)
3. Plan status must be `ready` or `in_progress`

Check prerequisites:
```bash
ls "$PLANS_DIR/{plan-name}/_plan.md" .claude/testing.md 2>/dev/null
```

If not found, output error and stop.

4. Must be on the correct feature branch

Verify the current branch matches `feature/{plan-name}`:
```bash
git branch --show-current
```

If the current branch is not `feature/{plan-name}`:
- Output an error explaining which branch is expected
- Ask the user if they'd like to check out `feature/{plan-name}`
- Do NOT proceed until on the correct branch

## Project Configuration

<testing>
@.claude/testing.md
</testing>

<code-standards>
@.claude/code-standards.md
</code-standards>

## Execution Algorithm

### Step 0: Check for Ralph Wiggum Plugin

Before starting execution, check if the ralph-wiggum plugin is installed by looking at the available skills listed in the system reminder. If skills like `ralph-wiggum:ralph-loop`, `ralph-wiggum:help`, or `ralph-wiggum:cancel-ralph` appear in the available skills list, the plugin is installed.

**Do NOT use `claude plugin list` via Bash** — this command does not work from inside a Claude Code session and will produce false negatives.

**If ralph-wiggum IS installed (skills are listed):**
- Automatically wrap execution with ralph-wiggum for session persistence
- Invoke: `/ralph-wiggum:loop "plan-orchestrate {plan-name}" --completion-promise "ALL_TASKS_COMPLETE" --max-iterations 100`
- This ensures the orchestrator continues even if context limits are reached

**If ralph-wiggum is NOT installed (skills are not listed):**
- Display a warning:
  ```
  WARNING: ralph-wiggum plugin is not installed.

  For large plans, execution may stop if context limits are reached.
  The orchestrator will continue, but session persistence is not available.

  To install ralph-wiggum for automatic session recovery:
    claude plugin marketplace add anthropics/claude-code
    claude plugin install ralph-wiggum@claude-code-plugins

  Continuing without ralph-wiggum...
  ```
- Continue with execution (the orchestrator will still work, but without session persistence)

### Step 1: Load Plan Context

Read plan files:
- `$PLANS_DIR/{plan-name}/_plan.md` - Plan overview
- `$PLANS_DIR/{plan-name}/*.md` - All task files (excluding _plan.md)

Note: Testing and code standards are auto-included above.

Parse each task file to extract:
- Task number (from filename)
- Status (pending | in_progress | completed | blocked)
- Dependencies (from `Depends on` field)
- Requirements (checkboxes)
- Retry count

Build a dependency graph as a data structure.

### Step 2: Update Plan Status

If plan status is `ready`, change to `in_progress`:
- Edit `$PLANS_DIR/{plan-name}/_plan.md`
- Set `## Status` to `in_progress`

**Establish the run fingerprint.** Every hook call below passes this back via
`--expect=`, so that agent files changing mid-run halt the orchestration rather
than silently swapping the pipeline. Read
`$PLANS_DIR/{plan-name}/.hook-fingerprint` and handle three distinct states —
conflating them is the mistake to avoid:

| State | Action |
|-------|--------|
| **Present and parseable** (one line: `discover-hooks-fingerprint-v1 <64-hex>`) | Use it as `$RUN_FINGERPRINT`. Pass the file's contents **verbatim** — do not trim, reformat, or re-derive them. |
| **Missing** | Not an error. Plans created before this feature have none. Capture one and write it to the plan directory so a resumed run is covered too, then continue: `"{skill-base-dir}/../../hooks/discover-hooks.sh" --fingerprint > "$PLANS_DIR/{plan-name}/.hook-fingerprint"` |
| **Present but unparseable** (empty, truncated, prose, wrong length) | **Halt.** Do not silently recapture — that would mask a botched write. Tell the user to delete the file to re-baseline. |

**Never reconstruct, abbreviate, or recall a fingerprint from memory.** It is
only ever produced by running the script. A hallucinated digest fails every
subsequent hook with bogus drift and bricks the run.

### Step 2a: Pre-Implementation Hook

Run the `pre-implementation` hook **once**, after the status is set to
`in_progress` and **before** the first batch is spawned.

Resolve and run enrolled agents via the **HOOKS.md discovery routine** (see
[Hook Discovery](#hook-discovery) below) with `HOOK = pre-implementation`. Pass
each agent the project context as described in
[Spawning hook agents](#spawning-hook-agents).

**Exit 0 with empty stdout** is an empty hook: return immediately, log nothing,
do no work, and proceed to Step 3. **Any non-zero exit stops the run** — see
[Hook Discovery](#hook-discovery) for the full result table.

### Step 3: Find Ready Tasks

A task is **ready** when:
- Status is `pending`
- ALL dependencies have status `completed`

```
ready_tasks = []
for each task in tasks:
    if task.status == "pending":
        if all(dep.status == "completed" for dep in task.dependencies):
            ready_tasks.append(task)
```

### Step 4: Check Termination Conditions

**All Complete:**
```
if all(task.status == "completed" for task in tasks):
    Run Step 4a: End-of-Run Hooks (quality gates + commit sequence before final completion)
    STOP
```

**Blocked State:**
```
if len(ready_tasks) == 0:
    if any(task.status == "pending" for task in tasks):
        # Tasks exist but none are ready - dependency deadlock or all blocked
        blocked_tasks = [t for t in tasks if t.status == "blocked"]
        Output: TASKS_BLOCKED: {list blocked task numbers and reasons}
        STOP
```

## Hook Discovery

All hooks in this skill (`pre-implementation`, `pre-batch`, `post-batch`,
`post-implementation`, `pre-commit`, `post-commit`) resolve their enrolled
agents by running **`hooks/discover-hooks.sh`**, the single implementation of
[HOOKS.md → Discovery Routine](../../HOOKS.md#discovery-routine). **Never
enumerate agent files by hand and never write a glob loop to do it.** For a
given `HOOK`:

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --hook=<HOOK> --expect="$RUN_FINGERPRINT"
```

`{skill-base-dir}` is the **`Base directory for this skill`** value stated when
this skill loaded — it is given verbatim, so no path inference is needed.
`${CLAUDE_PLUGIN_ROOT}` is **not** available in a skill's Bash calls.
`$RUN_FINGERPRINT` is the value established at [Step 2](#step-2-update-plan-status).

Then, by result:

- **Exit 0, empty stdout → empty hook.** Return immediately — no staging, no
  diffing, no spawns, and **no logging or narration**. "No narration" is literal
  and is the rule most often broken: do not name the hook, do not say it is
  empty/skipped, do not explain *why* it is empty, and **do not say the
  discovery script returned no agents**. A filtered query prints zero bytes
  precisely so there is nothing to echo. An empty hook is **completely
  invisible** in the user-facing output. See [HOOKS.md → Empty-hook fast
  path](../../HOOKS.md#empty-hook-fast-path).
- **Exit 0, output → PRINT it verbatim** as the resolved order, then spawn.
- **Exit 1 or 2 → stop the run.** Surface stderr verbatim.
- **Exit 3 → stop the run.** An agent file declares an invalid `phase` or
  `mode`. Surface stderr verbatim; it names the file and the fix.
- **Exit 4 → halt HCF.** Hook enrollment changed since this run started, so the
  remaining hooks would execute a different pipeline than the plan was reviewed
  against. Surface stderr verbatim. Do **not** continue the batch loop and do
  **not** commit.
- **Script missing or not executable → hard failure.** Say so and stop. There is
  no prose fallback; reconstructing the routine by hand is the failure this
  design exists to end.

**Only exit 0 with empty stdout is an empty hook.** Every other non-zero exit is
an error to report loudly.

On a normal (exit 0, non-empty) result, spawn each agent per its **`mode` field**
(`single` → one subagent for the whole plan; `batch` → split the relevant file
  list into batches of ~10 and spawn parallel subagents, one Task call per
  batch, all in a single message). The spawn mode comes from the agent's `mode`
  frontmatter field — never from sniffing the agent body text.

### Spawning hook agents

Hook agents are spawned with the Task tool using `subagent_type="{agent-name}"`.
The orchestrator only has `<testing>` and `<code-standards>` in context (see
[Project Configuration](#project-configuration)) — it does NOT have
`<architecture>`. Pass each hook agent the project context it needs verbatim:

> **CRITICAL: Pass the COMPLETE, VERBATIM content of the `<code-standards>` and
> `<testing>` tags above. Do NOT summarize, condense, or paraphrase. The full
> documents contain nuanced rules that are lost when summarized. Copy-paste the
> entire content between the tags.**

For a **`batch`** agent, send one prompt per batch:

```markdown
## Code Standards
{paste the COMPLETE content of <code-standards> verbatim — do NOT summarize}

## Testing Standards
{paste the COMPLETE content of <testing> verbatim — do NOT summarize}

## Files to Review
{list of files in this batch, one per line}
```

For a **`single`** agent, send one prompt covering the whole plan, including the
plan name, the changed-files list, and `<testing>` + `<code-standards>` verbatim.

> If a hook agent needs project architecture, that is out of scope for this
> orchestrator — it does not load `<architecture>`. Do NOT fabricate an
> `## Project Architecture` paste here.

### Step 4a: End-of-Run Hooks (Post-Implementation → Tests → Commit)

When all tasks are complete, run the end-of-run hook sequence. The control flow
is strictly:

**post-implementation → run full test suite → pre-commit → commit → post-commit**

> **CRITICAL INVARIANT: NOTHING is committed until AFTER the full test suite
> passes.** This ensures no broken code is ever committed. The `pre-commit` hook
> runs *after* tests pass and *before* the commit; `post-commit` runs *after*
> the commit and *before* the push/PR prompt.

**1. Run the `post-implementation` hook:**

Resolve and run enrolled agents via the [Hook Discovery](#hook-discovery)
routine with `HOOK = post-implementation`. To give batch agents a file list,
first compute the changed files (this stages everything only to read the list,
then unstages — nothing is committed):

```bash
git add -A && git diff --name-only --cached && git reset HEAD
```

Then spawn the resolved agents per their `mode` (see
[Spawning hook agents](#spawning-hook-agents)). **Exit 0 with empty stdout** is
an empty hook: return immediately, no logging, no work, and proceed to step 2.
**Any non-zero exit stops the run** — see [Hook Discovery](#hook-discovery).

**2. After ALL post-implementation agents complete, run validation:**
```bash
# Run full test suite
{parallel test command from testing.md}
```

> **CRITICAL: Nothing is committed until AFTER the full test suite passes.** This ensures no broken code is ever committed.

**3. On test failure** — isolate the cause (see
[Test-failure isolation](#test-failure-isolation) below), then either commit the
implementation only or output `TASKS_BLOCKED`.

**4. On tests passing — run the `pre-commit` hook:**

Resolve and run enrolled agents via [Hook Discovery](#hook-discovery) with
`HOOK = pre-commit`. These run *after* the suite passes and *before* the commit.
**Exit 0 with empty stdout** is an empty hook (silent no-op); **any non-zero
exit stops the run before the commit** — see [Hook Discovery](#hook-discovery).

> If a `pre-commit` agent modifies files, those edits are part of this commit. A
> pre-commit agent that changes files could break tests; that risk is covered by
> the [Test-failure isolation](#test-failure-isolation) stash, which now spans
> both post-implementation and pre-commit hook output.

**5. Commit:**
First, update `_plan.md` status to `completed`. Then stage and commit everything together in a **single commit**:
```bash
# 1. Update plan status BEFORE committing
# (edit $PLANS_DIR/{plan-name}/_plan.md — set Status to "completed")

# 2. Stage everything: implementation + hook agent fixes + plan files (including updated status)
git add -A "$PLANS_DIR/{plan-name}/"
git add -A
git commit -m "feat({plan-name}): {plan title summary}"
```
> **IMPORTANT:** There must be exactly ONE commit here — do NOT make a separate commit for the plan status update. Update the status first, then stage and commit all changes together.

**6. After the commit succeeds — run the `post-commit` hook:**

Resolve and run enrolled agents via [Hook Discovery](#hook-discovery) with
`HOOK = post-commit`. These run *after* the commit and *before* the push/PR
prompt (the [Output Summary](#output-summary) at the end of this skill).
**Exit 0 with empty stdout** is an empty hook (silent no-op); **any non-zero
exit is reported loudly** — see [Hook Discovery](#hook-discovery). The commit
has already happened, so report the failure rather than trying to undo it.

> **`post-commit` agents that produce uncommitted changes are REPORTED, not
> silently committed.** The commit above already happened; do not amend or
> create a second commit. Surface any working-tree changes a post-commit agent
> left behind so the user can decide what to do.

Output: `ALL_TASKS_COMPLETE`

#### Test-failure isolation

If the full test suite fails at step 3 (or after pre-commit edits), isolate
whether the **hook agents** (any `post-implementation` or `pre-commit` agent
that edited files) broke things versus the implementation itself. The git stash
isolation spans **both** the post-implementation and pre-commit hook output:

```bash
git stash
```
Re-run the test suite on just the implementation.

- If implementation tests pass: a hook agent (post-implementation or pre-commit)
  broke something. Drop the stash, commit implementation only, and output:
   ```
   ALL_TASKS_COMPLETE

   WARNING: A post-implementation or pre-commit hook agent broke tests. Implementation committed without hook fixes. Review and run manually.
   ```
- If implementation tests also fail: a TDD worker produced broken code. Restore
  the stash (`git stash pop`) and output `TASKS_BLOCKED` with details.

### Step 5: Spawn Parallel Workers

**Pre-batch hook (this loop iteration).** Before spawning workers, run the
`pre-batch` hook via the [Hook Discovery](#hook-discovery) routine with
`HOOK = pre-batch`. Because this runs on **every** loop iteration, honoring the
**empty-hook fast no-op** is important: on **exit 0 with empty stdout**, return
immediately — log nothing, do no work — so unconfigured loops add zero overhead.
**Any non-zero exit stops the run**; per-iteration checking is also what makes
drift (exit 4) surface promptly rather than at the end. See
[Hook Discovery](#hook-discovery).

For EACH ready task, spawn a Task tool subagent **in parallel** (single message with multiple Task tool calls):

```
Use the Task tool with subagent_type="tdd-worker" for EACH ready task.
All Task tool calls MUST be made in a SINGLE message to enable parallel execution.
```

**Worker Prompt (pass to each tdd-worker):**

> **CRITICAL: Pass the COMPLETE, VERBATIM content of the `<testing>` and `<code-standards>` tags above.
> Do NOT summarize. Subagents have no access to CLAUDE.md or project files beyond what you provide.**

```markdown
## Task File Path
{the concrete resolved path, e.g. $PLANS_DIR/{plan-name}/{task-file}.md}

## Project Testing Configuration
{paste the COMPLETE content of <testing> verbatim — do NOT summarize}

## Code Standards
{paste the COMPLETE content of <code-standards> verbatim — do NOT summarize}

## Your Task
{contents of the task file}
```

The tdd-worker agent already has all TDD methodology and rules. The prompt needs the project-specific configuration and task details since subagents do not inherit CLAUDE.md context.

Pass the **concrete** path under `## Task File Path`, not the literal `$PLANS_DIR` — the worker marks checkboxes and appends implementation notes there, and it must never read `.claude/hcf.json` or assume a default to find it. One resolver runs in this skill; every subagent is handed a finished path.

### Step 6: Collect Results

Wait for ALL parallel Task tool calls to complete. For each result:

**On TASK_COMPLETE:**
1. Verify all requirements are checked in task file
2. Set task status to `completed`
3. Update the task table in `_plan.md`

> **NOTE:** Do NOT commit here. All commits are deferred to Step 4a, after standards enforcement and the full test suite pass. This ensures no non-standard code is ever committed.

**On TASK_FAILED:**
1. Increment retry count in task file
2. If retry count >= 3:
   - Set status to `blocked`
   - Set blocked reason from error message
   - Update task table in `_plan.md`
3. If retry count < 3:
   - Keep status as `pending` (will retry in next batch)
   - Log the failure for visibility

**Post-batch hook (this loop iteration).** After all results for this batch are
collected and statuses are updated, run the `post-batch` hook via the
[Hook Discovery](#hook-discovery) routine with `HOOK = post-batch`. **Any
non-zero exit stops the run.** Because this
runs on **every** loop iteration, honoring the **empty-hook fast no-op** is
important: if no agents are enrolled, return immediately — log nothing, do no
work — so unconfigured loops add zero overhead.

### Step 7: Report Progress

After processing the batch, output:

```
Batch complete:
  Completed: {list of completed task numbers}
  Failed (will retry): {list of failed tasks with retry < 3}
  Blocked: {list of newly blocked tasks}

Progress: {completed}/{total} tasks
Ready for next batch: {count of newly ready tasks}
```

### Step 8: Continue Loop

Return to Step 3 and find the next batch of ready tasks.

Continue until:
- `ALL_TASKS_COMPLETE` - All tasks finished successfully
- `TASKS_BLOCKED: [list]` - No progress possible

## Handling Edge Cases

### Task Already In Progress
If a task has status `in_progress` (from interrupted previous run):
- Treat it as `pending` and include in ready check
- The worker will pick up where it left off based on [x] marks

### Partial Completion
If some requirements are already [x] in a task:
- Worker will skip those and continue with unchecked ones
- This enables resumption after interruption

### Dependency on Blocked Task
If task A depends on blocked task B:
- Task A can never become ready
- It should be reported in final TASKS_BLOCKED output

### Test Failures in Completed Requirements
If a previously passing test starts failing:
- Worker should report TASK_FAILED
- Investigation needed - likely a breaking change

## Session Persistence (Automatic)

The orchestrator automatically uses ralph-wiggum for session persistence if installed (see Step 0).

- If ralph-wiggum is installed: Execution automatically wraps with `/ralph-wiggum:loop` for session recovery
- If not installed: A warning is shown, but execution continues without persistence

The orchestrator outputs `ALL_TASKS_COMPLETE` when done, which satisfies ralph-wiggum's completion promise.

If blocked, it outputs `TASKS_BLOCKED: [...]` which will NOT satisfy the promise, but provides visibility into what's blocking progress.

## Output Summary

Final output should be one of:

**Success:**
```
ALL_TASKS_COMPLETE

Plan: {plan-name}
Total tasks: {N}
All tests passing.
Post-implementation hooks complete.
Commits created: {N}

## What Changed

{Brief, high-level summary of what was built or changed. Write this as a bulleted list
describing the user-visible outcomes — not implementation details. Derive this from the
completed task titles and the plan objective. For example:}

- Added visitor name column to the detail table
- Linked visitor rows to their detail pages
- Reordered columns to match design spec
- Added sorting to all new columns
```

> **NOTE:** The "What Changed" section should read like release notes — focus on outcomes,
> not internals. Pull from the plan's objective and completed task summaries.

After displaying the success output, prompt the user about pushing and creating a PR:

```
Would you like to push this branch and create a pull request?

1. **Yes, push and create PR** - I'll push feature/{plan-name} and open a PR
2. **Just push** - I'll push the branch, you can create the PR later
3. **No thanks** - Keep everything local for now
```

**Never push or create a PR without the user's explicit permission.** Wait for their response before taking action. If they choose option 1, push and use `gh pr create` with a summary derived from the plan objective and "What Changed" section.

**Linking GitHub Issues:** Check `_plan.md` for the `## Related Issues` field. If it contains issue references (e.g., `Closes #18`), include them in the PR body so GitHub automatically links and closes the issues when the PR is merged. Place them at the end of the PR body, each on its own line.

**Blocked:**
```
TASKS_BLOCKED: [003, 007]

Plan: {plan-name}
Completed: {X}/{N}
Blocked tasks:
  003: {blocked reason}
  007: {blocked reason}

Manual intervention required for blocked tasks.
```

**Partial Progress (for visibility during execution):**
```
Batch {X} complete.
Progress: {completed}/{total}
Continuing...
```

## Performance Expectations

With proper parallelization:
- 10 independent tasks: ~1-2 batches
- 50 tasks with shallow dependencies: ~3-5 batches
- 100 tasks: ~5-10 batches

Each batch runs tasks in parallel, dramatically reducing total time compared to sequential execution.
