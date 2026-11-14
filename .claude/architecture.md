# Architecture

HCF is a Claude Code plugin: markdown (skills, agents, docs) plus bash (hooks,
tests). There is no application code.

## Directory Structure

- `.claude-plugin/` - `plugin.json` and `marketplace.json` (versions must match).
- `skills/` - the user-facing workflow, one `SKILL.md` each:
  `project-setup`, `project-update`, `plan-create`, `plan-orchestrate`.
- `agents/` - bundled subagents: `tdd-worker` (implements one task test-first),
  `devils-advocate` (`phase: post-plan`), `standards-enforcer` (dormant).
- `hooks/` - bash run by Claude Code (`hooks.json`) or by the skills:
  - `hooks.json` - registers the lifecycle hooks.
  - `tdd-guard.sh` - PreToolUse (Edit|Write|MultiEdit|NotebookEdit|Bash). Inside
    a tdd-worker, judges each file change live via `verify-tdd.sh --gate`,
    records allowed calls in a sidecar (`<plan>/.tdd/<task>.<agent>.calls`) and
    a pre-image copy of each file (`.pre/`) for an exact revert.
  - `verify-tdd.sh` - the TDD verifier. Default mode reads a finished worker
    transcript and prints OK / REVIEW / FAILED with violations R0-R6; `--gate`
    judges one pending call; `--state`, `--count-tests`, `--removal-only`
    helpers.
  - `tdd-subagent-stop.sh` - SubagentStop: runs the verifier and writes the
    task's verdict (`<plan>/.tdd/<task>.verdict`).
  - `tdd-context.sh` - sourced: finds a worker's transcript, task file and
    IN FULL reads from the hook input.
  - `revert-task.sh` - undoes a failed task's changes from its transcript and
    the guard's saved copies.
  - `discover-hooks.sh`, `resolve-plans-dir.sh`, `resolve-project-dir.sh`,
    `gate-*.sh`, `detect-legacy-pipeline.sh`, `pipeline-status.sh`.
- `tests/` - `run-tests.sh` (runner), `lib.sh` (assertions), `test-*.sh`
  suites, `fixtures/`.
- Docs: `README.md` (users), `HOOKS.md` (authoritative hook reference,
  including the TDD enforcement section), `CHANGELOG.md`.

## Patterns Used

- **One verdict engine**: the live guard and the final verifier share the same
  transcript reader and rules in `verify-tdd.sh`, so they cannot disagree on
  what a test, a red run or a write is.
- **Fail closed**: inside a tdd-worker, any error in the hooks refuses the call
  (guard) or writes an ERROR verdict (stop hook).
- **Self-locating scripts**: `${BASH_SOURCE[0]}`; no `CLAUDE_PLUGIN_ROOT` in
  skill Bash calls (skills use their stated base directory).
- **Frontmatter enrollment**: agents join a hook point via `phase:` in their own
  frontmatter, resolved only by `discover-hooks.sh`.

## Conventions

- Any change to shell behaviour needs a test in `tests/test-*.sh`.
- `HOOKS.md` is authoritative; skills and agents point there.
- Feature PRs add `[Unreleased]` CHANGELOG entries; releases are their own PR.

## Key Integrations

- Claude Code hook protocol: PreToolUse JSON output
  (`hookSpecificOutput.permissionDecision` = deny with
  `permissionDecisionReason`, or `additionalContext` to inform the model while
  allowing the call), SubagentStop `decision: block`.
- `jq` is required by the TDD hooks (they fail closed without it).
