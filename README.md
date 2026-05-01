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
- [Learn the Workflow](#learn-the-workflow)
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
| Post-Plan Pipeline | Automated | Configurable agents review the plan |
| Execution | Autonomous | Parallel TDD implementation + post-implementation pipeline |

### Pipeline

The pipeline system controls which agents run before and after the core TDD implementation. It's configured in `.claude/pipeline.md`:

```markdown
# Pipeline

## post-plan
- devils-advocate

## post-implementation
<!-- - standards-enforcer -->
```

**Phases:**

| Phase | When | Default Agent |
|-------|------|---------------|
| `post-plan` | After plan creation, before user review | `devils-advocate` |
| `post-implementation` | After all TDD workers complete, before commit | none (`standards-enforcer` available, off by default) |

**Customizing the pipeline:**

Add, remove, or reorder agents at any phase. For example, to add a custom `security-reviewer` to post-plan, enable the built-in `standards-enforcer` (off by default), and add a custom `doc-updater` to post-implementation:

```markdown
# Pipeline

## post-plan
- devils-advocate
- security-reviewer

## post-implementation
- standards-enforcer
- doc-updater
```

**Creating custom agents:**

Create a markdown file in your project's `.claude/agents/` directory:

```
.claude/agents/doc-updater.md
```

The agent file follows the standard Claude Code agent format with frontmatter:

```markdown
---
name: doc-updater
description: "Updates documentation when implementation changes."
model: sonnet
tools: Read, Edit, Glob, Grep
---

You are a documentation updater. Your job is to...
{define the agent's behavior, process, and output format}
```

The agent name in `pipeline.md` must match the agent's filename (without `.md`). Local agents in `.claude/agents/` override plugin agents with the same name.

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
| `pipeline.md` | Workflow agent configuration |

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
├── skills/
│   ├── project-setup/
│   │   └── SKILL.md          # One-time setup skill (manual invocation only)
│   ├── project-update/
│   │   └── SKILL.md          # Sync project config with plugin updates (manual)
│   ├── plan-create/
│   │   └── SKILL.md          # Interactive planning skill (auto-triggers)
│   └── plan-orchestrate/
│       └── SKILL.md          # Parallel TDD execution skill (auto-triggers)
├── pipeline.md               # Default pipeline configuration
├── CLAUDE.md                 # Portable CLAUDE.md template for projects
└── README.md
```

## Design Principles

1. **Pure TDD** - No Gherkin/BDD, requirements map directly to test names
2. **Parallel by default** - Auto-detect independent tasks, maximize concurrency
3. **100% portable** - CLAUDE.md identical across all projects
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

## Learn the Workflow

HCF is the running case study in my [AI Workflow Cohort](https://shu.st/4kYuIy), a 5-week program to learn how to architect custom workflows for AI-assisted development.

## License

HCF is open-source software licensed under the [MIT License](LICENSE).
