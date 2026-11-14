# Changelog

All notable changes to HCF are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.5.0] — Unreleased

### Added
- **TDD is verified mechanically, not taken on trust.** A worker's summary used to be the only evidence of how it worked, and workers routinely wrote every test up front and implemented in one pass while reporting strict TDD. HCF now checks every `tdd-worker` from its own transcript:
  - An **edit guard** (`PreToolUse`) refuses a production change until a test run filtered to the current requirement has failed, refuses a new test before the last one has run (or several in one edit), refuses project files changed from Bash (only Edit/Write may change files, so every change can be checked), and refuses formatter runs without an explicit file list. Each refusal tells the worker what to do instead.
  - A test that **passes on its first run** must be answered before the worker moves on: make it fail for the right reason, or record `PASSED-FIRST: <requirement> — <why>`.
  - **Cut-back is the answer to a first-run pass**: the worker deletes the code that makes the test pass with removal-only Edits (no new tokens; `verify-tdd.sh --removal-only`), runs the test filtered and sees it fail, then rebuilds the code in GREEN, whether an earlier step over-built it or an earlier test needed it. The guard allows only removal-only production Edits while the pass is unanswered; the verifier counts the cut-back as red before green, and reports it as an R2 violation if no failing run of that requirement follows before other production code or a new test.
  - `PASSED-FIRST` is accepted (as `REVIEW`) only as `PASSED-FIRST: <requirement> — no-code: <why>`, for behaviour no production code delivers. A line without `no-code:` does not satisfy the guard and fails verification ("passed on its first run and was not cut back"): workers kept claiming an earlier test "needed" code it did not.
  - A requirement the worker never started is reported as `R1 … not attempted (no test written)`, so an unfinished task reads differently from a method violation. When those are the only violations, the verdict is still `FAILED` but carries an `unfinished: <n> requirement(s) not attempted` line, the worker ends with `TASK_FAILED: unfinished — <n> requirement(s) not attempted`, and `plan-orchestrate` resumes the same worker instead of reverting its finished requirements.
  - The guard reads a transcript that is still being written: `--gate` skips a half-written line and counts earlier edits whose result is not on disk yet, so tools streamed in one message cannot slip past it. If the check itself fails, the guard refuses the call instead of allowing it unchecked.
  - A test is counted only where it is declared: `it(`/`test(` followed by its name (`function test…(`, `def test_…(`, `#[Test]`, `@Test` as before). A helper calling `test()->markTestSkipped()` used to count as a new, unrun test and blocked every later test and production edit. The guard now counts through `verify-tdd.sh --count-tests`, so the guard and the verifier always agree.
  - `revert-task.sh` never wipes a parallel worker's changes: it restores a snapshot only when the file is still exactly what the reverted worker left; otherwise it undoes that worker's own edits around the other changes, or leaves the file untouched and exits 1.
  - A **verifier** (`SubagentStop`, `hooks/verify-tdd.sh`) replays the transcript when the worker stops and writes `<plan>/.tdd/<task>.verdict`: `OK`, `REVIEW` (justified first-run passes), `FAILED`, or `NONE` (no test requirements, so nothing was checked; the orchestrator reviews the output itself).
  - `plan-orchestrate` reads the verdict before accepting a task. A `FAILED` task, or a `REVIEW` whose justification shows over-building, is rejected: `hooks/revert-task.sh` undoes exactly that worker's file changes (earlier tasks' changes to the same files survive, unlike `git checkout`) and the task is retried.
- **`(guard)` requirements.** `plan-create` labels a requirement that an earlier requirement in the same task already delivers (another input to the same default, another entry point into the same path): `` - [ ] `it reads arguments from the cache` (guard) ``. A guard only has to be run on its own and may pass on its first run. `devils-advocate` checks every label.
- **`testRunners` in `.claude/hcf.json`** for test runners HCF does not recognise by name. A transcript with no recognised test run fails with a message pointing to it.

