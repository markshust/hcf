---
name: project-update
description: Update project configuration to match the latest HCF plugin defaults. Use when the HCF plugin has been updated and you want to sync your project's config.
disable-model-invocation: true
---

Sync a project's HCF configuration with the latest plugin defaults. Non-destructive — adds missing files, generates what's needed, and flags differences in existing ones.

## Prerequisites

This skill requires that `/project-setup` has been run at least once. If `CLAUDE.md` and `.claude/` don't exist, tell the user to run `/project-setup` first and stop.

## Execution Steps

### Step 1: Verify Project Is Configured

Check that the project has been set up:

```bash
ls CLAUDE.md .claude/ 2>/dev/null
```

If either is missing, stop and tell the user:
> This project hasn't been set up yet. Run `/project-setup` first.

### Step 2: Inventory Expected Files

These are the files that `project-setup` creates. Check which exist:

| File | Source |
|------|--------|
| `CLAUDE.md` | Generated from project context |
| `.claude/testing.md` | Generated from project context |
| `.claude/code-standards.md` | Generated from project context |
| `.claude/architecture.md` | Generated from project context |

> `.claude/pipeline.md` is **legacy** and is no longer an expected ongoing file. HCF now enrolls agents via frontmatter (see [HOOKS.md](../../HOOKS.md)). If a `.claude/pipeline.md` exists, it is handled by the one-time migration in Step 3 — do not treat its absence as a missing file.

Collect the list of missing files. Do NOT act on them yet — just note them.

### Step 3: Migrate Legacy `pipeline.md` to Frontmatter

This is a **one-time migration** from the legacy central registry (`.claude/pipeline.md`) to per-agent frontmatter enrollment (the model described in [HOOKS.md](../../HOOKS.md)). This step **detects** what needs to happen here; the actual changes are applied in Step 7 after a single confirmation.

#### 3a. Detect the legacy file

Check whether `.claude/pipeline.md` exists:

```bash
ls .claude/pipeline.md 2>/dev/null
```

- **Absent** → the project is already on the frontmatter model. Record migration status as *"no legacy `pipeline.md` — already on frontmatter"* and **skip the rest of Step 3 entirely**. There is nothing to migrate.
- **Present** → continue to 3b.

#### 3b. Compare against the known default

The migrator **must not** read the plugin's `pipeline.md` for comparison — that file is being removed from the plugin and will no longer exist. The known shipped default is embedded inline here:

```markdown
# Pipeline

## post-plan
- devils-advocate

## post-implementation
<!-- - standards-enforcer -->
```

Structurally, the default means: **`devils-advocate` is the only active agent** (under `post-plan`), and `post-implementation` has only a commented-out `standards-enforcer` (no active agents).

Read the project's `.claude/pipeline.md` and parse it into `(phase heading → [active agent names])`, where an "active" agent is a non-commented `- {name}` bullet under a `## {phase}` heading. Commented lines (`<!-- ... -->`) are NOT active agents.

- **Matches the default** (the only active agent across all phases is `devils-advocate` under `post-plan`, and nothing else is active) → migration is a **no-op delete**: the shipped frontmatter (`devils-advocate` with `phase: post-plan`) already reproduces it, so no agent needs stamping. Record migration status as *"legacy `pipeline.md` found (unchanged default) — will delete; frontmatter already reproduces it"*.
- **Customized** (any active agent other than the default `devils-advocate`/`post-plan` arrangement — e.g. an extra agent, a reordering, a different phase, or an uncommented `standards-enforcer`) → record migration status as *"legacy `pipeline.md` found (customized) — will migrate its active entries to frontmatter (preserving what runs) and delete it"*, and compute the per-agent migration plan in 3c (which skips agents the plugin already enrolls, stamps local agents in place, and copies + enables any plugin agent the project had turned on).

#### 3c. Build the per-agent migration plan (customized pipelines only)

