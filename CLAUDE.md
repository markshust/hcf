# {Project Name}

{Brief 1-2 sentence description of the project.}

## Core Principles

{List 3-5 key principles that guide development in this project. These should be always-true rules that affect how code is written.}

## Commands

```bash
# Run tests
{test command, always with parallel flag if exists}

# Lint/format
{lint command}

# Start dev server (assume already running)
{start command}
```

## Key Conventions

{5-10 bullet points of critical coding rules that apply to all work in this project.}

## Feature Development

For simple fixes and quick changes, use TDD (when at all possible).

For any feature or request beyond simple ones, use the `hcf:plan-create` skill to trigger the autonomous development workflow. NEVER use Claude Code's built-in plan mode. After writing a plan, ask user if they would like to execute it. Also provide the command to run it later with the `hcf:plan-orchestrate` skill.

Use this workflow for new features, multi-file changes, or anything requiring multiple steps or tests.

## Project Details

{Include exact format below with XML tag and @ includes.}

<testing>
@.claude/testing.md
</testing>

<code-standards>
@.claude/code-standards.md
</code-standards>
