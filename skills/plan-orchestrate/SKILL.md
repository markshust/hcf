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

## Project Configuration

<testing>
@.claude/testing.md
</testing>

<code-standards>
@.claude/code-standards.md
</code-standards>

## Execution Algorithm

### Step 0: Check for Ralph Wiggum Plugin

Before starting execution, check if the ralph-wiggum plugin is installed:

```bash
# Check if ralph-wiggum commands are available
claude plugin list 2>/dev/null | grep -q "ralph-wiggum"
```

**If ralph-wiggum IS installed:**
- Automatically wrap execution with ralph-wiggum for session persistence
- Invoke: `/ralph-wiggum:loop "plan-orchestrate {plan-name}" --completion-promise "ALL_TASKS_COMPLETE" --max-iterations 100`
- This ensures the orchestrator continues even if context limits are reached

**If ralph-wiggum is NOT installed:**
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

Capture the starting commit hash for later use in Step 4a:
```bash
git rev-parse HEAD
```
Store this as `{starting-commit}` — it's used to identify files changed during plan execution.

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
    Run Step 4a: Code Standards Enforcement (quality gate before final completion)
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

### Step 4a: Code Standards Enforcement

**Why this exists:** TDD workers focus on tests and implementation. This dedicated pass has a single focus: standards compliance.

When all tasks are complete:

**1. Get the list of changed files:**
```bash
git diff --name-only --diff-filter=ACM {starting-commit}..HEAD
```

**2. Split files into batches** of ~10 files each.

**3. Spawn parallel standards-enforcer subagents** (single message with multiple Task tool calls), one per batch:

```
Use the Task tool with subagent_type="standards-enforcer" for EACH batch.
All Task tool calls MUST be made in a SINGLE message to enable parallel execution.
```

**Worker Prompt (per batch):**

```markdown
## Code Standards
{pass the <code-standards> content from above}

## Files to Review
{list of files in this batch, one per line}
```

**4. After ALL enforcers return `BATCH_ENFORCED`, run validation:**
```bash
# Run lint
{lint command from code-standards.md or testing.md}

# Run full test suite
{parallel test command from testing.md}
```

**5. On lint/tests passing:**
1. Create a git commit if any files were changed:
   ```bash
   git add -A && git commit -m "style({plan-name}): enforce coding standards"
   ```
2. Update `_plan.md` status to `completed`
3. Output: `ALL_TASKS_COMPLETE`

**6. On lint/test failure:**
- If tests fail, investigate which enforcer's changes broke things. Revert those changes and re-run tests.
- If tests still pass after reverting, commit the remaining fixes and continue.
- Standards enforcement is non-blocking — if issues persist, output:
   ```
   ALL_TASKS_COMPLETE

   WARNING: Code standards enforcement encountered issues. Run linting manually.
   ```

### Step 5: Spawn Parallel Workers

For EACH ready task, spawn a Task tool subagent **in parallel** (single message with multiple Task tool calls):

```
Use the Task tool with subagent_type="tdd-worker" for EACH ready task.
All Task tool calls MUST be made in a SINGLE message to enable parallel execution.
```

**Worker Prompt (pass to each tdd-worker):**

```markdown
## Project Testing Configuration
{pass the <testing> content from above}

## Code Standards
{pass the <code-standards> content from above}

## Your Task
{contents of the task file}
```

The tdd-worker agent already has all TDD methodology and rules. The prompt needs the project-specific configuration and task details since subagents do not inherit CLAUDE.md context.

### Step 6: Collect Results

Wait for ALL parallel Task tool calls to complete. For each result:

**On TASK_COMPLETE:**
1. Verify all requirements are checked in task file
2. Set task status to `completed`
3. Create a git commit:
   ```bash
   git add -A && git commit -m "feat({plan-name}): {task title}"
   ```
4. Update the task table in `_plan.md`

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
Code standards enforced.
Commits created: {N}
```

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
