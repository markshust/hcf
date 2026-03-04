---
name: plan-create
description: Create structured implementation plans for autonomous TDD development. Use for new features, multi-file changes, or anything requiring multiple steps or tests. Triggers on "build", "create", "add a feature", "help me implement", "I need to build". Do NOT use this for "implement the plan" or "run the plan" - those should use plan-orchestrate instead. Skip for quick bug fixes, single-line changes, questions, or documentation.
argument-hint: "[feature description]"
---

# Plan Create

Transform feature requests into structured plans with task breakdowns, dependencies, and TDD requirements for parallel autonomous execution.

## Project Architecture

<architecture>
@.claude/architecture.md
</architecture>

## Execution Flow

### Phase 1: Understand the Request

**Initial Clarification**

Start by understanding the scope:

> I'll help you plan this feature. Let me ask a few questions to make sure I understand what you need.

Ask clarifying questions, such as (just examples):
1. **Scope**: What's the core functionality? What's explicitly out of scope?
2. **Users**: Who will use this? What permissions/roles are involved?
3. **Integration**: How does this connect to existing code?
4. **Edge cases**: Any specific error handling or edge cases to consider?
5. **Priority**: Which parts are must-have vs nice-to-have?

Keep questions focused and relevant to the specific feature. Your goal is to flush out all requirements so there is enough information to work on the task autonomously. If you have enough context to work on the feature and don't have any clarifying questions which would further enhance the ask or help define the requirements, continue.

### Phase 2: Define the Plan

Once you understand the requirements, create the plan overview:

**Create plan directory:**
```bash
mkdir -p .claude/plans/{plan-name}
```

Use a kebab-case name derived from the feature (e.g., `user-authentication`, `payment-processing`).

**Create `_plan.md`:**
```markdown
# Plan: {Feature Name}

## Created
{date}

## Status
planning | ready | in_progress | completed | blocked

## Objective
{1-2 sentence description of what this plan achieves}

## Scope

### In Scope
- {bullet points of included functionality}

### Out of Scope
- {bullet points of explicitly excluded functionality}

## Success Criteria
- [ ] {measurable outcome 1}
- [ ] {measurable outcome 2}
- [ ] All tests passing
- [ ] Code follows project standards

## Task Overview
| Task | Description | Depends On | Status |
|------|-------------|------------|--------|
| 001 | {title} | - | pending |
| 002 | {title} | 001 | pending |
| ... | ... | ... | ... |

## Architecture Notes
{Any architectural decisions or patterns to follow}

## Risks & Mitigations
- {potential risk}: {mitigation strategy}
```

### Phase 3: Break Down into Tasks

Create numbered task files. Follow these principles:

**Task Sizing:**
- Each task should be completable in 1 TDD cycle (15-30 min of focused work)
- A task typically has 3-7 requirements
- If a task has >7 requirements, split it
- If a task has <3 requirements, consider combining with related task

**Dependency Rules:**
- Tasks with no dependencies can run in parallel
- Explicitly declare ALL dependencies (not just immediate ones)
- Avoid circular dependencies
- Maximize parallelism by minimizing unnecessary dependencies

**Required Tasks:**
- If the plan creates a new package, the **final task** must create a `README.md` following the project's Package README Standards (see `code-standards.md`). This task depends on all other tasks so the README accurately reflects what was built.

**Task File Format (`{NNN}-{task-name}.md`):**

```markdown
# Task {NNN}: {Title}

**Status**: pending
**Depends on**: [{comma-separated task numbers, or "none"}]
**Retry count**: 0

## Description
{2-4 sentences describing what this task accomplishes and why}

## Context
{Any relevant context the implementer needs to know}
- Related files: {list key files to modify or reference}
- Patterns to follow: {reference to existing patterns in codebase}

## Requirements (Test Descriptions)
Write requirements as exact test names. These become the test method names.

- [ ] `it creates a new user with valid email and password`
- [ ] `it rejects duplicate email addresses with validation error`
- [ ] `it hashes passwords before storing in database`
- [ ] `it returns user object with id after successful creation`

## Acceptance Criteria
- All requirements have passing tests
- Code follows code standards
- No decrease in test coverage

## Implementation Notes
(Left blank - filled in by programmer during implementation)
```

### Phase 4: Validate Dependencies

After creating all tasks, verify:
1. No circular dependencies exist
2. Task 001 has no dependencies (or minimal bootstrap)
3. Dependencies form a valid DAG (Directed Acyclic Graph)
4. Maximum parallelism is achieved
5. All context exists to complete all tasks autonomously (if not, revisit asking clarifying questions)

**Dependency Visualization:**
Show the user a simple dependency tree:
```
001 ─┬─► 002 ─┬─► 005
     │        │
     └─► 003 ─┘
     │
     └─► 004 ────► 006
```

### Phase 5: Devil's Advocate Review

After validating dependencies, automatically run a devil's advocate review to stress-test the plan before presenting it to the user.

**Spawn a devils-advocate subagent:**

Use the Agent tool with `subagent_type="devils-advocate"` and pass the plan name and project context.

**The subagent prompt must include:**
1. The plan name (so it knows the directory path)
2. The project's architecture context:

