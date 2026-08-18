# Changelog

All notable changes to HCF are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.1.1] — 2026-08-17

A single bug fix, in the same place 2.1.0 fixed one: the enrollment a run is
built against must be the project's own, and must never be quietly substituted.

### Fixed
- **Project-local agents were invisible whenever the working directory was not the project root**, and nothing said so — [#4](https://github.com/markshust/hcf/issues/4)'s failure class, a silent false-empty enrollment, reached by a route 2.1.0 did not close. Discovery resolved the project as `${CLAUDE_PROJECT_DIR:-$PWD}` and then skipped a missing `.claude/agents` as the ordinary case it usually is. But `CLAUDE_PROJECT_DIR` is not exported to a skill's Bash calls, so in practice the anchor was `$PWD` alone — and the working directory persists across a session's Bash calls, so a single earlier `cd` was enough. Discovery then enumerated the plugin's agents only, and returned a perfectly well-formed answer.

  The visible damage came later. `plan-create` captures a fingerprint of the resolved enrollment and stores it with the plan; `plan-orchestrate` re-checks it at every hook. A fingerprint captured from the wrong directory records an enrollment the project never had, so the *next* run halts with `enrollment changed since this run started` and names a change nobody made. The documented remedy for that halt — delete the fingerprint and re-baseline — is also exactly what you would do to paper over a genuine enrollment change, so the guard trained you to ignore it.

  Resolution now walks up from the working directory to the nearest ancestor containing `.claude/`, falling back to the enclosing git repository root — a project that has not created `.claude/` yet is still a project, and `plan-create` has no prerequisite on `project-setup`, so it can legitimately be the first HCF command run in a fresh repo. Running from a subdirectory resolves identically to running from the root, and **when nothing yields a root the script aborts with exit 1** instead of assuming one. `$HOME` bounds both fallbacks, so neither `~/.claude` nor a dotfiles repo is mistaken for a project.

  `CLAUDE_PROJECT_DIR` still wins when set, and is still not required to contain a `.claude/` directory — but is now checked to be a directory at all. Set to a stale path, it used to produce the same silently-wrong enumeration one level up.

### Added
- `hooks/resolve-project-dir.sh` — the single implementation of project-root resolution, runnable on its own (`resolve-project-dir.sh` prints the root it found) and sourceable by other scripts. Following `discover-hooks.sh`'s precedent: path resolution that several callers depend on belongs in a script you can run and test, not in a snippet each caller reinvents.
- 28 tests covering resolution, both `$HOME` boundaries, and the refusal (`./tests/run-tests.sh test-project-dir`). The previous suite always set `CLAUDE_PROJECT_DIR`, which is why the fallback beneath it went untested and the bug in it survived a release.

## [2.1.0] — 2026-07-26

Primarily a bug-fix release. The two additions exist because fixing the bug
properly required a discovery implementation you can actually run and inspect.

### Fixed
- **Hooks silently failing to run** ([#4](https://github.com/markshust/hcf/issues/4)). Hook discovery was described in `HOOKS.md` as prose steps for the model to follow, so every session improvised its own bash enumeration. One such script hit a parse error partway through (`for f in $LOC/*.md 2>/dev/null` — redirections aren't allowed in a `for` word list), its partial output was consumed as a complete enumeration, and **every hook resolved empty**. Nothing surfaced, because the empty-hook rule mandates silence — a crashed discovery and a legitimately empty one were indistinguishable. Discovery is now a shipped script (`hooks/discover-hooks.sh`) that both skills run at all 8 call sites.
- **The frontmatter example in our own docs didn't parse.** `HOOKS.md` and `README.md` both document enrollment with a trailing comment on every value (`phase: post-plan   # enrolls this agent…`). That form yielded an unknown phase and a non-numeric order, so anyone copy-pasting the documented example got an agent that never ran.
- **Agent files with CRLF line endings were silently skipped**, since `---\r` doesn't match the frontmatter delimiter.
- **The local-overrides-plugin merge now keys on the frontmatter `name`**, as `HOOKS.md` always specified, rather than on the filename.
- **A discovery failure can no longer be mistaken for an empty hook.** The empty-hook fast path is now defined as *exit 0 with empty stdout*; every other non-zero exit is an error reported loudly. `HOOKS.md`'s silent fallback to "local agents only" is also gone — quietly dropping the plugin's own bundled agents was itself a failure mode.

### Added
- **A command you can run yourself.** `$(claude plugin path hcf)/hooks/discover-hooks.sh` prints what is enrolled at every hook; `--hook=<name>` for one, `--json` for tooling. This is the fastest answer to "why didn't my agent fire?" — a question that previously had no answer at all, since the improvised script no longer existed by the time you asked.
- **Drift detection.** `--fingerprint` captures the resolved enrollment across all 8 hooks; `plan-create` stores it with the plan and `plan-orchestrate` re-checks it on every hook call. If agent files change midway through a run, HCF halts and names what changed rather than silently finishing against a different pipeline than the plan was reviewed against. Agent *body* content is deliberately not covered — editing an agent's prose is not drift.
- **Test suite** (`./tests/run-tests.sh`) — 97 tests, no dependencies beyond bash/awk/sed/sort/grep, runs on bash 3.2 (stock macOS).

### Changed
- **An invalid `phase` or `mode` now aborts (exit 3) instead of being warned past.** Previously an unknown `phase` was ignored with a warning, which meant the agent ran *nowhere* — the same silent non-execution as the bug above, one level down. Validation is global, so the error surfaces at the first hook of a run rather than hours later at commit time. **This can affect existing projects:** an agent file with a typo'd `phase` runs today (minus that agent) and will now halt planning until it is fixed. The error names the file, the bad value, and both remedies — correct the value, or remove the `phase` key entirely to unenroll the agent. Only `plan-create` and `plan-orchestrate` call the script; `/project-update` and every other skill stay runnable.
- `HOOKS.md`'s Discovery Routine now documents what the script does rather than instructing the reader to enumerate agent files by hand.

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

[Unreleased]: https://github.com/markshust/hcf/compare/hcf--v2.1.1...HEAD
[2.1.1]: https://github.com/markshust/hcf/compare/hcf--v2.1.0...hcf--v2.1.1
[2.1.0]: https://github.com/markshust/hcf/compare/hcf--v2.0.0...hcf--v2.1.0
[2.0.0]: https://github.com/markshust/hcf/compare/hcf--v1.1.1...hcf--v2.0.0
[1.1.1]: https://github.com/markshust/hcf/compare/hcf--v1.1.0...hcf--v1.1.1
[1.1.0]: https://github.com/markshust/hcf/compare/hcf--v1.0.0...hcf--v1.1.0
[1.0.0]: https://github.com/markshust/hcf/releases/tag/hcf--v1.0.0
