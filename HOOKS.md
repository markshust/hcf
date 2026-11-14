# HCF Hooks

This is the authoritative reference for HCF's hook system. HCF uses
**convention over configuration**: instead of a central registry, each agent
declares its own pipeline membership in its frontmatter. The work skills
(`plan-create`, `plan-orchestrate`) point here rather than duplicating this
logic.

The previous central registry (`pipeline.md`) is now **legacy**. See
[Legacy `pipeline.md`](#legacy-pipelinemd) below for how it is detected and
superseded.

## Hook Points

There are exactly **8** hook points. A hook point is a named moment in the
plan/implementation flow at which enrolled agents run.

| Hook                  | Fires                                                                  |
|-----------------------|------------------------------------------------------------------------|
| `pre-plan`            | Before `plan-create` Phase 1 (Discovery) begins                        |
| `post-plan`           | `plan-create` Phase 6, after dependency validation                     |
| `pre-implementation`  | `plan-orchestrate` after Step 2, before the first batch                |
| `pre-batch`           | Before each batch of workers launches (Step 5)                         |
| `post-batch`          | When the last task of a batch finishes (Step 6)                        |
| `post-implementation` | `plan-orchestrate` Step 4a, when all tasks are complete                |
| `pre-commit`          | Step 4a, after the full test suite passes, before the commit          |
| `post-commit`         | Step 4a, after the commit, before the push/PR prompt                   |

### Batches overlap

`plan-orchestrate` schedules on a rolling basis: a task launches as soon as its
own dependencies complete, without waiting for unrelated tasks. A **batch** is
the set of tasks launched together in one pass, and several batches can be in
flight at once. `pre-batch` and `post-batch` still fire exactly once per batch,
but a `post-batch` agent may find other batches' unfinished edits in the working
tree, so it should look only at its own batch's tasks.

### Why there is no `execution` hook

There is deliberately **no** `execution` hook. In HCF, executing a plan **is**
the implementation loop — the Step 3 → 5 → 6 → 8 cycle in
`plan-orchestrate`. An `execution` hook would fire over that same span already
covered by the `*-implementation` and `*-batch` hooks (`pre-implementation`,
`pre-batch`, `post-batch`, `post-implementation`), so it would only duplicate
what those hooks express. Use those instead.

## Frontmatter Schema

An agent enrolls itself in a hook by adding these keys to its YAML frontmatter,
alongside the existing `name` / `description` / `model` / `tools` keys.

```yaml
---
name: devils-advocate
description: "..."
model: opus
tools: Read, Write, Edit, Glob, Grep
# --- hook enrollment ---
phase: post-plan   # enrolls this agent at the named hook point
order: 100         # integer; lower runs first; default 100
mode: single       # "single" | "batch"; default "single"
---
```

| Key     | Type    | Default    | Meaning                                                                                  |
|---------|---------|------------|------------------------------------------------------------------------------------------|
| `phase` | string  | (none)     | The hook point that enrolls this agent. Must be one of the 8 hooks above.                |
| `order` | integer | `100`      | Run order within a hook. Lower runs first. Equal values tie-break by `name`.            |
| `mode`  | enum    | `single`   | How the agent is spawned: `single` (one subagent for the whole plan) or `batch` (files are split into batches of ~10 and spawned as parallel subagents). |

### The enrollment rule

**If an agent declares a `phase`, it runs.** There is no conditional
evaluation. HCF intentionally has **no** `requires:` or `condition:` mechanism —
a declared `phase` is an unconditional enrollment. To stop an agent from
running at a hook, remove its `phase` key (or delete/override the agent); do not
look for a condition to toggle.

An agent with **no** `phase` key is simply not enrolled in any hook (e.g.
`tdd-worker`, which the orchestrator spawns directly, never via a hook).

## Discovery Routine

Hook resolution is performed by **`hooks/discover-hooks.sh`**, which ships with
the plugin. Callers run it and read its output. **Never enumerate agent files by
hand, and never write a glob loop to do it** — that is exactly the failure this
script exists to eliminate ([#4](https://github.com/markshust/hcf/issues/4)):
the routine used to be prose, every session improvised its own bash, one of
those scripts had a syntax error, and the partial output was consumed as a
complete enumeration. Every hook silently resolved empty.

Let `HOOK` be the hook point being run (one of the 8 above).

```bash
"{skill-base-dir}/../../hooks/discover-hooks.sh" --hook=<HOOK>
```

`{skill-base-dir}` is the **`Base directory for this skill`** value stated when
the skill loads. It is given verbatim, so no path inference is involved.
`${CLAUDE_PLUGIN_ROOT}` is **not** available here — it resolves only for
`hooks.json` entries, not for a skill's own Bash calls.

Then, based on the result:

| Exit | stdout | Meaning | What the caller does |
|------|--------|---------|----------------------|
| `0` | non-empty | Agents are enrolled | **Print the output verbatim** (this is the auditable resolved order), then spawn each agent in the listed order per its `mode` |
| `0` | **empty** | Empty hook | [Empty-hook fast path](#empty-hook-fast-path) — return silently |
| `1` | — | Runtime error; the plugin `agents/` dir is unresolvable | **Stop.** Surface stderr verbatim |
| `2` | — | Bad arguments, including a malformed `--expect` value | **Stop.** Surface stderr verbatim |
| `3` | — | An agent file declares an invalid `phase` or `mode` | **Stop.** Surface stderr verbatim |
| `4` | — | Enrollment changed mid-run ([drift](#drift-detection)) | **Stop.** Surface stderr verbatim |

**Only exit 0 with empty stdout is an empty hook.** Any non-zero exit is an
error to report loudly, never a hook to skip silently. Conflating the two is
what made the original bug invisible for so long.

**If the script is missing or not executable, that is a hard failure.** Say so
and stop. There is no prose fallback — falling back to hand-enumeration would
reintroduce improvised bash at exactly the moment the script is unavailable.

Spawn modes: `single` → one subagent for the whole plan. `batch` → split the
relevant file list into batches of ~10 and spawn parallel subagents (one Task
call per batch, all in a single message). The mode comes from the agent's
`mode` field, never from reading its body.

### What the script does (specification)

This is the contract `hooks/discover-hooks.sh` implements. It is here so the
behavior is reviewable — not as steps for anyone to perform by hand.

1. **Enumerate plugin agents.** Top-level `*.md` in the plugin's `agents/`
   directory, which the script resolves from its own location
   (`$(dirname "$0")/../agents`). Not recursive.
2. **Resolve the project root,** in order: `CLAUDE_PROJECT_DIR` when set (and a
   directory — set but pointing nowhere is an error, not a fallback); else the
   nearest ancestor of the working directory holding a `.claude/`; else the
   enclosing git repository root, since a project that has not created
   `.claude/` yet is still a project. `$HOME` bounds the last two, so neither
   user-level Claude config nor a dotfiles repo is mistaken for a project.
   Comparisons are made in physical (symlink-resolved) form, or a home reached
   through a symlink would slip past that boundary. **When nothing yields a
   root the script aborts with exit 1** rather than assuming the working
   directory — guessing produces a well-formed enrollment that silently omits
   every local agent, and a fingerprint captured that way stays wrong until it
   surfaces as a drift halt naming a change that never happened.
3. **Enumerate local agents.** Top-level `*.md` in `<project root>/.claude/agents`.
   A missing directory is normal, not an error — most projects have none. A
   missing *project* is not: see the step above.
4. **Parse frontmatter.** `name`, `phase`, `order`, `mode` from the **first**
   `---` block only, anchored at start-of-line. A commented `# phase:` key is
   **not** enrollment (this is what keeps `standards-enforcer` dormant). Quoted
   values are unquoted; a trailing ` # …` comment is stripped from unquoted
   values, so the [example above](#frontmatter-schema) parses as written; CRLF
   files are handled. A file with no `phase` is simply not enrolled.
5. **Merge with local override,** keyed on the frontmatter `name` — *not* the
   filename. A local file **overrides** a plugin agent of the same `name`
   entirely; there is no field-level merge. Duplicate names within one directory
   warn and resolve last-wins.
6. **Validate — fatally.** A `phase` outside the 8 hooks, or a `mode` other than
   `single`/`batch`, **aborts with exit 3**, naming every offending file and the
   fix. Validation is **global**: a bad value in a `post-commit` agent aborts a
   `pre-plan` query, so the problem surfaces at the earliest moment rather than
   hours later. A non-numeric `order` is milder — it warns and falls back to
   `100`.
7. **Filter** to `HOOK` when `--hook` is given.
8. **Sort** by `order` ascending (missing = `100`), then `name`
   case-insensitively. See [Sort and tie-break](#sort-and-tie-break).

Other flags: `--json` for machine-readable output, `--fingerprint` /
`--expect=` for [drift detection](#drift-detection), `--help` for usage. Run it
with no `--hook` for a by-hand debugging view of all 8 hooks — that is the
fastest answer to "why didn't my agent fire?".

### Drift detection

Enrollment must not change partway through a run, or the back half of an
orchestration executes a different pipeline than the plan was built against.

`--fingerprint` prints a stable digest of the fully-resolved enrollment across
**all 8 hooks**:

```
discover-hooks-fingerprint-v1 <64-hex>
```

`plan-create` writes this to `.claude/plans/{plan-name}/.hook-fingerprint`, and
`plan-orchestrate` passes it back as `--expect=<value>` on every hook call. If
enrollment changed, the script exits **4** and names what changed; HCF halts.

The hash covers each agent's origin (`plugin` or `local`), `name`, `phase`,
`order`, and `mode` — never paths, mtimes, or sizes, so it is stable across
machines and reinstalls. Including origin matters: without it, shadowing a
plugin agent with a local file carrying identical enrollment keys but entirely
different instructions would be a silent agent swap.

**Agent body content is deliberately not hashed.** Editing an agent's prose,
description, or `tools` list is *not* drift. Hashing bodies would fire on every
typo fix and on any plugin upgrade touching prose, which would make the
mechanism unusable. Drift detection answers "did the pipeline change?", not
"did this agent change?".

**Self-inflicted drift.** A plan whose own subject matter is agent files will
legitimately change enrollment mid-run and halt itself. That is correct, but
surprising — the escape hatch is to delete `.hook-fingerprint` and re-run to
re-baseline, which the exit-4 message says. Nothing else HCF does mid-run
touches `agents/` or `.claude/agents/`.

### Resolving the plugin `agents/` directory

The script self-locates: its `agents/` directory is always
`$(dirname "$0")/../agents`, so it must stay in the plugin's `hooks/` directory
alongside `agents/`. If that directory cannot be found the script **exits 1**
rather than proceeding with local agents only — silently dropping the plugin's
own bundled agents is precisely the failure mode being fixed.

(`project-update` separately resolves the plugin directory as "two levels up
from this skill file" for its legacy-migration path. That convention still
applies there and is unrelated to discovery.)

### Empty-hook fast path

A hook is **empty** when `discover-hooks.sh --hook=<HOOK>` exits **0** with
**empty stdout**. A non-zero exit is *not* an empty hook — see the table above.

When a hook is empty:
- **Return immediately.**
- Perform **no logging and no narration.** This means more than suppressing the
  resolved-order line: do **not** explain the empty result either. Do not state
  which agents declared no `phase`, do not name the hook, do not say it is empty
  or being skipped, and do not describe the enrollment analysis you just did.
  The entire discovery routine for an empty hook is **silent and internal** —
  nothing about it reaches the user-visible output.
- Do **no work** — no staging, no diffing, no subagent spawns.
- Do **not narrate the script call either.** A filtered query on an empty hook
  prints zero bytes precisely so there is nothing to echo. Do not say "the
  discovery script returned no agents" — that is the same narration wearing a
  different hat.

This keeps unused hooks free of overhead and noise. The common failure mode is
"thinking out loud" — narrating *why* a hook is empty (e.g. "standards-enforcer
and tdd-worker declare no phase, so this hook is a no-op"). That narration is
exactly what the fast path forbids: an empty hook is invisible, full stop. Only
a **non-empty** hook produces visible output (its printed resolved order).

The script itself is louder than its callers on purpose: run with **no**
`--hook`, it prints an explicit `(empty — …)` marker for every unenrolled hook,
because that mode exists for a human debugging by hand. The silence rule governs
what *skills* emit, not what the script can tell you when you ask it directly.

### Sort and tie-break

Order is fully deterministic:

1. Sort by `order`, ascending (integer). A **missing** `order` is treated as
   `100`.
2. For agents with **equal** `order`, tie-break by `name`, **case-insensitive,
   ascending** (A before B). For example, `Apple` and `banana` with the same
   `order` sort as `Apple`, `banana`.

## Legacy `pipeline.md`

HCF no longer reads `pipeline.md` as configuration; frontmatter enrollment is
always authoritative. A leftover `.claude/pipeline.md` is flagged by the
`SessionStart` hook (`hooks/detect-legacy-pipeline.sh`) and, more importantly,
**blocks the planning workflow**: `PreToolUse` (`gate-skill.sh`) and
`UserPromptExpansion` (`gate-command.sh`) deny `plan-create`/`plan-orchestrate`
while the file exists, regardless of how they are invoked. `/project-update` is
left runnable — it is the only component that migrates or deletes the file, and
once it does, the gates open automatically.

## TDD enforcement hooks (not agent hook points)

Separate from the 8 agent hook points above, HCF registers Claude Code hooks in
`hooks/hooks.json` that check every `tdd-worker` while it works. They need no
enrollment and do nothing outside a `tdd-worker` (the main session and every
other agent are untouched). This section is the reference for them; the README
only summarises it.

| Claude Code hook | Script | Does |
|---|---|---|
| `PreToolUse` (`Edit\|Write\|MultiEdit\|NotebookEdit\|Bash`) | `tdd-guard.sh` | Refuses a call that would break the TDD method right now, with a reason telling the worker what to do instead |
| `SubagentStop` | `tdd-subagent-stop.sh` | Runs `verify-tdd.sh` on the worker's whole transcript and writes the verdict that `plan-orchestrate` Step 6 reads |

Both call `verify-tdd.sh`, so the guard and the verifier judge by the same
rules. `revert-task.sh` undoes a rejected worker's changes. They need `jq`
(transcripts) and `python3` (revert).

### Who is a worker

An agent whose type ends in `tdd-worker` (`hcf:tdd-worker`, or a project-local
override), or, when Claude Code reports no agent type, a subagent whose first
prompt has a `## Task File Path` heading.

### What the guard refuses

- **A production change with no failing test.** A production file can change
  only after a test run *filtered to the current requirement* has failed.
  Adding a new test locks production again until that test has failed.
- **Batches of tests.** A second new test before the last one has been run, or
  more than one new test in a single edit.
- **Project files changed from Bash.** Files change only through
  Edit/Write/MultiEdit, so every change is recorded and can be checked and
  reverted. Refused: redirects (including `cat <<EOF > file`), `tee`,
  `sed -i`, `cp`/`mv`/`ln`/`install`/`rsync`/`touch`/`truncate`/`dd of=`,
  `patch`, `curl -o`/`wget`, code generators such as `artisan make:`,
  `sh -c`/`bash -c`/`eval` or a script piped into a shell that does any of
  these, and interpreter scripts that write, delete or rename files. This
  includes the task file: checkboxes are ticked with Edit.
- **Deletions, renames and commits.** `rm`, `unlink`, `rmdir`, `find -delete`,
  `git rm`, `git mv`, and `git commit` along with every other git command that
  changes the working tree (`apply`, `checkout`, `restore`, `stash`, `switch`,
  `reset --hard`, `clean -f`, `merge`, `rebase`, ...). A deletion cannot be
  reverted from the transcript, and only the orchestrator commits. Files git
  ignores (caches, build output) and paths outside the repository may be
  deleted. A worker that needs a project file gone names it in the task file's
  Implementation Notes, and the orchestrator removes it once the task is
  accepted.
- **Changes to another checkout** of the same repository (the main worktree or
  another `git worktree`). Paths outside the repository, such as `/tmp`, stay
  allowed.
- **Formatter runs without an explicit file list**, which would rewrite other
  tasks' files.
- **Edits that change the task's requirements**: removing or renaming a
  requirement line, or labelling one `(guard)`.
- **Any file change before the rules are read.** Every file the prompt names on
  an `IN FULL` line (an absolute path, in backticks) must have been opened with
  the Read tool first; only the task file is exempt.

### What counts as red

A test run is a command whose *executed* program is a test runner, after
wrappers such as `docker compose exec <service>`, `npx`, `python -m`, `env` or
`sh -c`; never a runner named in a comment or as an argument to
`echo`/`ls`/`grep`. Runners are recognised by name (Pest, PHPUnit, Jest,
Vitest, pytest, RSpec, Mocha, `go test`, `cargo test`, `npm`/`yarn`/`pnpm`/`bun
test`, `composer`/`mix`/`artisan test`, and more) or listed in
`.claude/hcf.json` (see the README's
[Test Runners](README.md#test-runners)).

A run is red for a requirement only when it is filtered to that requirement
and its output shows a test failure: a failing-test line as Pest, PHPUnit,
Vitest, Jest, pytest, Go, Rust or RSpec print it, a failure count
(`Tests: 1 failed`, so output trimmed with `tail` still counts), an assertion
failure, or a compile or collection failure. Such a line counts only at the
start of an output line (a passing test named "…FAILED…" is not a failure) and
never when the command printed it itself (`echo "FAILED …"`). Infrastructure
errors (Docker or a database unreachable, command not found, no tests found,
out of memory, a parse or syntax error) are never red.

Names are compared normalised, so `it creates a user`, `test_creates_a_user`,
`testCreatesAUser` and `TestCreatesAUser` match. A run only speaks for a
requirement whose test this worker has written, under that name.

### Requirements come from the prompt

The requirement list (names and `(guard)` labels) is read from the
`## Your Task` section of the worker's first prompt, where `plan-orchestrate`
pastes the task file, so a worker cannot change what it is held to. Every
requirement there counts, ticked or not. Removing or renaming one in the task
file, or labelling one `(guard)`, is a violation; a requirement the worker adds
is verified like the rest. Only when the prompt has no checklist is the task
file read instead.

A requirement labelled `(guard)` (by `plan-create`, for behaviour an earlier
requirement in the same task already delivers) only has to be run on its own;
it may pass on the first run.

### First-run passes are cut back

When any other test passes on its first filtered run, some production code
already delivers it. The worker **cuts it back**: until the pass is answered
the guard allows only removal-only Edits to production files (the edit's new
text keeps some of the old text's tokens in order and adds none), and once the
test fails on a filtered run the code is rebuilt in GREEN. The verifier counts
that as red before green; a cut-back not followed by a failing run of that
requirement (before any other production change or new test) is a violation.
The worker may instead fix a wrong test.

Only behaviour that **no production code** delivers (a language or framework
guarantee) may be recorded in the task file as
`PASSED-FIRST: <requirement> — no-code: <why>`, which gives a `REVIEW` verdict
for the orchestrator to check. A `PASSED-FIRST` line without `no-code:` is a
violation.

### Tasks without test requirements

A task whose checklist has no test names (docs, config) has no method to
check, so production files may be edited freely with Edit/Write and the
verdict is `NONE`. Everything else still applies: Bash writes, deletions,
other checkouts and bare formatter runs are refused, and reported as
violations (`FAILED`) if one got through.

### Verdicts

When a worker stops, the stop hook writes the verdict's first line:

| Verdict | Meaning |
|---|---|
| `OK` | every requirement went red before green, one at a time |
| `REVIEW` | no violations, but a `PASSED-FIRST … no-code:` claim needs checking |
| `FAILED` | the method was not followed; the violations follow, one per line. With an `unfinished: <n> requirement(s) not attempted` line, the only violations are requirements never started, and the orchestrator resumes the same worker instead of reverting |
| `NONE` | the task has no test requirements, so the method was not checked |
| `ERROR` | the check could not run; an `error:` line says why |

A `FAILED` or `ERROR` worker is stopped once more and told to end with
`TASK_FAILED`; a clean one whose last line is neither `TASK_COMPLETE` nor
`TASK_FAILED: <reason>` is asked once for it.

### Records

All under `<plan>/.tdd/`, named after the task file including its `.md`. The
plans directory is never committed, so neither are these.

| File | Written by | Holds |
|---|---|---|
| `001-foo.md.verdict` | stop hook | the verdict, a `transcript:` line naming the transcript it judged, then the verifier's report |
| `001-foo.md.transcript` | guard, on each file change it allows | the worker's transcript path, so an interrupted worker (no stop hook, no verdict) can still be reverted |
| `001-foo.md.<agent id>.calls` | guard | each file change it allowed, as transcript lines. The transcript can lag behind tools streamed in one message, so the guard reads these back with it |

### Exact revert

`revert-task.sh <task file> <transcript>` undoes exactly one worker's file
changes, from the before-and-after content Claude Code records with each
Edit/Write: it deletes files the worker created and restores the others to
their content from before its first change. Earlier tasks' changes to the same
files survive, and so do changes a parallel task made afterwards (the worker's
own edits are undone around them, or the file is left untouched and reported,
exit 1). `--dry-run` lists what it would do. `git checkout` is never used for
this: it would also discard earlier tasks' uncommitted work.

### Fresh workers start clean

The verifier judges one worker's transcript against every requirement in its
prompt. Work an earlier worker did is invisible to it, so `plan-orchestrate`
never hands a partly done task to a fresh worker: before a retry, and for a
task an interrupted run left `in_progress`, it reverts the earlier worker's
changes and resets the task file (or blocks the task when it cannot). Only the
*same* worker, resumed in the same session, continues an unfinished task.

### What is a test file

By its path relative to the project: under `tests/`, `test/`, `spec/`,
`specs/` or `__tests__/`, or named `FooTest.php`, `foo.test.ts`,
`foo.spec.js`, `foo_test.go`, `foo_spec.rb`, `FooSpec.rb` or `test_foo.py` (a
file named just `Spec.php` or `Test.php` is production code). Markdown, the
plan directory and paths outside the project are ignored. Every other file is
production.

**Limit:** tests written inside a production file (Rust's inline
`#[cfg(test)] mod tests`, Python doctests) are not recognised: the file is
production, so the test cannot be added before a failing run exists. Put such
tests in a separate test file (`tests/` for Rust).

### Fails closed

Inside a worker the hooks never allow what they cannot check. If the guard
cannot judge a call (the verifier errors), it refuses the call. If a worker's
context cannot be established at all (`jq` missing, an unreadable transcript,
no or an unreadable task file), the guard refuses every file change and the
stop hook writes an `ERROR` verdict where it can and tells the worker to end
with `TASK_FAILED: TDD hooks could not run — <why>`.

### Debugging

Set `HCF_TDD_PROBE_LOG=/path/to/file` in the environment Claude Code runs in
and both hooks append the raw JSON input of every call to that file.
`verify-tdd.sh <task file> <transcript>` can be run by hand on any worker
transcript; its header documents the rules (R1 to R6) in full.