### Changed
- `tdd-worker` changes files only with Edit/Write/MultiEdit and runs each requirement's RED step filtered to its test name.
- `plan-orchestrate` no longer relies on `@.claude/testing.md` / `@.claude/code-standards.md` includes, which are not expanded when a skill loads: the orchestrator reads both files itself, and workers and hook agents are told to read them in full by path instead of receiving tens of kilobytes pasted into every prompt.
- Plugin agents are namespaced: when the discovery script prints a bare name and no such subagent type exists, `plan-orchestrate` spawns `hcf:<name>`.
- HCF now needs `jq` (transcript verification) and `python3` (exact revert). Both fail loudly when missing; a task is never accepted unverified.
- **The edit guard holds a worker until it has read its rules.** Every file the prompt names on an `IN FULL` line (testing.md, code standards, CLAUDE.md) must be opened with the Read tool before any file change but the task file. Workers were skipping them, and with them the project's own test commands and rules.
- **The task file is changed with Edit, never from Bash.** Workers ticked every checkbox at the end with one `sed -i`, which the guard let through because the task file is not production code.
- **A clean worker must end with its terminal line.** On an `OK`, `REVIEW` or `NONE` verdict, the stop hook asks once for `TASK_COMPLETE` (or `TASK_FAILED: <reason>`) as the last line when it is missing; `plan-orchestrate` decides by the verdict and the checkboxes either way.
- `plan-orchestrate`'s worker prompt has an optional `## Parallel Run` section for per-worker resources a project's testing.md requires, such as one test database per parallel worker.
- **Requirements come from the worker's prompt, not its task file.** The requirement list (names and `(guard)` labels) is read from the `## Your Task` section of the first prompt, which `plan-orchestrate` must now fill with the task file verbatim; the task file is used only when that section has no checklist. A requirement removed or renamed in the task file, or labelled `(guard)` there, is violation R5, and the guard refuses such an edit live; a requirement the worker adds is allowed and verified like the rest. A worker could previously delete requirements, mark them `(guard)`, or break the format so nothing parsed (verdict `NONE`).
- **Red means a real failing run.** A run is a test run only when the runner is the program executed (after wrappers such as `docker compose exec <service>`, `npx`, `python -m`, `env`, `sh -c`), never in a comment or as an argument to `echo`/`ls`; the filter is read only after the runner (`docker compose exec -t` is not a filter). It is red when, filtered to the requirement, its output shows a failure at the start of a line (a failing-test line, a failure count such as `Tests: 1 failed`, an assertion failure, or a compile or collection failure), not merely the word FAILED anywhere (a passing test named "…FAILED…" no longer counts). A failure line the command echoed itself does not count, and infrastructure errors (Docker daemon, connection refused, no tests found, out of memory, parse/syntax errors) never do. Replayed against a real run's twelve worker transcripts, the honest ones still verify.
- **Names are matched normalised**: `it creates a user`, `test_creates_a_user`, `testCreatesAUser` and `TestCreatesAUser` are the same name, so PHPUnit, pytest and Go workers are no longer reported "not attempted". An exact filter for a requirement whose name is contained in another's counts for it, and a `PASSED-FIRST` line must name its requirement exactly.
- **Test files are classified relative to the project**, by real conventions (`FooTest.php`, `foo.test.ts`, `foo_test.go`, `test_foo.py`, `foo_spec.rb`, ...). A production file named `Spec.php` and every file of a project under a `spec/` or `test/` directory used to count as tests.
- **Project settings for any toolchain**: besides `testRunners`, `.claude/hcf.json` takes `commandWrappers` (prefixes that run another command) and `fileGenerators` (commands that write files). `testRunners` entries now match at the start of a command (or of what a wrapper runs), not anywhere in it.
- More test declarations are counted: `/** @test */`, `#[Test]` on a method (once, even when it is also named `test…`), Go `func TestX(`, Rust `#[test]`, `it.each(...)`, `it.only(`, `test.skip(`.
- `plan-orchestrate` deletes a task's old verdict and guard sidecars before launching its worker, checks that a verdict's `transcript:` line names the current worker's transcript before trusting it, names the verdict file exactly (`.tdd/001-foo.md.verdict`), and shows the exact `revert-task.sh --dry-run` command.

