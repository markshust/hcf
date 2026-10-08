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

### Step 0: Suggest Unattended Completion via /goal

Claude Code's built-in `/goal` command keeps a session working toward a
verifiable end state — its evaluator runs after each turn and pushes execution
to continue until the condition is met. Only the user can set a goal (`/goal`
is a user-typed command and cannot be invoked from a skill), so surface a
copy-pasteable tip and continue immediately. This is informational, never a
gate — do not wait for a response.

Display:

```
Tip: for large plans, you can keep this run going unattended with Claude Code's
built-in /goal command (interrupt me now to set it, or set it before a future run):

  /goal the {plan-name} plan run reached a terminal state: plan-orchestrate output ALL_TASKS_COMPLETE or TASKS_BLOCKED

Either way, an interrupted run resumes from disk — just re-run plan-orchestrate {plan-name}.
```

The suggested condition deliberately names **both** terminal outputs. A goal
phrased as only `ALL_TASKS_COMPLETE` leaves the evaluator demanding more turns
after a legitimately blocked run, when the correct behavior is to stop and
report the blockage.

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
`in_progress` and **before** the first batch is launched.

Resolve and run enrolled agents via the **HOOKS.md discovery routine** (see
[Hook Discovery](#hook-discovery) below) with `HOOK = pre-implementation`. Pass
each agent the project context as described in
[Spawning hook agents](#spawning-hook-agents).

**Exit 0 with empty stdout** is an empty hook: return immediately, log nothing,
do no work, and proceed to Step 3. **Any non-zero exit stops the run** — see
[Hook Discovery](#hook-discovery) for the full result table.

### Step 3: Find Ready Tasks

Execution is a **rolling** loop, not a lockstep one. Each task starts as soon as
its own dependencies are complete; it never waits for unrelated tasks that
happened to start alongside its dependencies. Track a **running set** — the
tasks with a worker in flight in this session.

A task is **ready** when:
- Status is `pending` (an `in_progress` task from an interrupted run counts as
  pending — see [Task Already In Progress](#task-already-in-progress))
- ALL dependencies have status `completed`
- It is **not** in the running set

```
ready_tasks = []
for each task in tasks (in task-number order):
    if task.status == "pending" and task not in running:
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

**Waiting:**
```
if len(ready_tasks) == 0 and len(running) > 0:
    # Nothing new can start yet, but workers are in flight
    Go to Step 6 and wait for the next completion
```

**Blocked State:**
```
if len(ready_tasks) == 0 and len(running) == 0:
    if any(task.status == "pending" for task in tasks):
        # Tasks exist but none are ready and nothing is running - dependency deadlock or all blocked
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
  against. Surface stderr verbatim. Stop launching (see
  [Stopping mid-run](#stopping-mid-run)) and do **not** commit.
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
then unstages — nothing is committed). The plans directory is left out: plan
files are working state, not code for agents to review.

```bash
git add -A && git reset -q -- "$PLANS_DIR" && git diff --name-only --cached && git reset HEAD
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
First, update `_plan.md` status to `completed`. Then stage and commit the implementation in a **single commit**, leaving the plans directory out:
```bash
# 1. Update plan status (local working state — it is not committed)
# (edit $PLANS_DIR/{plan-name}/_plan.md — set Status to "completed")

# 2. Stage implementation + hook agent fixes, then unstage the plans directory
git add -A
git reset -q -- "$PLANS_DIR"
git commit -m "feat({plan-name}): {plan title summary}"
```
> **IMPORTANT:** There must be exactly ONE commit here. **Never commit plan
> files.** Plans are ephemeral: once the work is committed, the code and its
> tests are the source of truth, and a plan kept in the repo goes stale
> alongside them. Unstaging `$PLANS_DIR` (rather than excluding it with a
> pathspec) works whether the directory is untracked, gitignored, or was
> committed by an older HCF version.

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

### Step 5: Launch a Batch

A **batch** is the set of ready tasks launched together in one pass through this
step. Batches still exist and still get the `pre-batch` and `post-batch` hooks;
what changed is when they start. A batch launches the moment tasks become ready
and capacity allows, so several batches can be in flight at once. Number
batches sequentially from 1 for the run.

**Every ready task launches.** HCF sets no concurrency limit of its own: the
limit is Claude Code's, 20 running subagents per session by default, raised with
the `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` environment variable. Over that limit
a spawn fails rather than queues, which
[At the subagent limit](#at-the-subagent-limit) below handles.

```
if at_limit:
    # A spawn hit Claude Code's limit and no worker has finished since
    Go to Step 6 and wait for the next completion
batch = ready_tasks
```

**Pre-batch hook.** Before launching, run the `pre-batch` hook via the
[Hook Discovery](#hook-discovery) routine with `HOOK = pre-batch`. Because this
runs before **every** batch, honoring the **empty-hook fast no-op** is
important: on **exit 0 with empty stdout**, return immediately — log nothing, do
no work — so unconfigured runs add zero overhead. **Any non-zero exit stops
launching** (see [Stopping mid-run](#stopping-mid-run)); checking per batch is
also what makes drift (exit 4) surface promptly rather than at the end.

**Mark the batch.** Set each task's status to `in_progress` in its task file and
in the task table in `_plan.md`, and add it to the running set.

**Launch.** Spawn one `tdd-worker` per task as a **background** subagent, all in
a single message, and do **not** wait for them here:

```
Use the Task tool with subagent_type="tdd-worker" and run_in_background=true for EACH task in the batch.
All Task tool calls for the batch go in a SINGLE message.
```

**At the subagent limit.** A spawn that fails with `Concurrent subagent limit
reached` never started, so it is not a failure of the task: set that task back
to `pending`, remove it from the running set, and do **not** increment its retry
count. Set `at_limit`, and do not retry the spawn — the next completion in
Step 6 clears `at_limit` and frees a slot. If the running set is empty when this
happens, no completion is coming to free a slot (the limit is taken by
subagents outside this run): surface the error and stop (see
[Stopping mid-run](#stopping-mid-run)).

Output one line, then continue to Step 6:

```
Batch {B} launched: tasks {list} (running {len(running)})
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

### Step 6: Collect One Result

Wait for the **next** worker to finish — the harness notifies you as each
background subagent completes. Do not poll, do not sleep, and do not wait for
the rest of its batch. Process that one result, remove the task from the
running set, and clear `at_limit`:

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
   - Set status back to `pending` (it is ready again on the next pass through Step 3)
   - Log the failure for visibility

**Post-batch hook.** If this result was the **last** outstanding task of its
batch, run the `post-batch` hook for that batch via the
[Hook Discovery](#hook-discovery) routine with `HOOK = post-batch`. Other
batches may still be running, so the working tree can hold their unfinished
edits; a `post-batch` agent should look only at its own batch's tasks. **Any
non-zero exit stops launching** (see [Stopping mid-run](#stopping-mid-run)).
Honor the **empty-hook fast no-op**: if no agents are enrolled, return
immediately — log nothing, do no work.

### Step 7: Report Progress

After each result, output one line:

```
Task {N} {complete | failed (retry {r}/3) | blocked}. Progress: {completed}/{total}, running {len(running)}, ready {len(ready_tasks)}
```

When a batch's last task finishes, also output:

```
Batch {B} complete:
  Completed: {list of completed task numbers}
  Failed (will retry): {list of failed tasks with retry < 3}
  Blocked: {list of newly blocked tasks}
```

### Step 8: Continue Loop

Return to Step 3 after **every** result, so tasks unblocked by that completion
launch immediately in a new batch while the others keep running.

Continue until:
- `ALL_TASKS_COMPLETE` - All tasks finished successfully
- `TASKS_BLOCKED: [list]` - No progress possible

### Stopping mid-run

When a hook or the subagent limit stops the run while workers are still in
flight, launch nothing further, but keep collecting results (Step 6, without
hooks) until the running set is empty, so every task file ends in an accurate
state. Then surface the error and stop. Do **not** run Step 4a and do **not**
commit.

## Handling Edge Cases

### Task Already In Progress
If a task has status `in_progress` at startup (from an interrupted previous run):
- Treat it as `pending` and include in ready check — no worker from this session is running it
- Tasks this session marked `in_progress` in Step 5 are in the running set and are never relaunched
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

## Session Persistence

Session persistence is native to Claude Code — no plugin is required:

- **Context limits are not a failure mode.** When the conversation grows long,
  auto-compaction summarizes it and execution continues.
- **All run state lives on disk.** Task statuses, requirement checkboxes, and
  retry counts are stored in the plan files, so re-running
  `plan-orchestrate {plan-name}` resumes exactly where a previous run stopped
  (see [Handling Edge Cases](#handling-edge-cases)).
- **Unattended completion is the user's opt-in** via the built-in `/goal`
  command (see Step 0). The orchestrator's terminal outputs are the goal's
  verifiable end states: `ALL_TASKS_COMPLETE` on success, `TASKS_BLOCKED: [...]`
  when no progress is possible. Both are terminal — a blocked run ends the goal
  too, rather than leaving it spinning.

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

**Plan cleanup:** End the success output by noting that the plan folder was not
committed and can be deleted once the branch is merged:
`Plan files in {plans dir}/{plan-name}/ were not committed — delete them once this work is merged.`
Never delete the folder yourself; the PR step above still reads `_plan.md`.

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

**Partial Progress (for visibility during execution):** the per-result and
per-batch lines from [Step 7](#step-7-report-progress).

## Performance Expectations

Total time tracks the plan's **longest dependency chain**, not the sum of each
batch's slowest task. A task never waits for unrelated work: if 002 takes 3
minutes and 003 takes 15, a task depending only on 002 starts at minute 3.

- 10 independent tasks: all start at once (up to the limit), bounded by the slowest
- Deep plans with uneven task sizes gain the most over lockstep batches
- Concurrency is Claude Code's subagent limit (20 by default; raise it with
  `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`), so very wide plans queue rather than
  all starting at once

