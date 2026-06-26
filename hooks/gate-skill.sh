#!/usr/bin/env bash
# HCF PreToolUse hook (matcher: Skill). Covers the path where Claude invokes the
# Skill tool. Denies plan-create / plan-orchestrate while a legacy
# .claude/pipeline.md exists, forcing migration via /hcf:project-update first.
# Everything else (including /hcf:project-update itself) is left untouched.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/pipeline-status.sh"

input="$(cat)"

# Only gate the HCF planning skills. project-update and all other skills pass through.
case "$input" in
  *plan-create*|*plan-orchestrate*) ;;
  *) exit 0 ;;
esac

[ "$(pipeline_status)" = "none" ] && exit 0

reason="HCF: this project still has a legacy .claude/pipeline.md. HCF now enrolls agents via frontmatter and no longer reads that file, so it must be migrated before the planning workflow can run. Tell the user to run /hcf:project-update first — it migrates any customizations into agent frontmatter and removes the stale file — then retry. Do not attempt to plan or orchestrate until the file is gone. Share this link so they can read about the change: https://github.com/markshust/hcf#pipeline"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
