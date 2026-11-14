# HCF (Halt and Catch Fire)

Autonomous development plugin for Claude Code. Define requirements with a PM, then let parallel workers implement everything using TDD.

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
  - [Installation](#installation)
  - [Updating](#updating)
  - [Quick Start](#quick-start)
- [How It Works](#how-it-works)
  - [Four Phases](#four-phases)
  - [Pipeline](#pipeline)
  - [Dependency Graph](#dependency-graph)
  - [Parallel Execution](#parallel-execution)
  - [TDD Methodology](#tdd-methodology)
  - [TDD Enforcement](#tdd-enforcement)
- [Reference](#reference)
  - [Files Created](#files-created)
  - [Task Format](#task-format)
  - [Skills](#skills)
  - [Outputs](#outputs)
- [Architecture](#architecture)
- [Advanced Configuration](#advanced-configuration)
  - [Plans Directory](#plans-directory)
  - [Test Runners](#test-runners)
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

### Updating

Claude Code doesn't auto-update third-party marketplaces by default, so HCF
stays on the installed version until you update it:

```bash
/plugin marketplace update hcf
/plugin install hcf@hcf
/reload-plugins
```

To get new versions automatically instead, run `/plugin`, open
**Marketplaces**, select `hcf`, and enable auto-update. Claude Code then checks
for updates at startup and prompts you to run `/reload-plugins` when one is
installed.

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
- Create `.claude/plans/user-auth/` with task files (or your configured [plans directory](#plans-directory))
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

The `plan-orchestrate` skill auto-triggers. It verifies you're on the correct `feature/{plan-name}` branch before starting.

Session persistence is native to Claude Code — no plugin required. Auto-compaction handles context limits, and all run state (task statuses, requirement checkboxes, retry counts) lives in the plan files, so an interrupted run resumes by re-running the plan. For large plans, you can optionally set a goal first so execution completes unattended:

```
/goal the user-auth plan run reached a terminal state: plan-orchestrate output ALL_TASKS_COMPLETE or TASKS_BLOCKED
```

After completion, you'll be prompted to push the branch and create a PR (never done without your permission).

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
| `pre-batch` | Before each batch of TDD workers launches |
| `post-batch` | When the last task of a batch finishes |
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
- Task 001 starts first (no dependencies)
- Tasks 002, 003, 004 start together when 001 finishes
- Task 006 starts as soon as 004 finishes, even if 002 and 003 are still running
- Task 005 starts when both 002 and 003 have finished

### Parallel Execution

Tasks start the moment their own dependencies finish. Nothing waits for an
unrelated task that happened to start at the same time:

```
t=0    001 starts                          → 1 worker
       001 done → 002, 003, 004 start      → 3 workers
       004 done → 006 starts               → 002, 003 still running
       002 + 003 done → 005 starts
```

Total time follows the plan's longest dependency chain rather than the slowest
task of each step. HCF sets no limit on how many workers run at once; Claude
Code does, at 20 subagents per session by default. To run more, raise it in your
shell or in the `env` block of your Claude Code settings:

```bash
export CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=40
```

### TDD Methodology

Each task follows strict Red → Green → Refactor:

1. Write failing test for one requirement
2. Write minimum code to pass
3. Refactor while tests stay green
4. Repeat for next requirement
5. Commit when task complete

### TDD Enforcement

HCF does not take a worker's word for how it worked. Every `tdd-worker` is
checked mechanically, from its own transcript, by hooks that ship with the
plugin (no setup needed):

- **Edit guard** (`PreToolUse`): inside a `tdd-worker`, a production file can
  only change after a test run *filtered to the current requirement* has
  failed. Adding a new test locks it again until that test fails. The guard
  also refuses a second new test before the first has run, more than one new
  test in a single edit, any project file changed from Bash (redirects
  including `cat <<EOF > file`, `tee`, `sed -i`, `cp`/`mv`/`ln`/`install`/
  `rsync`/`touch`/`truncate`/`dd of=`, `patch`, `git apply`/`checkout`/
  `restore` and other tree-changing git commands, code generators such as
  `artisan make:`, `sh -c`/`bash -c`/`eval` or a script piped into a shell
  that writes, interpreter scripts — files change only through Edit/Write), an
  edit to the task file that removes or renames a requirement or labels one
  `(guard)`,
  any change to another checkout of the same repository (the main worktree or
  another `git worktree`; paths outside the repository, such as `/tmp`, stay
  allowed), and a formatter run without an explicit file list. Each refusal tells the
  worker what to do instead. Calls it has allowed are also kept in a sidecar
  (`<plan>/.tdd/<task>.md.<agent id>.calls`), because the transcript can lag
  behind tools streamed in one message.
- **What counts as red.** A test run is a command whose *executed* program is
  a test runner (after wrappers such as `docker compose exec <service>`,
  `npx`, `python -m`, `env`, `sh -c`), never a runner named in a comment or as
  an argument to `echo`/`ls`/`grep`. It is red for a requirement only when it
  is filtered to that requirement and its output shows a test failure: a
  failing-test line as Pest, PHPUnit, Vitest, Jest, pytest, Go, Rust or RSpec
  print it, a failure count (`Tests: 1 failed`, so output trimmed with `tail`
  still counts), an assertion failure, or a compile or collection failure.
  Such a line counts only at the start of an output line (a passing test
  named "…FAILED…" is not a failure) and never when the command printed it
  itself (`echo "FAILED …"`). Infrastructure errors
  (Docker or a database unreachable, command not found, no tests found,
  out of memory, a parse or syntax error) are never red. Names are compared
  normalised, so `it creates a user`, `test_creates_a_user`,
  `testCreatesAUser` and `TestCreatesAUser` match.
- **Requirements come from the prompt.** The requirement list (names and
  `(guard)` labels) is read from the `## Your Task` section of the worker's
  first prompt, where `plan-orchestrate` pastes the task file; removing or
  renaming one in the task file, or labelling one `(guard)`, is a violation.
  A requirement the worker adds there is allowed and verified like the rest. Only when the prompt has no
  checklist is the task file read instead.
- **First-run passes are cut back.** When a test passes on its first filtered
  run, some production code already delivers it. The worker **cuts it back**:
  until the pass is answered the guard allows only removal-only Edits to
  production files (the edit's new text keeps some of the old text's tokens in
  order and adds none), and once the test fails on a filtered run the code is
  rebuilt in GREEN. The verifier counts that as red before green; a cut-back
  not followed by a failing run of that requirement (before any other
  production change or new test) is a violation. The worker may instead fix a
  wrong test. Only behaviour that **no production code** delivers (a language
  or framework guarantee) may be recorded as
  `PASSED-FIRST: <requirement> — no-code: <why>`, which the orchestrator
  reviews; a `PASSED-FIRST` line without `no-code:` is a violation.
- **Fails closed inside a worker.** If the guard cannot check a call (the
  verifier errors), it refuses the call. If the hooks cannot establish a
  `tdd-worker`'s context at all (`jq` missing, its transcript or task file
  unreadable, no `## Task File Path` in its prompt), the guard refuses every
  file change and the stop hook writes an `ERROR` verdict where it can and
  tells the worker to end with `TASK_FAILED: TDD hooks could not run — <why>`.
  Outside a `tdd-worker` the hooks do nothing.
- **Verifier** (`SubagentStop`): when a worker stops, `hooks/verify-tdd.sh`
  replays its transcript and writes a verdict to
  `<plan>/.tdd/<task file name>.verdict` (e.g. `.tdd/001-foo.md.verdict`) —
  `OK`, `REVIEW` (justified first-run passes to review), `FAILED`, `NONE` (the
  task has no test requirements, so nothing was checked) or `ERROR`. Its
  `transcript:` line names the transcript it judged, so the orchestrator can
  tell a stale verdict from the current worker's. A failed worker is told to
  end with `TASK_FAILED`.
- **Exact revert**: `plan-orchestrate` rejects a `FAILED` task (and a `REVIEW`
  where production code does deliver the behaviour), and undoes exactly that
  worker's file changes with `hooks/revert-task.sh` — earlier tasks' changes
  to the same files survive, and so do changes a parallel task made to the
  same file afterwards (the worker's own edits are undone around them, or the
  file is left untouched and reported) — before retrying it. A requirement
  the worker never started is reported as "not attempted (no test written)",
  so an unfinished task reads differently from a method violation: when those
  are its only violations, the worker reports `TASK_FAILED: unfinished — …`
  and the orchestrator resumes it instead of reverting its finished work.

Requirements that should already pass when written (a second input to the same
default, a second entry point into the same code path) are labelled `(guard)`
by `plan-create`: `` - [ ] `it reads arguments from the cache` (guard) ``. A
guard only has to be run on its own; it may pass on the first run.

A test run is recognised by the program it runs (Pest, PHPUnit, Jest, Vitest,
pytest, RSpec, Mocha, `go test`, `cargo test`, `npm`/`yarn`/`pnpm`/`bun test`,
`composer`/`mix`/`artisan test`, and more). A test file is recognised by its
path relative to the project: under `tests/`, `test/`, `spec/`, `specs/` or
`__tests__/`, or named `FooTest.php`, `foo.test.ts`, `foo.spec.js`,
`foo_test.go`, `foo_spec.rb`, `FooSpec.rb` or `test_foo.py` (a file named just
`Spec.php` or `Test.php` is production code). For anything else, see
[Test Runners](#test-runners). HCF relies
on TDD: a project with no test framework should set one up (`/hcf:project-setup`)
rather than skip verification.

## Reference

### Files Created

#### Project Config (`.claude/`)

| File | Purpose |
|------|---------|
| `testing.md` | Test commands, coverage requirements |
| `code-standards.md` | Linting, formatting rules |
| `architecture.md` | Directory structure, patterns |

#### Plans (`.claude/plans/{name}/`, configurable — see [Plans Directory](#plans-directory))

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

## Advanced Configuration

HCF works with no configuration. Everything below is opt-in, and the defaults
are what you get by leaving it alone.

### Plans Directory

Plans live in `.claude/plans/` by default. To put them somewhere else — beside
your other docs, or at the repo root — create `.claude/hcf.json`:

```json
{
  "plansDir": "docs/plans"
}
```

`plansDir` is a path **relative to the project root**. Absolute paths and any
`..` segment are rejected, because plan folders belong inside the repo they
document.

**No skill ever creates or modifies `.claude/hcf.json`.** `/hcf:project-setup`
does not ask about it and `/hcf:project-update` only validates it if you have
already written one. Its absence is the normal case, not an incomplete setup.

**A malformed value stops the run rather than falling back.** If `plansDir` is
absolute, escapes the project, or is set to an empty string, HCF reports it and
refuses. Quietly writing plans to `.claude/plans` when you asked for
`docs/plans` would be the worse outcome: you would find out much later, from
the wrong directory filling up.

**Changing it after plans exist means moving the folders yourself.** HCF does
not migrate them; `/hcf:project-update` warns when `.claude/plans` still holds
plan folders after a move.

**Plans are ephemeral.** A plan is the working state of a single run, not
documentation. `/hcf:plan-orchestrate` never commits plan files: it stages the
implementation and leaves the plans directory out. Once the work is committed,
the code and its tests are the source of truth. A plan kept around goes stale as
soon as the feature changes, and an agent that later reads it will be misled.
Keep the folder while the run is in progress, since that's what lets an
interrupted run resume, and delete it once the branch is merged. To keep plans
out of git entirely, add the directory to `.gitignore`:

```gitignore
.claude/plans/
```

To see what a project resolves to:

```bash
$(claude plugin path hcf)/hooks/resolve-plans-dir.sh
```

### Test Runners

TDD verification recognises a test run by the program a worker's Bash command
runs, and a Bash write by the program too. HCF knows the common runners and
wrappers of PHP, JavaScript, Python, Go, Rust and Ruby projects on its own. For
anything else, three keys in `.claude/hcf.json` say what HCF cannot know; each
entry is a literal command prefix, matched at the start of a command or of
what a wrapper runs:

| Key | For | Example |
|---|---|---|
| `testRunners` | commands that run the tests | `"bin/run-specs"`, `"make check"` |
| `commandWrappers` | prefixes that run another command, peeled off (with their `-` options) before the runner is looked for | `"bin/in-app"`, `"./dev exec web"` |
| `fileGenerators` | commands that write project files (refused from Bash, like a redirect) | `"bin/gen"`, `"npx plop"` |

A Python project whose tests run in a container through its own script:

```json
{
  "testRunners": ["./scripts/test"],
  "commandWrappers": ["./scripts/in-container"],
  "fileGenerators": ["cookiecutter"]
}
```

With it, `./scripts/in-container pytest -k test_creates_a_user` is a test run
filtered to `it creates a user`, and so is `./scripts/test -k creates_a_user`.
Built-in wrappers need no entry: `docker compose exec -T app pytest -k ...`,
`uv run pytest`, `npx vitest run -t ...`, `go test -run TestX ./...`.

When a task's transcript contains no recognised test run at all, the verifier
fails it with a message pointing here, rather than reporting every requirement
as never having failed.

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
- `jq` (TDD verification reads worker transcripts with it) and `python3`
  (exact task revert). Without `jq`, a `tdd-worker` can change no files and is
  stopped with an `ERROR` verdict; without `python3`, revert refuses to run. A
  task is never accepted unverified.

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
