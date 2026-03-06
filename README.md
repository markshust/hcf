# HCF (Halt and Catch Fire)

Autonomous development plugin for Claude Code. Define requirements with a PM, then let parallel workers implement everything using TDD.

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
  - [Installation](#installation)
  - [Quick Start](#quick-start)
- [How It Works](#how-it-works)
  - [Three Phases](#three-phases)
  - [Parallel Execution](#parallel-execution)
  - [TDD Methodology](#tdd-methodology)
- [Reference](#reference)
  - [Files Created](#files-created)
  - [Task Format](#task-format)
  - [Commands](#commands)
  - [Skills](#skills)
  - [Outputs](#outputs)
- [Architecture](#architecture)
- [Design Principles](#design-principles)
- [Development](#development)
  - [Local Testing](#local-testing)
  - [Testing Workflow](#testing-workflow)
  - [Debugging](#debugging)
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

```bash
/plugin install hcf
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
- Ask clarifying questions about requirements
- Break down into tasks with dependencies
- Write requirements as test descriptions
- Create `.claude/plans/user-auth/` with task files
- Run a **devil's advocate** review to find gaps and issues before execution

After planning completes, you'll be asked:
> Ready to begin autonomous implementation?
> 1. Yes, start now
> 2. No, I'll run it later

#### 3. Execute Autonomously

If you chose "later" or want to re-run, say:

```
"Run the user-auth plan" or "Execute the plan"
```

The `plan-orchestrate` skill auto-triggers and **automatically uses ralph-wiggum** for session persistence if installed. If not installed, you'll see a warning but execution continues.

ralph-wiggum is prompted during `/project-setup`, or install manually:
```bash
/plugin marketplace add anthropics/claude-code
/plugin install ralph-wiggum@anthropics-claude-code
```

## How It Works

### Three Phases

| Phase | Type | What Happens |
|-------|------|--------------|
| Setup | One-time | Configure project for autonomous dev |
| Planning | Interactive | Define tasks with human guidance |
| Review | Automated | Devil's advocate finds gaps in the plan |
| Execution | Autonomous | Parallel TDD implementation |

### Parallel Execution

Independent tasks run simultaneously:

```
Batch 1: Tasks 001, 002, 003 (no deps) → 3 parallel workers
Batch 2: Tasks 004, 005 (depend on batch 1) → 2 parallel workers
Batch 3: Task 006 (depends on 004, 005) → 1 worker
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
| `project-overview.md` | Project name, tech stack |
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

### Commands

| Command | Description |
|---------|-------------|
| `/project-setup` | Configure project (one-time) |

### Skills

| Skill | Trigger | Description |
|-------|---------|-------------|
| `plan-create` | "Help me implement...", "Build a...", etc. | Interactive planning |
| `plan-orchestrate` | "Run the plan", "Execute", "Start implementation" | Parallel TDD execution |

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
├── commands/
│   └── project-setup.md      # One-time setup command
├── skills/
│   ├── plan-create/
│   │   └── SKILL.md          # Interactive planning skill
│   └── plan-orchestrate/
│       └── SKILL.md          # Parallel TDD execution skill
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

Commands are namespaced with the plugin name:
- `/hcf:project-setup`

Skills auto-trigger based on their descriptions.

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
   Commands and skills should appear under the `hcf` namespace.

3. **Test each component:**
   ```bash
   # Test project setup (command)
   /hcf:project-setup

   # Test plan-create skill (auto-triggers on feature requests)
   "Create a plan to implement user authentication"

   # Test plan-orchestrate skill (auto-triggers on execution requests)
   "Run the user-auth plan" or "Execute the plan"
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
- Commands, skills, and other components stay at the plugin root level
- Skills auto-trigger based on patterns defined in `SKILL.md`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test locally with `--plugin-dir`
4. Submit a pull request

## License

MIT
