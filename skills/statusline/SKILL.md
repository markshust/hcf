---
name: statusline
description: Install the HCF plan-progress statusline, a colored "Plan: N%" for the plan running in the current checkout. Keeps any existing statusline and appends to it.
disable-model-invocation: true
---

Install HCF's plan-progress segment into the user's Claude Code statusline.

While `plan-orchestrate` runs a plan, the segment shows `Plan: N%`: completed tasks count fully, and each in-progress task counts by the share of requirements its TDD worker has ticked. It runs red (0%) through yellow (50%) to green (100%), and disappears when no plan is `in_progress`. It reads the checkout the session is in, so a run inside a worktree shows that worktree's plan.

`{skill-base-dir}` below is the **`Base directory for this skill`** value stated when this skill loaded; `${CLAUDE_PLUGIN_ROOT}` is not set in a skill's Bash calls.

## Step 1: Install the shim

The plugin lives in a versioned path that changes on every update, so settings must never point into it. Copy the shim to a stable path; it finds the newest installed HCF each time it runs:

```bash
cp "{skill-base-dir}/../../hooks/statusline-shim.sh" "$HOME/.claude/hcf-statusline.sh"
chmod +x "$HOME/.claude/hcf-statusline.sh"
```

Re-running this skill only refreshes the shim; it is safe to repeat.

## Step 2: Wire it into `~/.claude/settings.json`

Read `~/.claude/settings.json` (treat a missing file as `{}`). Change only the `statusLine` key; leave every other key as it is. Then follow the first case that matches:

| Current `statusLine` | Set it to |
|---|---|
| `command` already contains `hcf-statusline` | Nothing to change. Say it is already installed. |
| Absent | `{"type": "command", "command": "bash ~/.claude/hcf-statusline.sh --default", "refreshInterval": 10}` |
| A `command` statusline | Keep its other keys. Set `command` to `bash ~/.claude/hcf-statusline.sh --wrap '<previous command>'`, escaping each `'` in the previous command as `'\''`. Add `"refreshInterval": 10` only if it has none. |

`--default` shows `Context: N%`, then ` · Plan: N%` while a plan runs. `--wrap` runs the previous command with the same input and keeps its output: the segment goes right after its `Context: N%` when the line has one (`Context: 15% · Plan: 60%`), otherwise at the end of the first line. `refreshInterval` matters: without it the statusline only redraws on conversation events, and an orchestrator waiting on background workers has none, so the percentage would sit still.

After editing, confirm the file is still valid JSON (`jq . ~/.claude/settings.json` or `python3 -m json.tool ~/.claude/settings.json`). If it is not, restore the previous content and stop.

## Step 3: Report

Tell the user, briefly:
- What changed (show the old and new `statusLine.command`).
- The segment appears the next time the statusline redraws, and only while a plan is `in_progress`.
- To undo, set `statusLine.command` back to the old value shown.
- If they keep a custom statusline script, they can instead call `bash ~/.claude/hcf-statusline.sh "$DIR"` from inside it, with `DIR` being `workspace.current_dir`, to place the segment where they like.