Parse every `## {phase}` heading and, **in listed order**, every active `- {name}` agent bullet beneath it.

**Guiding principle: migration is behavior-preserving.** Whatever was *active* in `pipeline.md` must remain active under the new frontmatter model — the project's effective pipeline does not change. A local file is created **only when it is needed to reproduce an enrollment the plugin default does not already provide**: that way we never leave a redundant shadow, but we also never silently disable something the project was running.

For each `(phase, position, name)`, resolve the agent against both `.claude/agents/{name}.md` (local) and `{plugin-root}/agents/{name}.md` (plugin — resolve the plugin dir two levels up from this skill file), then classify by what it takes to keep the agent enrolled at this `phase`:

1. **Already enrolled by the plugin at this same phase** — no differing local copy, and the current plugin's `agents/{name}.md` already declares this `phase` (e.g. `devils-advocate` under `post-plan`). → **Skip entirely — no file.** The plugin already runs it here; a copy would be a redundant shadow. Record as *"already provided by the plugin — no action"*.
2. **Genuinely local / locally-modified agent** — a local `.claude/agents/{name}.md` exists and either has no plugin counterpart or its **body differs** from the plugin's. → **Stamp it in place** with `phase`/`order`/`mode`. No copy (already local).
3. **Plugin agent the project ENABLED but the plugin ships off / elsewhere** — no differing local copy, and the plugin does NOT declare this `phase` (e.g. an uncommented `standards-enforcer` under `post-implementation`, which the plugin ships dormant). The project was actively running it, so migration must **preserve that**: **copy the plugin's `agents/{name}.md` into `.claude/agents/{name}.md` and stamp** `phase`/`order`/`mode`. This is the *only* mechanism to keep a dormant plugin agent enabled, and it is required here — without it the migration would silently disable a capability the project was using. (The plugin ships such agents with their `phase` **commented out**; the stamp must write **active** `phase`/`order`/`mode` keys, replacing any commented enable-example carried over in the copy, so the agent is actually enabled.) (Note in the report: this local copy will not receive future plugin updates to that agent's body — the inherent cost of enabling a dormant plugin agent.)
4. **Unresolvable** — no local file and no plugin file by that name. → A dangling legacy reference; record as a ⚠ for the user. Do not fabricate a file.

**Frontmatter to stamp** (cases 2 and 3):
   - `phase`: the `## {phase}` heading the agent is listed under.
   - `order`: the agent's **1-based listed position within that phase × 10** (first → `10`, second → `20`, …).
   - `mode`: apply the **legacy body heuristic exactly once, here** (its last use ever): read the agent's **body** — if it mentions operating in **"batch"** or over a **"file list"**, stamp `mode: batch`; otherwise `mode: single`.
   - No `on-failure` or any other field — the schema (HOOKS.md) defines only `phase`, `order`, `mode`.

Record this plan; it is applied in Step 7. **Never change what the project runs:** an agent already enrolled by the plugin is left alone; a genuinely-local agent is stamped; a plugin agent the project had enabled is copied + stamped so it keeps running; a dangling reference is reported. The end state reproduces the project's effective pre-migration pipeline exactly.

### Step 4: Check .gitignore Entries

Verify that `.gitignore` contains required entries:

```
.claude/ralph-loop.local.md
```

For each missing entry, append it to `.gitignore`.

### Step 5: Check CLAUDE.md References

Read the project's `CLAUDE.md` and verify it references the `.claude/` config files: `testing.md`, `code-standards.md`, and `architecture.md`.

Also check whether `CLAUDE.md` contains a **Feature Development section** that wires up the planning workflow. Detect it by searching for a mention of the `hcf:plan-create` skill (a project may title the section differently, so match on the skill reference, not the heading text). If no reference to `plan-create` exists anywhere in `CLAUDE.md`, the section is **missing** — flag it for **automatic addition** in Step 7. This matters because without it `CLAUDE.md` never tells Claude to route feature work through HCF, and a strongly-worded "do this instead" elsewhere in `CLAUDE.md` (e.g. "start from this checklist") can suppress the skill's auto-trigger. If a `plan-create` reference already exists, record it as ✓ and do not touch it (the project may have customized the wording).