### Fixed
- **A write through a shell variable was reported as a project file.** `S=/tmp/scratch; cat > $S/notes` was read as the literal path `$S/notes` under the project and failed the worker with R4. The verifier now expands variables the same command assigns (`S=...`, `export S=...`, `$S` and `${S}`), plus `$HOME`, and `$PWD` as the directory the call ran in. A variable the command never assigns stays unexpanded, so a write through it is still reported.
- **The guard missed an edit streamed right after a new test.** It can run before the previous tool call of the same assistant message is in the transcript, so a production edit right after a test-adding edit was allowed. The guard now records each file change it allows in a sidecar (`.tdd/<task file name>.<agent id>.calls`) and `--gate` reads it after the transcript.
- **Bash writes the guard missed**: a heredoc whose opening line redirects (`cat <<'EOF' > app/Foo.php`), `sh -c`/`bash -c`/`eval` and scripts piped or fed by heredoc into a shell, `git apply`/`checkout`/`restore`/`stash`/`switch` and other tree-changing git commands, `patch`, `touch`, `ln`, `install`, `rsync`, `dd of=`, `truncate`, and code generators (`artisan make:`, `rails generate`, ...). The verifier also counts a Bash write when the command errored; only a call the guard refused is skipped.
- **The TDD hooks failed open.** With no `jq`, a task path in backticks or after a blank line, or a `## Task File Path` heading past line 200 of the prompt, they silently did nothing. The path is now parsed tolerantly from the whole first prompt, and inside a `tdd-worker` whose context cannot be established the guard refuses every file change and the stop hook writes an `ERROR` verdict (where it can) and tells the worker to end with `TASK_FAILED: TDD hooks could not run — <why>`. A verifier error at stop is handled the same way.
- **A worker in a worktree could edit the main checkout.** Paths outside the worker's cwd were all exempt as "outside the project", including the main worktree and other `git worktree` checkouts of the same repository. The guard now refuses those (`DENY-CHECKOUT`, telling the worker to work in its own directory) and the verifier reports them (R6); paths outside the repository, such as `/tmp`, stay exempt.
- **Symlinked plan directories** (a worktree's plan linked into the main checkout): task-dir, project and test-file checks in `verify-tdd.sh` and `revert-task.sh` compare paths both as given and with symlinks resolved, so plan files are never treated as production or reverted, and a cwd reached through a symlink still covers the project.
- `revert-task.sh` accepts `--dry-run` in any position (`revert-task.sh --dry-run <task> <transcript>` failed with `dirname: illegal option`), and treats a formatter the worker ran from Bash on files it named as the worker's own change, so a file it created and then formatted is deleted instead of "changed by another writer".
- A read-only command that mentions a formatter (`grep -rn "php-cs-fixer fix" .`) is no longer refused as a formatter run; formatters are recognised by the program run, and more of them are known (Pint, Ruff, Rubocop, `cargo fmt`, `go fmt`, ...), with check modes (`--test`, `--check`, `--dry-run`) treated as read-only.

## [2.4.0] — 2026-10-08

### Changed
- **Tasks start as soon as their own dependencies finish.** `plan-orchestrate` used to run lockstep batches: every task in a batch had to finish before any task in the next one started, so a task whose dependency took 3 minutes sat idle while an unrelated task in the same batch took 15. Workers now launch in the background and each completion immediately launches whatever it unblocked, so total time follows the plan's longest dependency chain instead of the sum of each batch's slowest task. Failed tasks under the retry limit are eligible again right away.

  Batches still exist: a batch is the set of tasks launched together, and `pre-batch` / `post-batch` still fire once per batch. What changed is that batches overlap, so a `post-batch` agent may see other batches' unfinished edits in the working tree. See [HOOKS.md → Batches overlap](HOOKS.md#batches-overlap).

### Fixed
- **Plans wider than Claude Code's subagent limit no longer lose tasks.** Claude Code runs at most 20 subagents per session by default and fails, rather than queues, any spawn over that. `plan-orchestrate` launched every ready task with no handling for that error, so a step with more than 20 ready tasks left the extras unstarted. A spawn refused at the limit now goes back to `pending` without using a retry and launches when the next worker finishes. HCF still sets no limit of its own; to run more workers at once, raise `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`.

## [2.3.1] — 2026-09-21

### Changed
- **Plan files are no longer committed** ([#15](https://github.com/markshust/hcf/issues/15)). Plans are ephemeral: they're the working state of one run, and once the work lands the code and tests are the source of truth. A committed plan goes stale as soon as the feature changes and misleads any agent that reads it later. `plan-orchestrate` now stages the implementation with `git add -A` and then unstages the plans directory. The same exclusion applies to the changed-file list passed to `post-implementation` agents. Unstaging rather than excluding the path in `git add` means it works whether the plans directory is untracked, gitignored, or already committed by an earlier version. The success output now reminds you to delete the plan folder once the branch is merged. The README no longer tells you to keep the plans directory git-tracked; it recommends gitignoring it instead. Plans committed by earlier versions are left alone.

## [2.3.0] — 2026-08-25

### Changed
- **Session persistence now relies on Claude Code natively; the ralph-wiggum integration is removed.** Its rationale is obsolete — sessions no longer die at context limits, auto-compaction summarizes and continues — and the integration never worked as documented anyway: `plan-orchestrate` told Claude to invoke `/ralph-wiggum:loop`, but the plugin's actual command is `ralph-loop`, and both its commands are marked `hide-from-slash-command-tool`, so Claude could never invoke them itself in the first place.

  In its place, `plan-orchestrate` (Step 0) and `plan-create` (the "ready to begin?" prompt) surface a copy-pasteable tip for Claude Code's built-in `/goal` command — `/goal` is user-typed and cannot be started by a skill, so a tip is the honest integration. The suggested condition deliberately covers **both** terminal outputs, `ALL_TASKS_COMPLETE` and `TASKS_BLOCKED`, so a legitimately blocked run ends the goal instead of leaving its evaluator demanding progress that cannot happen.

  `project-setup` no longer prompts to install ralph-wiggum and no longer writes the `.claude/ralph-loop.local.md` gitignore entry; `project-update` no longer checks for it (a stale entry in an existing project is harmless and left alone). Plan and task file formats are unchanged, interrupted runs still resume from on-disk state, and anyone who prefers ralph-wiggum can still start it manually — the orchestrator's terminal outputs satisfy its completion promise exactly as before.

## [2.2.0] — 2026-08-17

### Added
- **Configurable plans directory** ([#1](https://github.com/markshust/hcf/pull/1), by [@michielgerritsen](https://github.com/michielgerritsen)). Plans live in `.claude/plans/` unless a project sets `plansDir` in an optional, user-owned `.claude/hcf.json`:

  ```json
  { "plansDir": "docs/plans" }
  ```

  No skill creates or modifies that file, `project-setup` never asks about it, and with it absent everything behaves exactly as before. `plansDir` must be relative to the project root; absolute paths and `..` segments are rejected. Changing it once plans exist means moving the folders yourself — HCF does not migrate them, and `project-update` warns when `.claude/plans` still holds plan folders after a move.

  Resolution is `hooks/resolve-plans-dir.sh`, built on 2.1.1's project anchor, so the answer does not depend on the working directory and the `.hook-fingerprint` written beside a plan follows `plansDir` with it. **A malformed value stops the run instead of falling back to the default** — quietly writing plans somewhere the project did not ask for is the failure mode this whole area keeps producing, and the resolver deliberately does not add another instance of it. No `jq` dependency, for the same reason: a missing `jq` would turn a configured `plansDir` into a silent default on Debian minimal and Alpine.

  Subagents stay configuration-unaware. `plan-orchestrate` passes each `tdd-worker` a concrete `## Task File Path`, `plan-create` passes post-plan agents a concrete `## Plan Directory`, and both agents are told never to read `hcf.json` — one resolver runs per skill, so there is no second resolver to drift from the first.

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

[Unreleased]: https://github.com/markshust/hcf/compare/hcf--v2.4.0...HEAD
[2.4.0]: https://github.com/markshust/hcf/compare/hcf--v2.3.1...hcf--v2.4.0
[2.3.1]: https://github.com/markshust/hcf/compare/hcf--v2.3.0...hcf--v2.3.1
[2.3.0]: https://github.com/markshust/hcf/compare/hcf--v2.2.0...hcf--v2.3.0
[2.2.0]: https://github.com/markshust/hcf/compare/hcf--v2.1.1...hcf--v2.2.0
[2.1.1]: https://github.com/markshust/hcf/compare/hcf--v2.1.0...hcf--v2.1.1
[2.1.0]: https://github.com/markshust/hcf/compare/hcf--v2.0.0...hcf--v2.1.0
[2.0.0]: https://github.com/markshust/hcf/compare/hcf--v1.1.1...hcf--v2.0.0
[1.1.1]: https://github.com/markshust/hcf/compare/hcf--v1.1.0...hcf--v1.1.1
[1.1.0]: https://github.com/markshust/hcf/compare/hcf--v1.0.0...hcf--v1.1.0
[1.0.0]: https://github.com/markshust/hcf/releases/tag/hcf--v1.0.0
