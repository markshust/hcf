---
name: plan-create
description: Create structured implementation plans for autonomous TDD development. Use for new features, multi-file changes, or anything requiring multiple steps or tests. Triggers on aspirational openers ("let's build", "let's start building", "I want to make", "I want an app that", "help me build"), capability lists ("users should be able to X, Y, Z"), vague-noun patterns ("a system for", "a way to", "an app that", "functionality for"), and explicit build verbs ("build", "create", "add a feature", "help me implement", "I need to build"). Do NOT use this for "implement the plan" or "run the plan" - those should use plan-orchestrate instead. Skip for quick bug fixes, single-line changes, questions, or documentation.
argument-hint: "[feature description]"
---

# Plan Create

Transform feature requests into structured plans with task breakdowns, dependencies, and TDD requirements for parallel autonomous execution.

## Project Architecture

<architecture>
@.claude/architecture.md
</architecture>

## Execution Flow

### Phase 0: Pre-plan hook

Run this once, at the very start, before Phase 1 discovery.

**Run the `pre-plan` hook.**

Run the discovery script — never enumerate agent files by hand:

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --hook=pre-plan
```

`{skill-base-dir}` is the **`Base directory for this skill`** value stated when this skill loaded. `${CLAUDE_PLUGIN_ROOT}` is not available in a skill's Bash calls.

- **Exit 0, empty stdout** → empty hook. This is the default. Return immediately: print nothing, spawn nothing, say nothing about the hook at all, and proceed to Phase 1. Do **not** narrate that the script returned no agents — that is the narration `HOOKS.md` forbids.
- **Exit 0, output** → **print the output verbatim** as the resolved agent order, then spawn each listed agent in order per its `mode`.
- **Any non-zero exit** → **stop**. Surface the script's stderr verbatim and do not continue planning. Exit 3 means an agent file declares an invalid `phase` or `mode`; exit 4 means enrollment drifted. Neither is an empty hook. If the script is missing or not executable, that is also a hard stop — there is no fallback, and you must not reconstruct the routine by hand.

**Capture the enrollment fingerprint** now, for Phase 6's drift check:

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --fingerprint
```

Hold that value. **A fingerprint is only ever produced by running the script** — never reconstruct, abbreviate, or recall one from memory. If it is not to hand at Phase 6, re-run the command and say so. A hallucinated digest makes every later check fail with bogus drift and bricks the plan.