Also scan `CLAUDE.md` for any **stale reference to `pipeline.md`** — either the `<pipeline>` include block, or a config-file bullet/link an older `project-setup` left behind (e.g. `` - `pipeline.md` - Autonomous development workflow agents `` under a "Files" / "Detailed Configuration" section). `pipeline.md` is legacy and no longer read, so any such reference must go. Flag every stale reference for **automatic removal** in Step 7. This is independent of the Step 3 migration: a project that already migrated (so `pipeline.md` is gone) can still carry a stale reference, and this run must clean it.

Note any missing references.

### Step 6: Report and Confirm

Output a summary of everything found, using ✓ for current items, ✗ for items that need fixing, and ⚠ for items that need user attention:

```
HCF Project Update

Files:
  ✓ CLAUDE.md — exists
  ✓ .claude/testing.md — exists
  ✓ .claude/code-standards.md — exists
  ✓ .claude/architecture.md — exists

Pipeline migration:
  ⚠ legacy .claude/pipeline.md found (customized) — will migrate active entries to frontmatter (preserving what runs) and delete it:
      • devils-advocate    (post-plan)          → already provided by the plugin; no action
      • standards-enforcer (post-implementation) → enabled via frontmatter (copied into .claude/agents/ so it keeps running; won't auto-update with the plugin)

.gitignore:
  ✓ .claude/ralph-loop.local.md — present

CLAUDE.md References:
  ✓ testing.md — referenced
  ✓ code-standards.md — referenced
  ✓ architecture.md — referenced
  ✗ Feature Development section — missing; will add automatically (wires up hcf:plan-create / plan-orchestrate)
  ⚠ pipeline.md — stale reference(s) found; will remove automatically (legacy, no longer read)
```

The `✗ Feature Development section — missing` line appears only when `CLAUDE.md` has no reference to `hcf:plan-create`. It is added automatically in Step 7 (purely additive — a new section, no existing content is changed). Omit the line when a `plan-create` reference already exists.

The `⚠ pipeline.md — stale reference(s) found` line appears only when `CLAUDE.md` still references the legacy file (the `<pipeline>` include and/or a config-file bullet). Those are scrubbed automatically in Step 7 — independent of any migration, so this line can appear even for a project that already migrated. Omit the line when there are no such references.

The **Pipeline migration** line reflects the Step 3 detection and is one of:

- *no legacy `.claude/pipeline.md` — already on frontmatter* (✓; nothing to do)
- *legacy `.claude/pipeline.md` found (unchanged default) — will delete; frontmatter already reproduces it* (⚠ no-op delete)
- *legacy `.claude/pipeline.md` found (customized) — will migrate active entries to frontmatter (preserving what runs) and delete it* (⚠; list each active agent with its 3c outcome: **already provided by the plugin** (skipped, no file), **stamped** in place (local/modified agents), or **enabled via a local copy** (a plugin agent the project had turned on that the plugin ships dormant).)

When a customized `pipeline.md` is present, also include this note so the situation is explicit:

> Note: HCF no longer reads `.claude/pipeline.md` at all — agents enroll purely via frontmatter, and the shipped `devils-advocate` already declares `phase: post-plan`. Migration moves your **active** pipeline into frontmatter **without changing what runs**: agents the plugin already enrolls are left as-is (no redundant copy), your local/modified agents are stamped in place, and any **plugin agent you had enabled that ships dormant** (e.g. an uncommented `standards-enforcer`) is **copied locally and enabled** so it keeps running. Then the stale file is removed.

If there are any ✗ or ⚠ items, ask the user a **single** confirmation:
> I found {N} items that need attention (including a one-time `pipeline.md` → frontmatter migration). Want me to apply them? The migration runs in one automatic pass — no per-agent prompts.

