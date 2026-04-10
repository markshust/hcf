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

1. Plan must exist at `.claude/plans/{plan-name}/`
2. Project must be configured (`.claude/testing.md` exists)
3. Plan status must be `ready` or `in_progress`

Check prerequisites:
```bash
ls .claude/plans/{plan-name}/_plan.md .claude/testing.md 2>/dev/null
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
    claude plugin install ralph-wiggum@anthropics-claude-code

  Continuing without ralph-wiggum...
  ```
- Continue with execution (the orchestrator will still work, but without session persistence)

### Step 1: Load Plan Context

Read plan files:
- `.claude/plans/{plan-name}/_plan.md` - Plan overview
- `.claude/plans/{plan-name}/*.md` - All task files (excluding _plan.md)

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
- Edit `.claude/plans/{plan-name}/_plan.md`
- Set `## Status` to `in_progress`

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
    Run Step 4a: Post-Implementation Pipeline (quality gates before final completion)
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

### Step 4a: Post-Implementation Pipeline

When all tasks are complete, run the agents configured in the `post-implementation` phase of `pipeline.md`.

**1. Read the pipeline configuration:**

Parse the `## post-implementation` section from the `<pipeline>` context included in CLAUDE.md. Each bullet point is an agent name to run.

**2. Get the list of changed files:**
```bash
git add -A && git diff --name-only --cached && git reset HEAD
```
This temporarily stages everything to get the file list, then unstages. Nothing is committed yet.

**3. For each agent in the post-implementation list**, run it with the changed files:

For agents that operate on file batches (like `standards-enforcer`), split files into batches of ~10 and spawn parallel subagents. For agents that operate on the plan as a whole, spawn a single subagent.

**How to determine the agent's mode:** Read the agent's `.md` file. If it references "batch" or "file list" in its prompt format, use batch mode. Otherwise, use single mode.

**Batch mode** (e.g., standards-enforcer):
```
Use the Task tool with subagent_type="{agent-name}" for EACH batch.
All Task tool calls MUST be made in a SINGLE message to enable parallel execution.
```

Worker Prompt (per batch):

> **CRITICAL: Pass the COMPLETE, VERBATIM content of the `<code-standards>` and `<testing>` tags above.
> Do NOT summarize, condense, or paraphrase. The full documents contain nuanced rules
> that are lost when summarized. Copy-paste the entire content between the tags.**

```markdown
## Code Standards
{paste the COMPLETE content of <code-standards> verbatim — do NOT summarize}

## Testing Standards
{paste the COMPLETE content of <testing> verbatim — do NOT summarize}

## Files to Review
{list of files in this batch, one per line}
```

**Single mode** (e.g., doc-updater):
```
Use the Task tool with subagent_type="{agent-name}" once.
```

Pass the plan name, changed files list, and any relevant project context.

**4. After ALL post-implementation agents complete, run validation:**
```bash
# Run full test suite
{parallel test command from testing.md}
```

> **CRITICAL: Nothing is committed until AFTER the full test suite passes.** This ensures no broken code is ever committed.

**5. On tests passing:**
First, update `_plan.md` status to `completed`. Then stage and commit everything together in a **single commit**:
```bash
# 1. Update plan status BEFORE committing
# (edit .claude/plans/{plan-name}/_plan.md — set Status to "completed")

# 2. Stage everything: implementation + pipeline agent fixes + plan files (including updated status)
git add -A .claude/plans/{plan-name}/
git add -A
git commit -m "feat({plan-name}): {plan title summary}"
```
> **IMPORTANT:** There must be exactly ONE commit here — do NOT make a separate commit for the plan status update. Update the status first, then stage and commit all changes together.

Output: `ALL_TASKS_COMPLETE`

**6. On test failure:**
- Revert only the post-implementation agent changes to isolate whether they broke things:
   ```bash
   git stash
   ```
   Re-run the test suite on just the implementation.
- If implementation tests pass: a post-implementation agent broke something. Drop the stash, commit implementation only, and output:
   ```
   ALL_TASKS_COMPLETE

   WARNING: Post-implementation pipeline broke tests. Implementation committed without pipeline fixes. Review and run manually.
   ```
- If implementation tests also fail: a TDD worker produced broken code. Restore the stash (`git stash pop`) and output `TASKS_BLOCKED` with details.

### Step 5: Spawn Parallel Workers

For EACH ready task, spawn a Task tool subagent **in parallel** (single message with multiple Task tool calls):

```
Use the Task tool with subagent_type="tdd-worker" for EACH ready task.
All Task tool calls MUST be made in a SINGLE message to enable parallel execution.
```

**Worker Prompt (pass to each tdd-worker):**

> **CRITICAL: Pass the COMPLETE, VERBATIM content of the `<testing>` and `<code-standards>` tags above.
> Do NOT summarize. Subagents have no access to CLAUDE.md or project files beyond what you provide.**

```markdown
## Project Testing Configuration
{paste the COMPLETE content of <testing> verbatim — do NOT summarize}

## Code Standards
{paste the COMPLETE content of <code-standards> verbatim — do NOT summarize}

## Your Task
{contents of the task file}
```

The tdd-worker agent already has all TDD methodology and rules. The prompt needs the project-specific configuration and task details since subagents do not inherit CLAUDE.md context.

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
Post-implementation pipeline complete.
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
