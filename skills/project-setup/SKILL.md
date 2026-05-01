---
name: project-setup
description: One-time interactive setup to configure a project for autonomous development. Use when setting up a new project for TDD-based autonomous development with HCF.
disable-model-invocation: true
---

One-time interactive setup to configure a project for autonomous development.

## Purpose

Create `CLAUDE.md` and all project configuration files in `.claude/` through an interactive process with auto-detection.

## Execution Steps

### Step 1: Check for Existing Configuration

First, check if configuration already exists:

```bash
ls CLAUDE.md .claude/testing.md .claude/code-standards.md .claude/architecture.md .claude/pipeline.md 2>/dev/null
```

If CLAUDE.md and all 4 config files exist, inform the user:
> Project already configured. CLAUDE.md and config files exist in `.claude/`. To reconfigure, delete CLAUDE.md and `.claude/` then run `/project-setup` again.

Otherwise, continue with setup.

### Step 2: Auto-Detect Project Type

Scan the project root for configuration files to detect the tech stack:

**Check for these files (in parallel):**
- `composer.json` → PHP/Laravel/Symfony
- `package.json` → Node.js/React/Vue/Next.js
- `Cargo.toml` → Rust
- `go.mod` → Go
- `pyproject.toml` or `requirements.txt` → Python
- `Gemfile` → Ruby/Rails
- `pom.xml` or `build.gradle` → Java
- `*.csproj` or `*.sln` → .NET

**For each detected file, extract:**
- Framework and version
- Testing framework (from devDependencies or test config)
- Linting/formatting tools

**Example auto-detection output:**
```
Detected project configuration:
- Framework: Laravel 11 (from composer.json)
- PHP Version: 8.3
- Testing: Pest PHP (from composer.json require-dev)
- Linting: Laravel Pint (from composer.json require-dev)
```

### Step 3: Confirm Detection

Ask user to confirm detected configuration:
> I detected the following. Is this correct? (y/n)
> [Show detected config]

If incorrect, ask clarifying questions about each incorrect item.

### Step 4: Gather Additional Information

Ask these questions (skip if already detected):

**Q1: Test Command**
> What command runs your tests?
> Detected: `./vendor/bin/pest` [Enter to confirm or type custom]

**Q1b: Parallel Test Command**
> Does your test runner support parallel execution? If so, what's the command?
> (e.g., `./vendor/bin/pest --parallel`, `npm test -- --parallel`, `pytest -n auto`, `go test ./... -parallel 4`)
> [Enter detected parallel command, type custom, or 'none' if not supported]

Auto-detect hints:
- `composer.json` has `brianium/paratest` or `pestphp/pest` → suggest `{test command} --parallel`
- `package.json` has `jest` → suggest `{test command} --runInBand` is serial, default is already parallel
- `package.json` has `vitest` → already parallel by default
- `pytest` with `pytest-xdist` → suggest `pytest -n auto`
- `go test` → suggest `go test ./... -parallel {num}`
- `cargo test` → already parallel by default

**Q2: Lint Command**
> What command runs your linter?
> Detected: `./vendor/bin/pint` [Enter to confirm or type custom]

**Q3: Architectural Patterns**
> Which patterns does this project use? (select all that apply)
> - [ ] Repository pattern
> - [ ] Service classes
> - [ ] Form requests / DTOs
> - [ ] Event sourcing
> - [ ] CQRS
> - [ ] Other (specify)

**Q4: Code Standards**
> Any specific coding standards or style guides?
> Detected: PSR-12 [Enter to confirm or specify]

**Q5: Coverage Requirements**
> Minimum test coverage percentage? (e.g., 80)
> Default: 80

### Step 5: Open-Ended Project Dump

Offer the user a chance to provide additional context:

> **Tell me anything else about your project I should know.**
>
> You can paste:
> - README content
> - Architecture decisions
> - Naming conventions
> - Special requirements
> - Team preferences
>
> (Paste below, then type 'done' on a new line when finished, or 'skip' to skip)

Parse the dump for:
- Directory structure descriptions
- Naming conventions
- Special patterns or rules
- Integration details

### Step 6: Create Configuration Files

Create the `.claude/` directory and all config files:

```bash
mkdir -p .claude
```

**Add `.claude/ralph-loop.local.md` to `.gitignore`:**

Check if `.gitignore` exists and whether it already contains the entry. If not, append it:

```bash
# Ensure ralph-wiggum local state is gitignored
grep -qxF '.claude/ralph-loop.local.md' .gitignore 2>/dev/null || echo '.claude/ralph-loop.local.md' >> .gitignore
```

> **Note**: The templates below show the minimum required sections. Expand each file with additional relevant details based on project complexity. For example, a framework project might include extensive architecture docs, while a simple app might stick closer to the minimum.

**Create `.claude/testing.md`:**
```markdown
# Testing Configuration

## Test Framework
{detected framework}

## TDD Methodology

Each task follows strict Red → Green → Refactor:

1. Write failing test for one requirement
2. Write minimum code to pass
3. Refactor while tests stay green
4. Repeat for next requirement
5. Commit when task complete

## Commands
\`\`\`bash
# Run all tests (parallel)
{parallel test command, or test command if parallelism not supported}

# Run all tests (sequential, for debugging failures)
{test command}

# Run specific test file
{test command} {path placeholder}

# Run with coverage
{test command with coverage flag}
\`\`\`

## Parallel Execution
- **Default**: Always run tests in parallel unless debugging a specific failure
- Parallel command: `{parallel test command}`
- Sequential fallback: `{test command}` (use only when parallel causes flaky failures)

## Test File Locations
- Unit tests: `{detected or standard path}`
- Feature/Integration tests: `{detected or standard path}`

## Coverage Requirements
- Minimum: {specified}%
- New code must have tests

## Test Naming Convention
- Test files: `{Convention}Test.php` or `{convention}.test.ts`
- Test methods: `it {does something}` or `test {something}`
```