If the user confirms, proceed to Step 7 and apply **everything** (including the full migration) in a single pass. If everything is current, output "All up to date!" and stop.

### Step 7: Apply Fixes

Process each fixable item in order. **Never overwrite existing files. Never modify files without confirmation.**

#### Missing generated files (testing, code-standards, architecture)

For each missing file, generate it by auto-detecting from the project context — the same approach `project-setup` uses:

1. Scan the project for configuration files (`composer.json`, `package.json`, `Cargo.toml`, etc.)
2. Read existing `.claude/` config files for context about the project
3. Read `CLAUDE.md` for project identity and conventions
4. Generate the missing file following the template structure from `project-setup`
5. Show the user what will be created and confirm before writing

#### Legacy `pipeline.md` migration (one automatic pass)

If Step 3 found a legacy `.claude/pipeline.md`, run the **entire** migration now, automatically, in a **single pass** — there are **no per-agent prompts** (the one confirmation in Step 6 already covers all of it):

1. **No-op-delete case** (unchanged default): delete `.claude/pipeline.md`. The shipped `devils-advocate` frontmatter already reproduces the default, so nothing is stamped.

2. **Customized case:** execute the per-agent plan from Step 3c for **every** phase and **every** listed active agent, in one go. Per the 3c classification:
   - **Already provided by the plugin at that phase** → do nothing (the plugin already enrolls it; no file created).
   - **Genuinely local / modified agent** → stamp its frontmatter in place with `phase` (its heading), `order` (1-based listed position × 10), and `mode` (legacy body heuristic from 3c). Only `phase`/`order`/`mode`. No copy.
   - **Plugin agent the project had enabled but the plugin ships dormant** → **copy** the plugin's `agents/{name}.md` into `.claude/agents/{name}.md`, then **stamp** the same `phase`/`order`/`mode`, so the agent keeps running. This is required to preserve behavior (report the no-auto-update trade-off).
   - Then delete `.claude/pipeline.md`.
   - **Never change what the project runs:** every active agent stays enrolled — via the plugin default, an in-place stamp, or a copy-to-enable. If a genuinely-local agent cannot be stamped, or an entry is unresolvable, **report** it and leave `pipeline.md` in place rather than losing the enrollment.

(The `pipeline.md` references in `CLAUDE.md` are scrubbed separately, below — that step runs whether or not a migration happened.)

#### Scrub stale `pipeline.md` references from `CLAUDE.md` (automatic; always runs)

`pipeline.md` is legacy and no longer read, so `CLAUDE.md` must not reference it. Remove **every** stale reference flagged in Step 5 **automatically** — edit `CLAUDE.md` directly, do not merely suggest. This runs regardless of whether a migration happened this session (a project that migrated earlier may still carry a stale reference):

