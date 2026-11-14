# Code Standards

## Style Guide

Plain, portable bash in the style of the existing `hooks/*.sh`:

- `#!/usr/bin/env bash` and a header comment that says what the script does,
  its usage, and its exit codes.
- Comments explain *why* (the failure a rule prevents), not what a line does.
- Small functions, `local` variables, every expansion quoted.
- jq programs and awk programs in single quotes; shell values reach jq with
  `--arg`/`--rawfile`, and reach awk through `-v` or the environment
  (`ENVIRON[...]` when the value may hold backslashes).

## Portability rules (must hold; the plugin ships to macOS and Linux)

- **bash 3.2** (stock macOS `/bin/bash`): no `declare -A`, no `mapfile`, no
  `${var,,}`, no `;&`. Use parallel indexed arrays instead of associative ones.
- **`LC_ALL=C` on every `sort` and `awk`.**
- **BSD tools only**: no `grep -P`, no GNU `sed -i` semantics (`sed -i.bak`
  then delete, or avoid), no awk `gensub`.
- **Never `ls "$DIR"/*.md`**: install paths contain spaces. Use
  `shopt -s nullglob` with a quoted `for` glob loop.
- Hook scripts self-locate via `${BASH_SOURCE[0]}`; the project root comes from
  `${CLAUDE_PROJECT_DIR:-$PWD}`.
- Hook discovery is `hooks/discover-hooks.sh`; never enumerate agent files by
  hand.

## Linting

```bash
# Check for issues (must be clean for changed files)
shellcheck -S warning hooks/*.sh tests/*.sh
```

No auto-fixer. Fix findings by hand, or add a targeted
`# shellcheck disable=SCxxxx  # reason` on the line, as the hooks already do.

## Formatting

Two-space indentation, `case` arms aligned as in the existing scripts. No
formatter is run.

## Pre-commit Checks

- `shellcheck -S warning hooks/*.sh tests/*.sh` clean (info-level findings already exist and are accepted).
- `./tests/run-tests.sh` passes.
- User-facing changes get an entry under `[Unreleased]` in `CHANGELOG.md`;
  feature work never bumps the version.

## Naming Conventions

- Scripts: `kebab-case.sh` in `hooks/`; suites `tests/test-<area>.sh`.
- Functions and local variables: `snake_case`; helpers shared between hooks are
  prefixed `hcf_` (see `hooks/tdd-context.sh`).
- Environment variables: `SCREAMING_SNAKE_CASE`, prefixed `HCF_`
  (`HCF_GATE_TOOL`, `HCF_TDD_TASK_FILE`).
- Docs: `HOOKS.md` is the authoritative reference for the hook system; skills
  and agents point there rather than restate it.
