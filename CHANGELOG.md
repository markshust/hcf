# Changelog

All notable changes to HCF are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] — 2026-06-26

### Added
- **8 lifecycle hook points** spanning the plan and implementation flow: `pre-plan` / `post-plan`, `pre-implementation` / `post-implementation`, `pre-batch` / `post-batch`, and `pre-commit` / `post-commit`. Agents enroll at a hook to run at that named moment.
- **Agent-frontmatter pipeline fields** — agents declare their pipeline membership directly in YAML frontmatter: `phase` (the hook point to enroll at), `order` (run order within a hook; lower runs first, default `100`), and `mode` (`single` or `batch`, default `single`).
- **`HOOKS.md`** — a new top-level reference doc that is the authoritative source for the hook system: the 8 hook points, the frontmatter schema, the agent discovery routine, and sort/tie-break rules.
- **Migration hooks** (in `hooks/hooks.json`) — a `SessionStart` notice plus `PreToolUse` and `UserPromptExpansion` gates that detect a legacy `.claude/pipeline.md` and **block `plan-create`/`plan-orchestrate` until it is migrated** with `/project-update` (covering both Claude-invoked and directly-typed slash commands). `/project-update` itself is never blocked, so the fix is always available.
- **`Feature Development` section in the generated `CLAUDE.md`** — `project-setup` now emits a project-agnostic section, placed as the **first section** (right after the title/description), that routes feature work through `hcf:plan-create` / `hcf:plan-orchestrate` and tells Claude never to use the built-in plan mode. Previously the generated `CLAUDE.md` had no such wiring, so the planning workflow relied entirely on the skill's auto-trigger and could be suppressed by other directives in `CLAUDE.md`; the prominent placement is deliberate so it overrides them.

### Changed
- The pipeline is now configured via **agent frontmatter** (`phase:`) instead of a central `pipeline.md`. Declaring a `phase` on any agent enrolls it; because the bundled `devils-advocate` declares a `phase`, frontmatter enrollment is always authoritative.
- `plan-orchestrate` now reads each agent's `mode` field to decide how to spawn it (`single` vs `batch`) instead of inferring it from the agent body.
- `project-setup` no longer creates `pipeline.md`.
- `project-update` now **migrates** a legacy `pipeline.md` into agent frontmatter (and removes the file once migrated).
- `project-update` now **adds a missing Feature Development section** to `CLAUDE.md` automatically (purely additive — it never touches an existing section). This carries the `plan-create` / `plan-orchestrate` wiring across an upgrade for projects set up before the section existed.
- The **empty-hook fast path** now explicitly forbids *narrating* why a hook is empty, not just suppressing the resolved-order line. An empty hook is silent and internal — `plan-orchestrate` no longer "thinks out loud" about agent enrollment (e.g. "tdd-worker and standards-enforcer declare no phase → no-op") during a run. Documented in `HOOKS.md` and `plan-orchestrate`.
- `project-setup` and `project-update` are now **command-only** (`disable-model-invocation: true`) — they cannot be invoked programmatically by another skill.

### Removed
- `pipeline.md` is **no longer read as configuration** — there is no runtime fallback. HCF enrolls agents exclusively via frontmatter. A leftover `.claude/pipeline.md` blocks the planning workflow until `/project-update` migrates it into agent frontmatter and removes the file.

## [1.1.1] — 2026-05-01

### Changed
- `standards-enforcer` is now commented out by default in the `post-implementation` pipeline. The agent uses substantial tokens and isn't mission-critical for most users; uncomment in `.claude/pipeline.md` to re-enable code-standards enforcement on changed files before commit.

## [1.1.0] — 2026-05-01

### Added
- **Phase 1: Discovery & Assumption Brainstorm** in `plan-create` — solution-architect-style codebase exploration and permutation enumeration before clarifying questions are asked.
- **Phase 2: Grounded Clarification** — questions are now categorized as *must-answer* (decisions that shape scope/data model/architecture) versus *will-default-if-silent* (with proposed defaults stated).
- **Discovery Notes** section in the `_plan.md` template, capturing Phase 1 findings for resumed sessions and future readers.
- Expanded auto-trigger patterns in `plan-create`'s description: aspirational openers ("let's build", "I want an app that"), capability lists ("users should be able to X, Y, Z"), and vague-noun patterns ("a system for", "a way to").
- **Release Process** section in `CLAUDE.md` documenting the `hcf--v{version}` tag convention.

### Changed
- `plan-create` renumbered to 8 phases (Discovery is now Phase 1, Grounded Clarification is Phase 2; the former Phase 1 ("Initial Clarification") was replaced by the grounded version).
- README updated to reflect the new Discovery & Brainstorm step and the must-answer / will-default-if-silent question categorization.

### Removed
- `project-overview.md` is no longer generated by `project-setup` or audited by `project-update`. The default-template content was already mirrored in `CLAUDE.md`, and richer expansions tended to drift out of date relative to the codebase. Existing user files are left untouched but are no longer part of the HCF workflow.

## [1.0.0] — 2026-04-27

Initial public release.

### Added
- Plugin scaffolding via `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (same-repo marketplace for GitHub-based install).
- **Skills**: `project-setup` (one-time project configuration with stack auto-detection), `project-update` (sync project config with plugin defaults), `plan-create` (interactive planning with auto-trigger on feature requests), `plan-orchestrate` (parallel TDD execution with auto-trigger on execution requests).
- **Agents**: `tdd-worker` (strict Red → Green → Refactor implementation), `devils-advocate` (post-plan review for gaps and integration completeness), `standards-enforcer` (post-implementation code-standards enforcement).
- **Configurable pipeline** — `pipeline.md` controls which agents run in `post-plan` and `post-implementation` phases; supports custom agents via `.claude/agents/`.
- **Feature branch workflow** — plans automatically work on `feature/{plan-name}` branches; orchestrator verifies branch before execution.
- **Dependency graph + parallel batch execution** — tasks declare dependencies, orchestrator runs independent tasks in parallel batches.
- **Single-commit release pattern** — plan status, implementation, and pipeline fixes commit together after the full test suite passes.
- **ralph-wiggum integration** — orchestrator wraps execution with `/ralph-wiggum:loop` for session persistence on large plans.
- **GitHub issue linking** — `plan-create` captures issue references (`Closes #N`, `Relates to #N`) and `plan-orchestrate` includes them in PR bodies for auto-close on merge.
- MIT license.

[Unreleased]: https://github.com/markshust/hcf/compare/hcf--v2.0.0...HEAD
[2.0.0]: https://github.com/markshust/hcf/compare/hcf--v1.1.1...hcf--v2.0.0
[1.1.1]: https://github.com/markshust/hcf/compare/hcf--v1.1.0...hcf--v1.1.1
[1.1.0]: https://github.com/markshust/hcf/compare/hcf--v1.0.0...hcf--v1.1.0
[1.0.0]: https://github.com/markshust/hcf/releases/tag/hcf--v1.0.0