1. **The `<pipeline>` include block, if present** (only HCF's own repo `CLAUDE.md` has one; a generated user `CLAUDE.md` normally does not):

   ```
   <pipeline>
   @.claude/pipeline.md
   </pipeline>
   ```

   Remove the whole block. If absent, skip silently.

2. **Any other line referencing `pipeline.md`** — e.g. a config-file inventory bullet such as `` - `pipeline.md` - Autonomous development workflow agents `` under a "Files" / "Detailed Configuration" section. Remove each such line, leaving the surrounding lines and the section heading intact (do not delete the whole section).

After scrubbing, `CLAUDE.md` must contain zero references to `pipeline.md`. List each removed line in the Step 8 summary.

#### Missing Feature Development section (automatic; additive)

If Step 5 flagged the Feature Development section as missing (no `hcf:plan-create` reference anywhere in `CLAUDE.md`), add it automatically. This is purely additive — insert a new section, never rewrite or remove existing content. Place it **as the first section**, immediately after the title (`# ...`) and any 1–2 line project description that follows it, and **before the first `##` heading**. Prominence is intentional: an early section reliably overrides competing directives elsewhere in `CLAUDE.md` (e.g. "start from this checklist") that would otherwise suppress the planning trigger. Insert this block verbatim — it is intentionally project-agnostic:

```markdown
## Feature Development

For any feature or change beyond a simple fix, use the `hcf:plan-create` skill to trigger the autonomous development workflow. Never use Claude Code's built-in plan mode. After writing a plan, ask the user if they want to execute it, and provide the command to run it later with the `hcf:plan-orchestrate` skill.

Use this workflow for: new features, multi-file changes, anything requiring multiple steps or tests.

Skip for: quick bug fixes, single-line changes, questions, documentation. When skipped, still ensure appropriate tests exist for any added functionality.
```

Do this only when no `plan-create` reference exists — never duplicate or overwrite a section the project already has, even if its wording differs from the block above.

#### Missing CLAUDE.md references

Report which config files aren't referenced and suggest the snippet to add. Do NOT modify `CLAUDE.md` automatically — show the user what to add and let them decide.

#### Missing .gitignore entries

Append silently — these are non-destructive housekeeping entries.

### Step 8: Final Summary

After all fixes are applied, output:

```
Updates applied:
  ✓ Created .claude/architecture.md
  ✓ Added Feature Development section to CLAUDE.md (wires up hcf:plan-create / plan-orchestrate)
  ✓ Migrated legacy pipeline.md → frontmatter (preserved what runs):
      • devils-advocate    → already provided by the plugin (no change)
      • standards-enforcer  → enabled via frontmatter (copied into .claude/agents/ so it keeps running)
  ✓ Deleted .claude/pipeline.md
  ✓ Removed stale pipeline.md reference(s) from CLAUDE.md

All done!
```

If the migration was a no-op delete, the summary instead reads `✓ Removed redundant .claude/pipeline.md (frontmatter already reproduced it)`. If `pipeline.md` was absent, omit the migration lines entirely — but still show the `✓ Removed stale pipeline.md reference(s) from CLAUDE.md` line if any references were scrubbed (an already-migrated project can still have them). If `CLAUDE.md` had no `pipeline.md` references, omit that line too. If `CLAUDE.md` already had a `plan-create` reference, omit the Feature Development line.

## Error Handling

- The migration resolves each entry against the plugin dir (two levels up from this skill file) to classify it. If the plugin directory cannot be resolved, report the error and do NOT delete `pipeline.md` until every entry is classified — surface the unresolved entries and leave the file in place so nothing is silently dropped or disabled.
- The migration copies a plugin agent into `.claude/agents/` **only** to preserve an enablement the plugin default doesn't provide (case 3 — a dormant plugin agent the project had turned on); it never copies one the plugin already enrolls (that would be a redundant shadow). When stamping an existing local agent, edit it in place to add `phase`/`order`/`mode` — never replace it wholesale.
- **Removing stale `pipeline.md` references from `CLAUDE.md` is automatic** — `pipeline.md` is legacy and no longer read, so it must not be referenced (see Step 7's scrub subsection; this runs even when no migration happened). **Adding** missing config-file references (Step 7 "Missing CLAUDE.md references") stays suggest-only — never auto-add those.
- **Adding a missing Feature Development section to `CLAUDE.md` is automatic** but **purely additive** — append the project-agnostic block, never rewrite or delete existing content, and never add it when a `plan-create` reference already exists (the project may have customized the wording). This is what carries the workflow wiring across an upgrade from a pre-frontmatter version.
- **Never change what the project runs.** Every agent active in the legacy `pipeline.md` ends up enrolled the same way under frontmatter — via the plugin default, an in-place stamp, or a copy-to-enable. Only a truly unresolvable entry is reported and skipped, with `pipeline.md` left in place so the enrollment isn't lost.
- If auto-detection fails for a generated file, ask the user the relevant questions interactively (same as project-setup would)