*Optional expansions: Testing principles, framework-specific features, common test patterns, mocking strategies, CI configuration.*

**Create `.claude/code-standards.md`:**
```markdown
# Code Standards

## Style Guide
{detected or specified - e.g., PSR-12, Airbnb, StandardJS}

## Linting
\`\`\`bash
# Check for issues
{lint check command}

# Auto-fix issues
{lint fix command}
\`\`\`

## Formatting
\`\`\`bash
{format command if different from lint}
\`\`\`

## Pre-commit Checks
- Run linter before commits
- All tests must pass
- {any additional checks}

## Naming Conventions
- Classes: {PascalCase}
- Methods: {camelCase}
- Variables: {camelCase}
- Constants: {SCREAMING_SNAKE_CASE}
- Files: {convention}
```

*Optional expansions: Code structure rules, attribute/decorator standards, documentation standards, pre-commit hooks, code review checklist.*

**Create `.claude/architecture.md`:**
```markdown
# Architecture

## Directory Structure
{Map out the key directories and their purposes}

Example:
- `app/Models/` - Eloquent models
- `app/Services/` - Business logic services
- `app/Http/Controllers/` - HTTP request handlers
- `app/Http/Requests/` - Form request validation
- `tests/Unit/` - Unit tests (mirror app/ structure)
- `tests/Feature/` - Integration/feature tests

## Patterns Used
{List from user selection}
- Repository pattern: {yes/no + brief description}
- Service classes: {yes/no + brief description}
- etc.

## Conventions
{From user dump or defaults}
- One class per file
- Tests mirror source structure
- {any other conventions}

## Key Integrations
{If mentioned in dump}
```

*Optional expansions: DI/IoC details, plugin/extension system, event system, routing, configuration, bootstrap process, error handling, versioning strategy.*

**Create `.claude/pipeline.md`:**

Copy the default `pipeline.md` from the HCF plugin into the project's `.claude/` directory. This defines which agents run at each phase of the workflow.

```markdown
# Pipeline

Configure which agents run at each phase of the development workflow. Each entry is an agent name resolved from the project's `.claude/agents/` directory (local override) or the plugin's `agents/` directory (default).

## post-plan
- devils-advocate

## post-implementation
<!-- - standards-enforcer -->
```

Tell the user:
> **Pipeline configured** with `devils-advocate` enabled in `post-plan`. The `post-implementation` phase has `standards-enforcer` available but commented out by default — uncomment in `.claude/pipeline.md` if you want code-standards enforcement to run on changed files before commit.
> You can customize `.claude/pipeline.md` to add, remove, or reorder agents at each phase.
> Custom agents go in `.claude/agents/` — see the HCF README for details.

**Create `CLAUDE.md` in project root:**

This file provides always-on context for every Claude session. Keep it concise (~30-50 lines).

```markdown
# {Project Name}

{Brief 1-2 sentence description of the project.}

## Tech Stack

- **Language**: {language} {version}
- **Framework**: {framework if applicable}
- **Testing**: {test framework}
- **Linting**: {linter/formatter}

## Core Principles

{Extract 3-5 key principles from user input or your judgment. These should be always-true rules that affect how code is written.}

## Project Structure

{Brief 3-5 line summary of directory structure from architecture.md}

## Commands

\`\`\`bash
# Run tests
{test command}

# Lint/format
{lint command}

# Start dev server (if applicable)
{start command or remove this line}
\`\`\`

## Key Rules

{5-10 bullet points of critical coding rules extracted from code-standards.md and user input}

## Detailed Configuration

Project configuration files are in `.claude/`:
- `architecture.md` - Technical patterns and structure
- `testing.md` - Test configuration and commands
- `code-standards.md` - Coding conventions
```

### Step 7: Prompt for Ralph Wiggum Installation

For large plans that may exceed context limits, the ralph-wiggum plugin provides session persistence. Ask the user:

> **Optional: Install ralph-wiggum for session persistence?**
>
> The ralph-wiggum plugin enables autonomous execution of large plans (20+ tasks)
> by automatically recovering when context limits are reached.
>
> Install now? (y/n)

If yes, run the installation commands:

```bash
# Add the Anthropic marketplace (if not already added)
/plugin marketplace add anthropics/claude-code

# Install ralph-wiggum
/plugin install ralph-wiggum@claude-code-plugins
```

If no, inform them they can install later:
> You can install it anytime with:
> ```
> /plugin marketplace add anthropics/claude-code
> /plugin install ralph-wiggum@claude-code-plugins
> ```

### Step 8: Confirm Completion

After creating all files, output:

```
✓ Created CLAUDE.md
✓ Created .claude/testing.md
✓ Created .claude/code-standards.md
✓ Created .claude/architecture.md
✓ Created .claude/pipeline.md
{✓ Installed ralph-wiggum plugin (if installed)}

Project configured for autonomous development!

Next steps:
1. Review CLAUDE.md and the generated files in .claude/
2. Customize .claude/pipeline.md to add/remove workflow agents
3. Describe a feature to start planning: "Help me implement..."
4. The plan-create skill will auto-trigger to help you plan
```

## Error Handling

- If unable to detect project type: Ask user to specify manually
- If file creation fails: Report error and suggest checking permissions
- If user provides conflicting information: Ask for clarification

## Idempotency

- Check for existing CLAUDE.md and .claude/ config before running
- Never overwrite existing files without explicit confirmation
- Offer to update individual files if some exist
