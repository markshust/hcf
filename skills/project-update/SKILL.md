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
| `.claude/pipeline.md` | Copied from plugin's `pipeline.md` |

Collect the list of missing files. Do NOT act on them yet — just note them.

### Step 3: Compare Plugin-Sourced Files

For files that originate from the plugin (currently `pipeline.md`), compare the project's version against the plugin's default:

1. Read the plugin's default `pipeline.md` (from the plugin directory — resolve via the skill's own path, i.e., two levels up from this skill file)
2. Read the project's `.claude/pipeline.md` (if it exists)
3. Parse both to extract the list of agents per phase

**For each phase in the plugin's default:**
- If the phase doesn't exist in the project's pipeline, note that a new phase is available
- If the phase exists but is missing default agents, note which default agents are new

### Step 4: Check .gitignore Entries

Verify that `.gitignore` contains required entries:

```
.claude/ralph-loop.local.md
```

For each missing entry, append it to `.gitignore`.

### Step 5: Check CLAUDE.md References

Read the project's `CLAUDE.md` and verify it references the `.claude/` config files: `testing.md`, `code-standards.md`, and `architecture.md`. Skip `pipeline.md` — it's consumed internally by the HCF plugin, not by Claude directly.

Note any missing references.

### Step 5b: Validate hcf.json (if present)

`.claude/hcf.json` is an optional advanced configuration file that users create manually. Its absence is the normal case and must never be flagged or prompt a suggestion to create it.

If `.claude/hcf.json` exists:

1. Read and parse its contents.
2. Extract the `plansDir` value.
3. Apply each check below and collect any warnings. Use ⚠ for all findings here: nothing in this step is auto-fixable.

**Check A: containment rule**

If `plansDir` is an absolute path (starts with `/`) or contains `..` segments, add:
> ⚠ `.claude/hcf.json` — `plansDir` value "{value}" is invalid (absolute path or `..` segment). HCF will fall back to `.claude/plans`.

**Check B: directory existence**

If `plansDir` passes Check A but the directory it references does not exist, add:
> ⚠ `.claude/hcf.json` — `plansDir` "{value}" does not exist. Create it or correct the path.

**Check C: stale default plans**

If `plansDir` passes Check A and differs from `.claude/plans`, check whether `.claude/plans` still contains any subdirectories. If it does, add:
> ⚠ `.claude/hcf.json` — `plansDir` is set to "{value}" but `.claude/plans` still contains plan folders. Move them to "{value}" or remove them if they are no longer needed.

Never create, modify, or suggest creating `.claude/hcf.json`. Only report.

### Step 6: Report and Confirm

Output a summary of everything found, using ✓ for current items, ✗ for items that need fixing, and ⚠ for items that need user attention:

```
HCF Project Update

Files:
  ✓ CLAUDE.md — exists
  ✓ .claude/testing.md — exists
  ✓ .claude/code-standards.md — exists
  ✓ .claude/architecture.md — exists
  ✓ .claude/pipeline.md — exists (customized)

Pipeline:
  ✓ post-plan phase — up to date
  ⚠ post-implementation phase — plugin default includes 'standards-enforcer', project pipeline does not (intentional?)

.gitignore:
  ✓ .claude/ralph-loop.local.md — present

CLAUDE.md References:
  ✓ testing.md — referenced
  ✓ code-standards.md — referenced
  ✓ architecture.md — referenced

Advanced Config:
  ✓ .claude/hcf.json — present (plansDir: ".claude/my-plans")
```

If `.claude/hcf.json` is absent, omit the "Advanced Config" section entirely. Never list it as missing or suggest creating it.

If there are any ✗ or ⚠ items, ask the user:
> I found {N} items that need attention. Want me to fix them? I'll walk you through each one.

If the user confirms, proceed to Step 7. If everything is current, output "All up to date!" and stop.

### Step 7: Apply Fixes

Process each fixable item in order. **Never overwrite existing files. Never modify files without confirmation.**

#### Missing generated files (testing, code-standards, architecture)

For each missing file, generate it by auto-detecting from the project context — the same approach `project-setup` uses:

1. Scan the project for configuration files (`composer.json`, `package.json`, `Cargo.toml`, etc.)
2. Read existing `.claude/` config files for context about the project
3. Read `CLAUDE.md` for project identity and conventions
4. Generate the missing file following the template structure from `project-setup`
5. Show the user what will be created and confirm before writing

#### Missing plugin-sourced files (pipeline.md)

Read the plugin's default and create it in the project. No confirmation needed — this is a default.

#### Pipeline differences

For each new phase or missing default agent, ask the user individually:
> The plugin default includes '{agent-name}' in the {phase} phase. Add it? (y/n)

Only add agents the user approves. Never remove agents the user has added.

#### Missing CLAUDE.md references

Report which config files aren't referenced and suggest the snippet to add. Do NOT modify `CLAUDE.md` automatically — show the user what to add and let them decide.

#### Missing .gitignore entries

Append silently — these are non-destructive housekeeping entries.

### Step 8: Final Summary

After all fixes are applied, output:

```
Updates applied:
  ✓ Created .claude/architecture.md
  ✓ Added 'standards-enforcer' to post-implementation pipeline phase

All done!
```

## Error Handling

- If the plugin directory cannot be resolved, report the error and skip plugin-sourced file comparison
- Never overwrite existing files
- Never modify `CLAUDE.md` automatically — only suggest changes
- Never silently remove agents from the pipeline — only suggest additions
- If auto-detection fails for a generated file, ask the user the relevant questions interactively (same as project-setup would)