```
## Project Architecture
{paste the COMPLETE content of <architecture> verbatim}
```

The subagent will:
1. Read all task files and the `_plan.md`
2. Cross-reference against project source and architecture
3. Write findings to `.claude/plans/{plan-name}/_devils_advocate.md`
4. **Auto-apply** all Critical and Important fixes directly to task files and `_plan.md`
5. Return a summary of what changed

**After the subagent completes**, read the updated plan files and the `_devils_advocate.md` to prepare the recap for the user.

### Phase 6: Review with User

Present the refined plan along with what the devil's advocate changed:

> Here's the plan I've created for **{feature name}**:
>
> **Tasks:** {N} total
> **Parallel batches:** ~{estimate based on dependencies}
>
> | # | Task | Dependencies |
> |---|------|--------------|
> | 001 | {title} | none |
> | 002 | {title} | 001 |
> | ... | ... | ... |
>
> **Devil's Advocate Review**
>
> The plan was automatically stress-tested before presenting it to you. Here's what was refined:
>
> {summarize the Critical and Important changes that were applied, e.g.:}
> - Added missing dependency: task 005 now depends on 003 (shared interface needed)
> - Split task 008 into 008 and 009 (too large for single TDD cycle)
> - Added edge case requirements to task 004 (empty state handling)
> - Fixed method signature in task 012 (verified against source)
>
> {if there are Minor items or Questions from the review, list them:}
> **Items for your consideration:**
> - {Minor or Question items the user may want to weigh in on}
>
> Does this breakdown look correct? Would you like to:
> 1. Approve and proceed
> 2. Add/remove tasks
> 3. Adjust dependencies
> 4. Modify requirements for a specific task

Make adjustments based on feedback.

### Phase 7: Finalize

Once approved:

1. Update `_plan.md` status to `ready`
2. Confirm all task files are created
3. Output completion summary:

```
Plan created: {plan-name}

Location: .claude/plans/{plan-name}/
Total tasks: {N}
Independent tasks (batch 1): {count of tasks with no dependencies}
```

4. Ask the user if they want to start execution now:

> Ready to begin autonomous implementation?
>
> 1. **Yes, start now** - I'll trigger `plan-orchestrate` immediately
> 2. **No, I'll run it later** - Say "run the {plan-name} plan" anytime to start

5. If user chooses to start now:
   - Invoke the `plan-orchestrate` skill with the plan name to begin parallel execution
   - The orchestrator automatically uses ralph-wiggum if installed (warns if not)
   - Loops through all batches until complete

6. If user chooses later:
   - Confirm they can start anytime by saying "run the {plan-name} plan" or "execute the plan"
   - Note: ralph-wiggum is used automatically if installed
   - End the skill

## Writing Good Requirements

Requirements MUST be written as test descriptions. They should:

**Be specific and testable:**
- Good: `it returns 401 when authentication token is missing`
- Bad: `it handles authentication errors`

**Describe behavior, not implementation:**
- Good: `it sends welcome email after successful registration`
- Bad: `it calls EmailService.sendWelcome()`

**Cover edge cases explicitly:**
- Good: `it rejects passwords shorter than 8 characters`
- Bad: `it validates password`

**Be atomic (one assertion per requirement):**
- Good: `it stores user in database` + `it returns created user`
- Bad: `it stores user in database and returns it`

## Task Examples

### Example: User Model Task
```markdown
# Task 001: Create User Model

**Status**: pending
**Depends on**: none
**Retry count**: 0

## Description
Create the User Eloquent model with authentication fields and basic validation.

## Context
- Related files: app/Models/User.php (may exist, needs modification)
- Patterns to follow: Existing models in app/Models/

## Requirements (Test Descriptions)
- [ ] `it creates a user with email and password`
- [ ] `it hashes the password automatically when setting`
- [ ] `it validates email is required`
- [ ] `it validates email format is valid`
- [ ] `it validates email is unique`
- [ ] `it validates password minimum length is 8 characters`

## Acceptance Criteria
- All requirements have passing tests
- Migration exists for users table
- Model follows existing patterns
```

### Example: API Endpoint Task
```markdown
# Task 003: Create Registration Endpoint

**Status**: pending
**Depends on**: 001, 002
**Retry count**: 0

## Description
Create POST /api/register endpoint that creates new users and returns JWT token.

## Context
- Related files: routes/api.php, app/Http/Controllers/AuthController.php
- Patterns to follow: Existing API controllers

## Requirements (Test Descriptions)
- [ ] `it returns 201 with user data on successful registration`
- [ ] `it returns JWT token in response`
- [ ] `it returns 422 when email already exists`
- [ ] `it returns 422 when email format is invalid`
- [ ] `it returns 422 when password is too short`
- [ ] `it stores user in database on success`

## Acceptance Criteria
- All requirements have passing tests
- Route registered in api.php
- Uses form request for validation
```

## Error Handling

- If user provides vague requirements: Ask specific clarifying questions
- If dependencies create a cycle: Identify and ask user to resolve
- If tasks are too large: Suggest splitting with specific recommendations
- If plan seems incomplete: Ask about edge cases, error handling, security

## Output Format

Always end with the clear next steps showing how to execute the plan.
