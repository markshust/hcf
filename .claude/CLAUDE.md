# HCF

A Claude Code plugin for autonomous development orchestration with parallel TDD
execution. This repo *is* the plugin — it contains no application code, only
markdown (skills, agents, docs) and bash (hooks, tests).

This file is HCF's own project config. It is **not** the template shipped to
users — that lives inline in `skills/project-setup/SKILL.md`, and editing this
file has no effect on what `/hcf:project-setup` generates.

## Do not use HCF to build HCF

Do **not** invoke `hcf:plan-create` or `hcf:plan-orchestrate` for work in this
repo. HCF cannot bootstrap itself: `plan-orchestrate` requires
`.claude/testing.md` and `.claude/code-standards.md`, which this repo
deliberately does not have, and its hook agents would resolve against the very
`agents/` directory being edited. Work here directly, TDD where practical.

The plugin's own workflow is for *consumer* projects.

## Commands

```bash
# Run the full test suite (no dependencies; bash 3.2 compatible)
./tests/run-tests.sh

# Run one suite
./tests/run-tests.sh test-parse

# Lint shell
shellcheck hooks/*.sh tests/*.sh
```

## Key Conventions

- **Shell must run on bash 3.2** (stock macOS `/bin/bash`). No `declare -A`, no
  `mapfile`, no `${var,,}`. Use parallel indexed arrays instead of associative
  ones.
- **`LC_ALL=C` on every `sort` and `awk`**, or ordering differs between a macOS
  `en_US.UTF-8` user and a Linux `C` one.
- **BSD tools only** — no `grep -P`, no GNU `sed -i` semantics, no awk `gensub`.
  The plugin ships to macOS and Linux.
- **Never `ls "$DIR"/*.md`** — plugin install paths contain spaces. Use
  `shopt -s nullglob` with a `for` glob loop, and quote every path expansion.
- Hook scripts self-locate via `${BASH_SOURCE[0]}`; project root comes from
  `${CLAUDE_PROJECT_DIR:-$PWD}`.
- **`${CLAUDE_PLUGIN_ROOT}` is only set for `hooks.json` entries**, not for a
  skill's Bash calls. Skills use the `Base directory for this skill` value the
  harness states at load.
- `HOOKS.md` is the authoritative reference for the hook system. Skills point
  there rather than restating the routine — restating it is what caused #4.
- Hook discovery is `hooks/discover-hooks.sh`. Never enumerate agent files by
  hand or write a glob loop to do it.
- Any change to shell behavior needs a test in `tests/test-*.sh`; the runner
  auto-discovers them.

## Release Process

This repo is a Claude Code plugin published via its own marketplace manifest.
Releases are cut in their own PR — **feature PRs never bump the version**, they
only add entries under `[Unreleased]` in `CHANGELOG.md`.

To cut a release:

1. Move entries from `[Unreleased]` to a new `[X.Y.Z] — YYYY-MM-DD` section in
   `CHANGELOG.md`. Add a new comparison link at the bottom and update the
   `[Unreleased]` link to point to the new tag.
2. Bump `version` in **both** `.claude-plugin/plugin.json` and
   `.claude-plugin/marketplace.json` (must match, or `claude plugin tag`
   refuses).
3. Commit the changelog + version bump together.
4. Run `claude plugin tag --push` — auto-generates a tag in the form
   `hcf--v{version}` (note the **double dash** between plugin name and `v`) and
   pushes it. `--dry-run` previews without creating anything.
5. Mirror to GitHub Releases:
   `gh release create hcf--v{version} --title "hcf--v{version}" --notes-file <changelog-section> --latest`.
   **Always pass `--latest`** — without it GitHub picks the "Latest" badge by
   creation timestamp, which is wrong given this repo's tags are already out of
   chronological order.
6. Users update via `/plugin marketplace update hcf`, then
   `/plugin install hcf@hcf`, then `/reload-plugins`. The reload step is
   non-obvious and required.

**Versioning:** semver, read as `BREAKING.FEATURE.FIX`. New phases / agents /
skills = minor. Removing a generated file is treated as minor since existing
user data isn't destroyed.
