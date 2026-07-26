# HCF (Halt and Catch Fire)

Autonomous development plugin for Claude Code. Define requirements with a PM, then let parallel workers implement everything using TDD.

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
  - [Installation](#installation)
  - [Quick Start](#quick-start)
- [How It Works](#how-it-works)
  - [Four Phases](#four-phases)
  - [Pipeline](#pipeline)
  - [Dependency Graph](#dependency-graph)
  - [Parallel Execution](#parallel-execution)
  - [TDD Methodology](#tdd-methodology)
- [Reference](#reference)
  - [Files Created](#files-created)
  - [Task Format](#task-format)
  - [Skills](#skills)
  - [Outputs](#outputs)
- [Architecture](#architecture)
- [Design Principles](#design-principles)
- [Development](#development)
  - [Local Testing](#local-testing)
  - [Testing Workflow](#testing-workflow)
  - [Debugging](#debugging)
- [Changelog](#changelog)
- [Contributing](#contributing)
- [License](#license)

## Overview

HCF separates **planning** (human-in-the-loop) from **execution** (fully autonomous):

```
Planning → Human + AI collaborate on requirements
Execution → Parallel TDD workers implement autonomously
```

## Getting Started

### Installation

Add the marketplace, install, then reload:

```bash
/plugin marketplace add markshust/hcf
/plugin install hcf@hcf
/reload-plugins
```

### Quick Start

#### 1. Setup Project (one-time)

```bash
/project-setup
```

Interactively configures your project:
- Auto-detects tech stack (Laravel, React, etc.)
- Asks about testing, linting, architecture
- Creates `.claude/` config directory

#### 2. Plan a Feature

Just describe what you want:

```
"Help me implement user authentication with JWT"
```

The `plan-create` skill activates automatically to:
- **Discover & brainstorm** — explore the codebase and enumerate scope/assumption permutations a senior engineer would catch
- Create a `feature/{plan-name}` branch for the work
- Ask grounded clarifying questions categorized as **must-answer** vs **will-default-if-silent**
- Break down into tasks with dependencies
- Write requirements as test descriptions
- Create `.claude/plans/user-auth/` with task files
- Run **post-plan pipeline** agents (devil's advocate by default) to find gaps before execution

After planning completes, you'll be asked:
> Ready to begin autonomous implementation?
> 1. Yes, start now
> 2. No, I'll run it later

#### 3. Execute Autonomously

If you chose "later" or want to re-run, say:

```
"Run the user-auth plan" or "Execute the plan"
```

The `plan-orchestrate` skill auto-triggers. It verifies you're on the correct `feature/{plan-name}` branch before starting, and **automatically uses ralph-wiggum** for session persistence if installed. If not installed, you'll see a warning but execution continues.

After completion, you'll be prompted to push the branch and create a PR (never done without your permission).

ralph-wiggum is prompted during `/project-setup`, or install manually:
```bash
/plugin marketplace add anthropics/claude-code
/plugin install ralph-wiggum@claude-code-plugins
```

## How It Works

### Four Phases

| Phase | Type | What Happens |
|-------|------|--------------|
| Setup | One-time | Configure project for autonomous dev |
| Planning | Interactive | Discover codebase, brainstorm scope, then define tasks with human guidance |
| Post-Plan Hooks | Automated | Agents enrolled at the `post-plan` hook review the plan |
| Execution | Autonomous | Parallel TDD implementation, with agents enrolled at the implementation hooks |

### Pipeline

The pipeline controls which agents run at fixed points in the plan/implementation flow. HCF uses **convention over configuration**: there is no central registry — each agent enrolls itself by declaring a `phase` in its own YAML frontmatter. If an agent declares a `phase`, it runs at that hook; if it has no `phase`, it never runs via a hook.

**Hook points:**

There are exactly **8** hook points where enrolled agents can run:

| Hook | Fires |
|------|-------|
| `pre-plan` | Before planning Discovery begins |
| `post-plan` | After the plan is built and validated, before user review |
| `pre-implementation` | Before the first implementation batch |
| `pre-batch` | Before each batch of TDD workers is spawned |
| `post-batch` | After each batch of TDD workers completes |
| `post-implementation` | After all tasks complete |
| `pre-commit` | After the full test suite passes, before the commit |
| `post-commit` | After the commit, before the push/PR prompt |

By default, only `devils-advocate` is enrolled (at `post-plan`). See **[HOOKS.md](HOOKS.md)** for the authoritative reference — the full frontmatter schema, the deterministic discovery routine, and tie-break/ordering rules.

**Enrollment frontmatter:**

An agent enrolls by adding three keys to its frontmatter:

```yaml
---
name: devils-advocate
description: "..."
model: opus
tools: Read, Write, Edit, Glob, Grep
# --- hook enrollment ---
phase: post-plan   # one of the 8 hook points above
order: 10          # lower runs first within a hook; default 100
mode: single       # "single" | "batch"; default "single"
---
```

**Customizing the pipeline:**

Enable, add, remove, or reorder agents by editing frontmatter — never a central file.

- **Enable a built-in agent.** `standards-enforcer` ships with its enrollment commented out. Uncomment its `phase` (and optional `order` / `mode`) to turn it on:

  ```yaml
  ---
  name: standards-enforcer
  description: "..."
  model: opus
  tools: Read, Edit, Glob, Grep
  # To enable code-standards enforcement after implementation, uncomment:
  phase: post-implementation
  order: 50
  mode: batch
  ---
  ```

- **Add a custom gate.** Drop an agent file into your project's `.claude/agents/` directory with a `phase`, and it is enrolled automatically:

  ```markdown
  ---
  name: doc-updater
  description: "Updates documentation when implementation changes."
  model: sonnet
  tools: Read, Edit, Glob, Grep
  phase: post-implementation
  order: 100
  mode: single
  ---

  You are a documentation updater. Your job is to...
  {define the agent's behavior, process, and output format}
  ```

- **Disable an agent.** Remove (or comment out) its `phase` key — there is no condition to toggle.

The agent's **filename** (without `.md`) should match its frontmatter `name`. Local agents in `.claude/agents/` override plugin agents with the same `name` (the local file wins entirely) — the override is keyed on the frontmatter `name`, not the filename.

**Check what's actually enrolled.** After editing frontmatter, run the discovery script to confirm it took effect. This is the first thing to try when an agent doesn't fire:

```bash
$(claude plugin path hcf)/hooks/discover-hooks.sh
```

```
# hook: pre-plan
  (empty — no agents enrolled at this hook)

# hook: post-plan
  order=10    name=devils-advocate                          mode=single
...
```

Add `--hook=post-plan` for one hook, or `--json` for machine-readable output. HCF's planning skills run this exact script rather than enumerating agent files themselves, so what it prints is what will run.

A **non-zero exit means discovery genuinely failed** — it is not the same as a hook being empty. Exit `3` means an agent file declares an invalid `phase` or `mode` (the message names the file and the fix); exit `4` means enrollment changed partway through a run. Both halt HCF deliberately, rather than quietly running a different pipeline than you configured.

> **Upgrading from `pipeline.md`:** Earlier versions of HCF configured the pipeline in a central `.claude/pipeline.md` file. That file is **no longer read** — agent frontmatter is now the only source of pipeline configuration. If a leftover `.claude/pipeline.md` is present, HCF **blocks `plan-create` and `plan-orchestrate`** (you'll see a prompt on session start and when you try to plan) until you run **`/project-update`**, which migrates your configuration into agent frontmatter and removes the file. `/project-update` is never blocked, and the gate clears automatically once the file is gone.

### Dependency Graph

After generating a plan, HCF visualizes the task dependency graph so you can verify parallelism and ordering before execution:

```
001 ─┬─► 002 ─┬─► 005
     │        │
     └─► 003 ─┘
     │
     └─► 004 ────► 006
```

This tells the orchestrator which tasks can run in parallel and which must wait. In this example:
- **Batch 1:** Task 001 (no dependencies)
- **Batch 2:** Tasks 002, 003, 004 (all depend only on 001)
- **Batch 3:** Tasks 005, 006 (005 depends on 002+003; 006 depends on 004)

### Parallel Execution

Independent tasks within each batch run simultaneously:

```
Batch 1: Task 001 (no deps)          → 1 worker
Batch 2: Tasks 002, 003, 004         → 3 parallel workers
Batch 3: Tasks 005, 006              → 2 parallel workers
```

100 tasks might complete in 5-10 batches instead of 100 sequential runs.

### TDD Methodology

Each task follows strict Red → Green → Refactor:

1. Write failing test for one requirement
2. Write minimum code to pass
3. Refactor while tests stay green
4. Repeat for next requirement
5. Commit when task complete

## Reference

### Files Created

#### Project Config (`.claude/`)

| File | Purpose |
|------|---------|
| `testing.md` | Test commands, coverage requirements |
| `code-standards.md` | Linting, formatting rules |
| `architecture.md` | Directory structure, patterns |

#### Plans (`.claude/plans/{name}/`)

| File | Purpose |
|------|---------|
| `_plan.md` | Plan overview, task table |
| `001-{task}.md` | First task with requirements |
| `002-{task}.md` | Second task |
| ... | More tasks |

### Task Format

```markdown
# Task 001: Create User Model

**Status**: pending
**Depends on**: none
**Retry count**: 0

## Description
Create the User model with authentication fields.

## Requirements (Test Descriptions)
- [ ] `it creates a user with valid email and password`
- [ ] `it hashes the password before storing`
- [ ] `it validates email uniqueness`
```

Requirements become test names directly.

### Skills

All skills can be invoked directly with `/skill-name` or triggered automatically by Claude when your request matches their description.

| Skill | Invocation | Auto-triggers | Description |
|-------|------------|---------------|-------------|
| `project-setup` | `/project-setup` | No | Configure project (one-time) |
| `project-update` | `/project-update` | No | Sync config with latest plugin defaults |
| `plan-create` | `/plan-create [description]` | Yes — "Build a...", "Let's start building...", "I want an app that...", "Help me implement...", capability lists, etc. | Interactive planning with codebase discovery and grounded clarification |
| `plan-orchestrate` | `/plan-orchestrate [plan-name]` | Yes — "Run the plan", "Execute", "Start implementation" | Parallel TDD execution |

### Outputs

| Output | Meaning |
|--------|---------|
| `ALL_TASKS_COMPLETE` | Plan finished successfully |
| `TASKS_BLOCKED: [003, 007]` | Some tasks failed after retries |

## Architecture

```
hcf/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── agents/
│   ├── devils-advocate.md    # Plan reviewer - finds gaps before execution (opus)
│   ├── tdd-worker.md         # TDD implementation worker (sonnet)
│   └── standards-enforcer.md # Code standards enforcement (sonnet)
├── hooks/
│   ├── discover-hooks.sh     # Deterministic hook-agent discovery (see HOOKS.md)
│   ├── detect-legacy-pipeline.sh # SessionStart warning for a legacy pipeline.md
│   ├── gate-skill.sh         # PreToolUse gate on the planning skills
│   ├── gate-command.sh       # UserPromptExpansion gate on the planning skills
│   ├── pipeline-status.sh    # Shared helper sourced by the gates
│   └── hooks.json            # Lifecycle hook registrations
├── skills/
│   ├── project-setup/
│   │   └── SKILL.md          # One-time setup skill (manual invocation only)
│   ├── project-update/
│   │   └── SKILL.md          # Sync project config with plugin updates (manual)
│   ├── plan-create/
│   │   └── SKILL.md          # Interactive planning skill (auto-triggers)
│   └── plan-orchestrate/
│       └── SKILL.md          # Parallel TDD execution skill (auto-triggers)
├── tests/
│   ├── run-tests.sh          # Test suite entry point (no dependencies)
│   ├── lib.sh                # Assertions and fixture helpers
│   ├── test-*.sh             # Suites, auto-discovered by run-tests.sh
│   └── fixtures/             # Agent files exercising parser edge cases
├── .claude/
│   └── CLAUDE.md             # HCF's own project config (not shipped to users)
├── HOOKS.md                  # Authoritative hook/frontmatter reference
└── README.md
```

The `CLAUDE.md` template that `/project-setup` generates for **your** project
lives inline in `skills/project-setup/SKILL.md` — `.claude/CLAUDE.md` above is
this repo's own config and has no effect on what users get.

## Design Principles

1. **Pure TDD** - No Gherkin/BDD, requirements map directly to test names
2. **Parallel by default** - Auto-detect independent tasks, maximize concurrency
3. **100% portable** - the generated CLAUDE.md is identical across all projects
4. **Explicit dependencies** - Tasks declare what they depend on
5. **Fail gracefully** - Retry 3x, then block and continue with other tasks

## Development

### Requirements

- Claude Code CLI
- Git repository
- Test framework configured in project

### Local Testing

Test the plugin locally without publishing using the `--plugin-dir` flag:

```bash
claude --plugin-dir /path/to/hcf
```

Skills are namespaced with the plugin name:
- `/hcf:project-setup`
- `/hcf:plan-create [description]`
- `/hcf:plan-orchestrate [plan-name]`

Skills with `disable-model-invocation: true` (like `project-setup`) require manual invocation. Others auto-trigger based on their descriptions.

### Testing Workflow

1. **Start Claude Code with the plugin:**
   ```bash
   cd ~/Sites/your-test-project
   claude --plugin-dir ~/Sites/hcf
   ```

2. **Verify plugin loads:**
   ```
   /help
   ```
   Skills should appear under the `hcf` namespace.

3. **Test each component:**
   ```bash
   # Test project setup (direct invocation only)
   /hcf:project-setup

   # Test plan-create (auto-triggers on feature requests, or invoke directly)
   "Create a plan to implement user authentication"
   /hcf:plan-create user authentication with JWT

   # Test plan-orchestrate (auto-triggers on execution requests, or invoke directly)
   "Run the user-auth plan"
   /hcf:plan-orchestrate user-auth
   ```

### Debugging

Run with debug output to see plugin loading details:

```bash
claude --plugin-dir ./hcf --debug
```

To load multiple plugins:

```bash
claude --plugin-dir ./hcf --plugin-dir ./other-plugin
```

**Plugin Structure Notes:**
- Only `plugin.json` goes in `.claude-plugin/`
- Skills, agents, and other components stay at the plugin root level
- Each skill is a directory with a `SKILL.md` entrypoint
- Skills auto-trigger based on their `description` frontmatter (unless `disable-model-invocation: true`)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history. New user-visible changes are added to the `[Unreleased]` section as they land and moved into a versioned section at release time.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test locally with `--plugin-dir`
4. Add an entry to the `[Unreleased]` section of `CHANGELOG.md` if your change is user-visible
5. Submit a pull request

## Credits

Created by [Mark Shust](https://markshust.com)

## License

HCF is open-source software licensed under the [MIT License](LICENSE).