**IMPORTANT — no plan name exists yet.** The `pre-plan` hook fires *before* Phase 1 discovery. The plan name and plan directory are not created until Phase 3, so there is **no plan name to pass**. Each `pre-plan` agent receives only:
1. The raw feature request (the user's verbatim ask).
2. The project's architecture context:

```
## Project Architecture
{paste the COMPLETE content of <architecture> verbatim}
```

Do **not** attempt to pass a plan name or plan directory to a `pre-plan` agent — neither exists yet. The `pre-plan` hook is thin by design (policy gate / house-context injection).

### Phase 1: Discovery & Assumption Brainstorm

Approach this phase like a solution architect meeting with a client to flush out scope and requirements. Your job is not to ask everything — it's to think hard about the shape of the solution before asking grounded questions. Find the integration points, then enumerate the design axes the user probably hasn't thought about.

**Quick scope check first.** If the ask already specifies data model, scope boundaries, and integration points (e.g., "Add an `email_verified_at` column to users and a `SendVerificationEmail` job"), do a brief existence-check (do the named files/models exist?) and skip ahead to Phase 2 — the brainstorm below is for under-specified asks.

**1. Codebase discovery**

Read files specifically related to the ask. Architecture context is already loaded via the `<architecture>` block at the top of this skill — do not re-read `.claude/architecture.md`. Instead:
- Glob for domain-related files (e.g., for "track books", look for `book*`, `*Book*`, library/reading-list files)
- Read existing models, controllers, or components that overlap with the ask
- Note existing patterns the new feature must conform to or extend
- Identify what's already built vs. greenfield

**2. Permutation & assumption brainstorm**

For each noun and verb in the ask, enumerate plausible interpretations. Then enumerate the **hidden axes** — design decisions the user almost certainly hasn't specified but the implementer needs to know. Surface the non-obvious ones a senior engineer would catch and a junior would miss.

Focus on permutations that meaningfully change **scope, data model, or architecture**. Avoid minutiae (button colors, naming bikesheds, trivial config defaults).

Example for "track books I'm reading":
- **Book schema**: title only? +author/ISBN/cover/genre/pages/publication date?
- **List structure**: one global list, or multiple states ("want to read", "reading", "finished")?
- **"Finished" semantics**: boolean state, dated event, or reversible?
- **Hidden axes the ask didn't mention**: auth/multi-user, persistence layer, edit/delete operations, search/filter/sort, ratings/notes, web vs mobile UI, external lookups (ISBN APIs).

**3. Diff against codebase**

Produce a short "what I found vs. what you asked" comparison. Examples:
- "You have a `User` model with auth — books would extend it for per-user lists"
- "No models exist yet — this is greenfield"
- "Your existing controllers follow a `ResourceController` pattern; book routes would conform"

**Issue Detection:** If the user references a GitHub issue (e.g., "#18", "issue 18", a GitHub issue URL), capture it for the `## Related Issues` field in `_plan.md`. Use `Closes #N` for issues that will be fully resolved by this plan, or `Relates to #N` for partial/tangential references. If no issue is mentioned, set the field to "none".

### Phase 2: Grounded Clarification

Surface findings to the user, then ask categorized questions. The goal is to flush out enough to write a confident plan — like a solution architect leaving a client meeting with the spec they need.

**Format your response so users can skim past findings if they want — the Questions section must be self-sufficient.**

Present in this order:

> **What I Found**
> - {codebase findings: existing models, patterns, integration points, greenfield vs. extension}
>
> **Key Permutations to Resolve**
> {1-3 sentences naming the design axes that meaningfully shape scope/data model/architecture, derived from the brainstorm}
>
> **Questions**
>
> *Must answer (these shape scope, data model, or architecture):*
> 1. {scope-shaping question}
> 2. {data-model question}
> 3. {integration question}
>
> *Will default if you don't specify (defaults stated):*
> - {dimension}: {proposed default}
> - {dimension}: {proposed default}

**Question quality guidance:**
- No hard cap on count — some plans need many questions, some need few. Ask as many as warranted.
- Stay focused on **scope, data model, integration, and architecture**. Skip minutiae (UI colors, exact field names, naming bikesheds, trivial config).
- Each "must answer" should be a decision that, if assumed wrong, would force a rewrite. Each "will default" should be safe to assume with a stated default the user can override.
- If the Phase 1 quick scope check determined the ask was already concrete, skip to Phase 3 with no questions asked.

### Phase 3: Define the Plan

Once you understand the requirements, create the plan overview:

**Create feature branch:**
```bash
git checkout -b feature/{plan-name}
```

If the branch already exists (resuming a plan), check it out instead:
```bash
git checkout feature/{plan-name}
```

**Create plan directory:**
```bash
mkdir -p .claude/plans/{plan-name}
```

Use a kebab-case name derived from the feature (e.g., `user-authentication`, `payment-processing`).

**Record the enrollment fingerprint** so `plan-orchestrate` can detect that hook enrollment changed between planning and execution. Write it by **redirecting a fresh invocation** — do not re-type the value captured at Phase 0:

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --fingerprint > .claude/plans/{plan-name}/.hook-fingerprint
```

The file holds exactly that one line and nothing else — no heading, no comment, no explanation. Writing it as a redirect rather than transcribing a remembered value is deliberate: Phases 1–2 are a long interactive stretch, and a value carried across them is exactly what gets lost and then invented.

**Create `_plan.md`:**
```markdown
# Plan: {Feature Name}

## Created
{date}

## Status
planning | ready | in_progress | completed | blocked

## Objective
{1-2 sentence description of what this plan achieves}

## Related Issues
{list of GitHub issue references, e.g., "Closes #18", "Relates to #42", or "none"}

## Discovery Notes
{Brief summary of Phase 1 findings: existing models/patterns to extend, integration points, greenfield vs. existing code, key assumptions resolved during clarification. Captures context for future readers and resumed sessions.}

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

### Phase 4: Break Down into Tasks

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

### Phase 5: Validate Dependencies

After creating all tasks, verify:
1. No circular dependencies exist
2. Task 001 has no dependencies (or minimal bootstrap)
3. Dependencies form a valid DAG (Directed Acyclic Graph)
4. Maximum parallelism is achieved
5. All context exists to complete all tasks autonomously (if not, revisit Phase 2 for additional clarifying questions)

**Dependency Visualization:**
Show the user a simple dependency tree:
```
001 ─┬─► 002 ─┬─► 005
     │        │
     └─► 003 ─┘
     │
     └─► 004 ────► 006
```

### Phase 6: Run the `post-plan` Hook

After validating dependencies, resolve and run the agents enrolled at the `post-plan` hook.

**1. Resolve `post-plan` agents.**

Run the discovery script, passing the fingerprint captured at Phase 0 so a mid-planning change to agent files is caught:

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --hook=post-plan --expect="<phase-0 fingerprint>"
```

Never enumerate agent files by hand. If the Phase 0 value is not to hand, re-run `--fingerprint` to get a current one rather than inventing a digest.

**2. Empty-hook fast path.**

**Exit 0 with empty stdout** is an empty hook: **return immediately** — print nothing, spawn nothing, do no work, say nothing about the hook — and proceed to Phase 7. (No agent declaring `phase: post-plan` is a valid, clean configuration.) Do not narrate that the script returned no agents.

**3. Print the resolved agent order.**

On **exit 0 with output**, **PRINT that output verbatim** before spawning anything, so the run is auditable.

**On any non-zero exit, stop.** Surface the script's stderr verbatim and do not proceed to Phase 7. Exit 3 means an agent file declares an invalid `phase` or `mode`; exit 4 means enrollment changed since Phase 0 — the plan directory already holds a current fingerprint, so re-running `plan-create` proceeds cleanly. A missing or non-executable script is a hard stop with no fallback.

**4. Spawn each agent in the resolved order**, sequentially:

Use the Agent tool with `subagent_type="{agent-name}"`. The subagent prompt **must** include:
1. The plan name (so it knows the plan directory path).
2. The project's architecture context, pasted verbatim — do **not** summarize:

```
## Project Architecture
{paste the COMPLETE content of <architecture> verbatim}
```

**5. After each subagent completes**, read any updated plan files to prepare the recap for the user.

Agents enroll in `post-plan` by declaring `phase: post-plan` in their own frontmatter (see `HOOKS.md`). There is no hardcoded default list here — for example, `devils-advocate` participates because it declares `phase: post-plan` in its frontmatter, not because plan-create names it. To add, remove, or reorder agents at this hook, edit their frontmatter `phase`/`order` (or override a plugin agent with a local `.claude/agents` file of the same `name`).

### Phase 7: Review with User

Present the refined plan along with a summary of whatever `post-plan` agents actually ran in Phase 6.

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

**If one or more `post-plan` agents ran**, include a review section that summarizes what *those specific agents* changed. Title it after the agents that ran (e.g. "Post-Plan Review by {agent names that ran}"), and attribute the changes to the agent that made them. Do **not** assume a single fixed reviewer or hardcode "devil's advocate" — render whatever the resolved Phase 6 hook produced:

> **Post-Plan Review** ({names of agents that ran})
>
> The plan was reviewed by the agents enrolled at the `post-plan` hook. Here's what each refined:
>
> {for each agent that ran, summarize its changes, e.g.:}
> - Added missing dependency: task 005 now depends on 003 (shared interface needed)
> - Split task 008 into 008 and 009 (too large for single TDD cycle)
> - Added edge case requirements to task 004 (empty state handling)
> - Fixed method signature in task 012 (verified against source)
>
> {if there are deferred items from any agent, list them:}
> **Items for your consideration:**
> - {Items the user may want to weigh in on}

**If no `post-plan` agents ran** (the hook was empty), omit the "Post-Plan Review" section entirely — do not print an empty heading or any "reviewed by" line. Present the plan table and go straight to the approval prompt below.

Then, in all cases, ask:

> Does this breakdown look correct? Would you like to:
> 1. Approve and proceed
> 2. Add/remove tasks
> 3. Adjust dependencies
> 4. Modify requirements for a specific task

Make adjustments based on feedback.

### Phase 8: Finalize

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
