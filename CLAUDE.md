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

## Release Process

This repo is a Claude Code plugin published via its own marketplace manifest. To cut a release:

1. Move entries from `[Unreleased]` to a new `[X.Y.Z] — YYYY-MM-DD` section in `CHANGELOG.md`. Add a new comparison link at the bottom and update the `[Unreleased]` link to point to the new tag.
2. Bump `version` in **both** `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (must match).
3. Commit the changelog + version bump along with any feature changes.
4. Run `claude plugin tag --push` — this auto-generates a tag in the form `hcf--v{version}` (note the **double dash** between plugin name and `v`) and pushes it to the remote.
5. Users update via `/plugin install hcf@hcf` and must run `/reload-plugins` for the new version to take effect.

**Versioning:** semver. New phases / agents / skills = minor bump. Removing a generated file (e.g., dropping `project-overview.md` from setup) is treated as minor since existing user data isn't destroyed.

**During development:** add user-visible changes to the `[Unreleased]` section of `CHANGELOG.md` as you go — don't try to reconstruct it at release time.

## Project Details

{Include exact format below with XML tag and @ includes.}

<testing>
@.claude/testing.md
</testing>

<code-standards>
@.claude/code-standards.md
</code-standards>

<pipeline>
@.claude/pipeline.md
</pipeline>
